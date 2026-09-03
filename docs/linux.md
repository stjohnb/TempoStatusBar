# Linux App

**Depth: Reference.** Read this when working on the Linux tray crate
(`linux/`) — architecture, config/credential resolution, the GTK4 GUI, or
releases. For GTK visual-design rules specifically, read [DESIGN.md](DESIGN.md)
instead. For the macOS app, read [OVERVIEW.md](OVERVIEW.md) — the two apps
share no source.

The Linux tray app lives in `linux/` and is a separate Rust implementation, not
a port of the Swift code. The macOS app is mature, signed and notarized, so it
stays exactly as it is; the two apps share only the Tempo API contract and the
user-visible behaviour (thresholds, colours, day counting).

## Product constraints

- The owner explicitly wanted the Linux app to reproduce the macOS experience with a native GUI for both settings and status display, not a localhost web page. That is why `linux/src/gui.rs` ships GTK4 windows and why planning work for this crate should start from "native tray app" rather than browser-hosted UI.
- The published Linux release artifact must remain the fully static `.#static` build. Because GTK cannot be statically linked into that musl target, the public tarball intentionally stays tray+CLI only while nix/source builds keep the GUI feature enabled.

## Architecture

```
linux/Cargo.toml     Crate manifest
linux/src/main.rs    CLI (clap), tray implementation, poll loop
linux/src/tempo.rs   Jira/Tempo REST client and models
linux/src/config.rs  Config file, Secret Service blob, token resolution
linux/src/state.rs   Severity/Status model and colours
linux/src/icon.rs    Procedural 24x24 ARGB tray icon
linux/src/uimodel.rs GTK-free validation and presentation rules (unit-tested)
linux/src/gui.rs     GTK4 status and settings windows (`gui` feature)
linux/packaging/     .desktop entry, systemd user unit, INSTALL.md (shipped in
                     the release tarball)
flake.nix            Dev shell and packages (Linux only)
```

There is no async runtime: the tray runs on a background thread via `ksni`'s
blocking API and the poll loop wakes on either a timeout or an `mpsc` message
from a menu item. Without the GUI the poll loop owns the main thread; with it,
GTK owns the main thread — GTK objects are not `Send` — and the poll loop moves
to a worker, publishing each status through an `Arc<Mutex<Status>>` the window
reads on a 200 ms tick.

| Concern | macOS | Linux |
|---|---|---|
| Tray | `NSStatusBar` | StatusNotifierItem over D-Bus (`ksni`) |
| State | `WorklogStateManager` (`@MainActor`, Combine) | `Status` value recomputed each poll cycle |
| Credentials | Keychain (`CredentialManager`) | Secret Service blob / `token_command` / env var |
| Settings | `SettingsView` popover | GTK4 settings window, `config.toml` + CLI |
| Status detail | `ContentView` popover | GTK4 status window |
| Errors | `TempoError` / `CredentialError` | same-named `thiserror` enums |

`TempoError` is case-for-case with the Swift enum apart from `DecodeFailed`.
Swift folds a decode failure into `networkError`; here that would wrongly drive
the transport backoff loop, so it gets its own case.

The API contract is identical to the macOS app — see
[api-design.md](api-design.md). Same two endpoints, same 60-day window, same
`name`-then-`key` identifier resolution, same `Bearer` auth.

## StatusNotifierItem and GNOME

SNI is the KDE/freedesktop tray protocol. KDE Plasma, Xfce, Cinnamon, most
wlroots panels (Waybar, i3status-rust) and the tray plugins of other panels
support it natively.

**GNOME does not show SNI items without an extension.** Install
`gnome-shell-extension-appindicator` (the "AppIndicator and KStatusNotifierItem
Support" extension) or no icon will appear. This is expected SNI behaviour, not
an app bug; `tempo-statusbar` reports it on stderr and exits non-zero if no
StatusNotifierWatcher is available at startup.

## Credential storage across desktop environments

The `keyring` crate talks to the freedesktop **Secret Service D-Bus API**
(`org.freedesktop.secrets`), a cross-desktop standard rather than a GNOME API.
Only one provider may own that bus name at a time; the app simply uses whichever
one does.

| Desktop | Provider | Notes |
|---|---|---|
| GNOME | GNOME Keyring | The canonical implementation; works out of the box |
| KDE | KWallet / `ksecretd` | Secret Service support since KDE Frameworks 5.97 (Aug 2022); Plasma 6 ships `ksecretd` |
| Any | KeePassXC | Enable its Secret Service integration |
| i3 / sway / headless | none | No provider on the bus — use `token_command` or `TEMPO_API_TOKEN`, and set `jira_url` in the config file |

The Secret Service may prompt to unlock its collection on first read after
login. A locked or denied collection is reported as a keyring error, which
becomes a gray tray state with a hint — never a panic. Since 0.2.0 that error
blocks the Jira URL as well as the token, but it stays non-fatal: the tray shows
the error and retries at the next poll interval rather than exiting.

### The credentials blob

`tempo-statusbar set-credentials` stores one JSON object under service
`tempo-statusbar`, account `credentials`:

| Key | Meaning |
|---|---|
| `jira_url` | Base URL of the Jira instance |
| `account_id` | Jira Server username; `null` to resolve from `/myself` |
| `api_token` | The Jira API token |
| `warning_threshold` | Days before the orange state; `null` for the default |

This mirrors the macOS Keychain payload (`CredentialManager.swift`, service
`com.stjohnsoftware.TempoStatusBarApp`, account `credentials`), in snake_case.
The two stores never interoperate — they are separate machines' secret stores
holding the same four fields.

`tempo-statusbar set-token` is a read-modify-write of the blob's `api_token`
alone, so it never clobbers a stored `jira_url` or `account_id`.

The pre-0.2 entry under account `api-token` — a bare token, no JSON — is still
read as the last token fallback, and is never written or deleted. An install
that predates the blob keeps working untouched.

`secret-tool lookup service tempo-statusbar username api-token` therefore
returns nothing on a fresh install; the blob is under `username credentials`.
Note that reading it **prints the API token inside the JSON**, so do not run it
where the output is logged or shared.

### Resolution rules

The config file is an override layer, applied per field:

- `jira_url`, `account_id` and `warning_threshold`: a non-blank value in
  `config.toml` wins; otherwise the blob supplies it. A blank or whitespace
  value counts as absent on both sides.
- `poll_interval_secs` and `token_command` are **file-only** — they are
  settings, not credentials, and the blob has no place to put them.
- The keyring is **not consulted at all** when the file already supplies both
  `jira_url` and a token source (`token_command`, or `TEMPO_API_TOKEN` in the
  environment), so a box with no secrets daemon never touches D-Bus. The cost:
  in that configuration a keyring-stored `account_id` or `warning_threshold`
  is ignored.
- With no `jira_url` on either side, the tray shows an error naming the config
  path and `set-credentials`.

`tempo-statusbar show-config` prints the resolved values, annotated with where
each came from, plus whether a token was found and from which source. It never
prints the token, nor the `token_command` string.

### Token resolution order

1. `TEMPO_API_TOKEN`, if set and non-empty.
2. `token_command` from the config file, if set. Run as `sh -c <command>`;
   trimmed stdout is the token. Works with `pass show tempo`, `gopass`,
   `secret-tool`, `op read`, and anything else that prints a secret.
3. `api_token` from the credentials blob (service `tempo-statusbar`, account
   `credentials`).
4. The legacy pre-0.2 entry (service `tempo-statusbar`, account `api-token`).

`token_command` stdout is never logged and never appears in an error message —
only a bounded excerpt of stderr does.

`tempo-statusbar set-credentials` and `set-token` write to the Secret Service
and, on failure, print guidance naming the providers above and the two
fallbacks, rather than a raw D-Bus error.

## Configuration

Nothing in `config.toml` is required, and the file may be absent entirely —
`set-credentials` alone is enough to run the app. `tempo-statusbar init` writes
a fully commented-out sample to
`$XDG_CONFIG_HOME/tempo-statusbar/config.toml` (usually
`~/.config/tempo-statusbar/config.toml`) for the cases that need an override.
It refuses to overwrite an existing file.

| Field | Default | Default source | Meaning |
|---|---|---|---|
| `jira_url` | optional | Secret Service | Base URL of the Jira instance |
| `account_id` | optional | Secret Service | Jira Server username; resolved from `/myself` when unset everywhere |
| `warning_threshold` | 7 | Secret Service | Days before the orange state |
| `poll_interval_secs` | 3600 | file only | Poll interval (floored at 60) |
| `token_command` | unset | file only | Shell command printing the token on stdout |

The config file is re-read every poll cycle, so edits take effect at the next
refresh without a restart.

## GUI

Source and nix builds ship two native GTK4 windows, opened from the tray menu's
**Show Status** and **Settings…** items or from `tempo-statusbar settings`.

The **status window** mirrors the macOS `ContentView` popover: the day count, a
dot in the severity colour, the tooltip line, and — when there is a worklog —
its issue key and summary, time spent, date and comment. Rows with nothing in
them are hidden rather than shown empty. With no credentials it offers an
**Open Settings** button instead. It repaints on its own as poll cycles land;
**Refresh** asks for one immediately.

The **settings window** mirrors `SettingsView`: Jira URL, API token, account ID
with an **Auto-detect** button, and the warning threshold, plus **Test
Connection**, **Save**, and a separated **Clear Stored Credentials** behind a
confirmation. Save writes the same Secret Service blob `set-credentials` writes,
then triggers an immediate refresh.

Window sizes are independent of the macOS popovers: `gui.rs` currently uses
`380x300` for the status window and `420x660` for the settings window.

Three things are worth knowing:

- **The stored API token is never displayed.** The field renders empty every
  time the window opens; leaving it blank keeps whatever is stored, and typing
  in it replaces it. Nothing reads the token back out into a widget.
- **`config.toml` still wins per field.** Saving a `jira_url` that the file also
  sets changes the blob but not the running app, so the window puts an amber
  note under any field the file shadows. The app never rewrites `config.toml` —
  that would destroy the user's comments. `poll_interval_secs` and
  `token_command` remain file-only and the window says so.
- **Secret Service writes and Jira calls run off the GTK thread.** An unlock
  prompt or a Jira instance behind a disconnected VPN can block for tens of
  seconds; the window stays responsive and the triggering button is disabled
  until the result lands.

Colour, type and motion choices are recorded in [DESIGN.md](DESIGN.md).

**The published static tarball has no GUI.** It is built
`--no-default-features` (see [Releases](#releases)), because GTK cannot be
statically linked. On that binary the tray menu keeps its original three items,
`tempo-statusbar settings` exits non-zero with a pointer to
`set-credentials`, and configuration goes through the CLI and `config.toml`.
Install from nix — or build from source — for the GUI.

If GTK cannot open a display (no `DISPLAY`, no `WAYLAND_DISPLAY`), the app
prints `No display available; running without the GUI.` and carries on as a
tray, which is the sensible behaviour for a systemd user unit that starts
before the session is up.

## Status display

Severity thresholds and colours match the macOS app exactly:

| Days | Severity | Colour |
|---|---|---|
| `<= warning_threshold` | Ok | green `#34C759` |
| `== warning_threshold + 1` | Warning | orange `#FF9500` |
| `> warning_threshold + 1` | Overdue | red `#FF3B30` |
| no data / no credentials / error | — | gray `#8E8E93` |

The icon is drawn procedurally: a filled disc in the severity colour with the
day count in white on top, using an embedded 3x5 bitmap digit font (3x scale for
one digit, 2x for two). Counts above 99 render as `99`. `ksni::Icon` data is
ARGB32 in network byte order.

## Network error recovery

There is no `NWPathMonitor` equivalent. Instead, a transport failure backs off
exponentially: 15 s, then x4 per consecutive failure, capped at 3600 s, reset on
any successful poll. Only `TempoError::NetworkError` triggers backoff — an HTTP
401 or a malformed payload does not.

## Building and testing

```sh
cd linux
nix develop ..# --command cargo test
nix develop ..# --command cargo clippy --all-targets -- -D warnings
nix develop ..# --command cargo build --release
# What `nix build .#static` compiles — no GTK in the dependency graph.
nix develop ..# --command cargo build --release --no-default-features
```

Or `nix build` from the repo root for the packaged binary, or `nix run` to
start the tray. `nix build .#static` produces the static musl release binary;
verify it locally with:

```sh
readelf -l ./result/bin/tempo-statusbar | grep -c INTERP   # expect 0
./result/bin/tempo-statusbar --version
```

`run_tests.sh` remains macOS-only — it drives `xcodebuild`. Rust tests live in
`#[cfg(test)]` modules and are pure functions only: nothing constructs a
`TrayService` or a `keyring::Entry`, and nothing executes a `token_command`,
because CI has no D-Bus session.

CI runs everything through `nix develop` on `[self-hosted, linux]` — see
`.github/workflows/linux-ci.yml`. Every tool comes from the repo's own devShell;
nothing is installed on the runner.

## Releases

`nix build .#static` produces a fully static `x86_64-unknown-linux-musl`
binary at `./result/bin/tempo-statusbar` — the published release artifact.
`packages.default` is the ordinary dynamically-linked build and is what
`St-John-Software/nixos-config` consumes from the public mirror; it must keep
that attribute name.

The static build is **contingent on the crate's feature choices**: `reqwest`
uses `rustls-tls` with `webpki-roots` (trust roots compiled in, so no system
cert store and no `SSL_CERT_FILE`), `ksni` uses its pure-Rust zbus backend (no
`libdbus-sys`), and nothing pulls `openssl-sys` or `native-tls`. `ring` is the
only crate with C/asm and it builds for musl. Swapping any of those silently
breaks the static build — `linux/Cargo.toml` carries the same warning.

The GTK4 GUI is the reason the crate has a `gui` feature at all. No Rust GUI
toolkit survives static linking — GTK, Qt and FLTK link C libraries, and every
winit-based stack `dlopen`s libX11/libwayland/libxkbcommon, which a static
binary cannot do. So `packages.static` sets `buildNoDefaultFeatures`, dropping
gtk4 out of the dependency graph entirely, while `packages.default` builds it.
`Cargo.lock` listing gtk4 is harmless: `buildRustPackage` vendors every locked
crate but compiles only what the feature set selects. Nothing behind `gui` may
ever move into the default dependency set. `linux-ci.yml` builds
`--no-default-features` on every PR as the guard.

`.github/workflows/linux-release.yml` fires on pushes to `main` touching
`linux/**`, `flake.nix` or `flake.lock` and:

1. reads the version from `linux/Cargo.toml` via `nix eval .#static.version`
   and rejects anything that is not plain `X.Y.Z`;
2. no-ops with a `::notice::` if `linux-vX.Y.Z` already exists — the gate is
   version-driven, not push-driven, so a `linux/**` merge without a version
   bump is a green no-op;
3. builds `.#static`, asserts the ELF has no `INTERP` segment and that
   `tempo-statusbar --version` matches the tag;
4. publishes `tempo-statusbar-<version>-x86_64-linux.tar.gz` and a `.sha256`
   as GitHub release assets, together with the `.desktop` entry, the systemd
   user unit and `INSTALL.md` from `linux/packaging/`.

The tag namespace `linux-v*` is deliberately separate from the macOS `v1.3.x`
line, so the two release cadences are not welded together. `release-tag.yml`
(the macOS sign+notarize workflow) has no tag filter of its own, so all three
of its jobs carry a `!startsWith(github.event.release.tag_name, 'linux-v')`
guard.

There is no S3 upload — unlike the macOS DMG, the Linux tarball lives on the
GitHub release itself, which is what the Claws snapshot job copies to the
public mirror `stjohnb/TempoStatusBar` on the next sync (~02:00).

x86_64 only. Both self-hosted runners are x86_64; `packages.static` is defined
for `aarch64-linux` too, but nothing builds or publishes it. aarch64 and other
architectures build from source with
`nix build github:stjohnb/TempoStatusBar#static`.

## Scope

Deliberately not implemented:

- **No GUI in the downloadable binary.** The GTK4 windows ship in source and
  nix builds only; the published static tarball is tray plus CLI. See
  [GUI](#gui).
- **No Launch at Login toggle.** There is no cross-desktop equivalent of
  `SMAppService`; the systemd user unit in `linux/packaging/` covers it.
- **No update checker.** Install and update through nix, your distro, or by
  downloading a newer `linux-v*` release.
- **No distro packaging.** No AUR, Flatpak or `.deb`; the release artifact is a
  single static binary plus the desktop-integration files in
  `linux/packaging/`.
