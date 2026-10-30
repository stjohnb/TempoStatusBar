# TempoStatusBar observability

This is the repo's observability policy under the St-John-Software observability contract ([contract](https://git.home.bstjohn.net/St-John-Software/claws/src/branch/main/docs/observability-contract.md)).

## Observability

### Scope

TempoStatusBar ships two desktop applications, both running as processes on the user's own machine and both polling Jira Tempo Server/Data Center:

- a signed macOS menu bar app (Swift/SwiftUI, flat source at the repo root);
- a separate Linux tray app (Rust crate in `linux/`).

There is no server-side service, no Kubernetes deployment, no static site and no CronJob. Neither app listens on a network port.

This repo emits no runtime telemetry.

Only **Logging** (local, on-device diagnostics) and **What every change adds** apply. **Metrics**, **Traces**, **Latency budgets** and **Dashboards and alerts** are `none`, with reasons given in each section.

### Logging

Neither app writes JSON to stdout, and nothing is shipped to Loki. The structured logging contract assumes a container and a log shipper; a user's desktop has neither, so the JSON field table does not apply here. The rules that still apply are:

- **macOS app.** Logging goes through `os.Logger`. The subsystem is the app's bundle identifier, with one category per component: `AppDelegate`, `CredentialManager`, `UpdateChecker`, `SettingsView`, `WorklogStateManager`, `TempoService`. Entries are readable only locally, in Console.app or with `log show`. Nothing is written to files or to stdout.
- **Linux app.** Diagnostics are plain-text lines written to stderr, for startup failures and `set-credentials` prompts. The crate uses no logging framework.
- Use lowercase `os.Logger` levels (`debug`, `info`, `error`) on macOS. An error is logged as its `localizedDescription`; the `err` object with a stack does not apply, because Swift errors have no stack to record.
- Mark interpolated values `privacy: .public` only when they are not sensitive. Ids and status values qualify; anything from a credential does not.
- **Credentials are never logged or printed.** Never log or print `apiToken`, `githubToken`, Linux `token_command` stdout, or any other credential value, at any level, in any message. `token_command` stdout never appears in an error message. Only a bounded excerpt of its stderr does, as already documented in [docs/linux.md](linux.md).

### Metrics

`none`. There is no metrics endpoint, no Prometheus scrape target and no analytics SDK. The apps hold no network listener, so there is nothing to scrape.

### Traces

`none`. No tracing SDK (no OpenTelemetry or equivalent) is linked, and no spans are recorded.

### Latency budgets

`none`, as an SLO or uptime target, since nothing is hosted. For context only, the timing facts in the code are:

- both apps poll Tempo hourly (3600 s);
- the macOS app retries a failed poll after 15 s and checks GitHub Releases every 24 h;
- the Linux app uses a 30 s HTTP request timeout.

### Dashboards and alerts

`none`. No Grafana dashboards or alert rules exist for this repo, in this repo or in any infra repo. The only "alert" is the in-app status colour shown to the user.

### What every change adds

- **A new HTTP route:** does not apply. The apps serve no HTTP routes.
- **A new DB query:** does not apply. The apps have no database. Keychain and Secret Service access is not logged.
- **A new background job** (timer or poll loop): on macOS, add an `os.Logger` `debug` line at start and an `error` line on failure. On Linux, add a stderr line on failure.
- **A new external call** (any host beyond the configured Jira URL and GitHub Releases): name the host and path in [docs/api-design.md](api-design.md) or [docs/linux.md](linux.md). Log failures at error level, naming the path but never the token. Cover it with a `MockURLProtocol` test (macOS) or a Rust unit test (Linux).
- **Any future telemetry** (crash reporting, analytics, a metrics endpoint): requires reopening this policy and a product decision first, and must keep the credential rule above.
