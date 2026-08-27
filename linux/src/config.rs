//! Config file, Secret Service credentials and API-token resolution.
//!
//! `jira_url`, `account_id`, the API token and `warning_threshold` live in a
//! single JSON blob in the Secret Service, mirroring the macOS Keychain
//! payload. `config.toml` is a pure override layer — every field is optional
//! and the file may be absent entirely. The token is looked up in a fixed
//! order so the app still works on desktops with no Secret Service provider —
//! see `docs/linux.md`.

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

pub const KEYRING_SERVICE: &str = "tempo-statusbar";
pub const KEYRING_USER: &str = "credentials";
/// Pre-0.2 entry: the bare token. Still read, never written. Do not delete it.
pub const LEGACY_KEYRING_USER: &str = "api-token";
pub const TOKEN_ENV_VAR: &str = "TEMPO_API_TOKEN";

const DEFAULT_WARNING_THRESHOLD: u32 = 7;
const DEFAULT_POLL_INTERVAL_SECS: u64 = 3600;

/// Printed whenever a keyring operation fails, so the user gets a next step
/// instead of a raw D-Bus error.
pub const SECRET_SERVICE_HELP: &str = "\
No Secret Service provider could be reached. Install or enable GNOME Keyring,
KWallet (KDE Frameworks 5.97+) or KeePassXC's Secret Service integration — or
set the TEMPO_API_TOKEN environment variable, or a `token_command` in the
config file, instead. Without a provider the config file must also carry
`jira_url`, because the keyring now holds more than the token.";

pub const SAMPLE_CONFIG: &str = "\
# TempoStatusBar (Linux) configuration — every field is optional.
#
# jira_url, account_id and the API token are normally stored in the desktop
# Secret Service by `tempo-statusbar set-credentials`. Uncomment a field here
# only to override what is stored.
#
# jira_url = \"https://jira.example.com\"
# account_id = \"jbloggs\"
# warning_threshold = 7
# poll_interval_secs = 3600
#
# Optional: shell command printing the API token on stdout. Takes precedence
# over the Secret Service, and is the escape hatch on desktops with no secrets
# daemon. Only stderr is ever surfaced in errors; stdout is never logged.
# token_command = \"pass show tempo\"
";

/// Everything in config.toml is optional; the file is an override layer.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct FileConfig {
    #[serde(default)]
    pub jira_url: Option<String>,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default)]
    pub warning_threshold: Option<u32>,
    #[serde(default)]
    pub poll_interval_secs: Option<u64>,
    #[serde(default)]
    pub token_command: Option<String>,
}

/// The JSON blob in the Secret Service. Mirrors the macOS Keychain payload in
/// CredentialManager.swift (snake_case here; the two stores never interop).
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct StoredCredentials {
    #[serde(default)]
    pub jira_url: String,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default)]
    pub api_token: String,
    #[serde(default)]
    pub warning_threshold: Option<u32>,
}

/// Hand-written so the token can never reach a log line or an error message.
impl fmt::Debug for StoredCredentials {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StoredCredentials")
            .field("jira_url", &self.jira_url)
            .field("account_id", &self.account_id)
            .field("api_token", &"<redacted>")
            .field("warning_threshold", &self.warning_threshold)
            .finish()
    }
}

/// Resolved settings the poll loop uses.
#[derive(Debug, Clone)]
pub struct Config {
    pub jira_url: String,
    pub account_id: Option<String>,
    pub warning_threshold: u32,
    pub poll_interval_secs: u64,
    pub token_command: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum CredentialError {
    #[error(
        "No API token stored. Run `tempo-statusbar set-credentials`, set TEMPO_API_TOKEN, \
         or set `token_command` in the config file."
    )]
    NoStoredCredentials,
    #[error("Secret Service error: {0}")]
    Keyring(#[from] keyring::Error),
    #[error("token_command failed: {0}")]
    TokenCommandFailed(String),
    #[error(
        "No Jira URL configured. Run `tempo-statusbar set-credentials`, or set `jira_url` in {0}."
    )]
    NoJiraUrl(PathBuf),
    #[error(
        "Stored credentials are not valid JSON ({0}). Re-run `tempo-statusbar set-credentials`."
    )]
    InvalidStoredCredentials(String),
    #[error("Could not read config file {0}: {1}")]
    UnreadableConfig(PathBuf, String),
    #[error("Invalid config file {0}: {1}")]
    InvalidConfig(PathBuf, String),
}

pub fn config_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("tempo-statusbar")
        .join("config.toml")
}

/// A missing file is not an error — every field can come from the keyring.
pub fn load_file(path: &Path) -> Result<FileConfig, CredentialError> {
    if !path.exists() {
        return Ok(FileConfig::default());
    }
    let raw = std::fs::read_to_string(path).map_err(|error| {
        CredentialError::UnreadableConfig(path.to_path_buf(), error.to_string())
    })?;
    toml::from_str(&raw)
        .map_err(|error| CredentialError::InvalidConfig(path.to_path_buf(), error.to_string()))
}

/// Non-empty trimmed value, or None.
fn present(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

/// True unless the file already supplies a URL *and* a token source, in which
/// case a box with no Secret Service provider must never touch D-Bus.
pub fn needs_keyring(file: &FileConfig, env_token: Option<&str>) -> bool {
    let have_url = present(file.jira_url.as_deref()).is_some();
    let have_token =
        present(env_token).is_some() || present(file.token_command.as_deref()).is_some();
    !(have_url && have_token)
}

/// File value wins per field; the keyring fills the rest. Blank strings count
/// as absent on both sides. `poll_interval_secs` and `token_command` are
/// file-only — they are settings, not credentials.
pub fn resolve(
    file: &FileConfig,
    stored: Option<&StoredCredentials>,
    path: &Path,
) -> Result<Config, CredentialError> {
    let jira_url = present(file.jira_url.as_deref())
        .or_else(|| present(stored.map(|stored| stored.jira_url.as_str())))
        .ok_or_else(|| CredentialError::NoJiraUrl(path.to_path_buf()))?
        .to_string();

    let account_id = present(file.account_id.as_deref())
        .or_else(|| present(stored.and_then(|stored| stored.account_id.as_deref())))
        .map(str::to_string);

    let warning_threshold = file
        .warning_threshold
        .or_else(|| stored.and_then(|stored| stored.warning_threshold))
        .unwrap_or(DEFAULT_WARNING_THRESHOLD);

    Ok(Config {
        jira_url,
        account_id,
        warning_threshold,
        poll_interval_secs: file
            .poll_interval_secs
            .unwrap_or(DEFAULT_POLL_INTERVAL_SECS),
        token_command: present(file.token_command.as_deref()).map(str::to_string),
    })
}

/// Where a resolved token came from. Reported by `show-config`, which must
/// establish the source without ever printing the value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenSource {
    Environment,
    TokenCommand,
    SecretService,
    LegacySecretService,
}

impl fmt::Display for TokenSource {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let text = match self {
            TokenSource::Environment => "environment",
            TokenSource::TokenCommand => "token_command",
            TokenSource::SecretService => "Secret Service",
            TokenSource::LegacySecretService => "Secret Service (legacy api-token entry)",
        };
        formatter.write_str(text)
    }
}

/// Resolution order: `TEMPO_API_TOKEN`, then `token_command`, then the stored
/// blob, then the legacy `api-token` entry. Pure up to `run_token_command` and
/// `load_legacy_token`.
pub fn load_token(
    config: &Config,
    env_token: Option<&str>,
    stored: Option<&StoredCredentials>,
) -> Result<String, CredentialError> {
    resolve_token(config, env_token, stored).map(|(token, _)| token)
}

/// As `load_token`, but also reports which source won.
pub fn resolve_token(
    config: &Config,
    env_token: Option<&str>,
    stored: Option<&StoredCredentials>,
) -> Result<(String, TokenSource), CredentialError> {
    match resolve_token_without_legacy(config, env_token, stored)? {
        Some(found) => Ok(found),
        None => match load_legacy_token()? {
            Some(token) => Ok((token, TokenSource::LegacySecretService)),
            None => Err(CredentialError::NoStoredCredentials),
        },
    }
}

/// The first three sources. `None` means only the legacy keyring entry is left
/// to try — which keeps everything above it testable without a D-Bus session.
fn resolve_token_without_legacy(
    config: &Config,
    env_token: Option<&str>,
    stored: Option<&StoredCredentials>,
) -> Result<Option<(String, TokenSource)>, CredentialError> {
    if let Some(token) = present(env_token) {
        return Ok(Some((token.to_string(), TokenSource::Environment)));
    }

    if let Some(command) = present(config.token_command.as_deref()) {
        return run_token_command(command).map(|token| Some((token, TokenSource::TokenCommand)));
    }

    if let Some(token) = present(stored.map(|stored| stored.api_token.as_str())) {
        return Ok(Some((token.to_string(), TokenSource::SecretService)));
    }

    Ok(None)
}

/// Trimmed and non-empty, or None. Read as a parameter everywhere else so the
/// resolution logic stays testable without `std::env::set_var`.
pub fn env_token() -> Option<String> {
    std::env::var(TOKEN_ENV_VAR)
        .ok()
        .map(|token| token.trim().to_string())
        .filter(|token| !token.is_empty())
}

/// `Ok(None)` without touching D-Bus when the file already supplies both a URL
/// and a token source.
pub fn load_stored_if_needed(
    file: &FileConfig,
) -> Result<Option<StoredCredentials>, CredentialError> {
    if !needs_keyring(file, env_token().as_deref()) {
        return Ok(None);
    }
    load_stored()
}

pub fn load_stored() -> Result<Option<StoredCredentials>, CredentialError> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)?;
    let raw = match entry.get_password() {
        Ok(raw) => raw,
        Err(keyring::Error::NoEntry) => return Ok(None),
        Err(error) => return Err(CredentialError::Keyring(error)),
    };
    if raw.trim().is_empty() {
        return Ok(None);
    }
    // The raw value holds the token; only the parse error's own text is safe.
    serde_json::from_str(&raw)
        .map(Some)
        .map_err(|error| CredentialError::InvalidStoredCredentials(error.to_string()))
}

pub fn store_credentials(creds: &StoredCredentials) -> Result<(), CredentialError> {
    let raw = serde_json::to_string(creds)
        .map_err(|error| CredentialError::InvalidStoredCredentials(error.to_string()))?;
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)?;
    entry.set_password(&raw)?;
    Ok(())
}

/// The pre-0.2 bare-token entry. Read-only: nothing ever writes or deletes it,
/// so an install that predates the blob keeps working.
fn load_legacy_token() -> Result<Option<String>, CredentialError> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, LEGACY_KEYRING_USER)?;
    match entry.get_password() {
        Ok(token) if !token.trim().is_empty() => Ok(Some(token.trim().to_string())),
        Ok(_) => Ok(None),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(CredentialError::Keyring(error)),
    }
}

/// Runs `sh -c <command>` and takes trimmed stdout as the token. Only a
/// stderr excerpt is ever surfaced — stdout holds the secret.
fn run_token_command(command: &str) -> Result<String, CredentialError> {
    let output = Command::new("sh")
        .arg("-c")
        .arg(command)
        .output()
        .map_err(|error| CredentialError::TokenCommandFailed(error.to_string()))?;

    if !output.status.success() {
        return Err(CredentialError::TokenCommandFailed(stderr_excerpt(
            &output.stderr,
        )));
    }

    let token = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if token.is_empty() {
        return Err(CredentialError::TokenCommandFailed(
            "command printed nothing on stdout".to_string(),
        ));
    }
    Ok(token)
}

fn stderr_excerpt(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return "command exited non-zero".to_string();
    }
    trimmed.chars().take(200).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Pure values only: these tests must never execute a token_command, touch
    // the keyring, or set an environment variable — CI has no D-Bus session
    // and tests run in parallel.

    const PATH: &str = "/nonexistent/tempo-statusbar/config.toml";

    fn config_path_for_tests() -> &'static Path {
        Path::new(PATH)
    }

    fn stored() -> StoredCredentials {
        StoredCredentials {
            jira_url: "https://stored.example.com".to_string(),
            account_id: Some("stored-user".to_string()),
            api_token: "stored-token".to_string(),
            warning_threshold: Some(4),
        }
    }

    fn config_with_token_command(token_command: Option<&str>) -> Config {
        Config {
            jira_url: "https://jira.example.com".to_string(),
            account_id: None,
            warning_threshold: 7,
            poll_interval_secs: 3600,
            token_command: token_command.map(str::to_string),
        }
    }

    #[test]
    fn the_sample_config_parses() {
        let file: FileConfig = toml::from_str(SAMPLE_CONFIG).unwrap();
        assert!(file.jira_url.is_none());
        assert!(file.token_command.is_none());
    }

    #[test]
    fn missing_config_file_yields_an_empty_override() {
        let file = load_file(config_path_for_tests()).unwrap();
        assert!(file.jira_url.is_none());
        assert!(file.account_id.is_none());
        assert!(file.warning_threshold.is_none());
        assert!(file.poll_interval_secs.is_none());
        assert!(file.token_command.is_none());
    }

    #[test]
    fn file_config_reads_every_field() {
        let file: FileConfig = toml::from_str(
            "jira_url = \"https://jira.example.com\"\n\
             account_id = \"jbloggs\"\n\
             warning_threshold = 3\n\
             poll_interval_secs = 900\n\
             token_command = \"pass show tempo\"\n",
        )
        .unwrap();
        assert_eq!(file.jira_url.as_deref(), Some("https://jira.example.com"));
        assert_eq!(file.account_id.as_deref(), Some("jbloggs"));
        assert_eq!(file.warning_threshold, Some(3));
        assert_eq!(file.poll_interval_secs, Some(900));
        assert_eq!(file.token_command.as_deref(), Some("pass show tempo"));
    }

    #[test]
    fn stored_credentials_round_trip_through_json() {
        let raw = serde_json::to_string(&stored()).unwrap();
        let parsed: StoredCredentials = serde_json::from_str(&raw).unwrap();
        assert_eq!(parsed.jira_url, "https://stored.example.com");
        assert_eq!(parsed.account_id.as_deref(), Some("stored-user"));
        assert_eq!(parsed.api_token, "stored-token");
        assert_eq!(parsed.warning_threshold, Some(4));

        let empty: StoredCredentials = serde_json::from_str("{}").unwrap();
        assert!(empty.jira_url.is_empty());
        assert!(empty.api_token.is_empty());
        assert!(empty.account_id.is_none());
        assert!(empty.warning_threshold.is_none());
    }

    #[test]
    fn stored_credentials_debug_redacts_the_token() {
        let rendered = format!("{:?}", stored());
        assert!(!rendered.contains("stored-token"));
        assert!(rendered.contains("<redacted>"));
    }

    #[test]
    fn resolve_prefers_the_file_over_the_keyring() {
        let file = FileConfig {
            jira_url: Some("https://file.example.com".to_string()),
            account_id: Some("file-user".to_string()),
            warning_threshold: Some(2),
            poll_interval_secs: Some(120),
            token_command: Some("pass show tempo".to_string()),
        };
        let config = resolve(&file, Some(&stored()), config_path_for_tests()).unwrap();
        assert_eq!(config.jira_url, "https://file.example.com");
        assert_eq!(config.account_id.as_deref(), Some("file-user"));
        assert_eq!(config.warning_threshold, 2);
        assert_eq!(config.poll_interval_secs, 120);
        assert_eq!(config.token_command.as_deref(), Some("pass show tempo"));
    }

    #[test]
    fn resolve_falls_back_to_the_keyring_for_every_field() {
        let config = resolve(
            &FileConfig::default(),
            Some(&stored()),
            config_path_for_tests(),
        )
        .unwrap();
        assert_eq!(config.jira_url, "https://stored.example.com");
        assert_eq!(config.account_id.as_deref(), Some("stored-user"));
        assert_eq!(config.warning_threshold, 4);
        // poll_interval_secs and token_command are file-only settings.
        assert_eq!(config.poll_interval_secs, 3600);
        assert!(config.token_command.is_none());
    }

    #[test]
    fn resolve_treats_a_blank_stored_jira_url_as_absent() {
        // `set-token` on a fresh box writes a blob with an empty jira_url.
        let blank = StoredCredentials {
            jira_url: "   ".to_string(),
            account_id: Some("  ".to_string()),
            api_token: "stored-token".to_string(),
            warning_threshold: None,
        };
        let file = FileConfig {
            jira_url: Some("https://file.example.com".to_string()),
            ..FileConfig::default()
        };
        let config = resolve(&file, Some(&blank), config_path_for_tests()).unwrap();
        assert_eq!(config.jira_url, "https://file.example.com");
        assert!(config.account_id.is_none());
        assert_eq!(config.warning_threshold, 7);

        match resolve(
            &FileConfig::default(),
            Some(&blank),
            config_path_for_tests(),
        ) {
            Err(CredentialError::NoJiraUrl(path)) => assert_eq!(path, Path::new(PATH)),
            other => panic!("expected NoJiraUrl, got {other:?}"),
        }
    }

    #[test]
    fn resolve_without_a_jira_url_anywhere_reports_no_jira_url() {
        match resolve(&FileConfig::default(), None, config_path_for_tests()) {
            Err(CredentialError::NoJiraUrl(path)) => assert_eq!(path, Path::new(PATH)),
            other => panic!("expected NoJiraUrl, got {other:?}"),
        }
    }

    #[test]
    fn needs_keyring_is_false_with_a_file_url_and_token_command() {
        let file = FileConfig {
            jira_url: Some("https://file.example.com".to_string()),
            token_command: Some("pass show tempo".to_string()),
            ..FileConfig::default()
        };
        assert!(!needs_keyring(&file, None));

        let env_only = FileConfig {
            jira_url: Some("https://file.example.com".to_string()),
            ..FileConfig::default()
        };
        assert!(!needs_keyring(&env_only, Some("env-token")));
    }

    #[test]
    fn needs_keyring_is_true_without_a_token_source() {
        let url_only = FileConfig {
            jira_url: Some("https://file.example.com".to_string()),
            ..FileConfig::default()
        };
        assert!(needs_keyring(&url_only, None));
        assert!(needs_keyring(&url_only, Some("   ")));

        let token_only = FileConfig {
            token_command: Some("pass show tempo".to_string()),
            ..FileConfig::default()
        };
        assert!(needs_keyring(&token_only, None));
        assert!(needs_keyring(&FileConfig::default(), None));
    }

    #[test]
    fn load_token_prefers_the_env_var_over_the_stored_blob() {
        let config = config_with_token_command(None);
        let (token, source) =
            resolve_token(&config, Some("  env-token  "), Some(&stored())).unwrap();
        assert_eq!(token, "env-token");
        assert_eq!(source, TokenSource::Environment);
    }

    #[test]
    fn load_token_uses_the_stored_blob_when_no_env_var() {
        let config = config_with_token_command(None);
        let (token, source) = resolve_token(&config, Some("   "), Some(&stored())).unwrap();
        assert_eq!(token, "stored-token");
        assert_eq!(source, TokenSource::SecretService);
        assert_eq!(
            load_token(&config, None, Some(&stored())).unwrap(),
            "stored-token"
        );
    }

    #[test]
    fn load_token_without_any_source_is_no_stored_credentials() {
        // `resolve_token` would go on to read the legacy keyring entry and then
        // return NoStoredCredentials; stop at the boundary so no D-Bus call is
        // made. A blank stored token must fall through, not be handed back.
        let config = config_with_token_command(None);
        let blank = StoredCredentials {
            api_token: "  ".to_string(),
            ..StoredCredentials::default()
        };
        assert!(resolve_token_without_legacy(&config, None, Some(&blank))
            .unwrap()
            .is_none());
        assert!(resolve_token_without_legacy(&config, Some(""), None)
            .unwrap()
            .is_none());
    }

    #[test]
    fn stderr_excerpt_is_bounded_and_never_empty() {
        assert_eq!(stderr_excerpt(b"   "), "command exited non-zero");
        assert_eq!(
            stderr_excerpt(b"gpg: decryption failed"),
            "gpg: decryption failed"
        );
        assert_eq!(stderr_excerpt(&vec![b'x'; 500]).len(), 200);
    }
}
