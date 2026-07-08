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
TempoStatusBarAppTests/        XCTest unit tests (mocked)
.github/workflows/             CI/CD (PR, main, release)
```

### Key Classes

| Class / Type | Role |
|---|---|
| `AppDelegate` | `NSApplicationDelegate`; owns `NSStatusItem` and one persistent `NSPopover` (status); creates settings `NSPopover` on demand |
| `WorklogStateManager` | `@MainActor` singleton `ObservableObject`; central state (days, latest worklog, error, loading); drives all UI |
| `TempoService` | Singleton; fetches worklogs and user info from Jira/Tempo API |
| `CredentialManager` | Singleton; persists credentials to macOS Keychain |
| `ContentView` | SwiftUI popover shown by "Status" menu item |
| `SettingsView` | SwiftUI popover shown by "Settings" menu item (also openable from `ContentView`) |

## Key Patterns

### State Management

`WorklogStateManager.shared` is the single source of truth. It exposes `@Published` properties:

- `daysSinceLastWorklog: Int?` — nil until data is loaded
- `latestWorklog: Worklog?`
- `isLoading: Bool`
- `errorMessage: String?`
- `hasCredentials: Bool`
- `warningThreshold: Int` — loaded from credentials; default 7

`AppDelegate` subscribes to these via `AsyncStream` (Swift concurrency `for await` on `$property.values`) and re-renders the status bar item on any change.

Credential changes are broadcast via `NotificationCenter` (`.credentialsChanged`) so that `AppDelegate` can call `stateManager.checkCredentialsAndRefresh()` immediately without polling.

### Status Bar Menu Structure

The status bar item's context menu is assembled in `AppDelegate.setupStatusBar()`. The menu order is:

1. Status — opens the status detail popover (`ContentView`)
2. *(separator)*
3. About TempoStatusBar — calls `showAbout()`
4. *(separator)*
5. Settings — opens the settings popover (`SettingsView`)
6. *(separator)*
7. Quit

`showAbout()` displays an `NSAlert` (not `NSApp.orderFrontStandardAboutPanel`) because the app runs as a `LSUIElement = YES` agent; `orderFrontStandardAboutPanel` does not reliably render in apps without a standard foreground activation policy. The version string is read from `Bundle.main` keys `CFBundleShortVersionString` (marketing version, e.g. `1.0`) and `CFBundleVersion` (build number).

### Status Bar Display Logic

`AppDelegate.updateStatusBarDisplay()` reads from `WorklogStateManager` computed properties to render the status bar item:

- **Error / no credentials:** `button.title = "❌"` + tooltip describing the specific error (credential missing, unauthorized, forbidden, not found, network)
- **Normal state:** uses `stateManager.statusBarTitle` (plain text) and an `NSAttributedString` with `stateManager.statusBarColor` (an `NSColor`) for color

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
| Settings (`SettingsView`) | `NSSize(width: 400, height: 500)` | `.frame(width: 400, height: 500)` |

When changing a view's frame size, always update the matching `contentSize` in `AppDelegate`.

### Auto-Refresh

`WorklogStateManager` installs a `Timer` that fires every 3600 seconds (1 hour) to call `loadTempoData()`. The timer is invalidated by `resetForTesting()`.

## API Integration

The app targets the **Tempo Server / Data Center** REST API (not Tempo Cloud). See [api-design.md](api-design.md) for full details.

**Endpoints used:**

| Method | Path | Purpose |
|---|---|---|
| GET | `/rest/api/2/myself` | Resolve username/key from API token |
| GET | `/rest/tempo-timesheets/3/worklogs` | Fetch worklogs for a user (60-day window) |

Auth: `Authorization: Bearer <apiToken>` header.

User identification uses `name` or `key` from `/myself` (Jira Server username), not the Atlassian cloud `accountId`. The `UserInfo.accountId` field is mapped from the `name` field in the decoder.

## Credential Storage

Credentials are stored in the macOS Keychain as a JSON-encoded blob under service `com.stjohnsoftware.TempoStatusBar`, account `credentials`. The Keychain provides hardware-backed encryption at rest and OS-level access control. The item is marked `kSecAttrAccessibleWhenUnlocked` so it is only available when the user is logged in.

A migration path exists for users upgrading from the previous version, which stored AES-GCM-encrypted credentials in `UserDefaults`. On first `loadCredentials()` call, if no Keychain item exists, the manager attempts to decrypt the legacy `UserDefaults` entries, saves them to Keychain, and deletes the `UserDefaults` keys.

Fields stored: `apiToken`, `accountId` (username), `jiraURL`, `warningThreshold`.

Saving or deleting credentials posts `.credentialsChanged` to `NotificationCenter`.

## Configuration

All user-facing configuration is set via `SettingsView`:

| Field | Description | Default |
|---|---|---|
| Jira Instance URL | Base URL, e.g. `https://yourcompany.atlassian.net` | — |
| API Token | Jira Personal Access Token | — |
| Account ID | Jira username (optional; auto-detected via `/myself`) | — |
| Warning Threshold | Days before warning state activates | 7 |

No environment variables or build-time configuration. There are no hardcoded endpoints beyond the relative API paths.

## CI/CD

Three GitHub Actions workflows — see [ci-cd.md](ci-cd.md) for full details.

| Workflow | Trigger | Key jobs |
|---|---|---|
| `pr-verification.yml` | PRs to `main` | Build+test, SwiftLint, Trivy scan, DMG artifact, PR comment |
| `main-verification.yml` | Push to `main`, manual | Build, Trivy scan, docs check |
| `release-tag.yml` | Release events, manual | Release build, Trivy scan, docs check |

All workflows use `xcode-version: '26.x'`. PR and main workflows use `cancel-in-progress: true`; the release workflow uses `cancel-in-progress: false`.

## Testing

Tests live in `TempoStatusBarAppTests/`. The custom shell script `run_tests.sh` is used by CI instead of a plain `xcodebuild test` call.

Key test file: `WorklogStateManagerTests.swift` — covers initial state, credential loading, data fetching, error handling, computed status properties, and data clearing.
