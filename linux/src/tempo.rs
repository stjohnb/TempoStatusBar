//! Jira / Tempo Server REST client.
//!
//! Mirrors `TempoService.swift` — same two endpoints, same identifier
//! resolution, same error cases. See `docs/api-design.md`.

use std::time::Duration;

use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone};
use serde::Deserialize;

/// The macOS app queries the same 60-day window.
const WORKLOG_WINDOW_DAYS: i64 = 60;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// Case-for-case with `TempoError` in `TempoService.swift`, plus
/// `DecodeFailed`: the Swift client folds a decode failure into
/// `networkError`, which here would wrongly drive the network backoff loop.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum TempoError {
    #[error("Missing API credentials")]
    MissingCredentials,
    #[error("Invalid Jira URL")]
    InvalidUrl,
    #[error("Unauthorized - check your API token")]
    Unauthorized,
    #[error("Forbidden - check your account permissions")]
    Forbidden,
    #[error("Network error - check your connection")]
    NetworkError,
    #[error("API error (HTTP {0})")]
    ApiError(u16),
    #[error("Unexpected response from the Tempo API")]
    DecodeFailed,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UserInfo {
    pub name: Option<String>,
    pub key: Option<String>,
    /// Decoded for parity with the macOS `UserInfo` model; unused here.
    #[allow(dead_code)]
    pub email_address: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Worklog {
    pub date_started: String,
    pub time_spent_seconds: i64,
    pub comment: Option<String>,
    pub issue: Option<WorklogIssue>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorklogIssue {
    pub key: Option<String>,
    pub summary: Option<String>,
}

#[derive(Debug, Deserialize)]
struct WorklogResponse {
    results: Vec<Worklog>,
}

impl Worklog {
    pub fn started_at(&self) -> Option<DateTime<Local>> {
        parse_date(&self.date_started)
    }

    pub fn days_since_started(&self, today: NaiveDate) -> Option<i64> {
        Some(days_since(self.started_at()?.date_naive(), today))
    }

    pub fn issue_key(&self) -> Option<String> {
        self.issue.as_ref()?.key.clone()
    }
}

/// The Tempo Server API returns either a bare array or a `{"results": [...]}`
/// envelope depending on version, so try both.
pub fn parse_worklogs(data: &[u8]) -> Result<Vec<Worklog>, TempoError> {
    if let Ok(worklogs) = serde_json::from_slice::<Vec<Worklog>>(data) {
        return Ok(worklogs);
    }
    serde_json::from_slice::<WorklogResponse>(data)
        .map(|response| response.results)
        .map_err(|_| TempoError::DecodeFailed)
}

/// Parses both shapes Tempo emits: RFC 3339 with an offset, and a bare
/// `yyyy-MM-ddTHH:mm:ss.SSS` which is local time (as the macOS app treats it).
pub fn parse_date(raw: &str) -> Option<DateTime<Local>> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(raw) {
        return Some(parsed.with_timezone(&Local));
    }
    let naive = NaiveDateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f").ok()?;
    Local.from_local_datetime(&naive).earliest()
}

/// Whole calendar days between two local dates. Today is 0; future dates
/// clamp to 0 rather than going negative.
pub fn days_since(started: NaiveDate, today: NaiveDate) -> i64 {
    (today - started).num_days().max(0)
}

pub fn most_recent_worklog(worklogs: &[Worklog]) -> Option<&Worklog> {
    worklogs
        .iter()
        .filter_map(|worklog| worklog.started_at().map(|date| (date, worklog)))
        .max_by_key(|(date, _)| *date)
        .map(|(_, worklog)| worklog)
}

pub struct TempoClient {
    http: reqwest::blocking::Client,
}

impl TempoClient {
    pub fn new() -> Result<Self, TempoError> {
        let http = reqwest::blocking::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|_| TempoError::NetworkError)?;
        Ok(Self { http })
    }

    pub fn fetch_user_info(&self, token: &str, jira_url: &str) -> Result<UserInfo, TempoError> {
        let body = self.get(token, jira_url, "rest/api/2/myself", &[])?;
        serde_json::from_slice(&body).map_err(|_| TempoError::DecodeFailed)
    }

    /// A non-empty `account_id` is used directly; otherwise `/myself` resolves
    /// the Jira Server username (`name`, falling back to `key`).
    pub fn fetch_latest_worklog(
        &self,
        token: &str,
        jira_url: &str,
        account_id: Option<&str>,
        today: NaiveDate,
    ) -> Result<Option<Worklog>, TempoError> {
        let identifier = match account_id.map(str::trim).filter(|id| !id.is_empty()) {
            Some(id) => id.to_string(),
            None => {
                let user = self.fetch_user_info(token, jira_url)?;
                user.name
                    .or(user.key)
                    .map(|id| id.trim().to_string())
                    .filter(|id| !id.is_empty())
                    .ok_or(TempoError::MissingCredentials)?
            }
        };

        let from = today - chrono::Duration::days(WORKLOG_WINDOW_DAYS);
        let query = [
            ("username", identifier),
            ("dateFrom", from.format("%Y-%m-%d").to_string()),
            ("dateTo", today.format("%Y-%m-%d").to_string()),
        ];
        let body = self.get(token, jira_url, "rest/tempo-timesheets/3/worklogs", &query)?;
        let worklogs = parse_worklogs(&body)?;
        Ok(most_recent_worklog(&worklogs).cloned())
    }

    fn get(
        &self,
        token: &str,
        jira_url: &str,
        path: &str,
        query: &[(&str, String)],
    ) -> Result<Vec<u8>, TempoError> {
        let base = jira_url.trim().trim_end_matches('/');
        let url =
            reqwest::Url::parse(&format!("{base}/{path}")).map_err(|_| TempoError::InvalidUrl)?;

        let response = self
            .http
            .get(url)
            .query(query)
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .send()
            .map_err(|_| TempoError::NetworkError)?;

        match response.status().as_u16() {
            200 => response
                .bytes()
                .map(|body| body.to_vec())
                .map_err(|_| TempoError::NetworkError),
            401 => Err(TempoError::Unauthorized),
            403 => Err(TempoError::Forbidden),
            status => Err(TempoError::ApiError(status)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::Severity;

    fn date(year: i32, month: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(year, month, day).expect("valid date")
    }

    #[test]
    fn decodes_a_bare_worklog_array() {
        let json = br#"[
            {"dateStarted":"2026-08-10T09:00:00.000","timeSpentSeconds":3600,
             "issue":{"key":"TEMPO-1","summary":"Work"}}
        ]"#;
        let worklogs = parse_worklogs(json).expect("decodes");
        assert_eq!(worklogs.len(), 1);
        assert_eq!(worklogs[0].issue_key().as_deref(), Some("TEMPO-1"));
    }

    #[test]
    fn decodes_the_results_envelope() {
        let json = br#"{"results":[
            {"dateStarted":"2026-08-10T09:00:00.000","timeSpentSeconds":1800,"comment":"note"}
        ]}"#;
        let worklogs = parse_worklogs(json).expect("decodes");
        assert_eq!(worklogs.len(), 1);
        assert!(worklogs[0].issue_key().is_none());
    }

    #[test]
    fn rejects_a_malformed_payload() {
        assert_eq!(
            parse_worklogs(b"{\"nope\":true}").unwrap_err(),
            TempoError::DecodeFailed
        );
    }

    #[test]
    fn parses_a_bare_local_timestamp() {
        let parsed = parse_date("2026-08-10T09:30:00.000").expect("parses");
        assert_eq!(parsed.date_naive(), date(2026, 8, 10));
    }

    #[test]
    fn parses_a_timestamp_without_fractional_seconds() {
        let parsed = parse_date("2026-08-10T09:30:00").expect("parses");
        assert_eq!(parsed.date_naive(), date(2026, 8, 10));
    }

    #[test]
    fn parses_rfc3339_with_an_offset() {
        // Compared as an instant so the assertion holds in any runner timezone.
        let parsed = parse_date("2026-08-10T09:30:00.000+02:00").expect("parses");
        let expected = DateTime::parse_from_rfc3339("2026-08-10T07:30:00Z").expect("valid");
        assert_eq!(parsed.timestamp(), expected.timestamp());
    }

    #[test]
    fn rejects_a_malformed_date() {
        assert!(parse_date("not-a-date").is_none());
        assert!(parse_date("").is_none());
    }

    #[test]
    fn days_since_counts_calendar_days_and_clamps_the_future() {
        let today = date(2026, 8, 13);
        assert_eq!(days_since(today, today), 0);
        assert_eq!(days_since(date(2026, 8, 6), today), 7);
        assert_eq!(days_since(date(2026, 8, 20), today), 0);
    }

    #[test]
    fn worklog_days_since_started_uses_the_local_date() {
        let worklog = Worklog {
            date_started: "2026-08-06T09:00:00.000".into(),
            time_spent_seconds: 3600,
            comment: None,
            issue: None,
        };
        assert_eq!(worklog.days_since_started(date(2026, 8, 13)), Some(7));
    }

    #[test]
    fn worklog_days_since_started_is_none_for_a_malformed_date() {
        let worklog = Worklog {
            date_started: "garbage".into(),
            time_spent_seconds: 0,
            comment: None,
            issue: None,
        };
        assert_eq!(worklog.days_since_started(date(2026, 8, 13)), None);
    }

    #[test]
    fn most_recent_worklog_skips_unparseable_dates() {
        let json = br#"[
            {"dateStarted":"2026-08-01T09:00:00.000","timeSpentSeconds":1,
             "issue":{"key":"OLD"}},
            {"dateStarted":"nonsense","timeSpentSeconds":1,"issue":{"key":"BAD"}},
            {"dateStarted":"2026-08-11T09:00:00.000","timeSpentSeconds":1,
             "issue":{"key":"NEW"}}
        ]"#;
        let worklogs = parse_worklogs(json).expect("decodes");
        let latest = most_recent_worklog(&worklogs).expect("has a latest");
        assert_eq!(latest.issue_key().as_deref(), Some("NEW"));
    }

    #[test]
    fn most_recent_worklog_is_none_when_empty_or_all_unparseable() {
        assert!(most_recent_worklog(&[]).is_none());
        let worklogs = parse_worklogs(br#"[{"dateStarted":"x","timeSpentSeconds":1}]"#).unwrap();
        assert!(most_recent_worklog(&worklogs).is_none());
    }

    #[test]
    fn days_map_to_the_same_severities_as_the_macos_app() {
        let today = date(2026, 8, 13);
        let days = days_since(date(2026, 8, 4), today);
        assert_eq!(days, 9);
        assert_eq!(Severity::from_days(days, 7), Severity::Overdue);
    }
}
