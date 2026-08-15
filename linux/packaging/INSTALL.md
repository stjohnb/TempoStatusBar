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

## 2. Configure

```sh
tempo-statusbar init                              # writes the sample config
$EDITOR ~/.config/tempo-statusbar/config.toml     # set jira_url
```

| Field | Default | Meaning |
|---|---|---|
| `jira_url` | required | Base URL of the Jira instance |
| `account_id` | unset | Jira Server username; resolved from `/myself` when unset |
| `warning_threshold` | 7 | Days before the orange state |
| `poll_interval_secs` | 3600 | Poll interval (floored at 60) |
| `token_command` | unset | Shell command printing the token on stdout |

The config file is re-read every poll cycle, so edits take effect at the next
refresh without a restart.

## 3. Store the API token

```sh
tempo-statusbar set-token    # prompts, stores in the freedesktop Secret Service
```

The token is resolved in this order:

1. `TEMPO_API_TOKEN`, if set and non-empty.
2. `token_command` from the config file — run as `sh -c <command>`, trimmed
   stdout is the token. Works with `pass show tempo`, `gopass`, `secret-tool`,
   `op read`, and anything else that prints a secret.
3. The Secret Service, under service `tempo-statusbar`, account `api-token`.

On a headless box, or under i3/sway with no Secret Service provider on the
session bus, use one of the first two rather than `set-token`.

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
