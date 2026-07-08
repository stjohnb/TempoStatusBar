# CI/CD

## Workflow Files

All workflows live in `.github/workflows/`. Three workflows cover the full development lifecycle.

### Common Settings (all workflows)

- **Runners:** `macos-latest` for build/test/quality jobs; `self-hosted` for security scans and documentation checks
- **Xcode:** `xcode-version: '26.x'` via `maxim-lobanov/setup-xcode@v1` (semver range, picks up patch updates automatically within Xcode 26)
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
6. Unit tests via `./run_tests.sh` — uploads `test-results.xcresult` as artifact (7-day retention)
7. Archive (`xcodebuild … archive -archivePath ./build/TempoStatusBarApp.xcarchive`)
8. Verify `.app` bundle structure
9. **Verify code signature** — confirms `Authority=TempoStatusBar Signing` is present
10. Create DMG with `hdiutil create`
11. Delete any previous `pr-<N>` pre-release for this PR (`gh release delete --cleanup-tag`, ignored if absent)
12. Publish DMG as a pre-release tagged `pr-<N>` via `softprops/action-gh-release` (raw `.dmg`, no zip wrapping)
13. **Post or update PR comment** with the release-page download link (see below)
14. **Clean up signing keychain** (post-run step)

### `code-quality`

Permissions: default (`contents: read`)

Steps: Checkout + Xcode setup + `brew install swiftlint` + `swiftlint lint --reporter github-actions-logging`

### `security-scan`

Runs on `self-hosted`. Steps: Checkout + `aquasecurity/trivy-action@master` (filesystem scan, SARIF output) + upload to GitHub Security tab.

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
| `main-build` | macOS | Import signing cert → Debug + Release + Archive + verify signature + DMG creation → clean up keychain |
| `security-check` | self-hosted | Trivy filesystem scan (SARIF to Security tab) |
| `documentation-check` | self-hosted | Verifies required docs exist (`README.md`, `CONTRIBUTING.md`) |

---

## `release-tag.yml` — Release Build

**Trigger:** GitHub `release` events (`created`, `edited`), manual dispatch

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release-build` | macOS | Import signing cert → Release build + Archive + verify signature + DMG (named `TempoStatusBarApp-<version>.dmg`) → attach raw DMG to the GitHub Release page → clean up keychain |
| `security-check` | self-hosted | Trivy scan |
| `documentation-check` | self-hosted | Docs presence check |

The `release-build` job uploads the DMG to the GitHub Release via `softprops/action-gh-release`, pinned to a full commit SHA (`3bb12739c298aeb8a4eeaf626c5b8d85266b0e65`, tag `v2.6.2`). SHA pinning is required here — this action writes to the public release page, so mutable refs (e.g. `@v2`, `@master`) are not acceptable. The upload step is gated with `if: github.event_name == 'release' && github.event.action == 'created'` so that manual `workflow_dispatch` runs (used for build testing) skip the upload and do not fail due to the absence of an associated release.

---

## `pr-cleanup.yml` — PR Cleanup

**Trigger:** `pull_request` with `types: [closed]` (fires on both merge and unmerged close)

Runs on `ubuntu-latest`. Single step: `gh release delete pr-<N> --yes --cleanup-tag` (with `|| true` so a missing release is non-fatal). Skipped for fork PRs.

This workflow exists so per-PR pre-releases do not accumulate on the Releases page indefinitely.

---

## Code Signing

All three workflows sign the `.app` bundle using a self-signed certificate named **"TempoStatusBar Signing"** stored as a repository secret. The signing process runs as a discrete step before the archive step and is cleaned up in a post-run step.

**Secrets required (configured in GitHub repository settings):**

| Secret | Content |
|---|---|
| `SIGNING_CERT_P12_BASE64` | Base64-encoded `.p12` file containing the self-signed certificate and private key |
| `SIGNING_CERT_PASSWORD` | Password for the `.p12` archive |
| `KEYCHAIN_PASSWORD` | Password for the temporary CI keychain created during the run |

**Signing process:**

1. Decode `SIGNING_CERT_P12_BASE64` to a `.p12` file in `$RUNNER_TEMP`
2. Create a temporary keychain (`$RUNNER_TEMP/build.keychain-db`) and unlock it
3. Import the `.p12` into the temporary keychain
4. Prepend the temp keychain to the user's keychain search list so Xcode finds the identity automatically during build
5. Delete the `.p12` file from disk immediately after import
6. Build — Xcode signs the `.app` bundle using the discovered identity
7. Verify: `codesign --verify --deep --strict` + assert `Authority=TempoStatusBar Signing` is present in the signature
8. Post-run: delete the temporary keychain (`security delete-keychain`)

**Self-signed cert behavior:** macOS does not trust self-signed certs for Gatekeeper validation, so the build is not notarized. However, `codesign --verify --deep --strict` still passes and the signature establishes a stable identity that can be compared across builds. The `security find-identity -p codesigning` step is run without `-v` (valid) because the self-signed cert will not appear as valid in the system trust store.

---

## Key Design Decisions

- **`xcode-version: '26.x'`** — uses semver range to pick up patch updates automatically within Xcode 26. Tracks the current year-based Xcode release (Apple adopted year-based naming starting with Xcode 26 in 2026).
- **PR DMG distribution via per-PR pre-release** — DMGs for PR builds are published via `softprops/action-gh-release` to a pre-release tagged `pr-<N>`, NOT via `actions/upload-artifact`. The artifact action always wraps its payload in a `.zip`; macOS treats a DMG extracted from a downloaded zip as a different quarantine origin than a DMG downloaded raw from the Releases page, causing Keychain re-prompts even with identical signing identities. Publishing via the same action used for tagged releases keeps the quarantine origin consistent. Per-PR pre-releases are cleaned up automatically by `pr-cleanup.yml` when the PR closes.
- **`contents: write` on `build-and-test`** — The PR-build-publishing step uses `softprops/action-gh-release` to create/update a per-PR pre-release, which writes to the repo's Releases. The job declares its own `permissions` block, which replaces the workflow-level permissions for that job — so `contents: write` must be listed explicitly on the job, not just at the workflow level. The workflow-level `contents` permission stays at `read`.
- **`cancel-in-progress`** — `true` for PR and main workflows to prevent stale runs from blocking the queue; `false` for the release workflow so in-flight release builds are not interrupted.
- **DMG naming** — PR builds: `TempoStatusBarApp-pr-<N>-<sha>`; release builds: `TempoStatusBarApp-<version>`.
- **Artifact retention** — `test-results` (xcresult) artifacts: 7 days for PRs, 30 days for main. PR build DMGs live as assets on a per-PR pre-release and are deleted when the PR closes (`pr-cleanup.yml`). Tagged-release DMGs live on the GitHub Release page and do not expire.
- **Fork PRs** — both the pre-release publish step and the PR comment step are skipped for forks (read-only `GITHUB_TOKEN`). Fork contributors who need to test their build should either rebase onto the upstream repo or build locally with Xcode.
- **SwiftLint** — installed at CI runtime via `brew`; configuration in `.swiftlint.yml`.
- **Trivy action** — pinned to `@master` (mutable ref); consider pinning to a fixed tag in a future cleanup.
- **SHA pinning for release-publishing actions** — `softprops/action-gh-release` is pinned to a full commit SHA rather than a tag or moving ref. Actions that write to the public release page carry higher supply-chain risk if compromised; use full SHA pins for them. When updating the pin, verify the SHA with `gh api repos/softprops/action-gh-release/git/refs/tags/<version>` before committing.
- **PR comment body construction** — the `github-script` step in `pr-verification.yml` builds the PR comment using an array joined with `\n` rather than a template literal. Template literals with unindented multi-line content break YAML block scalars; the array approach keeps every JavaScript line at consistent indentation within the `script: |` block and avoids YAML parse errors. The download URL is constructed deterministically from the PR number and version string — no `listWorkflowRunArtifacts` API call is needed.
- **Self-signed code signing** — all workflows sign the archive using a self-signed cert stored as a base64 secret. This establishes a consistent signing identity and satisfies `codesign --verify --deep --strict` without requiring an Apple Developer account or notarization. The cert is imported into a temporary keychain that is deleted at the end of each run — it is never written to the runner's permanent login keychain.
- **Signing verification in CI** — a dedicated "Verify code signature" step asserts `Authority=TempoStatusBar Signing` is present in the built archive. This catches accidental ad-hoc or unsigned builds before the DMG is packaged and distributed.
