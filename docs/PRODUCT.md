# TempoStatusBar — Product Requirements

**Entry point.** Read this before planning any feature or bug fix. It says
WHAT the product must do and WHY; [OVERVIEW.md](OVERVIEW.md) and the other
docs under `docs/` say HOW the code meets these requirements.

## What this is

TempoStatusBar is a personal Jira Tempo worklog reminder: a macOS menu bar
app (the primary product) and a companion Linux tray app that poll Tempo
Server/Data Center and show how many days have passed since the last
worklog, escalating a visual warning the longer it's been. It's built and
used by a single owner (@stjohnb) across their own Mac and Linux desktops.
The source is private; a public, read-only mirror exists so releases can be
downloaded without exposing the private repo.

## Goals

- Give an always-visible, at-a-glance signal of worklog staleness without
  opening Jira.
- Work unattended: launch at login, refresh automatically, recover from
  transient network loss on its own.
- Keep credentials safe — OS-native secret storage, never logged or printed.
- Present the same status semantics on macOS and Linux even though the two
  apps share no source code.

## Non-goals

- Not a general Tempo/Jira client — no worklog entry, editing, or reporting.
- Not targeting Tempo Cloud, only Tempo Server/Data Center.
- Not multi-user or team-facing — one set of credentials per install.
- Not distributed through app stores or system package managers beyond a
  signed DMG (macOS) or a static binary / Nix package (Linux).

## Areas

| Area | Read this when | Doc |
|---|---|---|
| Status monitoring | Changing severity thresholds, colours, emoji, or day-count logic — on either platform | [product/status-monitoring.md](product/status-monitoring.md) |
| macOS app | Working on macOS-specific behavior — updates, credentials UX, launch at login | [product/macos-app.md](product/macos-app.md) |
| Linux app | Working on Linux-specific behavior — the native GUI, cross-desktop credentials, release artifact shape | [product/linux-app.md](product/linux-app.md) |
| Distribution | Changing how PR builds, releases, or update checks reach users | [product/distribution.md](product/distribution.md) |

## Cross-cutting constraints

Standing rules from the repo owner that aren't tied to one product area.

### Any secret that has touched a git ref is burned

If a credential or secret value is ever committed to any git ref (including
a branch, tag, or PR that was later force-pushed away), treat it as
compromised the moment it lands — rotate it first. Do not treat
`git rm`/history-rewrite alone as sufficient remediation.

**Why:** removing a file from `HEAD` or even rewriting history doesn't undo
exposure to anyone who already cloned/fetched the ref. Originating incident:
#107, a tracked `.mcp-claws.json` with a live MCP auth token and a Postgres
connection string.

### Dependency vulnerabilities must be surfaced automatically

The repo must keep an automated dependency-vulnerability signal. Since the
move to Forgejo that is Forgejo-side Renovate (configured in
`St-John-Software/fleet-infra`) plus the Trivy scan in PR, main and release
CI, which fails the build on any CRITICAL finding with a fix available. If
repo or CI configuration is ever touched via automation, don't drop either.

**Why:** standing security/compliance expectation, not a one-off ask —
originating requirement #38.

**Supersedes:** "Dependabot vulnerability alerts must stay enabled" (#38).
Dependabot and GitHub code scanning are GitHub-only; the GitHub copy of the
repo is archived after the Forgejo migration (#clw_01M45RN20AQVB7Y7X1MTQRB3DA).

### CI jobs must never trigger interactive OS dialogs on the shared runners

A CI job popping an OS dialog (e.g. a keychain-unlock prompt) in the
logged-in GUI session of a shared self-hosted Mac is unacceptable, even at
the cost of dropping test coverage.

**Why:** issue #234 — a signing job's keychain manipulation triggered an
`assistantd` password prompt on the shared `tempo` Mac. The owner's stated
priority: "Avoid triggering any dialogs from CI runs. Can drop test coverage
if needed." See [ci-cd.md](ci-cd.md#key-design-decisions) for the fix.

### All CI workflows (Forgejo Actions, and formerly GitHub Actions) must run on self-hosted runners

No workflow job should use a hosted runner (`ubuntu-latest`,
`macos-latest`, etc.). CI now runs as Forgejo Actions in
`.forgejo/workflows/`, on the same `[self-hosted, macos, tempo]` and
`[self-hosted, linux]` labels.

**Why:** repeatedly asserted by the owner (#5, #16). macOS jobs moved to
GitHub-hosted `macos-15` for a time (PR #126, after #121/#122's self-hosted
experiment hit keychain-popup problems) but that hit GitHub's macOS-minute
billing limits, so #165 moved macOS jobs back to self-hosted for good — the
keychain-popup problem #121/#122 ran into was later fixed properly by #234
rather than by giving up on self-hosted again. Self-hosted is the current
and intended state for every job.

**Supersedes:** PR #126's move of macOS build/test/quality jobs to
GitHub-hosted `macos-15`, and PR #122's "sticking with GitHub-hosted
runners" decision.
