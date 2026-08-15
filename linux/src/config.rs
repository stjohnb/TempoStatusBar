//! Config file and API-token resolution.
//!
//! The token is looked up in a fixed order so the app works on desktops with
//! no Secret Service provider — see `docs/linux.md`.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Deserialize;

pub const KEYRING_SERVICE: &str = "tempo-statusbar";
pub const KEYRING_USER: &str = "api-token";
pub const TOKEN_ENV_VAR: &str = "TEMPO_API_TOKEN";

/// Printed whenever a keyring operation fails, so the user gets a next step
/// instead of a raw D-Bus error.
pub const SECRET_SERVICE_HELP: &str = "\
No Secret Service provider could be reached. Install or enable GNOME Keyring,
KWallet (KDE Frameworks 5.97+) or KeePassXC's Secret Service integration — or
set the TEMPO_API_TOKEN environment variable, or a `token_command` in the
config file, instead.";

pub const SAMPLE_CONFIG: &str = "\
# TempoStatusBar (Linux) configuration.

# Base URL of your Jira instance.
jira_url = \"https://jira.example.com\"

# Jira Server username. Leave unset to resolve it from /rest/api/2/myself.
# account_id = \"jbloggs\"

# Days without a worklog before the tray turns orange (then red).
warning_threshold = 7

# How often to poll, in seconds.
poll_interval_secs = 3600

# Optional: shell command printing the API token on stdout. Takes precedence
# over the Secret Service, and is the escape hatch on desktops with no secrets
# daemon. Only stderr is ever surfaced in errors; stdout is never logged.
# token_command = \"pass show tempo\"
";

fn default_warning_threshold() -> u32 {
    7
}

fn default_poll_interval_secs() -> u64 {
    3600
}

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    pub jira_url: String,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default = "default_warning_threshold")]
    pub warning_threshold: u32,
    #[serde(default = "default_poll_interval_secs")]
    pub poll_interval_secs: u64,
    #[serde(default)]
    pub token_command: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum CredentialError {
    #[error(
        "No API token stored. Run `tempo-statusbar set-token`, set TEMPO_API_TOKEN, \
         or set `token_command` in the config file."
    )]
    NoStoredCredentials,
    #[error("Secret Service error: {0}")]
    Keyring(#[from] keyring::Error),
    #[error("token_command failed: {0}")]
    TokenCommandFailed(String),
    #[error("No config file at {0}. Run `tempo-statusbar init` to create one.")]
    NoConfigFile(PathBuf),
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

pub fn load(path: &Path) -> Result<Config, CredentialError> {
    if !path.exists() {
        return Err(CredentialError::NoConfigFile(path.to_path_buf()));
    }
    let raw = std::fs::read_to_string(path).map_err(|error| {
        CredentialError::UnreadableConfig(path.to_path_buf(), error.to_string())
    })?;
    toml::from_str(&raw)
        .map_err(|error| CredentialError::InvalidConfig(path.to_path_buf(), error.to_string()))
}

/// Resolution order: `TEMPO_API_TOKEN`, then `token_command`, then the
/// freedesktop Secret Service.
pub fn load_token(config: &Config) -> Result<String, CredentialError> {
    if let Ok(token) = std::env::var(TOKEN_ENV_VAR) {
        let token = token.trim();
        if !token.is_empty() {
            return Ok(token.to_string());
        }
    }

    if let Some(command) = config
        .token_command
        .as_deref()
        .map(str::trim)
        .filter(|command| !command.is_empty())
    {
        return run_token_command(command);
    }

    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)?;
    match entry.get_password() {
        Ok(token) if !token.trim().is_empty() => Ok(token.trim().to_string()),
        Ok(_) => Err(CredentialError::NoStoredCredentials),
        Err(keyring::Error::NoEntry) => Err(CredentialError::NoStoredCredentials),
        Err(error) => Err(CredentialError::Keyring(error)),
    }
}

pub fn store_token(token: &str) -> Result<(), CredentialError> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, KEYRING_USER)?;
    entry.set_password(token)?;
    Ok(())
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

    // Deserialization only: these tests must never execute a token_command or
    // touch the keyring — CI has no D-Bus session.

    #[test]
    fn applies_defaults_for_omitted_fields() {
        let config: Config = toml::from_str("jira_url = \"https://jira.example.com\"").unwrap();
        assert_eq!(config.jira_url, "https://jira.example.com");
        assert_eq!(config.warning_threshold, 7);
        assert_eq!(config.poll_interval_secs, 3600);
        assert!(config.account_id.is_none());
        assert!(config.token_command.is_none());
    }

    #[test]
    fn reads_every_field() {
        let config: Config = toml::from_str(
            "jira_url = \"https://jira.example.com\"\n\
             account_id = \"jbloggs\"\n\
             warning_threshold = 3\n\
             poll_interval_secs = 900\n\
             token_command = \"pass show tempo\"\n",
        )
        .unwrap();
        assert_eq!(config.account_id.as_deref(), Some("jbloggs"));
        assert_eq!(config.warning_threshold, 3);
        assert_eq!(config.poll_interval_secs, 900);
        assert_eq!(config.token_command.as_deref(), Some("pass show tempo"));
    }

    #[test]
    fn rejects_a_config_without_a_jira_url() {
        assert!(toml::from_str::<Config>("warning_threshold = 3").is_err());
    }

    #[test]
    fn the_sample_config_parses() {
        let config: Config = toml::from_str(SAMPLE_CONFIG).unwrap();
        assert_eq!(config.warning_threshold, 7);
        assert!(config.token_command.is_none());
    }

    #[test]
    fn missing_config_file_is_reported_with_its_path() {
        let path = Path::new("/nonexistent/tempo-statusbar/config.toml");
        match load(path) {
            Err(CredentialError::NoConfigFile(reported)) => assert_eq!(reported, path),
            other => panic!("expected NoConfigFile, got {other:?}"),
        }
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
