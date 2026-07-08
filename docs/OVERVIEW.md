# TempoStatusBar — Developer Overview

## Purpose

TempoStatusBarApp is a macOS menu bar application that monitors Jira Tempo worklog activity. It polls the Tempo REST API hourly and displays in the menu bar how many days have elapsed since the user's last worklog entry, using color-coded status indicators so users can immediately see if they are overdue.

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
TempoStatusBarAppTests/        XCTest unit tests (mocked)
.github/workflows/             CI/CD (PR, main, release)
```

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

`checkCredentialsAndRefresh()` loads credentials once and passes them to `loadTempoData(preloadedCredentials:)`. This avoids a second Keychain read inside `loadTempoData` when credentials were already read at the call site. Tests that call `loadTempoData` directly can supply preloaded credentials via the same parameter.

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
enum TempoError: Error {
    case missingCredentials   // identifier empty after /myself lookup
    case invalidURL           // malformed jiraURL
    case unauthorized         // HTTP 401
    case forbidden            // HTTP 403
    case networkError         // URLSession failure or non-HTTPURLResponse
    case apiError(statusCode: Int)  // any other non-200
}
```

Credential changes are broadcast via `NotificationCenter` (`.credentialsChanged`) so that `AppDelegate` can call `stateManager.checkCredentialsAndRefresh()` immediately without polling.

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

`showAbout()` displays an `NSAlert` (not `NSApp.orderFrontStandardAboutPanel`) because the app runs as a `LSUIElement = YES` agent; `orderFrontStandardAboutPanel` does not reliably render in apps without a standard foreground activation policy. The version string is read from `Bundle.main` keys `CFBundleShortVersionString` (marketing version, e.g. `1.0`) and `CFBundleVersion` (build number).

### Settings View Behavior

`SettingsView` has two action buttons beyond Save:

- **Auto-detect** (Account ID field): calls `TempoService.fetchUserInfo` with the current token/URL and fills in `accountId` from `userInfo.name`. The field is populated but not saved until the user clicks "Save & Done".
- **Test Connection**: calls the module-level `runConnectionTest` function, which:
  1. If `accountId` is non-empty: calls `/myself` and compares the returned `name`/`key` against the supplied `accountId` (case-insensitive). A mismatch returns a `⚠️` warning and skips the worklog fetch — this prevents a false positive where authentication succeeds but the wrong user's worklogs are queried.
  2. Calls `fetchLatestWorklog` and reports success or the specific error.
- **Clear Stored Credentials** (shown only when `CredentialManager.shared.hasStoredCredentials()` is `true`): calls `deleteCredentials()`, which deletes the Keychain item, removes any legacy `UserDefaults` keys, clears all form fields, and resets `warningThreshold` to 7. The deletion posts `.credentialsChanged`, so `AppDelegate` refreshes the status bar immediately.

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

`UpdateChecker.shared` queries `https://api.github.com/repos/St-John-Software/TempoStatusBar/releases/latest` on launch and every 24 hours via a `Timer`. `parseSemver` strips leading `v`/`V`, splits on `.`, and pads shorter arrays with zeros for comparison — correctly handling `1.2.10 > 1.2.9` where string comparison would fail. The manual "Check for Updates…" menu item always shows a result and ignores `skippedVersion`; the automatic path suppresses the alert if the user previously chose "Skip This Version" for the latest release. "Skip This Version" persists the version string in `UserDefaults` under `TempoStatusBar.UpdateChecker.skippedVersion`. No Sparkle dependency — users click through to `release.html_url` to download.

**Private repository support:** when the repository is private, unauthenticated requests return 404. Users can configure an optional GitHub Personal Access Token (PAT) in the "GitHub Update Token" field in Settings. The token is stored in the Keychain alongside other credentials and sent as `Authorization: Bearer <token>` on update-check requests. A fine-grained PAT scoped to `St-John-Software/TempoStatusBar` with `Contents: read` is sufficient. When a token is configured, a `404` response is treated as `.failed` (wrong scope, revoked, or wrong account) rather than `.skipped`, so the user receives a visible error instead of silent skipping. Without a token, a `404` is still treated as `.skipped(reason: "no published releases")`. HTTP `401` is always treated as `.failed` regardless of token presence.

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

A migration path exists for users upgrading from versions that stored credentials in `UserDefaults` (pre-Keychain). On first `loadCredentials()` call, if no Keychain item exists under the current service name, the manager checks for AES-GCM-encrypted credentials in `UserDefaults`, decrypts them, saves them to Keychain, and removes the `UserDefaults` keys. Users upgrading from builds that used the previous Keychain service name (`com.stjohnsoftware.TempoStatusBar`, pre-#95) must re-enter their credentials once; the old item is left in place and ignored to avoid triggering an ACL prompt across signing identities (see #94/#98).

Fields stored: `apiToken`, `accountId` (username), `jiraURL`, `warningThreshold`, `githubToken` (optional; used for authenticated update checks against private repos).

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

`AppDelegate.showAbout()` displays this constant in the About alert. Because the file lives in `DerivedData`, it is never checked in — developers who open the project fresh must build once before the constant is visible to Swift.

## Configuration

All user-facing configuration is set via `SettingsView`:

| Field | Description | Default |
|---|---|---|
| Jira Instance URL | Base URL, e.g. `https://yourcompany.atlassian.net` | — |
| API Token | Jira Personal Access Token | — |
| Account ID | Jira username (optional; auto-detected via `/myself`) | — |
| Warning Threshold | Days before warning state activates | 7 |
| Launch at Login | Toggle in "App Settings" section; macOS 13+ only (disabled with explanatory note on macOS 12) | off |
| GitHub Update Token | Optional PAT for authenticated update checks; required when the repo is private. Fine-grained PAT scoped to `St-John-Software/TempoStatusBar` with `Contents: read`. | — |

No environment variables or build-time configuration. There are no hardcoded endpoints beyond the relative API paths.

## CI/CD

Five GitHub Actions workflows — see [ci-cd.md](ci-cd.md) for full details.

| Workflow | Trigger | Key jobs |
|---|---|---|
| `pr-verification.yml` | PRs to `main` | Build+test (with signing), SwiftLint, Trivy scan, per-PR pre-release publish, PR comment |
| `pr-cleanup.yml` | PR `closed` | Deletes the per-PR pre-release |
| `main-verification.yml` | Push to `main`, manual | Build (with signing), Trivy scan, docs check |
| `release-tag.yml` | Release events, manual | Release build (with signing), Trivy scan, docs check |
| `notify-failures.yml` | `main-verification` failure | Creates a GitHub issue when main-branch build fails (deduplicates) |

All workflows use `xcode-version: '26.x'`. PR and main workflows use `cancel-in-progress: true`; the release workflow uses `cancel-in-progress: false`.

All build jobs sign the `.app` bundle using a self-signed certificate stored as repository secrets (`SIGNING_CERT_P12_BASE64`, `SIGNING_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`). The certificate is imported into a temporary keychain at build time and verified with `codesign --verify --deep --strict` before DMG packaging. See [ci-cd.md](ci-cd.md#code-signing) for full details.

## Testing

Tests live in `TempoStatusBarAppTests/`. The custom shell script `run_tests.sh` is used by CI instead of a plain `xcodebuild test` call.

`WorklogStateManagerTests.swift` contains four test classes:

| Test class | Coverage |
|---|---|
| `WorklogStateManagerTests` | Initial state, credential loading, data fetching, error handling (including network retry), computed status properties, data clearing |
| `ConnectionTestTests` | `runConnectionTest` — Account ID mismatch, case-insensitive match, key-field fallback, nil identity fields, fetch-user-info errors, empty accountId bypass |
| `CredentialManagerHasStoredCredentialsTests` | `hasStoredCredentials()` before/after save and delete (hits the real Keychain) |
| `WorklogDaysSinceStartedTests` | `Worklog.daysSinceStarted` — today (0), N days ago, malformed date, ISO8601 with timezone, future date |
