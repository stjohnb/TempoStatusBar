# Design

**Depth: Deep dive.** Read this only when touching the Linux app's GTK4
windows' colour, type, or motion choices (`linux/src/gui.rs`). For the GTK4
crate's architecture and behavior, read [linux.md](linux.md) instead. The
macOS app is SwiftUI and follows the platform's own conventions; nothing
here applies to it.

## Principle: stay native

A tray app's windows appear inside whatever desktop the user runs. They should
look like that desktop, not like a brand. So the CSS provider styles **only**
`.tempo-*` classes and defines four colours; everything else — button shapes,
text colour, backgrounds, focus rings, dark mode — is inherited from the user's
GTK theme and is deliberately not overridden.

## Palette

The four status colours are the macOS `NSColor` system values, shared with the
tray icon and `state.rs`, so the window's dot and the tray icon can never
disagree:

| Token | Value | Meaning |
|---|---|---|
| `@tempo_ok` | `#34C759` | Within the warning threshold |
| `@tempo_warning` | `#FF9500` | One day past it |
| `@tempo_overdue` | `#FF3B30` | Further past it |
| `@tempo_neutral` | `#8E8E93` | No data, no credentials, error |

There is no accent colour beyond these. The theme supplies the one the user
already chose.

## Type

One pairing, with contrast carried by size and weight rather than by a second
palette:

- **Headline** (`.tempo-headline`) — the day count. `JetBrains Mono`, falling
  back to `Fira Mono` then `DejaVu Sans Mono`, 32 px, weight 800. A monospace
  face because the headline is a number that changes daily and should not
  reflow; no web fonts, so an absent face degrades to the system monospace.
- **Body** — the theme's default UI font at its default size, unstyled.
- **Field labels** (`.tempo-field`) — weight 600, same size as body.
- **Hints** (`.tempo-hint`) — 90 %, opacity 0.7.
- **Overrides** (`.tempo-warn`) — 90 %, in `@tempo_warning`. Used for the
  per-field note that `config.toml` shadows a value.

## Surface

The window header carries a `repeating-linear-gradient` hairline in
`@tempo_neutral` at 10 % rather than a flat block of colour, so the header
reads as a texture in both light and dark themes without picking a background
colour that fights the theme's own.

## Motion

None. Nothing animates, so there is nothing to gate behind a reduced-motion
preference. Long operations (Save, Test Connection, Auto-detect) report
progress by disabling their button and writing to the status label, not by
spinning.
