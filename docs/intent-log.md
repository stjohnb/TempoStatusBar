# Intent Log

This file is a chronological, append-only record of @stjohnb's stated
requirements, intentions, constraints, and rationale for this project —
the "why" behind decisions that isn't derivable from reading the code
alone. Entries are grouped under `### YYYY-MM-DD` headings (the date the
underlying issue/PR closed or merged), oldest first, and reference the
issue/PR number that the intent came from. Implementation mechanics
(how something works today) live in `docs/OVERVIEW.md`,
`docs/api-design.md`, and `docs/ci-cd.md` — this file only covers intent.

**This log is append-only.** Later entries may supersede or reverse
earlier ones without deleting them — read forward to see how thinking
changed over time, and check whether a later entry notes that it
supersedes an earlier one before trusting an early decision as still
current.

### 2025-07-18

- Status indicator semantics were defined early and simply (#4): show
  ⏰ once the warning threshold is reached, and 🚨 once it's been
  exceeded. This two-stage escalation (ok → warning → critical) is the
  origin of the threshold-based status logic that later PRs (e.g. #13)
  had to keep consistent across `statusEmoji`/`statusColor`.

### 2026-04-06

- PR builds needed to be trivially installable by a non-technical
  reviewer (#11): a raw "open the Actions run and find the artifact"
  flow was rejected as too manual — @stjohnb wanted a direct download
  link posted straight into the PR conversation.

### 2026-04-09

- macOS CI runners were explicitly exempted from the "must be
  self-hosted" policy at this point in time (#16, #17): GitHub-hosted
  `macos-latest` runners were considered required for macOS builds and
  not replaceable with self-hosted at the time. **(This was reversed
  twice later — self-hosted macOS was requested in #121/2026-05-30,
  dropped again in #126/2026-06-03, then re-adopted for good in
  #165/2026-07-05. See those entries.)**
- Credential values must never be logged, even for debugging (#14):
  verbose `print` debugging was leaking API tokens, account IDs, and
  Jira URLs to stdout. Debug output with real diagnostic value was
  moved to `os_log`/`Logger`, explicitly excluding any credential
  field — the origin of the "never log or print `apiToken`" rule.

### 2026-04-16

- Dependabot vulnerability alerts must be enabled for the repo (#38) —
  a standing security/compliance expectation, not a one-off ask.
- The original `UserDefaults`-based credential storage (AES-GCM with
  the decryption key stored right next to the ciphertext) was called
  out as "effectively obfuscation," not real security, and replaced
  with proper macOS Keychain storage (#34/resolves #33). Key
  constraint: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — tokens
  must not sync/backup via iCloud Keychain.

### 2026-04-21

- The version string shown in the app and in the DMG filename needed
  to be the **real** version, not a placeholder — specifically the
  nearest git tag combined with the PR/commit suffix, e.g.
  `1.1.0-RC1-pr-45-08cd262` (#44, #45). @stjohnb rejected several
  intermediate attempts ("Version 1.0", "Version unknown") before this
  was nailed down — the requirement was for the download filename and
  the in-app "About" version to always match exactly.
- Every build (local and CI) needed a **stable, shared code signature**
  so upgrades wouldn't repeatedly trigger macOS's "keychain wants your
  password" prompt (#46). Stop-gap: a self-signed `TempoStatusBar
  Signing` identity pinned via `CODE_SIGN_STYLE = Manual`, with an
  explicit documented upgrade path to a real Apple Developer ID
  certificate once enrollment completed (delivered later in #78/#92).

### 2026-04-22

- Investigating repeated keychain password prompts on PR builds led to
  the insight that the zip-wrapping GitHub Actions' `upload-artifact`
  applies to DMG downloads was the actual cause (differing
  `com.apple.quarantine` xattr vs. a release DMG) — not a signing bug
  (#54). Decision: stop distributing zips, move to straight DMGs
  everywhere.

### 2026-04-24

- Users should not have to manually add the app to their macOS Login
  Items — @stjohnb asked for this to be automated (#52), which became
  the `LaunchAtLoginManager`/`SMAppService` feature.
- Zip distribution was removed for PR and release builds (#56) for the
  quarantine-xattr reason found in #54. Explicit constraint carried
  forward: PR reviewers must still be able to download a DMG directly
  from the PR to test it — removing zips must not remove that ability,
  only change the wrapping format.

### 2026-05-13

- The Keychain service identifier needed to change once signed builds
  were shipping, specifically so **new installs start fresh** rather
  than hitting an old, cross-identity keychain item they can't access
  (#94).
- Moved Release builds from the self-signed cert to a real Apple
  Developer ID Application certificate plus notarization (#92), now
  that Apple Developer Program enrollment was complete — goal: users
  should no longer see Gatekeeper "unidentified developer" warnings on
  downloaded DMGs. Debug builds deliberately stayed ad-hoc-signed so
  local dev doesn't need the production cert. PR/main builds
  deliberately skip notarization to avoid burning per-push
  latency/quota — only tagged releases are notarized.
- A real production incident — a `v1.3.0-RC1` GitHub release created
  with a title that didn't match its underlying git tag, which silently
  produced a wrongly-named stable-looking artifact and an orphaned tag
  — drove a new rule: the release workflow must hard-fail immediately
  if `release.tag_name != release.name`, rather than silently building
  the wrong thing (#93).
- The bundle ID (`com.example...` → `com.stjohnsoftware.TempoStatusBarApp`)
  and the Keychain service name were changed together, deliberately, in
  one PR (#95): both changes invalidate OS-held "app identity" state
  (Launch-at-Login registration, Keychain ACL), so bundling them means
  existing users hit **one** disruption (re-enter credentials, retoggle
  Launch at Login) instead of two staggered ones. Explicitly documented
  as *not* a security downgrade — the old keychain item was already
  effectively inaccessible under the new Developer-ID signing identity.

### 2026-05-14

- Update checks were failing outright because the app was pointed at
  the **private** repo (#102) — GitHub's API refuses anonymous requests
  against private repos, so a token-based settings field was added as
  a stopgap. (Superseded — see the tokenless, public-repo-based fix in
  #160/2026-07-03.)
- "The app should check for updates" was the original, minimally-scoped
  ask that became the whole `UpdateChecker` feature (#71).
- Switching Release signing to Developer ID + notarization (#78) was
  framed explicitly around user trust: avoid Gatekeeper warnings on
  downloaded DMGs, now that Developer Program enrollment was done.
- The #94/#95 keychain rename was supposed to guarantee **zero**
  password prompts for upgrading users (fresh keychain item, no
  migration). Follow-up commits on #95 added migration logic that
  read the *old* keychain item to carry credentials forward — which
  reintroduced the exact ACL prompt #94 was meant to eliminate (now
  two prompts instead of one) (#98). This is a direct
  self-correction/contradiction of the "zero prompts" goal stated in
  #94 and assumed satisfied by #95 — worth knowing if `CredentialManager`
  still has a `legacyKeychainService` fallback path today.

### 2026-05-19

- Docs-only PRs should not require a full macOS build+test run (#111,
  #110). Root cause stated directly: CI was blocked because the repo
  had run out of macOS build minutes, and a pure-documentation change
  has no reason to consume them — this is the origin of the
  "CI skips for docs-only changes" rule (later codified as the
  general guidance to keep pure-docs work out of code PRs, and to
  batch/minimize macOS-triggering PRs since minutes are limited/billed).

### 2026-05-30

- Before the repo could be made public, a tracked file
  (`.mcp-claws.json`) containing two live secrets (a local MCP auth
  token and a Postgres connection string with a public IP) had to be
  fully remediated (#107). Stated policy: **once a secret has touched
  any git ref, treat it as burned** — rotate it first, don't rely on
  removal/history-rewrite alone to "fix" the exposure. Going public was
  explicitly blocked on this, because the in-app update-check work
  needed the repo to be public to function.
- Running an actual GitHub Actions runner unattended on a personal
  laptop kept triggering interactive Keychain-access popups, which
  defeats the point of CI (#121) — @stjohnb wanted a way to run
  self-hosted CI without interaction. **(This direction was reversed
  eleven days later in #126 — see 2026-06-03 — then reversed back in
  #165 — see 2026-07-05.)**

### 2026-06-03

- macOS CI was moved **away** from self-hosted runners, back to
  GitHub-hosted `macos-15` (#126), explicitly abandoning the
  self-hosted-CI effort from #121/#122: "GitHub macOS CI minutes are
  limited/billed and self-hosted CI is being dropped." This directly
  **supersedes the self-hosted push from #121** (2026-05-30 entry).
  Alongside the runner change, several open PRs were deliberately
  squashed into one consolidated PR specifically to conserve macOS CI
  minutes (each open PR triggers a full macOS build+test) — the origin
  of the current "batch related changes into PRs, avoid stacking"
  guidance. Linux utility jobs (Trivy, docs, cleanup, notify) were
  explicitly left self-hosted throughout — only the macOS jobs moved.

### 2026-07-03

- `UpdateChecker` was repointed from the private repo to the **public**
  `stjohnb/TempoStatusBar` mirror specifically so update checks work
  without requiring users to paste a GitHub personal access token
  (#160) — this **supersedes the token-based stopgap from #102**
  (2026-05-14 entry). Explicit ordering constraint: the URL flip must
  not merge until the public repo actually has published releases,
  otherwise every check 404s. Removing the now-unnecessary
  `githubToken` field from `CredentialManager.Credentials` was
  deliberately split into a separate, optional follow-up because it's
  a Keychain-persisted struct — the decode path needs to stay
  tolerant of the old field to avoid breaking existing installs.

### 2026-07-05

- macOS CI was moved **back** to self-hosted runners
  (`[self-hosted, macos, tempo]`) (#165, confirmed green in #162) —
  this **supersedes the GitHub-hosted move from #126** (2026-06-03
  entry). Rationale this time: the two self-hosted Macs are shared
  infrastructure across TempoStatusBar, bonkus, and namey CI, and have
  different Xcode versions installed. `maxim-lobanov/setup-xcode`
  reconfigures the *machine-global* `xcode-select` via `sudo`, which
  had already broken bonkus's iOS build by silently repointing its
  runner at CommandLineTools — so Xcode selection was moved to a
  job-scoped `DEVELOPER_DIR` export instead of a global tool switch,
  and the same fix was rolled out in parallel across all three repos
  sharing the fleet. `timeout-minutes` was added to all macOS jobs so
  one wedged job can't starve the shared two-runner pool.

### 2026-07-08

- Public availability model clarified (#159): development continues
  only in this private repo; a sync job mirrors source to a public
  snapshot at `github.com/stjohnb/TempoStatusBar`, and stable release
  DMGs are mirrored there too so the public repo has downloadable
  releases without maintaining a separate PAT-based release process.
  Deliberate simplification: only the most recent release is mirrored,
  not historical ones. Known imperfection accepted for now: the
  mirrored release tag isn't guaranteed to point at a source-accurate
  snapshot commit (tracked separately, not blocking).
- A `README.public.md` was required specifically for public/snapshot
  readers with **no access to the private repo** (#168): no commands
  that assume the author's private infrastructure, no links to files
  the snapshot scrubs (`.claude/`, `.plans/`, `ideas/`, internal
  automation docs), no credentials/tokens/keys even as examples, and —
  per a follow-up correction — don't even mention that the public repo
  is a sync of a private one. Constraint for maintainers: unlike the
  main README, this file is **not** kept in sync automatically and
  must be hand-maintained.

### 2026-07-09

- A real incident on a *different* repo sharing the same runner fleet
  (a Mac idle-slept 9 minutes into a CI build) revealed that macOS
  idle sleep is driven by the user-input idle timer, not CPU load — so
  a busy CI build cannot keep a shared Mac awake on its own (#170).
  Fix rolled out fleet-wide (this repo + bonkus + namey in lockstep):
  every macOS job takes a job-scoped `caffeinate` assertion right after
  checkout, time-bounded to the job's timeout plus a margin, released
  in an `if: always()` step. Deliberately warn-only/non-blocking so a
  runner without the keep-awake tooling installed just degrades to the
  old behavior instead of failing builds.
