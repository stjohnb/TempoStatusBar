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

- **macOS app.** Logging goes through `os.Logger`. The subsystem is the app's bundle identifier, with one category per component: `AppDelegate`, `CredentialManager`, `UpdateChecker`, `SettingsView`, `WorklogStateManager`, `TempoService`. `WorklogStateManager` is defined in `TempoService.swift`, which holds two loggers (categories `WorklogStateManager` and `TempoService`). `LaunchAtLoginManager` and `ContentView` have no logger. Entries are readable only locally, in Console.app or with `log show`. Nothing is written to files or to stdout.
- **Linux app.** Errors and prompts (startup failures, `set-credentials` prompts) are written to stderr with `eprintln!`. The CLI's normal output goes to stdout with `println!`: the `show-config` output and the `set-credentials`/`set-token` success message. The tray's poll results appear only in the tray status; nothing is logged for them. The crate uses no logging framework.
- Use lowercase `os.Logger` levels (`debug`, `info`, `error`) on macOS. An error is logged as its `localizedDescription`; the `err` object with a stack does not apply, because Swift errors have no stack to record.
- Mark interpolated values `privacy: .public` only when they are not sensitive. Ids and status values qualify; anything from a credential does not. An interpolation without a `privacy:` marker is redacted by default, which is acceptable (as in `SettingsView.swift` and the migration error in `CredentialManager.swift`).
- **Credentials are never logged or printed.** Never log or print `apiToken`, `githubToken`, Linux `token_command` stdout, or any other credential value, at any level, in any message. `token_command` stdout never appears in an error message. Only a bounded excerpt of its stderr does, as already documented in [docs/linux.md](linux.md).

### Metrics

`none`. There is no metrics endpoint, no Prometheus scrape target and no analytics SDK. The apps hold no network listener, so there is nothing to scrape.

### Traces

`none`. No tracing SDK (no OpenTelemetry or equivalent) is linked, and no spans are recorded.

### Latency budgets

`none`, as an SLO or uptime target, since nothing is hosted. For context only, the timing facts in the code are:

- the macOS app polls Tempo every 3600 s (`setupTimer`), retries a network failure after 15 s (`retryDelay`) and re-polls when the network returns (`NWPathMonitor`);
- the macOS app checks GitHub Releases every 86400 s;
- the Linux app polls every 3600 s by default, configurable with `poll_interval_secs` (minimum 60 s), and uses 300 s after a config-load error;
- on transport failures the Linux app backs off exponentially from 15 s by x4 up to 3600 s, with a 30 s HTTP request timeout.

### Dashboards and alerts

`none`. No Grafana dashboards or alert rules exist for this repo, in this repo or in any infra repo. The only "alert" is the in-app status colour shown to the user.

### What every change adds

- **A new HTTP route:** does not apply. The apps serve no HTTP routes.
- **A new DB query:** does not apply. The apps have no database. Keychain and Secret Service access is not logged.
- **A new background job** (timer or poll loop) must, on macOS, add an `os.Logger` `debug` line at start and an `error` line on failure. On Linux, it must add a stderr line on failure.
- **A new external call** (any host beyond the configured Jira URL and GitHub Releases) must be named, with host and path, in [docs/api-design.md](api-design.md) or [docs/linux.md](linux.md). It must log failures at error level, naming the path but never the token, and be covered by a `MockURLProtocol` test (macOS) or a Rust unit test (Linux).
- **Any future telemetry** (crash reporting, analytics, a metrics endpoint) requires reopening this policy and a product decision first, and must keep the credential rule above.

### Known gaps

- Accepted: these are desktop apps with no log shipper, so they do not emit JSON on stdout; they use `os.Logger` on macOS and plain-text stderr on Linux instead of the structured JSON contract.
- Accepted: nothing is hosted, so there are no metrics, traces, SLOs, dashboards or alerts.
- The macOS hourly refresh timer (`WorklogStateManager.setupTimer` / `loadTempoData`) logs no `debug` line when it starts. `loadTempoData` failures from HTTP status errors (401, 403, other non-200) are mapped to state but not logged at error level; only transport errors in `TempoService` are logged.
- The macOS daily update-check timer (`AppDelegate.scheduleAutomaticUpdateChecks` / `runAutomaticUpdateCheck`) logs no `debug` start line. Failures are logged by `UpdateChecker`.
- The Linux poll loop (`poll_loop`/`poll_once` in `linux/src/main.rs`) writes no stderr line when a poll fails; the error appears only in the tray status.
- `TempoService.performRequest` does not log non-200 HTTP responses, which falls short of the rule that external-call failures are logged at error level.
