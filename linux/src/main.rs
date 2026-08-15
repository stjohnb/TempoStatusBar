//! TempoStatusBar for Linux — a StatusNotifierItem tray showing days since the
//! last Jira Tempo worklog. See `docs/linux.md`.

mod config;
mod icon;
mod state;
mod tempo;

use std::path::Path;
use std::process::ExitCode;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::time::Duration;

use chrono::Local;
use clap::{Parser, Subcommand};
use ksni::blocking::TrayMethods;
use ksni::menu::StandardItem;
use ksni::MenuItem;

use crate::config::CredentialError;
use crate::state::{Severity, Status};
use crate::tempo::{TempoClient, TempoError};

/// Transport failures back off exponentially instead of hammering a Jira
/// instance that is behind a disconnected VPN.
const BACKOFF_START: Duration = Duration::from_secs(15);
const BACKOFF_FACTOR: u32 = 4;
const BACKOFF_MAX: Duration = Duration::from_secs(3600);

#[derive(Parser)]
#[command(
    name = "tempo-statusbar",
    version,
    about = "Tray indicator for days since your last Jira Tempo worklog"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Store the Jira API token in the desktop Secret Service
    SetToken,
    /// Write a sample config file if none exists
    Init,
}

enum Msg {
    Refresh,
    Quit,
}

struct TempoTray {
    status: Status,
    tx: Sender<Msg>,
}

impl ksni::Tray for TempoTray {
    fn id(&self) -> String {
        "tempo-statusbar".into()
    }

    fn title(&self) -> String {
        "TempoStatusBar".into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        vec![icon::render(&self.status)]
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        ksni::ToolTip {
            title: "TempoStatusBar".into(),
            description: self.status.tooltip(),
            ..Default::default()
        }
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        vec![
            StandardItem {
                label: self.status.menu_line(),
                enabled: false,
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Refresh now".into(),
                activate: Box::new(|tray: &mut Self| {
                    let _ = tray.tx.send(Msg::Refresh);
                }),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(|tray: &mut Self| {
                    let _ = tray.tx.send(Msg::Quit);
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

fn main() -> ExitCode {
    match Cli::parse().command {
        Some(Command::SetToken) => set_token(),
        Some(Command::Init) => init(&config::config_path()),
        None => run_tray(&config::config_path()),
    }
}

/// One poll: the status to show, how long to wait afterwards, and whether the
/// failure was a transport error (which triggers backoff).
struct Cycle {
    status: Status,
    poll_interval: Duration,
    network_error: bool,
}

fn poll_once(client: &TempoClient, config_path: &Path) -> Cycle {
    let config = match config::load(config_path) {
        Ok(config) => config,
        Err(error) => {
            return Cycle {
                status: Status::Error(error.to_string()),
                poll_interval: Duration::from_secs(300),
                network_error: false,
            }
        }
    };
    let poll_interval = Duration::from_secs(config.poll_interval_secs.max(60));

    let token = match config::load_token(&config) {
        Ok(token) => token,
        Err(CredentialError::NoStoredCredentials) => {
            return Cycle {
                status: Status::NoCredentials,
                poll_interval,
                network_error: false,
            }
        }
        Err(error) => {
            return Cycle {
                status: Status::Error(error.to_string()),
                poll_interval,
                network_error: false,
            }
        }
    };

    let today = Local::now().date_naive();
    let mut network_error = false;
    let status = match client.fetch_latest_worklog(
        &token,
        &config.jira_url,
        config.account_id.as_deref(),
        today,
    ) {
        Ok(Some(worklog)) => match worklog.days_since_started(today) {
            Some(days) => Status::Days {
                days,
                severity: Severity::from_days(days, config.warning_threshold),
                issue_key: worklog.issue_key(),
            },
            None => Status::NoData,
        },
        Ok(None) => Status::NoData,
        Err(error) => {
            network_error = error == TempoError::NetworkError;
            Status::Error(error.to_string())
        }
    };

    Cycle {
        status,
        poll_interval,
        network_error,
    }
}

fn run_tray(config_path: &Path) -> ExitCode {
    let client = match TempoClient::new() {
        Ok(client) => client,
        Err(error) => {
            eprintln!("Could not create the HTTP client: {error}");
            return ExitCode::FAILURE;
        }
    };

    let (tx, rx) = mpsc::channel();
    let tray = TempoTray {
        status: Status::NoData,
        tx: tx.clone(),
    };
    let handle = match tray.spawn() {
        Ok(handle) => handle,
        Err(error) => {
            eprintln!("Could not start the tray: {error}");
            eprintln!(
                "This desktop needs a StatusNotifierItem host. On GNOME, install the \
                 AppIndicator extension (gnome-shell-extension-appindicator)."
            );
            return ExitCode::FAILURE;
        }
    };

    let mut backoff = BACKOFF_START;
    loop {
        let cycle = poll_once(&client, config_path);
        let status = cycle.status.clone();
        if handle.update(move |tray| tray.status = status).is_none() {
            // Tray service shut down underneath us.
            return ExitCode::FAILURE;
        }

        let delay = if cycle.network_error {
            let delay = backoff;
            backoff = (backoff * BACKOFF_FACTOR).min(BACKOFF_MAX);
            delay
        } else {
            backoff = BACKOFF_START;
            cycle.poll_interval
        };

        match rx.recv_timeout(delay) {
            Ok(Msg::Refresh) | Err(RecvTimeoutError::Timeout) => continue,
            Ok(Msg::Quit) | Err(RecvTimeoutError::Disconnected) => break,
        }
    }

    handle.shutdown().wait();
    ExitCode::SUCCESS
}

fn set_token() -> ExitCode {
    let token = match rpassword::prompt_password("Jira API token: ") {
        Ok(token) => token,
        Err(error) => {
            eprintln!("Could not read the token: {error}");
            return ExitCode::FAILURE;
        }
    };
    let token = token.trim();
    if token.is_empty() {
        eprintln!("No token entered; nothing was stored.");
        return ExitCode::FAILURE;
    }

    match config::store_token(token) {
        Ok(()) => {
            println!("Token stored in the desktop Secret Service.");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            eprintln!("{}", config::SECRET_SERVICE_HELP);
            ExitCode::FAILURE
        }
    }
}

fn init(path: &Path) -> ExitCode {
    if path.exists() {
        eprintln!("{} already exists; leaving it alone.", path.display());
        return ExitCode::FAILURE;
    }
    if let Some(parent) = path.parent() {
        if let Err(error) = std::fs::create_dir_all(parent) {
            eprintln!("Could not create {}: {error}", parent.display());
            return ExitCode::FAILURE;
        }
    }
    match std::fs::write(path, config::SAMPLE_CONFIG) {
        Ok(()) => {
            println!("Wrote {}", path.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("Could not write {}: {error}", path.display());
            ExitCode::FAILURE
        }
    }
}
