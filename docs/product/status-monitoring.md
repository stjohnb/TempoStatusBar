# Status Monitoring

**Depth: Reference.** Read this when changing severity thresholds, colours,
emoji, or day-count logic that determines what the tray/menu-bar icon shows,
on either platform. For macOS-only concerns, read
[macos-app.md](macos-app.md). For Linux-only concerns, read
[linux-app.md](linux-app.md).

## Problem

The owner needs an always-visible signal, on whichever desktop they're
using, of how many days have passed since their last Tempo worklog —
without opening Jira or doing the threshold math themselves.

## Users

The repo owner, running one or both of the macOS menu bar app and the Linux
tray app.

## Requirements

### Status must escalate through exactly three severity tiers plus a neutral no-data state

Within the warning threshold: ok (green, ✅). One day past it: warning
(orange, ⏰). Further past it: overdue (red, 🚨). No data, no credentials,
or an error: neutral grey.

**Why:** established by PR #4 ("Change alarm display logic") specifically so
the icon alone conveys urgency without the user reading the day count.

### macOS and Linux status displays must never disagree for the same input

The same day count and warning threshold must produce the same severity,
colour, and escalation point on both platforms, even though the two apps
share no source code.

**Why:** the owner runs both apps across their own Mac and Linux desktops
and expects one mental model. The Linux app's colours are defined as the
literal macOS `NSColor` values for this reason — see
[linux.md](../linux.md#status-display) and [DESIGN.md](../DESIGN.md).

### The app must recover automatically from transient network failures without manual action

A dropped and later restored network path (e.g. reconnecting a VPN) must
clear an error state and re-fetch on its own.

**Why:** issue #64 — the status icon showed a persistent error after a VPN
reconnect until the user manually opened the app and clicked refresh; the
owner expects it to self-heal.

## Non-goals & rejected ideas

None recorded.

## Open questions

None recorded.
