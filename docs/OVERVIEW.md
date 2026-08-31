# TempoStatusBar — Developer Overview

## Purpose

TempoStatusBar is a repository for a signed macOS menu bar app and a separate Linux tray companion that monitor Jira Tempo Server/Data Center worklog activity. The macOS app is the primary product; the Linux crate mirrors the same API contract and status semantics for Linux desktops without sharing implementation code.

## Architecture

The project is a single-target macOS app with no external package dependencies. All source files live flat in the repo root.

```
TempoStatusBarApp.xcodeproj/   Xcode project
AppDelegate.swift              App entry point, NSStatusBar integration
TempoService.swift             State manager, API client, data models
CredentialManager.swift        Encrypted credential persistence
ContentView.swift              SwiftUI popover (status detail view)
SettingsView.swift             SwiftUI settings popover
UpdateChecker.swift            GitHub Releases update check
LaunchAtLoginManager.swift     SMAppService login-item wrapper (macOS 13+)
TempoStatusBarAppTests/        XCTest unit tests (mocked)
linux/                         Linux tray app (Rust) — see "Linux App" below
flake.nix                      Nix dev shell + package for the Linux app
.github/actions/               Composite actions (setup-nix)
.github/workflows/             CI/CD (PR, main, release, Linux)
README.md                      Private-repo README (setup/config instructions)
README.public.md               Source for the public repo's README — see "Public Snapshot" below
```

### Linux App

`linux/` is a separate Rust implementation of the same idea for Linux desktops:
a StatusNotifierItem tray (via `ksni`) that polls the same two Tempo endpoints
and applies the same severity thresholds and colours. It is not a port of the
Swift code and shares no source with it — the macOS app is unchanged by its
existence. Credentials come from the freedesktop Secret Service, a
`token_command`, or `TEMPO_API_TOKEN`; the Linux app now has native GTK status
and settings windows, but still has no update checker. See [linux.md](linux.md)
for the architecture, config precedence rules, desktop-environment credential
matrix, and deliberate scope cuts.

## Documentation Map

- [api-design.md](api-design.md): Tempo Server/Data Center endpoints, auth, identifier resolution, and API-layer error handling.
- [ci-cd.md](ci-cd.md): GitHub Actions workflows, self-hosted runner constraints, signing, notarization, S3 release storage, and release automation.
- [linux.md](linux.md): Linux crate architecture, config and credential resolution, GTK windows, static release constraints, and tray-specific gotchas.
- [DESIGN.md](DESIGN.md): Linux GTK presentation rules only.
- [requirements.md](requirements.md): Cross-cutting owner requirements that are not owned by a single subsystem doc.
- [claws-automation.md](claws-automation.md): Automatically maintained repo automation conventions; do not edit it manually.

### Key Classes

| Class / Type | Role |
|---|---|
| `AppDelegate` | `NSApplicationDelegate`; owns `NSStatusItem` and two `NSPopover` instances (status and settings), both created at startup in `setupStatusBar()` |
| `WorklogStateManager` | `@MainActor` singleton `ObservableObject`; central state (days, latest worklog, error, loading); drives all UI |
| `TempoService` | Singleton; fetches worklogs and user info from Jira/Tempo API |
| `CredentialManager` | Singleton; persists credentials to macOS Keychain |
| `LaunchAtLoginManager` | Singleton; wraps `SMAppService.mainApp` (macOS 13+) to register/unregister the app as a login item |
| `UpdateChecker` | `@MainActor` singleton; queries GitHub Releases `/latest` and compares to `appVersion` |
| `ContentView` | SwiftUI popover shown by "Status" menu item |
| `SettingsView` | SwiftUI popover shown by "Settings" menu item (also openable from `ContentView`) |
| `runConnectionTest` | Module-level free function called by `SettingsView`; extracted from the view to enable unit testing without a SwiftUI host |

## Key Patterns

### State Management

`WorklogStateManager.shared` is the single source of truth. It exposes `@Published` properties:

- `daysSinceLastWorklog: Int?` — nil until data is loaded
- `latestWorklog: Worklog?`
- `isLoading: Bool`
- `lastError: WorklogStateError?` — typed error; see `WorklogStateError` below
- `hasCredentials: Bool`
- `warningThreshold: Int` — loaded from credentials; default 7

`errorMessage: String?` is a computed property (`lastError?.displayMessage`) provided for convenience; it is not `@Published`.

`AppDelegate` subscribes to `$daysSinceLastWorklog`, `$lastError`, and `$hasCredentials` via a single `Publishers.Merge3(...).sink` call (Combine) in `setupStateObserver()` and re-renders the status bar item on any change.

`checkCredentialsAndRefresh()` loads credentials once and passes them to `loadTempoData(preloadedCredentials:)`. This avoids a second Keychain read inside `loadTempoData` when credentials were already read at the call site. It also updates `hasCredentials` and `warningThreshold` synchronously before the async fetch begins. Tests that call `loadTempoData` directly can supply preloaded credentials via the same parameter.

`refresh()` is a lighter-weight re-fetch that calls `loadTempoData()` directly without pre-loading credentials. It short-circuits immediately if `hasCredentials` is `false`. Use this path when credentials are known to be valid and only the worklog data needs to be re-fetched — `ContentView`'s "Refresh" button uses `refresh()` while `onAppear` uses `checkCredentialsAndRefresh()` (which also revalidates credentials).

### Error Types

Two error enums model different failure domains:

**`WorklogStateError`** — the surface-level error stored in `WorklogStateManager.lastError`:

```swift
enum WorklogStateError: Equatable {
    case noCredentials              // loadCredentials() threw noStoredCredentials
    case credentialError(detail: String)  // any other credential load failure
    case keychainError(status: OSStatus)  // raw Keychain OSStatus failure
    case tempo(TempoError)          // wraps a TempoError from the API layer
    case other(message: String)     // unexpected error from anywhere
}
```

**`CredentialError`** — thrown by `CredentialManager` and mapped to `WorklogStateError` cases in `loadTempoData()`:

```swift
enum CredentialError: Error {
    case noStoredCredentials        // no Keychain item and no legacy UserDefaults item
    case decodingFailed(error: Error)  // JSON decode of Keychain data failed
    case keychainError(status: OSStatus)  // Keychain API returned non-success status
}
```

**`TempoError`** — thrown by `TempoService` and wrapped in `WorklogStateError.tempo(_:)`:

```swift
enum TempoError: Error, LocalizedError, Equatable {
    case missingCredentials   // identifier empty after /myself lookup
    case invalidURL           // malformed jiraURL
    case unauthorized         // HTTP 401
    case forbidden            // HTTP 403
    case networkError         // URLSession failure or non-HTTPURLResponse
    case apiError(statusCode: Int)  // any other non-200
}
```

Credential changes are broadcast via `NotificationCenter` (`.credentialsChanged`) so that `AppDelegate` can call `stateManager.checkCredentialsAndRefresh()` immediately without polling.

### Minimal Main Menu

`AppDelegate.applicationDidFinishLaunching(_:)` installs a minimal `NSMenu` as `NSApp.mainMenu` with two submenus: **App** (Quit) and **Edit** (Undo, Redo, Cut, Copy, Paste, Select All). This is required because the app runs as `LSUIElement = YES` (no Dock icon, no standard foreground activation policy) — without an explicit main menu, SwiftUI `TextField` and `SecureField` inside popovers do not receive the standard Edit action selectors, so keyboard shortcuts like Cmd+V (Paste) and Cmd+A (Select All) are silently dropped.

### Status Bar Menu Structure

The status bar item's context menu is assembled in `AppDelegate.setupStatusBar()`. The menu order is:

1. Status — opens the status detail popover (`ContentView`)
2. *(separator)*
3. About TempoStatusBar — calls `showAbout()`
4. Check for Updates… — calls `UpdateChecker.shared.checkForUpdates()` and presents an alert
5. *(separator)*
6. Settings — opens the settings popover (`SettingsView`)
7. *(separator)*
8. Quit

`showAbout()` displays an `NSAlert` (not `NSApp.orderFrontStandardAboutPanel`) because the app runs as a `LSUIElement = YES` agent; `orderFrontStandardAboutPanel` does not reliably render in apps without a standard foreground activation policy. The version string shown is the build-time `appVersion` constant — see [Version String Generation](#version-string-generation) below.

### Settings View Behavior

`SettingsView` has two action buttons beyond Save:

- **Auto-detect** (Account ID field): calls `TempoService.fetchUserInfo` with the current token/URL and fills in `accountId` from `userInfo.name`. The field is populated but not saved until the user clicks "Save & Done".
- **Test Connection**: calls the module-level `runConnectionTest` function, which:
  1. If `accountId` is non-empty: calls `/myself` and compares the returned `name`/`key` against the supplied `accountId` (case-insensitive). A mismatch returns a `⚠️` warning and skips the worklog fetch — this prevents a false positive where authentication succeeds but the wrong user's worklogs are queried.
  2. Calls `fetchLatestWorklog` and reports success or the specific error.
- **Clear Stored Credentials** (shown only when `stateManager.hasCredentials` is `true`): calls `deleteCredentials()`, which deletes the Keychain item, removes any legacy `UserDefaults` keys, clears all form fields, and resets `warningThreshold` to 7. The deletion posts `.credentialsChanged`, so `AppDelegate` refreshes the status bar immediately.

All credential fields (`apiToken`, `accountId`, `jiraURL`) are whitespace-trimmed before any save or test operation.

`ContentView` provides a secondary entry point to settings: when `hasCredentials` is `false`, it renders an "Open Settings" button that opens `SettingsView` as a SwiftUI `.sheet`. This is a separate `SettingsView` instance from the `settingsPopover` in `AppDelegate`; both load and save credentials independently via `CredentialManager.shared`.

### Status Bar Display Logic

`AppDelegate.updateStatusBarDisplay()` reads from `WorklogStateManager` computed properties to render the status bar item:

- **Error / no credentials:** `button.title = "❌"` + a tooltip chosen by **typed** pattern-matching on `stateManager.lastError`:
  - `.tempo(.unauthorized)` → "API token invalid…"
  - `.tempo(.forbidden)` → "Access forbidden…"
  - `.tempo(.apiError(404))` / `.tempo(.missingCredentials)` → "Account not found…"
  - `.tempo(.networkError)` → "Network error…"
  - anything else → `error.displayMessage`
  - No credentials at all (`!stateManager.hasCredentials`) → "No credentials configured…"
- **Normal state:** uses `stateManager.statusBarTitle` (plain text) and an `NSAttributedString` with `stateManager.statusBarColor` (an `NSColor`) for color

All threshold comparisons go through a single private `Severity` enum (`ok`, `warning`, `overdue`) computed from `daysSinceLastWorklog` and `warningThreshold`. All status computed properties (`statusEmoji`, `statusBarTitle`, `statusBarColor`, `statusColor`) switch on `severity` rather than re-implementing the boundary conditions independently.

The computed properties on `WorklogStateManager` that drive rendering:

| Property | nil | `days <= threshold` | `days == threshold+1` | `days > threshold+1` |
|---|---|---|---|---|
| `statusEmoji` | `""` | `✅` | `⏰` | `🚨` |
| `statusBarTitle` | `"⏱️"` | `"✅ <days>"` | `"⏰ <days>"` | `"🚨 <days>"` |
| `statusBarColor` (NSColor) | `.labelColor` | `.systemGreen` | `.systemOrange` | `.systemRed` |
| `statusColor` (SwiftUI Color) | `.secondary` | `.green` | `.orange` | `.red` |
| `statusBarTooltip` | `"No worklog data available"` | `"Last worklog: N day(s) ago"` | same | same |

### Dependency Injection for Testing

`WorklogStateManager` accepts injected implementations of two protocols:

```swift
protocol CredentialManagerProtocol { ... }
protocol TempoServiceProtocol { ... }
```

The real singletons (`CredentialManager.shared`, `TempoService.shared`) are the defaults. Tests inject `MockCredentialManager` and `MockTempoService` by setting `stateManager.credentialManager` and `stateManager.tempoService` after calling `stateManager.resetForTesting()`.

### Popover Sizing

Two `NSPopover` instances are created in `AppDelegate.setupStatusBar()` / `showSettings()`. Each popover's `contentSize` **must match** the SwiftUI `.frame(width:height:)` declared in the corresponding view, otherwise macOS anchors the popover based on the declared size and the extra content overflows into the menu bar area.

| Popover | `NSPopover.contentSize` | SwiftUI frame |
|---|---|---|
| Status (`ContentView`) | `NSSize(width: 350, height: 280)` | `.frame(width: 350, height: 280)` |
| Settings (`SettingsView`) | `NSSize(width: 400, height: 640)` | `.frame(width: 400, height: 640)` |

When changing a view's frame size, always update the matching `contentSize` in `AppDelegate`.

### Launch at Login

`LaunchAtLoginManager.shared` wraps `SMAppService.mainApp` from the `ServiceManagement` framework. `isEnabled` reads live OS state on every call — do not cache it; the OS is the source of truth. `setEnabled(_:)` is a throwing function; `SettingsView` reverts the toggle on error. On macOS 12, the API is unavailable: `isEnabled` returns `false` and the Settings toggle is rendered as a disabled informational row. No entitlement or `Info.plist` changes are needed beyond `import ServiceManagement`.

### Auto-Refresh and Network Error Recovery

`WorklogStateManager` installs a `Timer` that fires every 3600 seconds (1 hour) to call `loadTempoData()`. The timer is invalidated by `resetForTesting()`.

Two additional recovery mechanisms handle transient network failures (e.g., VPN reconnect):

- **`NWPathMonitor`** (`import Network`): when the network path becomes `.satisfied` while `lastErrorWasNetworkError == true` and credentials are present, the monitor automatically calls `loadTempoData()` on the main actor. This recovers the status icon as soon as the VPN interface comes up.
- **Scheduled retry task** (`retryTask`): when a `.networkError` is thrown, a `Task` is queued to retry `loadTempoData()` after `retryDelay` seconds (default `15`). The task is cancelled if the path monitor fires first, or if a new load starts. `retryDelay` is non-`private` so tests can set it to a small value (e.g. `0.05`) to avoid slow test execution.

The `lastErrorWasNetworkError` flag is set `true` only on `.networkError` and cleared on any successful load, any other error type, or `resetForTesting()`. This prevents the path monitor from triggering spurious reloads during normal operation when the network path changes.

### Update Checking

`AppDelegate` triggers update checks in two ways: on launch (`runAutomaticUpdateCheck()`) and every 24 hours via an `updateCheckTimer` (`Timer`, 86400 s). The manual "Check for Updates…" menu item calls `checkForUpdatesManually()`. Both paths delegate to `performUpdateCheck(showUpToDateAlert:respectSkippedVersion:)`, which calls `UpdateChecker.shared.checkForUpdates()` and presents an alert based on the result:

- `.upToDate` — shows an info alert only when `showUpToDateAlert` is `true`
- `.updateAvailable` — shows a three-button alert: **Download Update**, **Skip This Version**, **Remind Me Later**
- `.skipped` / `.failed` — shows an info/warning alert only when `showUpToDateAlert` is `true`

The automatic path passes `respectSkippedVersion: true` so the alert is suppressed if the user previously clicked "Skip This Version". The manual path always shows a result.

`UpdateChecker.shared` performs the actual API call to `https://api.github.com/repos/stjohnb/TempoStatusBar/releases/latest` — a **public** repo, distinct from the private `St-John-Software/TempoStatusBar` source repo this codebase lives in. Requests include `User-Agent: TempoStatusBar/<version>` — the GitHub API rejects requests that omit this header. `parseSemver` strips leading `v`/`V`, splits on `.`, and pads shorter arrays with zeros for comparison — correctly handling `1.2.10 > 1.2.9` where string comparison would fail. "Skip This Version" persists the version string in `UserDefaults` under `TempoStatusBar.UpdateChecker.skippedVersion`. No Sparkle dependency — users click through to `release.html_url` to download.

**Testability:** `UpdateChecker` exposes two injectable properties for unit tests:
- `session: URLSession` — replaced with an ephemeral session backed by `MockURLProtocol` to intercept network requests without hitting the real GitHub API
- `currentVersionProvider: () -> String` — overridden to return a controlled version string

**No authentication:** requests are unauthenticated — there is no GitHub token plumbing (removed in #161, which repointed the checker from the private source repo at the public mirror). A `404` is treated as `.skipped(reason: "no published releases")` rather than an error, since the public repo may not yet have any releases published. HTTP `401` and other non-200 statuses are treated as `.failed`.

### Public Snapshot

Development happens in this private repo; a public mirror at `stjohnb/TempoStatusBar` is what `UpdateChecker` and end users see. Two independent mechanisms populate it, both external to this repo's own CI:

- **Source snapshot** — a Claws sync routine periodically publishes a squashed, history-free snapshot of this repo to the public one. `README.public.md` (repo root) is the source for that snapshot's `README.md` — the filename never appears in the published output, so its content must never self-reference `README.public.md`, mention syncing/snapshotting, or reference this private source repo, credentials, self-hosted CI, or signing/release internals. `README.md` (this repo's own root README) is separate and is **not** published as-is.
- **Release mirroring** — when a new stable release (not RC/pre-release) is published here, a separate Claws routine fetches the notarized DMG and creates/updates the matching release on the public repo (most-recent-only, no historical backfill). This is what `UpdateChecker` polls via the public repo's `/releases/latest`. Nothing in `.github/workflows/release-tag.yml` performs this mirroring — it happens entirely outside this repo's CI, using credentials the sync routine already holds. **Since #177 the DMG is no longer attached to this repo's GitHub Release as an asset** — `release-tag.yml` publishes it to S3 (`https://tempo-statusbar-releases.s3.us-east-1.amazonaws.com/releases/TempoStatusBarApp-<version>.dmg`) and writes that link into the release body. The external mirror routine must download the DMG from the S3 URL (or the release-body link), not from a release asset — coordinating that change in the routine is outside this repo.

## API Integration

The app targets the **Tempo Server / Data Center** REST API (not Tempo Cloud). See [api-design.md](api-design.md) for full details.

**Endpoints used:**

| Method | Path | Purpose |
|---|---|---|
| GET | `/rest/api/2/myself` | Resolve username/key from API token |
| GET | `/rest/tempo-timesheets/3/worklogs` | Fetch worklogs for a user (60-day window) |

Auth: `Authorization: Bearer <apiToken>` header.

User identification uses `name` or `key` from `/myself` (Jira Server username), not the Atlassian cloud `accountId`. `UserInfo` exposes `name`, `key`, and `emailAddress` fields directly — there is no custom decoder and no `accountId` field.

## Credential Storage

Credentials are stored in the macOS Keychain as a JSON-encoded blob under service `com.stjohnsoftware.TempoStatusBarApp`, account `credentials`. The Keychain provides hardware-backed encryption at rest and OS-level access control. The item is marked `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, which prevents iCloud Keychain backup and sync of API tokens — appropriate for security tokens that should not leave the device. On macOS the login keychain remains unlocked for the duration of the user session, so the app can read credentials at any point while logged in.

The app is **not sandboxed** (`com.apple.security.app-sandbox` is absent from the entitlements). This means Keychain access and outbound HTTPS work without additional entitlements; the Release build uses an empty entitlements plist to satisfy `CODE_SIGN_ENTITLEMENTS` while maintaining Hardened Runtime compatibility.

A migration path exists for users upgrading from versions that stored credentials in `UserDefaults` (pre-Keychain). On first `loadCredentials()` call, if no Keychain item exists under the current service name, the manager checks for AES-GCM-encrypted credentials in `UserDefaults`, decrypts them, saves them to Keychain, and removes the `UserDefaults` keys. Users upgrading from builds that used the previous Keychain service name (`com.stjohnsoftware.TempoStatusBar`, pre-#95) must re-enter their credentials once; the old item is left in place and ignored to avoid triggering an ACL prompt across signing identities (see #94/#98).

Fields stored: `apiToken`, `accountId` (username), `jiraURL`, `warningThreshold`. (A `githubToken` field existed prior to #161 for authenticated update checks against the private repo; it was removed once `UpdateChecker` was repointed at a public repo. Old Keychain blobs containing a `githubToken` key still decode cleanly since `Credentials` uses synthesized `Decodable`, which ignores unknown JSON keys.)

Saving or deleting credentials posts `.credentialsChanged` to `NotificationCenter`.

## Version String Generation

`appVersion` is a build-time constant generated by a Run Script build phase in `TempoStatusBarApp.xcodeproj`. The script writes `AppVersion.swift` to `${DERIVED_FILE_DIR}` (not in the source tree) with the content:

```swift
let appVersion = "<resolved-version>"
```

Resolution order:
1. `MARKETING_VERSION` build setting (e.g. `1.0`) — used if set and not equal to the default `1.0`
2. `git describe --tags --abbrev=0` (latest tag, with leading `v` stripped)
3. `"unknown"` if both sources fail

CI release and PR builds always pass `MARKETING_VERSION=<tag-version>` on the `xcodebuild` command line, which overrides the value baked into `project.pbxproj` and ensures the binary version matches the release tag. Without this override the hardcoded `MARKETING_VERSION` in the project file would take precedence over the tag (the failure mode fixed in #105).

`AppDelegate.showAbout()` displays this constant in the About alert. Because the file lives in `DerivedData`, it is never checked in — developers who open the project fresh must build once before the constant is visible to Swift.

## Configuration

User-facing configuration is platform-specific.

### macOS app

| Field | Description | Default |
|---|---|---|
| Jira Instance URL | Base URL, e.g. `https://yourcompany.atlassian.net` | — |
| API Token | Jira Personal Access Token | — |
| Account ID | Jira username (optional; auto-detected via `/myself`) | — |
| Warning Threshold | Days before warning state activates | 7 |
| Launch at Login | Toggle in "App Settings" section; macOS 13+ only (disabled with explanatory note on macOS 12) | off |

macOS credentials are stored in the Keychain JSON blob under service `com.stjohnsoftware.TempoStatusBarApp`, account `credentials`. There are no macOS runtime environment variables; update checks are unauthenticated against the public GitHub repo, so the old GitHub token setting is gone.

### Linux app

The Linux crate resolves configuration per field from `config.toml`, Secret Service, and one environment variable:

| Setting | Source(s) | Notes |
|---|---|---|
| `jira_url` | `config.toml`, Secret Service | file overrides stored value when non-blank |
| `account_id` | `config.toml`, Secret Service | blank means resolve from `/myself` |
| `warning_threshold` | `config.toml`, Secret Service | defaults to `7` |
| `poll_interval_secs` | `config.toml` only | defaults to `3600`, floored to `60` |
| `token_command` | `config.toml` only | shell command whose stdout is the token |
| `TEMPO_API_TOKEN` | environment | highest-precedence Linux token source |

There are no hardcoded API hosts beyond the relative Jira and Tempo paths. See [linux.md](linux.md) for the exact precedence rules and for the static-release caveat: the published Linux tarball intentionally omits the GTK GUI because GTK cannot be statically linked into the `.#static` build.

## Automation

Issue triage, PR labelling, and related repository maintenance are handled by the Claws automation service. See [claws-automation.md](claws-automation.md) for details on how Claws manages this repo.

## Requirements

Standing, cross-cutting constraints from the repo owner that aren't tied to one subsystem doc (e.g. GitHub repo settings, secret-handling policy) live in [requirements.md](requirements.md). Subsystem-specific constraints and their rationale live inline in the relevant doc (this file, [api-design.md](api-design.md), [ci-cd.md](ci-cd.md)) rather than in a separate log.

## CI/CD

Nine GitHub Actions workflows — see [ci-cd.md](ci-cd.md) for full details. DMGs are stored in S3 (bucket `tempo-statusbar-releases`), uploaded via GitHub OIDC (`AWS_ROLE_ARN` secret) — not as GitHub Release assets (#177). The Linux tray app releases separately as a GitHub release asset, not via S3 (#192).

| Workflow | Trigger | Key jobs |
|---|---|---|
| `linux-ci.yml` | PRs/pushes touching `linux/**`, `flake.nix`, `flake.lock` | `cargo fmt --check`, clippy, test, release build — all via `nix develop` on `[self-hosted, linux]` |
| `linux-release.yml` | Push to `main` touching `linux/**`, `flake.nix`, `flake.lock`, manual | Version-gated: builds `.#static` (musl), asserts static linkage + `--version` match, tags `linux-vX.Y.Z`, publishes tarball + `.sha256` as GitHub release assets |
| `pr-verification.yml` | PRs to `main` | Build+test (with signing), SwiftLint, Trivy scan, DMG upload to `s3://…/pr/<N>/`, PR comment |
| `pr-cleanup.yml` | PR `closed` | Deletes the PR's `pr/<N>/` prefix from S3 |
| `main-verification.yml` | Push to `main`, manual | Build (with signing), Trivy scan, docs check |
| `release-tag.yml` | Release events, manual | Release build (with signing), DMG upload to `s3://…/releases/`, download link in release notes, Trivy scan, docs check — skipped for `linux-v*` releases |
| `s3-bootstrap.yml` | Manual only | One-time idempotent provisioning of the S3 bucket + OIDC role (uses temporary bootstrap credentials, then decommissioned) |
| `notify-failures.yml` | `workflow_run` on `Main Verification`, `Actions Storage Cleanup`, `Linux CI`, or `Linux Release` failure (push/schedule runs only) | Creates a GitHub issue when a monitored main-branch workflow fails (deduplicates per workflow) |
| `actions-storage-cleanup.yml` | Push to `main` (primary), daily 05:00 UTC backstop, manual | Purges all GHA caches and artifacts older than 3 days to protect org storage quota |

`.github/dependabot.yml` (not a workflow) enables weekly dependency updates for the `github-actions` (`/`) and `cargo` (`/linux`) ecosystems, each grouped into a single PR — see [ci-cd.md](ci-cd.md#githubdependabotyml--dependency-updates).

All macOS jobs start with a shared `Select Xcode` step that resolves the newest installed Xcode on the runner and exports a job-scoped `DEVELOPER_DIR` (no `sudo`, no machine-global `xcode-select` — the two Macs are shared with namey and bonkus CI). PR and main workflows use `cancel-in-progress: true`; the release workflow uses `cancel-in-progress: false`. Build/test/quality jobs run on `[self-hosted, macos, tempo]`; utility jobs (security scans, docs checks, PR cleanup, failure notification) run on `[self-hosted, linux]`. Changes are batched and the number of PRs is kept low to reduce queue wait times.

All build jobs sign the `.app` bundle using a Developer ID Application certificate stored as repository secrets (`SIGNING_CERT_P12_BASE64`, `SIGNING_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`). The certificate is imported into a temporary keychain at build time and verified with `codesign --verify --deep --strict` before DMG packaging. See [ci-cd.md](ci-cd.md#code-signing) for full details.

## Testing

Tests live in `TempoStatusBarAppTests/`. The custom shell script `run_tests.sh` is used by CI instead of a plain `xcodebuild test` call.

### `WorklogStateManagerTests.swift` — four test classes

| Test class | Coverage |
|---|---|
| `WorklogStateManagerTests` | Initial state, credential loading, data fetching, error handling (including network retry), computed status properties, data clearing |
| `ConnectionTestTests` | `runConnectionTest` — Account ID mismatch, case-insensitive match, key-field fallback, nil identity fields, fetch-user-info errors, empty accountId bypass |
| `CredentialManagerHasStoredCredentialsTests` | `hasStoredCredentials()` before/after save and delete (hits the real Keychain; whole suite is skipped when `TEMPO_SKIP_KEYCHAIN_TESTS=1`, as set on the shared self-hosted CI runners — see [ci-cd.md](ci-cd.md#key-design-decisions)) |
| `WorklogDaysSinceStartedTests` | `Worklog.daysSinceStarted` — today (0), N days ago, malformed date, ISO8601 with timezone, future date |

### `UpdateCheckerTests.swift` — one test class + `MockURLProtocol`

| Test class | Coverage |
|---|---|
| `UpdateCheckerTests` | `parseSemver` (v-prefix, uppercase V, no prefix, unknown/empty/prerelease returns nil), `compare` (numeric ordering, padding, equal), `checkForUpdates` (unknown version skipped, HTTP 404 returns `.skipped`, HTTP 200 newer/same tag, HTTP 401/non-200 returns `.failed`, transport error, malformed JSON) |

`MockURLProtocol` is a `URLProtocol` subclass that intercepts all requests made through an ephemeral `URLSession`. Tests inject it by setting `UpdateChecker.shared.session` to a session whose `URLSessionConfiguration.ephemeral.protocolClasses` includes `MockURLProtocol`. The static `handler` closure returns the desired `(Data, URLResponse)` or throws to simulate transport errors. This keeps update-checker tests entirely offline.
