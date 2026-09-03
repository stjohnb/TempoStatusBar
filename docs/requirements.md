# Cross-Cutting Requirements

**Depth: Reference.** Read this when checking a standing, cross-cutting
constraint from the repo owner that isn't tied to one subsystem (e.g. a
GitHub repo setting, a secret-handling policy). For a constraint specific to
one subsystem, read that doc instead (`OVERVIEW.md`, `api-design.md`,
`ci-cd.md`, `linux.md`) — this file is not a catch-all.

Standing constraints from the repo owner (@stjohnb) that aren't tied to a
single subsystem doc. These are current-state requirements, not a history —
see individual feature docs (`OVERVIEW.md`, `api-design.md`, `ci-cd.md`) for
subsystem-specific constraints and their rationale.

## Dependabot vulnerability alerts must stay enabled

Dependabot vulnerability alerts must be enabled for this repo (originating
requirement: #38).

**Why:** standing security/compliance expectation, not a one-off ask — the
owner wants notification of vulnerable dependencies regardless of whether
any active work touches them.

**How to apply:** this is a GitHub repository setting (Settings → Security →
Code security and analysis), not something expressed in code — it can't be
verified by reading the source. If repo configuration is ever touched
(e.g. via Terraform/API automation), don't disable or omit this setting.

## Any secret that has touched a git ref is burned

If a credential or secret value is ever committed to any git ref (including
a branch, tag, or PR that was later force-pushed away), treat it as
compromised the moment it lands — rotate it first. Do not treat
`git rm`/history-rewrite alone as sufficient remediation (originating
incident: #107, a tracked `.mcp-claws.json` with a live MCP auth token and a
Postgres connection string).

**Why:** removing a file from `HEAD` or even rewriting history doesn't undo
exposure to anyone who already cloned/fetched the ref; the owner's stated
policy is rotate-first, cleanup-second.

**How to apply:** if you ever discover a tracked file, commit, or CI log
containing what looks like a live credential in this repo, flag it and
recommend rotation before recommending any git-history remediation.
