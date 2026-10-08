# Distribution

**Depth: Reference.** Read this when changing how PR builds, tagged
releases, or update checks reach users. For the macOS-specific update-check
requirement, read [macos-app.md](macos-app.md). For CI/release pipeline
mechanics, read [ci-cd.md](../ci-cd.md).

## Problem

Get built artifacts — PR test builds, tagged macOS releases, Linux release
binaries — into the owner's (and any downstream user's) hands with minimal
manual steps, despite the source repo being private.

The private source repo is canonical on Forgejo
(`git.home.bstjohn.net/St-John-Software/TempoStatusBar`) and its CI runs as
Forgejo Actions workflows in `.forgejo/workflows/`, without `gh`. Releases are
Forgejo releases: the macOS DMG lives in S3 and is linked from the release
body, while the Linux tarball and `.sha256` are Forgejo release assets. Claws
mirrors the latest release of each to the public GitHub repo
`stjohnb/TempoStatusBar`, which stays on GitHub and is what users and the
update checker see.

## Users

The repo owner, testing their own PR builds; anyone who installs the app
from the public mirror.

## Requirements

### PR and release builds must be directly downloadable with a single link

No "open the Actions run and dig through Artifacts" step.

**Why:** issue #11 — "This is too manual... Provide a direct download link
in the comment."

### Update checks and release downloads must work without any GitHub credentials

Neither the user nor the app should need a GitHub token to check for or
download updates.

**Why:** the source repo is private, so the original design needed a PAT
(#102). The owner had this replaced by pointing update checks at the public
mirror and removing the token entirely (#160, #223) — simplicity over
completeness.

**Supersedes:** the original #102/PR #104 design (token-gated checks against
the private repo).

### The public mirror only needs to carry the most recent release, not full history

Mirroring the latest stable release is enough; there's no requirement to
backfill or keep historical releases in sync.

**Why:** issue #159 — "most recent release only, no need for historic
ones" — this avoids needing a PAT-driven historical sync process.

## Non-goals & rejected ideas

None recorded.

## Open questions

### Aligning the mirrored release tag with a source-accurate snapshot commit

The mirrored release tag is currently anchored at the latest snapshot commit
rather than a source commit that exactly matches the tag. Tracked externally
as St-John-Software/claws#1941 (#159).
