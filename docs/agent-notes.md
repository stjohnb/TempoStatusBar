# Agent Notes

**Depth: Reference.** Read this when debugging a host/CI/Claws operational
issue that isn't explained by [OVERVIEW.md](OVERVIEW.md) or [ci-cd.md](ci-cd.md)
— e.g. a shared-runner quirk or a Claws-automation behavior. For subsystem
architecture or workflow design, read those docs instead.

Durable, hard-won facts refined from agent memory stores — operational
gotchas about the host or the Claws automation that don't belong to any one
feature doc. Verify against current state before relying on them; they are
not a substitute for [OVERVIEW.md](OVERVIEW.md) or [ci-cd.md](ci-cd.md).

## Claws pushes to open PR branches

Claws bots actively push to open PR branches (CI-fix commits, rebases onto
`main`). If you have a local checkout of a PR branch that Claws is also
managing, expect non-fast-forward pushes from it — fetch and rebase onto its
commits rather than force-pushing over them.

## Worktrees share a working directory per host session

On a shared automation host running multiple worktrees/sessions concurrently,
parallel shell commands that each `cd` into a different repo worktree race
the same shell's working directory. Always use an explicit path per command
(or a single `cd` immediately before the command it applies to) rather than
relying on a prior `cd` having "stuck" for a later parallel call.
