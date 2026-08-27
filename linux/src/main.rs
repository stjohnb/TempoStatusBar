//! TempoStatusBar for Linux — a StatusNotifierItem tray showing days since the
//! last Jira Tempo worklog. See `docs/linux.md`.

mod config;
mod icon;
mod state;
mod tempo;

use std::io::Write;
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
    /// Store the Jira URL, account ID and API token in the desktop Secret Service
    SetCredentials,
    /// Store the Jira API token in the desktop Secret Service
    SetToken,
    /// Print the resolved configuration (never the token)
    ShowConfig,
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
        Some(Command::SetCredentials) => set_credentials(),
        Some(Command::SetToken) => set_token(),
        Some(Command::ShowConfig) => show_config(&config::config_path()),
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
    let file = match config::load_file(config_path) {
        Ok(file) => file,
        Err(error) => {
            return Cycle {
                status: Status::Error(error.to_string()),
                poll_interval: Duration::from_secs(300),
                network_error: false,
            }
        }
    };
    let poll_interval = Duration::from_secs(file.poll_interval_secs.unwrap_or(3600).max(60));

    let stored = match config::load_stored_if_needed(&file) {
        Ok(stored) => stored,
        Err(error) => {
            return Cycle {
                status: Status::Error(error.to_string()),
                poll_interval,
                network_error: false,
            }
        }
    };
    let config = match config::resolve(&file, stored.as_ref(), config_path) {
        Ok(config) => config,
        Err(error) => {
            return Cycle {
                status: Status::Error(error.to_string()),
                poll_interval,
                network_error: false,
            }
        }
    };

    let env_token = config::env_token();
    let token = match config::load_token(&config, env_token.as_deref(), stored.as_ref()) {
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

/// Loads the stored blob for a write path (`set-credentials`/`set-token`).
/// These are the only commands that can overwrite the blob, so an unreadable
/// one must not be a dead end: a corrupted `InvalidStoredCredentials` blob is
/// discarded with a warning rather than leaving the user stuck re-running the
/// same failing command. Genuine keyring/D-Bus errors still bail.
fn load_stored_for_write() -> Result<config::StoredCredentials, ExitCode> {
    match config::load_stored() {
        Ok(stored) => Ok(stored.unwrap_or_default()),
        Err(CredentialError::InvalidStoredCredentials(error)) => {
            eprintln!(
                "Warning: stored credentials were not valid JSON ({error}); overwriting with a fresh entry."
            );
            Ok(config::StoredCredentials::default())
        }
        Err(error) => {
            eprintln!("{error}");
            eprintln!("{}", config::SECRET_SERVICE_HELP);
            Err(ExitCode::FAILURE)
        }
    }
}

/// Prompts for the Jira URL, account ID and token, then writes all three as one
/// blob. A blank answer keeps whatever is already stored.
fn set_credentials() -> ExitCode {
    let mut creds = match load_stored_for_write() {
        Ok(creds) => creds,
        Err(code) => return code,
    };

    let url_prompt = if creds.jira_url.trim().is_empty() {
        "Jira URL [https://jira.example.com]: ".to_string()
    } else {
        format!("Jira URL [{}]: ", creds.jira_url.trim())
    };
    let jira_url = match prompt(&url_prompt) {
        Ok(answer) => answer,
        Err(error) => {
            eprintln!("Could not read the Jira URL: {error}");
            return ExitCode::FAILURE;
        }
    };
    if !jira_url.is_empty() {
        creds.jira_url = jira_url;
    } else if creds.jira_url.trim().is_empty() {
        eprintln!("No Jira URL entered; nothing was stored.");
        return ExitCode::FAILURE;
    }

    let account_prompt = match creds.account_id.as_deref().map(str::trim) {
        Some(current) if !current.is_empty() => {
            format!("Jira username (blank = keep, `-` = clear) [{current}]: ")
        }
        _ => "Jira username (blank = resolve from /myself): ".to_string(),
    };
    let account_id = match prompt(&account_prompt) {
        Ok(answer) => answer,
        Err(error) => {
            eprintln!("Could not read the Jira username: {error}");
            return ExitCode::FAILURE;
        }
    };
    if account_id == "-" {
        creds.account_id = None;
    } else if !account_id.is_empty() {
        creds.account_id = Some(account_id);
    }

    let token = match rpassword::prompt_password("Jira API token (blank = keep stored): ") {
        Ok(token) => token.trim().to_string(),
        Err(error) => {
            eprintln!("Could not read the token: {error}");
            return ExitCode::FAILURE;
        }
    };
    if !token.is_empty() {
        creds.api_token = token;
    } else if creds.api_token.trim().is_empty() {
        eprintln!("No token entered; nothing was stored.");
        return ExitCode::FAILURE;
    }

    store(&creds, "Credentials stored in the desktop Secret Service.")
}

/// Updates only the token field, so a stored `jira_url`/`account_id` survives.
fn set_token() -> ExitCode {
    let mut creds = match load_stored_for_write() {
        Ok(creds) => creds,
        Err(code) => return code,
    };

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
    creds.api_token = token.to_string();

    store(&creds, "Token stored in the desktop Secret Service.")
}

fn store(creds: &config::StoredCredentials, success: &str) -> ExitCode {
    match config::store_credentials(creds) {
        Ok(()) => {
            println!("{success}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            eprintln!("{}", config::SECRET_SERVICE_HELP);
            ExitCode::FAILURE
        }
    }
}

/// Reads one trimmed line from stdin after printing `label`.
fn prompt(label: &str) -> std::io::Result<String> {
    print!("{label}");
    std::io::stdout().flush()?;
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    Ok(answer.trim().to_string())
}

/// Prints the resolution the tray would use. Never prints the token itself,
/// nor the `token_command` string, which may embed a private path.
fn show_config(config_path: &Path) -> ExitCode {
    println!("config file: {}", config_path.display());
    if !config_path.exists() {
        println!("             (absent — every value comes from the Secret Service)");
    }

    let file = match config::load_file(config_path) {
        Ok(file) => file,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    let stored = match config::load_stored_if_needed(&file) {
        Ok(stored) => stored,
        Err(error) => {
            eprintln!("{error}");
            eprintln!("{}", config::SECRET_SERVICE_HELP);
            return ExitCode::FAILURE;
        }
    };
    let config = match config::resolve(&file, stored.as_ref(), config_path) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };

    let from_file = |value: Option<&str>| value.map(str::trim).is_some_and(|v| !v.is_empty());

    println!(
        "jira_url: {} {}",
        config.jira_url,
        source(from_file(file.jira_url.as_deref()), true)
    );
    match config.account_id.as_deref() {
        Some(account_id) => println!(
            "account_id: {account_id} {}",
            source(from_file(file.account_id.as_deref()), true)
        ),
        None => println!("account_id: (resolved from /myself)"),
    }
    println!(
        "warning_threshold: {} {}",
        config.warning_threshold,
        source(
            file.warning_threshold.is_some(),
            stored
                .as_ref()
                .is_some_and(|s| s.warning_threshold.is_some())
        )
    );
    println!(
        "poll_interval_secs: {} {}",
        config.poll_interval_secs,
        source(file.poll_interval_secs.is_some(), false)
    );
    // The command string itself may embed a path the user considers private.
    match config.token_command {
        Some(_) => println!("token_command: set (config.toml)"),
        None => println!("token_command: unset"),
    }

    let env_token = config::env_token();
    match config::resolve_token(&config, env_token.as_deref(), stored.as_ref()) {
        Ok((_, token_source)) => println!("api_token: found (source: {token_source})"),
        Err(CredentialError::NoStoredCredentials) => println!("api_token: not found"),
        Err(error) => println!("api_token: not found ({error})"),
    }

    ExitCode::SUCCESS
}

fn source(from_file: bool, from_keyring: bool) -> &'static str {
    match (from_file, from_keyring) {
        (true, _) => "(config.toml)",
        (false, true) => "(Secret Service)",
        (false, false) => "(default)",
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
