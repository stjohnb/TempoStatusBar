//! GTK4 status and settings windows.
//!
//! Mirrors `ContentView.swift` and `SettingsView.swift`. Everything here runs
//! on the main thread: GTK objects are not `Send`, so only `Arc<Mutex<Status>>`,
//! the `mpsc` endpoints and `glib::MainLoop` cross the thread boundary.
//!
//! There is deliberately no `gtk::Application` — a tray app has no window at
//! startup, and `Application` exits once the last window closes. A bare
//! `glib::MainLoop` keeps the process alive with zero windows open.
//!
//! Presentation rules live in `uimodel.rs` so they can be tested without GTK.
//! Styling choices are recorded in `docs/DESIGN.md`.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gtk::gdk;
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use gtk4 as gtk;

use crate::config::{self, StoredCredentials};
use crate::state::{Status, WorklogDetail};
use crate::tempo::TempoClient;
use crate::uimodel::{self, SettingsForm};
use crate::{Msg, UiMsg};

/// How often the tick drains the tray channel and re-reads the shared status.
/// Fast enough that a menu click feels instant, slow enough to be free.
const TICK: Duration = Duration::from_millis(200);

const STATUS_SIZE: (i32, i32) = (380, 300);
const SETTINGS_SIZE: (i32, i32) = (420, 660);

/// See `docs/DESIGN.md`. Only `.tempo-*` classes are styled, so the windows
/// otherwise inherit the user's GTK theme.
const CSS: &str = "\
@define-color tempo_ok #34C759;
@define-color tempo_warning #FF9500;
@define-color tempo_overdue #FF3B30;
@define-color tempo_neutral #8E8E93;

.tempo-headline {
  font-family: \"JetBrains Mono\", \"Fira Mono\", \"DejaVu Sans Mono\", monospace;
  font-size: 32px;
  font-weight: 800;
}

.tempo-header {
  font-weight: 700;
  padding-bottom: 6px;
  background-image: repeating-linear-gradient(
    135deg,
    alpha(@tempo_neutral, 0.10) 0px,
    alpha(@tempo_neutral, 0.10) 1px,
    transparent 1px,
    transparent 7px
  );
}

.tempo-field { font-weight: 600; }

.tempo-hint {
  font-size: 90%;
  opacity: 0.7;
}

.tempo-warn {
  font-size: 90%;
  color: @tempo_warning;
}
";

/// The GUI half of the tray's channels.
pub struct UiChannels {
    pub ui_rx: Receiver<UiMsg>,
    pub tx: Sender<Msg>,
}

/// `false` when there is no display to talk to — the caller must then fall
/// back to tray-only operation rather than exiting.
pub fn init() -> bool {
    gtk::init().is_ok()
}

/// Created before `run` so the poll thread can `.quit()` it on the way out.
pub fn main_loop() -> glib::MainLoop {
    glib::MainLoop::new(None, false)
}

/// Runs the GTK main loop on the calling thread until `main_loop` is quit.
///
/// `open_settings` opens the settings window immediately, for the
/// `tempo-statusbar settings` subcommand, which has no tray behind it.
pub fn run(
    main_loop: glib::MainLoop,
    shared: Arc<Mutex<Status>>,
    channels: UiChannels,
    config_path: PathBuf,
    open_settings: bool,
) {
    install_css();

    let status_window: Rc<RefCell<Option<StatusWindow>>> = Rc::new(RefCell::new(None));
    let settings_window: Rc<RefCell<Option<gtk::Window>>> = Rc::new(RefCell::new(None));
    let rendered: Rc<RefCell<Option<Status>>> = Rc::new(RefCell::new(None));

    if open_settings {
        present_settings(&settings_window, &channels.tx, &config_path);
        // `tempo-statusbar settings` has no tray keeping the process alive, so
        // closing its one window has to end the main loop.
        if let Some(window) = settings_window.borrow().as_ref() {
            let main_loop = main_loop.clone();
            window.connect_close_request(move |_| {
                main_loop.quit();
                glib::Propagation::Proceed
            });
        }
    }

    glib::source::timeout_add_local(TICK, move || {
        while let Ok(message) = channels.ui_rx.try_recv() {
            match message {
                UiMsg::ShowStatus => present_status(
                    &status_window,
                    &settings_window,
                    &channels.tx,
                    &config_path,
                    &rendered,
                    &shared,
                ),
                UiMsg::ShowSettings => {
                    present_settings(&settings_window, &channels.tx, &config_path)
                }
            }
        }

        // Cheap: a clone of a small enum, only when the window is open.
        if status_window.borrow().is_some() {
            let current = shared.lock().expect("status mutex").clone();
            if rendered.borrow().as_ref() != Some(&current) {
                if let Some(window) = status_window.borrow().as_ref() {
                    window.render(&current);
                }
                *rendered.borrow_mut() = Some(current);
            }
        }

        glib::ControlFlow::Continue
    });

    main_loop.run();
}

fn install_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(CSS);
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }
}

/// Runs `work` on a scratch thread and delivers the result back on the GTK
/// thread. Secret Service writes can block on an unlock prompt and an HTTP
/// call on a dead VPN blocks until the 30 s timeout; neither may freeze the UI.
fn spawn_with_result<T: Send + 'static>(
    work: impl FnOnce() -> T + Send + 'static,
    done: impl Fn(T) + 'static,
) {
    let slot: Arc<Mutex<Option<T>>> = Arc::new(Mutex::new(None));
    let writer = Arc::clone(&slot);
    std::thread::spawn(move || {
        let result = work();
        *writer.lock().expect("result slot") = Some(result);
    });

    glib::source::timeout_add_local(Duration::from_millis(100), move || {
        let taken = slot.lock().expect("result slot").take();
        match taken {
            Some(result) => {
                done(result);
                glib::ControlFlow::Break
            }
            None => glib::ControlFlow::Continue,
        }
    });
}

// ---------------------------------------------------------------- status ---

/// The status window's mutable parts, so a poll result can repaint it without
/// rebuilding the widget tree.
struct StatusWindow {
    window: gtk::Window,
    dot: gtk::DrawingArea,
    color: Rc<RefCell<u32>>,
    headline: gtk::Label,
    subtitle: gtk::Label,
    issue: gtk::Label,
    summary: gtk::Label,
    time_spent: gtk::Label,
    date: gtk::Label,
    comment: gtk::Label,
    no_credentials: gtk::Box,
}

impl StatusWindow {
    fn render(&self, status: &Status) {
        *self.color.borrow_mut() = status.color();
        self.dot.queue_draw();
        self.headline.set_text(&uimodel::status_headline(status));
        self.subtitle.set_text(&uimodel::status_subtitle(status));

        let detail = match status {
            Status::Days { detail, .. } => Some(detail),
            _ => None,
        };
        let empty = WorklogDetail::default();
        let detail = detail.unwrap_or(&empty);

        set_optional(&self.issue, detail.issue_key.as_deref());
        set_optional(&self.summary, detail.issue_summary.as_deref());
        set_row(&self.time_spent, "Time spent", Some(&detail.time_spent));
        set_row(&self.date, "Date", detail.date_started.as_deref());
        set_row(&self.comment, "Comment", detail.comment.as_deref());

        self.no_credentials
            .set_visible(matches!(status, Status::NoCredentials));
    }

    fn present(&self) {
        self.window.present();
    }
}

/// Hides the label entirely when there is nothing to show, so the window never
/// carries an empty row.
fn set_optional(label: &gtk::Label, text: Option<&str>) {
    match text.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => {
            label.set_text(value);
            label.set_visible(true);
        }
        None => label.set_visible(false),
    }
}

fn set_row(label: &gtk::Label, name: &str, value: Option<&str>) {
    match value.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => {
            label.set_text(&format!("{name}: {value}"));
            label.set_visible(true);
        }
        None => label.set_visible(false),
    }
}

fn present_status(
    slot: &Rc<RefCell<Option<StatusWindow>>>,
    settings: &Rc<RefCell<Option<gtk::Window>>>,
    tx: &Sender<Msg>,
    config_path: &Path,
    rendered: &Rc<RefCell<Option<Status>>>,
    shared: &Arc<Mutex<Status>>,
) {
    if slot.borrow().is_none() {
        let window = build_status_window(slot, settings, tx, config_path);
        *slot.borrow_mut() = Some(window);
        // Force a repaint on the next tick regardless of what changed.
        *rendered.borrow_mut() = None;
    }
    let status = shared.lock().expect("status mutex").clone();
    if let Some(window) = slot.borrow().as_ref() {
        window.render(&status);
        window.present();
    }
    *rendered.borrow_mut() = Some(status);
}

fn build_status_window(
    slot: &Rc<RefCell<Option<StatusWindow>>>,
    settings: &Rc<RefCell<Option<gtk::Window>>>,
    tx: &Sender<Msg>,
    config_path: &Path,
) -> StatusWindow {
    let window = gtk::Window::builder()
        .title("Tempo Status")
        .default_width(STATUS_SIZE.0)
        .default_height(STATUS_SIZE.1)
        .build();

    let root = vbox(12);
    root.set_margin_top(16);
    root.set_margin_bottom(16);
    root.set_margin_start(16);
    root.set_margin_end(16);

    let header = gtk::Label::new(Some("Tempo Status"));
    header.set_xalign(0.0);
    header.add_css_class("tempo-header");
    root.append(&header);

    let color = Rc::new(RefCell::new(crate::state::COLOR_NEUTRAL));
    let dot = gtk::DrawingArea::new();
    dot.set_content_width(12);
    dot.set_content_height(12);
    dot.set_valign(gtk::Align::Center);
    let dot_color = Rc::clone(&color);
    dot.set_draw_func(move |_, cr, width, height| {
        let argb = *dot_color.borrow();
        let channel = |shift: u32| f64::from((argb >> shift) & 0xFF) / 255.0;
        cr.set_source_rgb(channel(16), channel(8), channel(0));
        let radius = f64::from(width.min(height)) / 2.0;
        cr.arc(
            f64::from(width) / 2.0,
            f64::from(height) / 2.0,
            radius,
            0.0,
            std::f64::consts::TAU,
        );
        // A failed fill just means no dot; there is nothing useful to report.
        let _ = cr.fill();
    });

    let headline = gtk::Label::new(None);
    headline.add_css_class("tempo-headline");
    headline.set_xalign(0.0);

    let top = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    top.append(&dot);
    top.append(&headline);
    root.append(&top);

    let subtitle = gtk::Label::new(None);
    subtitle.set_xalign(0.0);
    subtitle.set_wrap(true);
    root.append(&subtitle);

    let issue = gtk::Label::new(None);
    issue.set_xalign(0.0);
    issue.add_css_class("tempo-field");
    let summary = gtk::Label::new(None);
    summary.set_xalign(0.0);
    summary.set_wrap(true);
    summary.add_css_class("tempo-hint");

    let detail = vbox(4);
    detail.append(&issue);
    detail.append(&summary);
    let time_spent = detail_row(&detail);
    let date = detail_row(&detail);
    let comment = detail_row(&detail);
    comment.set_wrap(true);
    root.append(&detail);

    let no_credentials = vbox(8);
    let note = gtk::Label::new(Some("No credentials configured"));
    note.set_xalign(0.0);
    no_credentials.append(&note);
    let open_settings = gtk::Button::with_label("Open Settings");
    open_settings.set_halign(gtk::Align::Start);
    no_credentials.append(&open_settings);
    root.append(&no_credentials);

    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    footer.set_halign(gtk::Align::End);
    footer.set_valign(gtk::Align::End);
    footer.set_vexpand(true);
    let refresh = gtk::Button::with_label("Refresh");
    let settings_button = gtk::Button::with_label("Settings…");
    footer.append(&refresh);
    footer.append(&settings_button);
    root.append(&footer);

    let refresh_tx = tx.clone();
    refresh.connect_clicked(move |_| {
        // A dead channel means the poll loop is already shutting down.
        let _ = refresh_tx.send(Msg::Refresh);
    });

    for button in [&settings_button, &open_settings] {
        let settings = Rc::clone(settings);
        let tx = tx.clone();
        let config_path = config_path.to_path_buf();
        button.connect_clicked(move |_| present_settings(&settings, &tx, &config_path));
    }

    let slot = Rc::clone(slot);
    window.connect_close_request(move |_| {
        *slot.borrow_mut() = None;
        glib::Propagation::Proceed
    });

    window.set_child(Some(&root));

    StatusWindow {
        window,
        dot,
        color,
        headline,
        subtitle,
        issue,
        summary,
        time_spent,
        date,
        comment,
        no_credentials,
    }
}

fn detail_row(parent: &gtk::Box) -> gtk::Label {
    let label = gtk::Label::new(None);
    label.set_xalign(0.0);
    parent.append(&label);
    label
}

// -------------------------------------------------------------- settings ---

fn present_settings(slot: &Rc<RefCell<Option<gtk::Window>>>, tx: &Sender<Msg>, config_path: &Path) {
    if slot.borrow().is_none() {
        let window = build_settings_window(slot, tx, config_path);
        *slot.borrow_mut() = Some(window);
    }
    if let Some(window) = slot.borrow().as_ref() {
        window.present();
    }
}

fn build_settings_window(
    slot: &Rc<RefCell<Option<gtk::Window>>>,
    tx: &Sender<Msg>,
    config_path: &Path,
) -> gtk::Window {
    let window = gtk::Window::builder()
        .title("Tempo Settings")
        .default_width(SETTINGS_SIZE.0)
        .default_height(SETTINGS_SIZE.1)
        .build();

    let status_label = gtk::Label::new(None);
    status_label.set_xalign(0.0);
    status_label.set_wrap(true);

    // Deliberately `load_stored`, not `load_stored_if_needed`: the user is
    // explicitly asking to see and edit what is stored, so skipping D-Bus
    // because the file happens to supply a URL would show the wrong values.
    let stored = match config::load_stored() {
        Ok(stored) => stored.unwrap_or_default(),
        Err(error) => {
            status_label.set_text(&format!("{error}\n\n{}", config::SECRET_SERVICE_HELP));
            StoredCredentials::default()
        }
    };
    let file = config::load_file(config_path).unwrap_or_default();
    let overrides = uimodel::overridden_by_file(&file);
    let stored = Rc::new(RefCell::new(stored));

    let root = vbox(14);
    root.set_margin_top(16);
    root.set_margin_bottom(16);
    root.set_margin_start(16);
    root.set_margin_end(16);

    let header = gtk::Label::new(Some("Jira Tempo Settings"));
    header.set_xalign(0.0);
    header.add_css_class("tempo-header");
    root.append(&header);

    let url_entry = gtk::Entry::new();
    url_entry.set_text(&stored.borrow().jira_url);
    url_entry.set_placeholder_text(Some("https://jira.yourcompany.com"));
    root.append(&field(
        "Jira Instance URL",
        &url_entry,
        "e.g. https://jira.yourcompany.com",
        overrides
            .jira_url
            .then(|| override_note("jira_url", config_path)),
    ));

    let token_entry = gtk::PasswordEntry::new();
    token_entry.set_show_peek_icon(true);
    // The stored token is never loaded into a widget; blank means "keep it".
    token_entry.set_placeholder_text(Some("leave blank to keep the stored token"));
    root.append(&field(
        "API Token",
        &token_entry,
        "Stored in the desktop Secret Service. Never shown once saved.",
        None,
    ));

    let account_entry = gtk::Entry::new();
    account_entry.set_text(stored.borrow().account_id.as_deref().unwrap_or_default());
    account_entry.set_hexpand(true);
    account_entry.set_placeholder_text(Some("blank = resolve from /myself"));
    let detect = gtk::Button::with_label("Auto-detect");
    let account_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    account_row.append(&account_entry);
    account_row.append(&detect);
    root.append(&field(
        "Account ID (optional)",
        &account_row,
        "Your Jira Server username (e.g. 'jbloggs'), not the internal user ID.",
        overrides
            .account_id
            .then(|| override_note("account_id", config_path)),
    ));

    let threshold = gtk::SpinButton::new(
        Some(&gtk::Adjustment::new(
            f64::from(stored.borrow().warning_threshold.unwrap_or(7)),
            1.0,
            365.0,
            1.0,
            1.0,
            0.0,
        )),
        1.0,
        0,
    );
    threshold.set_halign(gtk::Align::Start);
    root.append(&field(
        "Warning Threshold",
        &threshold,
        "Days without a worklog before the tray turns orange.",
        overrides
            .warning_threshold
            .then(|| override_note("warning_threshold", config_path)),
    ));

    root.append(&status_label);

    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let test = gtk::Button::with_label("Test Connection");
    let save = gtk::Button::with_label("Save");
    let close = gtk::Button::with_label("Close");
    buttons.append(&test);
    buttons.append(&save);
    buttons.append(&close);
    root.append(&buttons);

    let clear = gtk::Button::with_label("Clear Stored Credentials");
    clear.set_halign(gtk::Align::Start);
    clear.set_margin_top(8);
    root.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    root.append(&clear);

    let footer = gtk::Label::new(Some(&format!(
        "poll_interval_secs and token_command are file-only settings — edit {}.",
        config_path.display()
    )));
    footer.set_xalign(0.0);
    footer.set_wrap(true);
    footer.set_valign(gtk::Align::End);
    footer.set_vexpand(true);
    footer.add_css_class("tempo-hint");
    root.append(&footer);

    // The token to authenticate with: what was typed, else what is stored.
    let effective_token = {
        let stored = Rc::clone(&stored);
        let token_entry = token_entry.clone();
        move || {
            let typed = token_entry.text().trim().to_string();
            if typed.is_empty() {
                stored.borrow().api_token.clone()
            } else {
                typed
            }
        }
    };

    connect_detect(
        &detect,
        &account_entry,
        &url_entry,
        &status_label,
        effective_token.clone(),
    );
    connect_test(&test, &url_entry, &status_label, effective_token);
    connect_save(
        &save,
        SaveWidgets {
            url: url_entry.clone(),
            token: token_entry,
            account: account_entry.clone(),
            threshold: threshold.clone(),
            status: status_label.clone(),
        },
        Rc::clone(&stored),
        tx.clone(),
    );
    connect_clear(
        &clear,
        &window,
        &status_label,
        ClearWidgets {
            url: url_entry,
            account: account_entry,
            threshold,
        },
        Rc::clone(&stored),
        tx.clone(),
    );

    let close_window = window.clone();
    close.connect_clicked(move |_| close_window.close());

    let slot = Rc::clone(slot);
    window.connect_close_request(move |_| {
        *slot.borrow_mut() = None;
        glib::Propagation::Proceed
    });

    window.set_child(Some(&scrolled(&root)));
    window
}

struct SaveWidgets {
    url: gtk::Entry,
    token: gtk::PasswordEntry,
    account: gtk::Entry,
    threshold: gtk::SpinButton,
    status: gtk::Label,
}

fn connect_save(
    button: &gtk::Button,
    widgets: SaveWidgets,
    stored: Rc<RefCell<StoredCredentials>>,
    tx: Sender<Msg>,
) {
    button.connect_clicked(move |button| {
        let form = SettingsForm {
            jira_url: widgets.url.text().to_string(),
            account_id: widgets.account.text().to_string(),
            api_token: widgets.token.text().to_string(),
            warning_threshold: widgets.threshold.value_as_int().max(0) as u32,
        };
        let creds = match uimodel::validate(&form, &stored.borrow()) {
            Ok(creds) => creds,
            Err(message) => {
                widgets.status.set_text(&message);
                return;
            }
        };

        widgets.status.set_text("Saving…");
        button.set_sensitive(false);

        let to_store = creds.clone();
        let button = button.clone();
        let status = widgets.status.clone();
        let token = widgets.token.clone();
        let stored = Rc::clone(&stored);
        let tx = tx.clone();
        spawn_with_result(
            move || config::store_credentials(&to_store).map_err(|error| error.to_string()),
            move |result| {
                button.set_sensitive(true);
                match result {
                    Ok(()) => {
                        *stored.borrow_mut() = creds.clone();
                        // The blob now holds it; the widget must not.
                        token.set_text("");
                        status.set_text("Saved.");
                        let _ = tx.send(Msg::Refresh);
                    }
                    Err(message) => status.set_text(&message),
                }
            },
        );
    });
}

struct ClearWidgets {
    url: gtk::Entry,
    account: gtk::Entry,
    threshold: gtk::SpinButton,
}

fn connect_clear(
    button: &gtk::Button,
    window: &gtk::Window,
    status: &gtk::Label,
    widgets: ClearWidgets,
    stored: Rc<RefCell<StoredCredentials>>,
    tx: Sender<Msg>,
) {
    let window = window.clone();
    let status = status.clone();
    button.connect_clicked(move |button| {
        let dialog = gtk::AlertDialog::builder()
            .message("Clear stored credentials?")
            .detail(
                "The Jira URL, account ID and API token will be removed from the \
                 desktop Secret Service. This cannot be undone.",
            )
            .buttons(["Cancel", "Clear"])
            .cancel_button(0)
            .default_button(0)
            .build();

        let button = button.clone();
        let status = status.clone();
        let stored = Rc::clone(&stored);
        let tx = tx.clone();
        let url = widgets.url.clone();
        let account = widgets.account.clone();
        let threshold = widgets.threshold.clone();
        dialog.choose(Some(&window), gio::Cancellable::NONE, move |answer| {
            // Button index 1 is "Clear"; anything else (including a
            // dismissed dialog) leaves the blob alone.
            if !matches!(answer, Ok(1)) {
                return;
            }
            button.set_sensitive(false);
            spawn_with_result(
                || config::delete_credentials().map_err(|error| error.to_string()),
                move |result| {
                    button.set_sensitive(true);
                    match result {
                        Ok(()) => {
                            *stored.borrow_mut() = StoredCredentials::default();
                            url.set_text("");
                            account.set_text("");
                            threshold.set_value(7.0);
                            status.set_text("Stored credentials cleared.");
                            let _ = tx.send(Msg::Refresh);
                        }
                        Err(message) => status.set_text(&message),
                    }
                },
            );
        });
    });
}

fn connect_test(
    button: &gtk::Button,
    url: &gtk::Entry,
    status: &gtk::Label,
    token: impl Fn() -> String + 'static,
) {
    let url = url.clone();
    let status = status.clone();
    button.connect_clicked(move |button| {
        let (jira_url, token) = (url.text().trim().to_string(), token());
        if jira_url.is_empty() || token.is_empty() {
            status.set_text("A Jira URL and an API token are needed to test the connection.");
            return;
        }
        status.set_text("Testing…");
        button.set_sensitive(false);

        let button = button.clone();
        let status = status.clone();
        spawn_with_result(
            move || fetch_identity(&token, &jira_url),
            move |result| {
                button.set_sensitive(true);
                match result {
                    Ok(name) => status.set_text(&format!("Connected as {name}.")),
                    Err(message) => status.set_text(&message),
                }
            },
        );
    });
}

fn connect_detect(
    button: &gtk::Button,
    account: &gtk::Entry,
    url: &gtk::Entry,
    status: &gtk::Label,
    token: impl Fn() -> String + 'static,
) {
    let account = account.clone();
    let url = url.clone();
    let status = status.clone();
    button.connect_clicked(move |button| {
        let (jira_url, token) = (url.text().trim().to_string(), token());
        if jira_url.is_empty() || token.is_empty() {
            status.set_text("A Jira URL and an API token are needed to detect your account.");
            return;
        }
        status.set_text("Detecting…");
        button.set_sensitive(false);

        let button = button.clone();
        let account = account.clone();
        let status = status.clone();
        spawn_with_result(
            move || fetch_identity(&token, &jira_url),
            move |result| {
                button.set_sensitive(true);
                match result {
                    Ok(name) => {
                        // Filled in, not persisted — Save still has to be clicked.
                        account.set_text(&name);
                        status.set_text(&format!("Detected {name}."));
                    }
                    Err(message) => status.set_text(&message),
                }
            },
        );
    });
}

/// `/myself`'s `name`, falling back to `key`. Runs off the GTK thread; the
/// token is passed by value and never logged.
fn fetch_identity(token: &str, jira_url: &str) -> Result<String, String> {
    let client = TempoClient::new().map_err(|error| error.to_string())?;
    let user = client
        .fetch_user_info(token, jira_url)
        .map_err(|error| error.to_string())?;
    user.name
        .or(user.key)
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .ok_or_else(|| "The Jira API returned no username.".to_string())
}

// ----------------------------------------------------------------- glue ----

fn vbox(spacing: i32) -> gtk::Box {
    gtk::Box::new(gtk::Orientation::Vertical, spacing)
}

fn scrolled(child: &impl IsA<gtk::Widget>) -> gtk::ScrolledWindow {
    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(child)
        .build()
}

/// A label, the control, an explanatory hint and — when `config.toml` shadows
/// the field — an amber warning that saving it here changes nothing.
fn field(
    name: &str,
    control: &impl IsA<gtk::Widget>,
    hint: &str,
    warning: Option<String>,
) -> gtk::Box {
    let group = vbox(4);
    let label = gtk::Label::new(Some(name));
    label.set_xalign(0.0);
    label.add_css_class("tempo-field");
    group.append(&label);
    group.append(control);

    let hint_label = gtk::Label::new(Some(hint));
    hint_label.set_xalign(0.0);
    hint_label.set_wrap(true);
    hint_label.add_css_class("tempo-hint");
    group.append(&hint_label);

    if let Some(warning) = warning {
        let warn = gtk::Label::new(Some(&warning));
        warn.set_xalign(0.0);
        warn.set_wrap(true);
        warn.add_css_class("tempo-warn");
        group.append(&warn);
    }
    group
}

fn override_note(field: &str, config_path: &Path) -> String {
    format!(
        "Overridden by {} — saving {field} here has no effect until you remove it from that file.",
        config_path.display()
    )
}
