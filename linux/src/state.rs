//! Status model shared by the tray icon, tooltip and menu.
//!
//! Mirrors the severity thresholds and status colours of the macOS app — see
//! the status table in `docs/OVERVIEW.md`.

/// ARGB colours matching the macOS `NSColor` system palette.
pub const COLOR_OK: u32 = 0xFF34_C759;
pub const COLOR_WARNING: u32 = 0xFFFF_9500;
pub const COLOR_OVERDUE: u32 = 0xFFFF_3B30;
pub const COLOR_NEUTRAL: u32 = 0xFF8E_8E93;

/// Mirrors the private `Severity` enum in `TempoService.swift`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Ok,
    Warning,
    Overdue,
}

impl Severity {
    pub fn from_days(days: i64, warning_threshold: u32) -> Self {
        let threshold = i64::from(warning_threshold);
        if days <= threshold {
            Severity::Ok
        } else if days == threshold + 1 {
            Severity::Warning
        } else {
            Severity::Overdue
        }
    }

    pub fn color(self) -> u32 {
        match self {
            Severity::Ok => COLOR_OK,
            Severity::Warning => COLOR_WARNING,
            Severity::Overdue => COLOR_OVERDUE,
        }
    }
}

/// What the tray is currently showing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// Credentials are present but no worklog was found in the query window.
    NoData,
    /// No API token could be resolved from any source.
    NoCredentials,
    /// A display message. Never contains a token or `token_command` output.
    Error(String),
    Days {
        days: i64,
        severity: Severity,
        issue_key: Option<String>,
    },
}

impl Status {
    pub fn color(&self) -> u32 {
        match self {
            Status::Days { severity, .. } => severity.color(),
            Status::NoData | Status::NoCredentials | Status::Error(_) => COLOR_NEUTRAL,
        }
    }

    /// Short text for the SNI tooltip.
    pub fn tooltip(&self) -> String {
        match self {
            Status::Days { days, .. } => {
                format!("Last worklog: {days} day{} ago", plural(*days))
            }
            Status::NoData => "No worklog data available".to_string(),
            Status::NoCredentials => "No credentials configured".to_string(),
            Status::Error(message) => message.clone(),
        }
    }

    /// The first (disabled) line of the tray menu.
    pub fn menu_line(&self) -> String {
        match self {
            Status::Days {
                days,
                issue_key: Some(key),
                ..
            } => format!("Last worklog: {days} day{} ago ({key})", plural(*days)),
            _ => self.tooltip(),
        }
    }
}

fn plural(days: i64) -> &'static str {
    if days == 1 {
        ""
    } else {
        "s"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn severity_boundaries_match_the_macos_app() {
        assert_eq!(Severity::from_days(0, 7), Severity::Ok);
        assert_eq!(Severity::from_days(7, 7), Severity::Ok);
        assert_eq!(Severity::from_days(8, 7), Severity::Warning);
        assert_eq!(Severity::from_days(9, 7), Severity::Overdue);
        assert_eq!(Severity::from_days(100, 7), Severity::Overdue);
    }

    #[test]
    fn severity_honours_a_custom_threshold() {
        assert_eq!(Severity::from_days(3, 3), Severity::Ok);
        assert_eq!(Severity::from_days(4, 3), Severity::Warning);
        assert_eq!(Severity::from_days(5, 3), Severity::Overdue);
    }

    #[test]
    fn non_day_states_render_neutral() {
        assert_eq!(Status::NoData.color(), COLOR_NEUTRAL);
        assert_eq!(Status::NoCredentials.color(), COLOR_NEUTRAL);
        assert_eq!(Status::Error("boom".into()).color(), COLOR_NEUTRAL);
        assert_eq!(
            Status::Days {
                days: 1,
                severity: Severity::Ok,
                issue_key: None
            }
            .color(),
            COLOR_OK
        );
    }

    #[test]
    fn tooltip_pluralises_days() {
        let one = Status::Days {
            days: 1,
            severity: Severity::Ok,
            issue_key: None,
        };
        let two = Status::Days {
            days: 2,
            severity: Severity::Ok,
            issue_key: None,
        };
        assert_eq!(one.tooltip(), "Last worklog: 1 day ago");
        assert_eq!(two.tooltip(), "Last worklog: 2 days ago");
    }

    #[test]
    fn menu_line_includes_the_issue_key_when_known() {
        let status = Status::Days {
            days: 3,
            severity: Severity::Ok,
            issue_key: Some("TEMPO-1".into()),
        };
        assert_eq!(status.menu_line(), "Last worklog: 3 days ago (TEMPO-1)");
    }
}
