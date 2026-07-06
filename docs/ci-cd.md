# CI/CD

## Workflow Files

All workflows live in `.github/workflows/`. Six workflows cover the full development lifecycle.

### Common Settings (all workflows)

- **Runners:** Self-hosted `[self-hosted, macos, tempo]` for build/test/quality jobs; `[self-hosted, linux]` for security scans, documentation checks, PR cleanup, and failure notification. The `tempo` label pins these jobs to the Mac that does **not** run the real TempoStatusBarApp: signing jobs put a temp keychain into the runner user's keychain search list, and on a Mac where the real app is polling, that triggers keychain-unlock dialogs in the user's session.
- **Xcode:** every macOS job starts with a shared `Select Xcode` step that finds the newest non-beta Xcode under `/Applications` and exports a **job-scoped `DEVELOPER_DIR`**. It deliberately does *not* use `maxim-lobanov/setup-xcode` or `xcode-select`: those change the machine-global active Xcode via `sudo`, and the two Macs are shared with namey and bonkus CI (which use the same step). No job may mutate machine-global state.
- **Concurrency:** PR and main workflows use `cancel-in-progress: true` to cancel redundant runs; the release workflow uses `cancel-in-progress: false` to avoid interrupting in-flight release builds

---

## `pr-verification.yml` — PR Verification

**Trigger:** `pull_request` targeting `main`

**Jobs:**

### `build-and-test`

Permissions: `contents: write`, `pull-requests: write`

Steps:
1. Checkout + Xcode setup
2. Generate version string: `<latest-tag>-pr-<PR number>-<short SHA>` (stored as step output `steps.version.outputs.version`)
3. **Import signing certificate** (see [Code Signing](#code-signing) below)
4. Debug build (`xcodebuild … -configuration Debug`)
5. Release build (`xcodebuild … -configuration Release`)
6. Unit tests via `./run_tests.sh`, with `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS: "1"` set on the step (see [Key Design Decisions](#key-design-decisions)) — uploads `test-results.xcresult` as artifact (3-day retention)
7. Archive (`xcodebuild … archive -archivePath ./build/TempoStatusBarApp.xcarchive`)
8. Verify `.app` bundle structure
9. **Verify code signature** — confirms `Authority=TempoStatusBar Signing` is present
10. Create DMG with `hdiutil create`
11. **Sign and notarize DMG** (skipped on fork PRs) — sign the DMG with the Developer ID identity, submit via `xcrun notarytool`, staple, and re-verify with `spctl --assess`
12. Delete any previous `pr-<N>` pre-release for this PR (`gh release delete --cleanup-tag`, ignored if absent)
13. Publish DMG as a pre-release tagged `pr-<N>` via `softprops/action-gh-release` (raw `.dmg`, no zip wrapping)
14. **Post or update PR comment** with the release-page download link (see below)
15. **Clean up signing keychain + notarization key** (post-run step)

### `code-quality`

Permissions: default (`contents: read`)

Steps: Checkout + Xcode setup + install SwiftLint (`command -v swiftlint || brew install swiftlint` — self-hosted runners keep it installed between runs, so this only installs on a cold runner; a bare `brew install` would otherwise try to upgrade an existing copy and fail where the Homebrew prefix isn't user-writable) + `swiftlint lint --reporter github-actions-logging`

### `security-scan`

Runs on `[self-hosted, linux]`. Steps: Checkout + `aquasecurity/trivy-action@master` (filesystem scan, SARIF output, `cache: 'false'`) + upload to GitHub Security tab.

**Doc-only skip:** The workflow trigger uses `paths-ignore: ['docs/**', '**/*.md']`, so PRs that change only documentation files do not trigger the workflow at all — the build, lint, and scan jobs simply do not run. Branch protection on `main` must require the workflow name ("PR Verification") rather than individual job names; if individual job names are listed as required checks, doc-only PRs will be blocked in "Expected" state because those checks never report.

---

## PR Build Comment

After the DMG is published to the per-PR pre-release, an `actions/github-script@v7` step posts (or updates) a comment on the PR. This only runs for non-fork PRs (`github.event.pull_request.head.repo.full_name == github.repository`) because fork PRs receive a read-only token and cannot write comments or releases.

**Comment identity:** An HTML marker `<!-- pr-build-comment -->` is embedded in the comment body. The step paginates all PR comments, finds the existing marker comment if present, and updates it rather than creating a new one. This ensures exactly one build comment per PR regardless of how many pushes are made.

**Download link:** The comment links to a deterministic release-asset URL of the form `<server>/<owner>/<repo>/releases/download/pr-<N>/TempoStatusBarApp-<version>.dmg`. No API lookup is required because the tag and filename are both known statically inside the workflow.

The step uses `continue-on-error: true` so a comment failure doesn't fail the build.

---

## `main-verification.yml` — Main Branch Verification

**Trigger:** Push to `main`, manual dispatch (`workflow_dispatch`)

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `main-build` | `[self-hosted, macos, tempo]` | Import signing cert → Release build + unit tests (real-keychain suite skipped, see below) + Archive + verify signature + DMG creation → clean up keychain |
| `security-check` | `[self-hosted, linux]` | Trivy filesystem scan (SARIF to Security tab) |
| `documentation-check` | `[self-hosted, linux]` | Verifies required docs exist (`README.md`, `CONTRIBUTING.md`) |

---

## `release-tag.yml` — Release Build

**Trigger:** GitHub `release` events (`created`, `edited`), manual dispatch

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release-build` | `[self-hosted, macos, tempo]` | Import signing cert → Release build + Archive (both with `MARKETING_VERSION=<tag>` override) + verify signature + DMG (named `TempoStatusBarApp-<version>.dmg`) → attach raw DMG to the GitHub Release page → clean up keychain |
| `security-check` | `[self-hosted, linux]` | Trivy scan |
| `documentation-check` | `[self-hosted, linux]` | Docs presence check |

The `release-build` job uploads the DMG to the GitHub Release via `softprops/action-gh-release`, pinned to a full commit SHA (`3bb12739c298aeb8a4eeaf626c5b8d85266b0e65`, tag `v2.6.2`). SHA pinning is required here — this action writes to the public release page, so mutable refs (e.g. `@v2`, `@master`) are not acceptable. The upload step is gated with `if: github.event_name == 'release' && github.event.action == 'created'` so that manual `workflow_dispatch` runs (used for build testing) skip the upload and do not fail due to the absence of an associated release.

### Release name / tag consistency check

The first step of `release-build` asserts that `github.event.release.tag_name` equals `github.event.release.name`. This catches the failure mode where a release is created in the GitHub UI with a title like `v1.3.0-RC1` but the underlying tag is left at `v1.3.0` — the release looks correct in the UI but the workflow extracts the wrong version from `GITHUB_REF`, and the stable `v1.3.0` tag gets pushed prematurely. The check fails the workflow before any build work runs and prints recovery instructions. It's gated on `if: github.event_name == 'release'` so `workflow_dispatch` runs are unaffected.

---

## `pr-cleanup.yml` — PR Cleanup

**Trigger:** `pull_request` with `types: [closed]` (fires on both merge and unmerged close)

Runs on `[self-hosted, linux]`. Single step: `gh release delete pr-<N> --yes --cleanup-tag` (with `|| true` so a missing release is non-fatal). Skipped for fork PRs.

This workflow exists so per-PR pre-releases do not accumulate on the Releases page indefinitely.

---

## `notify-failures.yml` — Main Branch Failure Notification

**Trigger:** `workflow_run` on the `"Main Verification"` and `"Actions Storage Cleanup"` workflows, type `completed`

**Permissions:** `contents: read`, `issues: write`, `actions: read`

**Concurrency:** group `notify-main-failure`, `cancel-in-progress: false`

**Job: `notify`**

Runs on `[self-hosted, linux]`. The job only executes when:
- `github.event.workflow_run.conclusion == 'failure'`
- `github.event.workflow_run.head_branch == 'main'`

**Steps:**

1. **Deduplication check** — uses `gh issue list` + `jq` to count open issues with the title `"Build failure: <workflow name>"`. If one already exists, no new issue is created (prevents flood of duplicate issues for repeated failures before anyone fixes the build).
2. **Dynamic label** — checks whether a `bug` label exists in the repo (`gh label list | grep -qx "bug"`). Only passes `--label bug` to `gh issue create` if the label is present; omits the flag otherwise to avoid a hard failure on repos without that label.
3. **Issue creation** — creates an issue titled `"Build failure: <workflow name>"` (e.g. `"Build failure: Main Verification"` or `"Build failure: Actions Storage Cleanup"`) with a body linking to the failed workflow run URL. The title is built from `github.event.workflow_run.name`, so each monitored workflow deduplicates independently.

**Key design points:**
- The `workflow_run` trigger (rather than a step inside `main-verification.yml`) keeps failure notification fully decoupled from the build workflow. The build workflow does not need to be modified when notification behavior changes.
- The branch guard (`head_branch == 'main'`) prevents the job from firing on feature-branch runs of the same workflow.
- `notify-failures.yml` does **not** include itself in the `workflows:` list — self-referential inclusion would cause the workflow to trigger on its own runs.
- `cancel-in-progress: false` on the concurrency group ensures back-to-back main failures each get their own issue-creation attempt (though deduplication prevents actual duplicate issues).

---

## `actions-storage-cleanup.yml` — Actions Storage Cleanup

**Trigger:** `push` to `main` (primary — runs on every merge), `schedule` (`cron: '0 5 * * *'` — daily 05:00 UTC backstop), `workflow_dispatch`. The push trigger was added in #152 because the schedule-only configuration never fired a single run after the workflow was introduced — GitHub's cron scheduler has registration latency and drops scheduled runs under load, so cleanup now hooks the reliable push-to-main event.

**Permissions:** `actions: write`, `contents: read`

**Concurrency:** group `actions-storage-cleanup`, `cancel-in-progress: true` (the purge is idempotent — cancelling an in-flight run in favour of the newest is safe)

**Job: `purge-caches`**

Runs on `[self-hosted, linux]`. Two steps:

1. **Purge all caches** — `gh cache delete --all --repo ${{ github.repository }} || true`. The `|| true` guard prevents the job from failing when there are no caches to delete (the `gh` CLI exits non-zero on an empty list).
2. **Delete artifacts older than 3 days** — uses `gh api --paginate` to list all non-expired artifacts, filters for those whose `created_at` is more than 3 days old, and deletes each via `gh api -X DELETE`. Both PR and main `test-results` now use 3-day retention, so a 3-day cutoff deletes no live debugging artifact early. This step exists because legacy DMG artifacts uploaded before DMG distribution moved to per-PR pre-releases carried the 90-day default GitHub retention and accumulated against the org-shared quota (#146).

This workflow protects the org-shared 2 GB Actions storage quota. These workflows do not rely on GHA caching (Trivy DB and binary persist on the self-hosted Linux disk between runs), so purging all caches daily is safe. If a future workflow ever legitimately introduces cross-run caching, this scheduled job must be revisited — a comment in the workflow file notes this explicitly.

---

## Code Signing

All three workflows sign the Release `.app` bundle with a **Developer ID Application** certificate issued by Apple. The Release configuration sets `CODE_SIGN_IDENTITY = "Developer ID Application"`, `CODE_SIGN_STYLE = Manual`, and `ENABLE_HARDENED_RUNTIME = YES`; the team ID is supplied at build time via the `DEVELOPMENT_TEAM` secret. The Debug configuration is signed ad-hoc (`CODE_SIGN_IDENTITY = "-"`) so local developers don't need access to the production cert.

The release and PR workflows additionally **notarize and staple** the DMG so Gatekeeper accepts the download silently. Main builds sign but do **not** notarize — see [Key Design Decisions](#key-design-decisions).

**Secrets required (configured in GitHub repository settings):**

| Secret | Content |
|---|---|
| `SIGNING_CERT_P12_BASE64` | Base64-encoded `.p12` file containing the Developer ID Application certificate and its private key |
| `SIGNING_CERT_PASSWORD` | Password for the `.p12` archive |
| `KEYCHAIN_PASSWORD` | Password for the temporary CI keychain created during the run |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID (10-character alphanumeric, e.g. `ABC1234567`) — overrides the empty `DEVELOPMENT_TEAM` in `project.pbxproj` |
| `AC_API_KEY_ID` | App Store Connect API Key ID |
| `AC_API_ISSUER_ID` | App Store Connect API Issuer ID |
| `AC_API_KEY_P8_BASE64` | Base64-encoded `.p8` private key downloaded when the API key was created |

**Signing process (all workflows):**

1. Decode `SIGNING_CERT_P12_BASE64` to a `.p12` file in `$RUNNER_TEMP`
2. Create a temporary keychain (`$RUNNER_TEMP/build.keychain-db`) and unlock it
3. Import the `.p12` into the temporary keychain
4. Download and import the Apple **Developer ID Certification Authority** intermediate (`DeveloperIDG2CA.cer`) into the temp keychain so `codesign` can build the full chain to the system-trusted Apple Root CA (without it, `codesign` fails with `errSecInternalComponent` on Xcode 26 — #133)
5. Prepend the temp keychain to the user's keychain search list so Xcode finds the identity automatically during build
6. Delete the `.p12` file from disk immediately after import
7. Build — Xcode signs the `.app` bundle using the Developer ID identity (with Hardened Runtime)
8. Verify: `codesign --verify --deep --strict`, assert `Authority=Developer ID Application:` is present, and assert the `runtime` flag appears in the signature flags
9. Post-run: delete the temporary keychain (`security delete-keychain`)

**Notarization (release and PR workflows):**

1. Decode `AC_API_KEY_P8_BASE64` to `$RUNNER_TEMP/AuthKey.p8`
2. Sign the DMG itself with `codesign --sign "Developer ID Application: …" --timestamp` (notarytool will reject an unsigned container)
3. Submit the DMG via `xcrun notarytool submit … --key … --key-id … --issuer … --wait --timeout 30m`
4. Staple with `xcrun stapler staple` so the ticket is embedded in the DMG and Gatekeeper does not need to call home on first launch
5. Re-verify with `xcrun stapler validate` and `spctl --assess --type open --context context:primary-signature` — this is the canonical end-user Gatekeeper check
6. Post-run: delete the temporary keychain and `AuthKey.p8`

**Why App Store Connect API key instead of an app-specific password?** API keys are revocable per-key without rotating the Apple ID, scoped to a single role, and work headlessly without 2FA flows. App-specific passwords work with `notarytool` too but are tied to the Apple ID and more painful to rotate.

---

## Key Design Decisions

- **`Select Xcode` via job-scoped `DEVELOPER_DIR`** — resolves the newest non-beta Xcode installed on whichever self-hosted runner picks up the job. The two self-hosted Macs do not necessarily have the same Xcode installed, so pinning a single version (e.g. `'26.x'`) would fail on any runner lacking it. Exporting `DEVELOPER_DIR` per job (instead of `sudo xcode-select` / `setup-xcode`) means the choice never leaks outside the job — required because the same two Macs also serve namey and bonkus iOS CI.
- **Shared-runner contract** — the two self-hosted Macs are shared by TempoStatusBar, namey, and bonkus CI. Every macOS job in all three repos follows the same rules: no `sudo`; never mutate machine-global state (`xcode-select`, system keychain search order, Homebrew upgrades); guard tool installs with `command -v <tool> || <user-scoped install>`; keep signing material in per-job temp keychains that are deleted in an `always()` cleanup step; and set `timeout-minutes` on every macOS job so a wedged job can't starve the two-runner pool.
  - **Caveat — signing jobs mutate the user keychain state.** The signing step is the one sanctioned exception to "never mutate machine-global state": it replaces the user's keychain search list with only the temp keychain (`security list-keychains -d user -s "$KEYCHAIN_PATH"`) and sets it as the user default (`security default-keychain -d user`), because the runner user has no GUI login session and `codesign` otherwise fails with `errSecInternalComponent` when the signing keychain is only in the search list. Both mutations are reverted in the `always()` "Clean up signing keychain" step (restore the search list and default to `login.keychain-db` alone, delete the temp keychain). **Residual risk:** because the search list is fully replaced rather than prepended, any other keychain that happened to be in the user's search list before the job ran (potentially added by a concurrent namey/bonkus job on these same two shared Macs) is dropped for the job's duration, and if that cleanup never runs (runner disconnects mid-job, process killed out-of-band, post-steps skipped), the shared Mac's user search list and default keychain are left pointing at an orphaned temp keychain, which can break `security`/`codesign` in the next job from *any* of the three repos. A signing job on this repo self-heals on its next run (it re-sets the search list and default), but non-signing jobs and other repos do not — if that state is observed, reset it manually with `security list-keychains -d user -s login.keychain-db` and `security default-keychain -d user -s login.keychain-db`. A future hardening is a defensive reset as the first step of every macOS job; changing the signing flow that way needs coordination across all three repos first (see "Do not change the signing flow without coordinating").
- **PR DMG distribution via per-PR pre-release** — DMGs for PR builds are published via `softprops/action-gh-release` to a pre-release tagged `pr-<N>`, NOT via `actions/upload-artifact`. The artifact action always wraps its payload in a `.zip`; macOS treats a DMG extracted from a downloaded zip as a different quarantine origin than a DMG downloaded raw from the Releases page, causing Keychain re-prompts even with identical signing identities. Publishing via the same action used for tagged releases keeps the quarantine origin consistent. Per-PR pre-releases are cleaned up automatically by `pr-cleanup.yml` when the PR closes.
- **`contents: write` on `build-and-test`** — The PR-build-publishing step uses `softprops/action-gh-release` to create/update a per-PR pre-release, which writes to the repo's Releases. The job declares its own `permissions` block, which replaces the workflow-level permissions for that job — so `contents: write` must be listed explicitly on the job, not just at the workflow level. The workflow-level `contents` permission stays at `read`.
- **`cancel-in-progress`** — `true` for PR and main workflows to prevent stale runs from blocking the queue; `false` for the release workflow so in-flight release builds are not interrupted.
- **DMG naming** — PR builds: `TempoStatusBarApp-pr-<N>-<sha>`; release builds: `TempoStatusBarApp-<version>`.
- **Artifact retention** — `test-results` (xcresult) artifacts: 3 days for both PRs and main. PR build DMGs live as assets on a per-PR pre-release and are deleted when the PR closes (`pr-cleanup.yml`). Tagged-release DMGs live on the GitHub Release page and do not expire.
- **Fork PRs** — both the pre-release publish step and the PR comment step are skipped for forks (read-only `GITHUB_TOKEN`). Fork contributors who need to test their build should either rebase onto the upstream repo or build locally with Xcode.
- **SwiftLint** — installed at CI runtime via `brew`; configuration in `.swiftlint.yml`.
- **Trivy action** — pinned to `@master` (mutable ref); consider pinning to a fixed tag in a future cleanup. GHA caching is explicitly disabled (`cache: 'false'`) on all three Trivy steps — the self-hosted Linux runners already persist the Trivy DB and binary on local disk between runs, so GHA cache is redundant and would otherwise accumulate ~112 MB of org-shared Actions storage quota (Trivy DB + binary cached per run). Any caches that do accumulate are purged daily by `actions-storage-cleanup.yml`.
- **SHA pinning for release-publishing actions** — `softprops/action-gh-release` is pinned to a full commit SHA rather than a tag or moving ref. Actions that write to the public release page carry higher supply-chain risk if compromised; use full SHA pins for them. When updating the pin, verify the SHA with `gh api repos/softprops/action-gh-release/git/refs/tags/<version>` before committing.
- **PR comment body construction** — the `github-script` step in `pr-verification.yml` builds the PR comment using an array joined with `\n` rather than a template literal. Template literals with unindented multi-line content break YAML block scalars; the array approach keeps every JavaScript line at consistent indentation within the `script: |` block and avoids YAML parse errors. The download URL is constructed deterministically from the PR number and version string — no `listWorkflowRunArtifacts` API call is needed.
- **`MARKETING_VERSION` CLI override** — Release and PR `xcodebuild` invocations pass `MARKETING_VERSION=<tag-version>` on the command line. This overrides the value hardcoded in `project.pbxproj` and ensures `appVersion`, `CFBundleShortVersionString`, and the About alert all report the release tag (e.g. `1.3.0`), not the stale project-file value (#105).
- **Developer ID signing with Hardened Runtime** — Release builds are signed with an Apple-issued Developer ID Application certificate and built with `ENABLE_HARDENED_RUNTIME = YES`. The cert is imported into a temporary keychain that is deleted at the end of each run — it is never written to the runner's permanent login keychain. Debug builds use ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) so local development doesn't depend on the production cert. The Apple **Developer ID Certification Authority** intermediate is also imported into the temp keychain so `codesign` can build the full chain; without it Xcode 26 runners fail with `errSecInternalComponent` (#133).
- **Notarization on PR and release builds** — both `pr-verification.yml` and `release-tag.yml` sign, notarize, and staple the DMG so users (including maintainers grabbing a PR build) don't hit Gatekeeper's first-launch warning. Main builds still skip notarization because their DMGs are not distributed. Notarization adds ~30s–2min per build. The PR notarization steps are gated on `github.event.pull_request.head.repo.full_name == github.repository` so that fork PRs (no secrets) skip them gracefully — those PRs still produce a signed DMG, just not a notarized one, and the publish + comment steps are already skipped for forks.
- **Signing verification in CI** — the "Verify code signature" step asserts both `Authority=Developer ID Application:` and the presence of the `runtime` flag in the signature. This catches accidental ad-hoc, self-signed, or unhardened builds before the DMG is packaged.
- **`spctl --assess` over `stapler validate` alone** — the release workflow runs both. `stapler validate` confirms a ticket exists locally; `spctl --assess --type open --context context:primary-signature` is what Gatekeeper actually runs when a user opens the file from a quarantined download. Asserting both protects against the case where stapling appeared to succeed but the ticket doesn't satisfy Gatekeeper.
- **Self-hosted runners — macOS and Linux** — build/test/quality jobs run on `[self-hosted, macos, tempo]`. The Linux-only utility jobs (Trivy scans, docs checks, PR cleanup, failure notification) run on `[self-hosted, linux]` and declare an explicit OS label so they are never scheduled onto a macOS runner.
- **Real-keychain test skip on CI (`TEMPO_SKIP_KEYCHAIN_TESTS`)** — `CredentialManagerHasStoredCredentialsTests` (see [OVERVIEW.md](OVERVIEW.md#testing)) exercises the real Keychain via `CredentialManager.shared`, including deleting the item under the production service name in `setUp`/`tearDown`. On the shared self-hosted Macs, the runner user's login keychain holds genuine credentials, and headless keychain access blocks on an authorization dialog instead of failing fast (observed as multi-minute test hangs, and once an actual password prompt on the runner's screen). `pr-verification.yml` and `main-verification.yml` set `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS: "1"` on the "Run unit tests" step; `xcodebuild` only forwards environment variables prefixed `TEST_RUNNER_` into the test-host process (stripping the prefix), so the test suite sees plain `TEMPO_SKIP_KEYCHAIN_TESTS=1`. The gate lives in `setUpWithError` (via `XCTSkipIf`) rather than `setUp`, because it must run before any keychain access is attempted. Locally, without the env var, the suite runs unskipped against the real Keychain as before.
