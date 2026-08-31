# TempoStatusBar

TempoStatusBar is primarily a macOS menu bar app that polls Jira Tempo Server/Data Center and shows how many days have elapsed since the user's last worklog. This repo also contains a separate Linux tray implementation in `linux/`; the two apps share API and UX intent, but not source code.

## Where to read first

- Start with [docs/OVERVIEW.md](/home/brendan/.claws/worktrees/St-John-Software/TempoStatusBar/doc-maintainer/claws/docs-20260829-6b6d/docs/OVERVIEW.md) for architecture, key patterns, configuration, and links to subsystem docs.
- For Tempo API work, read [docs/api-design.md](/home/brendan/.claws/worktrees/St-John-Software/TempoStatusBar/doc-maintainer/claws/docs-20260829-6b6d/docs/api-design.md). For workflow or release changes, read [docs/ci-cd.md](/home/brendan/.claws/worktrees/St-John-Software/TempoStatusBar/doc-maintainer/claws/docs-20260829-6b6d/docs/ci-cd.md). For Linux-specific work, read [docs/linux.md](/home/brendan/.claws/worktrees/St-John-Software/TempoStatusBar/doc-maintainer/claws/docs-20260829-6b6d/docs/linux.md).

## Key Conventions

- All source files for the macOS app live flat at the repo root; `linux/` is a separate Rust crate and must not be treated as shared code.
- `WorklogStateManager.shared` is the macOS single source of truth, stays on the main actor, and drives UI through `@Published` state.
- Credentials are sensitive. Never log or print `apiToken`, `githubToken`, Linux `token_command` stdout, or any other credential value.
- `docs/claws-automation.md` is maintained automatically; do not edit or move it.
- All changes land via pull request; nothing is pushed directly to the default branch. See [docs/claws-automation.md](/home/brendan/.claws/worktrees/St-John-Software/TempoStatusBar/doc-maintainer/claws/docs-20260829-6b6d/docs/claws-automation.md) for the full convention.
