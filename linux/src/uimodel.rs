//! Pure presentation and validation logic for the GTK windows.
//!
//! Deliberately GTK-free so it compiles and is tested in both feature
//! configurations — `gui.rs` is only the widget plumbing on top of this.

use crate::config::{self, StoredCredentials};
use crate::state::Status;

/// What the settings window's entries currently hold.
#[derive(Debug, Clone, Default)]
pub struct SettingsForm {
    pub jira_url: String,
    pub account_id: String,
    /// Typed token. Blank means "keep whatever is stored" — the stored token
    /// is never loaded into the widget, so blank is the normal case.
    pub api_token: String,
    pub warning_threshold: u32,
}

/// Which fields `config.toml` overrides, so the window can warn that saving
/// them to the Secret Service will have no visible effect.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FileOverrides {
    pub jira_url: bool,
    pub account_id: bool,
    pub warning_threshold: bool,
}

/// Merges the form into the stored blob, or reports the first problem as text
/// fit for the window's status label.
pub fn validate(
    form: &SettingsForm,
    stored: &StoredCredentials,
) -> Result<StoredCredentials, String> {
    let jira_url = form.jira_url.trim();
    if jira_url.is_empty() {
        return Err("A Jira URL is required.".to_string());
    }
    if !(jira_url.starts_with("http://") || jira_url.starts_with("https://")) {
        return Err("The Jira URL must start with http:// or https://.".to_string());
    }
    if !(1..=365).contains(&form.warning_threshold) {
        return Err("Warning threshold must be between 1 and 365 days.".to_string());
    }

    let account_id = form.account_id.trim();
    let token = form.api_token.trim();
    let api_token = if token.is_empty() {
        if stored.api_token.trim().is_empty() {
            return Err("An API token is required.".to_string());
        }
        stored.api_token.clone()
    } else {
        token.to_string()
    };

    Ok(StoredCredentials {
        // A single trailing slash is the common paste; the client trims it too,
        // but storing it clean keeps `show-config` output tidy.
        jira_url: jira_url.strip_suffix('/').unwrap_or(jira_url).to_string(),
        // Blank means "resolve from /myself", matching `set-credentials`.
        account_id: if account_id.is_empty() {
            None
        } else {
            Some(account_id.to_string())
        },
        api_token,
        warning_threshold: Some(form.warning_threshold),
    })
}

/// The large day count at the top of the status window.
pub fn status_headline(status: &Status) -> String {
    match status {
        Status::Days { days, .. } => {
            format!("{days} day{}", if *days == 1 { "" } else { "s" })
        }
        Status::NoData => "No data".to_string(),
        Status::NoCredentials => "Not configured".to_string(),
        Status::Error(_) => "Error".to_string(),
    }
}

/// The line under the headline. Same text as the tray tooltip.
pub fn status_subtitle(status: &Status) -> String {
    status.tooltip()
}

/// Applies the same non-blank test `config::resolve` uses, so the warnings
/// cannot drift from the resolution rules.
pub fn overridden_by_file(file: &config::FileConfig) -> FileOverrides {
    let present = |value: Option<&str>| value.map(str::trim).is_some_and(|v| !v.is_empty());
    FileOverrides {
        jira_url: present(file.jira_url.as_deref()),
        account_id: present(file.account_id.as_deref()),
        warning_threshold: file.warning_threshold.is_some(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::{Severity, WorklogDetail};

    fn stored() -> StoredCredentials {
        StoredCredentials {
            jira_url: "https://stored.example.com".to_string(),
            account_id: Some("stored-user".to_string()),
            api_token: "stored-token".to_string(),
            warning_threshold: Some(4),
        }
    }

    fn form() -> SettingsForm {
        SettingsForm {
            jira_url: "https://jira.example.com".to_string(),
            account_id: "jbloggs".to_string(),
            api_token: "typed-token".to_string(),
            warning_threshold: 7,
        }
    }

    #[test]
    fn validate_accepts_a_complete_form() {
        let creds = validate(&form(), &StoredCredentials::default()).unwrap();
        assert_eq!(creds.jira_url, "https://jira.example.com");
        assert_eq!(creds.account_id.as_deref(), Some("jbloggs"));
        assert_eq!(creds.api_token, "typed-token");
        assert_eq!(creds.warning_threshold, Some(7));
    }

    #[test]
    fn validate_requires_a_jira_url() {
        let blank = SettingsForm {
            jira_url: "   ".to_string(),
            ..form()
        };
        assert_eq!(
            validate(&blank, &stored()).unwrap_err(),
            "A Jira URL is required."
        );
    }

    #[test]
    fn validate_requires_an_http_scheme() {
        let bare = SettingsForm {
            jira_url: "jira.example.com".to_string(),
            ..form()
        };
        assert_eq!(
            validate(&bare, &stored()).unwrap_err(),
            "The Jira URL must start with http:// or https://."
        );
        let plain = SettingsForm {
            jira_url: "http://jira.example.com".to_string(),
            ..form()
        };
        assert!(validate(&plain, &stored()).is_ok());
    }

    #[test]
    fn validate_strips_a_single_trailing_slash() {
        let trailing = SettingsForm {
            jira_url: "  https://jira.example.com/  ".to_string(),
            ..form()
        };
        assert_eq!(
            validate(&trailing, &stored()).unwrap().jira_url,
            "https://jira.example.com"
        );
    }

    #[test]
    fn validate_keeps_the_stored_token_when_the_field_is_blank() {
        let blank = SettingsForm {
            api_token: "   ".to_string(),
            ..form()
        };
        assert_eq!(
            validate(&blank, &stored()).unwrap().api_token,
            "stored-token"
        );
    }

    #[test]
    fn validate_requires_a_token_when_none_is_stored() {
        let blank = SettingsForm {
            api_token: String::new(),
            ..form()
        };
        assert_eq!(
            validate(&blank, &StoredCredentials::default()).unwrap_err(),
            "An API token is required."
        );
    }

    #[test]
    fn validate_turns_a_blank_account_id_into_none() {
        let blank = SettingsForm {
            account_id: "  ".to_string(),
            ..form()
        };
        assert!(validate(&blank, &stored()).unwrap().account_id.is_none());
    }

    #[test]
    fn validate_bounds_the_warning_threshold() {
        let zero = SettingsForm {
            warning_threshold: 0,
            ..form()
        };
        assert_eq!(
            validate(&zero, &stored()).unwrap_err(),
            "Warning threshold must be between 1 and 365 days."
        );
        let too_many = SettingsForm {
            warning_threshold: 366,
            ..form()
        };
        assert!(validate(&too_many, &stored()).is_err());
        for days in [1, 365] {
            let edge = SettingsForm {
                warning_threshold: days,
                ..form()
            };
            assert!(validate(&edge, &stored()).is_ok());
        }
    }

    #[test]
    fn headline_and_subtitle_cover_every_status() {
        let days = |days| Status::Days {
            days,
            severity: Severity::Ok,
            detail: WorklogDetail::default(),
        };
        assert_eq!(status_headline(&days(1)), "1 day");
        assert_eq!(status_headline(&days(3)), "3 days");
        assert_eq!(status_headline(&Status::NoData), "No data");
        assert_eq!(status_headline(&Status::NoCredentials), "Not configured");
        assert_eq!(status_headline(&Status::Error("boom".into())), "Error");

        assert_eq!(status_subtitle(&days(3)), "Last worklog: 3 days ago");
        assert_eq!(status_subtitle(&Status::Error("boom".into())), "boom");
    }

    #[test]
    fn overridden_by_file_ignores_blank_values() {
        let blank = config::FileConfig {
            jira_url: Some("   ".to_string()),
            account_id: Some(String::new()),
            ..config::FileConfig::default()
        };
        assert_eq!(overridden_by_file(&blank), FileOverrides::default());

        let set = config::FileConfig {
            jira_url: Some("https://file.example.com".to_string()),
            account_id: Some("file-user".to_string()),
            warning_threshold: Some(3),
            ..config::FileConfig::default()
        };
        assert_eq!(
            overridden_by_file(&set),
            FileOverrides {
                jira_url: true,
                account_id: true,
                warning_threshold: true,
            }
        );
    }
}
