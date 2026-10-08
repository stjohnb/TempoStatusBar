# Linux App

**Depth: Reference.** Read this when working on Linux-specific product
behavior — the native GUI, cross-desktop credential storage, or what the
published release artifact must be. For status severity/colour logic shared
with macOS, read [status-monitoring.md](status-monitoring.md). For release
mechanics, read [distribution.md](distribution.md).

## Problem

The owner moved to a Linux desktop (GNOME at the time, not committed to
staying there) and wants the same at-a-glance worklog-staleness signal and
settings experience they had on macOS.

## Users

The repo owner, on Linux desktops — GNOME today, potentially KDE or others.

## Requirements

### The Linux app must ship a native GUI for both settings and status, not a browser-hosted page

Settings entry (Jira URL, token, account ID, threshold) and the status
detail view must be native desktop windows.

**Why:** issue #208 — "I don't like the sound of settings via a web page.
Surely we can get a native gui. We'll need it to display the statuses too."
The ask was explicitly to reproduce the macOS experience (#189, #208), not
build a localhost web UI.

### Credential storage on Linux must work across desktop environments, not just GNOME

Secrets must be readable/writable through a cross-desktop mechanism rather
than a GNOME-only API.

**Why:** the owner was on GNOME but explicitly "not committed to that"
(#189) and asked directly what happens to secrets on KDE or another desktop
environment. The freedesktop Secret Service (GNOME Keyring, KWallet/
ksecretd, KeePassXC, etc.) was chosen for this reason — see
[linux.md](../linux.md#credential-storage-across-desktop-environments) for
the provider matrix.

### The published Linux release artifact must be a single static binary needing no distro packaging

The downloadable release must run on any distro from one file, with no
separate packaging (no `.deb`, no Flatpak, no AUR).

**Why:** issue #192 — the owner asked for a static musl build specifically
because the crate's dependency graph already made that the easiest thing to
build correctly (no system cert store, no libdbus, one file), avoiding the
maintenance burden of per-distro packages for a personal project.

## Non-goals & rejected ideas

None recorded beyond the deliberate scope cuts already listed in
[linux.md](../linux.md#scope) (no update checker, no Launch-at-Login
equivalent, no GUI in the static download, no non-x86_64 releases) — those
are implementation scope decisions, not rejected owner asks.

## Open questions

None recorded.
