# macOS App

**Depth: Reference.** Read this when working on macOS-specific product
behavior — login/launch behavior, update checking, or the credentials UI.
For status severity/colour logic shared with Linux, read
[status-monitoring.md](status-monitoring.md). For how builds reach users,
read [distribution.md](distribution.md).

## Problem

Give the owner a persistent, low-friction way to know their Tempo worklog is
going stale, running unattended in the menu bar with minimal setup.

## Users

The repo owner, on their own Mac(s).

## Requirements

### The app must be able to launch automatically at login without extra manual setup

A login-item toggle in Settings should be enough; the user shouldn't need to
add the app to Login Items themselves.

**Why:** issue #52 asked whether auto-run was purely a manual System
Settings step and whether it could be automated instead.

### Update checks must work without the user or the app holding a GitHub token

Checking for a new version must not require the user to create or paste a
personal access token.

**Why:** the app originally checked the private source repo for releases,
which needed a PAT (#102). Once a public mirror existed, the owner had the
checker repointed there and the token input removed entirely (#160, #223) —
update checks should work for free, out of the box.

**Supersedes:** the original design in #102/PR #104, which stored a
`githubToken` credential and required it for update checks.

### Credential-storage changes must never risk breaking existing users' stored credentials without a migration path

Any change to how or where credentials are stored — including
UI/messaging-only changes — must spell out how a user upgrading from the
previous version keeps (or is clearly warned about losing) access to what
they already saved.

**Why:** PR #31 (a UI warning about insecure credential storage) was closed
without merging after the owner asked whether it was a breaking change and
whether existing installs would lose access to stored credentials on
upgrade. Later Keychain-identity migrations (UserDefaults→Keychain, and the
pre-#95→post-#95 service rename) both had to define an explicit migration
path for this reason — see [OVERVIEW.md](../OVERVIEW.md#credential-storage).

## Non-goals & rejected ideas

### A UI warning about insecure credential storage, without a migration story

PR #31 was closed without merging; see the credential-storage requirement
above.

## Open questions

None recorded.
