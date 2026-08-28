# TempoStatusBar (Linux) — install

A tray app showing days since your last Jira Tempo worklog. This tarball holds
a statically linked `x86_64` binary: no runtime dependencies, no system cert
store, no glibc version to match.

## 1. Install the binary

```sh
install -Dm755 tempo-statusbar ~/.local/bin/tempo-statusbar
```

Make sure `~/.local/bin` is on your `PATH` — most distros add it when the
directory exists at login, so you may need to log out and back in, or add it
yourself:

```sh
export PATH="$HOME/.local/bin:$PATH"    # in ~/.profile, ~/.bashrc or ~/.zshrc
```

## 2. Store your credentials

```sh
tempo-statusbar set-credentials    # prompts, stores in the freedesktop Secret Service
tempo-statusbar settings           # GTK4 window, or the tray's "Settings…" item
```

**This tarball has no GUI**: `settings` exits with a message, and the tray menu
has no window items. That is deliberate — GTK cannot be statically linked, so
the fully static binary is tray plus CLI. Install from nix, or build from
source, if you want the windows.

This asks for the Jira URL, your Jira username (blank to resolve it from
`/rest/api/2/myself`) and the API token, and stores all three as one entry in
the Secret Service. That is the whole setup — no config file is needed.

Check what the tray will use with `tempo-statusbar show-config`; it prints the
resolved settings and where each came from, but never the token itself.

## 3. Optional: a config file

Only needed to override what is stored, or to set `poll_interval_secs` or
`token_command`, which live in the file alone:

```sh
tempo-statusbar init                              # writes a commented sample
$EDITOR ~/.config/tempo-statusbar/config.toml
```

| Field | Default | Default source | Meaning |
|---|---|---|---|
| `jira_url` | optional | Secret Service | Base URL of the Jira instance |
| `account_id` | optional | Secret Service | Jira Server username; resolved from `/myself` when unset everywhere |
| `warning_threshold` | 7 | Secret Service | Days before the orange state |
| `poll_interval_secs` | 3600 | file only | Poll interval (floored at 60) |
| `token_command` | unset | file only | Shell command printing the token on stdout |

A non-blank value in the file wins over the stored one, field by field. The
file is re-read every poll cycle, so edits take effect at the next refresh
without a restart.

The token is resolved in this order:

1. `TEMPO_API_TOKEN`, if set and non-empty.
2. `token_command` from the config file — run as `sh -c <command>`, trimmed
   stdout is the token. Works with `pass show tempo`, `gopass`, `secret-tool`,
   `op read`, and anything else that prints a secret.
3. The stored credentials, under service `tempo-statusbar`, account
   `credentials`.
4. The legacy pre-0.2 entry, under service `tempo-statusbar`, account
   `api-token` — read only, never written.

On a headless box, or under i3/sway with no Secret Service provider on the
session bus, use one of the first two instead of `set-credentials`, and set
`jira_url` in the config file as well: without a provider the app has nowhere
else to read it from.

## 4. Start it at login

Two options are shipped in this tarball. **The systemd user unit is
recommended.**

### systemd user unit (recommended)

```sh
install -Dm644 tempo-statusbar.service ~/.config/systemd/user/tempo-statusbar.service
systemctl --user enable --now tempo-statusbar.service
```

`tempo-statusbar` deliberately exits non-zero when no `StatusNotifierWatcher`
is on the session bus. At login that is usually a race — the panel or the GNOME
AppIndicator extension has not finished starting — and a plain `.desktop`
autostart entry loses that race permanently. The unit's `Restart=on-failure`
retries every 5 s and wins it.

### `.desktop` autostart

```sh
install -Dm644 tempo-statusbar.desktop ~/.config/autostart/tempo-statusbar.desktop
```

Simpler, but one-shot: if the tray host is not up yet when it fires, nothing
restarts the app.

## GNOME needs an extension

GNOME Shell shows **no** StatusNotifierItem without
`gnome-shell-extension-appindicator` (the "AppIndicator and KStatusNotifierItem
Support" extension). Installing the package is not enough — enable the
extension (via the Extensions app or `gnome-extensions enable
appindicatorsupport@rgcjonas.gmail.com`) and restart the session.

Without it, `tempo-statusbar` prints a `StatusNotifierWatcher` message on
stderr and exits non-zero rather than sitting there invisibly. This is expected
SNI behaviour, not an app bug.

KDE Plasma, Xfce, Cinnamon and wlroots panels (Waybar, i3status-rust) support
SNI natively and need nothing extra.

## Other architectures

The published tarball is `x86_64` only. Build from source elsewhere:

```sh
nix build github:stjohnb/TempoStatusBar#static
```
