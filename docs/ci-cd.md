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

Permissions: `contents: read`, `pull-requests: write`, `actions: read`

Steps:
1. Checkout + Xcode setup
2. Debug build (`xcodebuild … -configuration Debug`)
3. Release build (`xcodebuild … -configuration Release`)
4. Unit tests via `./run_tests.sh` — uploads `test-results.xcresult` as artifact (7-day retention)
5. Archive (`xcodebuild … archive -archivePath ./build/TempoStatusBarApp.xcarchive`)
6. Verify `.app` bundle structure
7. Generate version string: `pr-<PR number>-<short SHA>` (stored as step output `steps.version.outputs.version`)
8. Create DMG with `hdiutil create`
9. Upload DMG as artifact `TempoStatusBarApp-<version>` (7-day retention)
10. **Post or update PR comment** with download link (see below)

### `code-quality`

Permissions: default (`contents: read`)

Steps: Checkout + Xcode setup + `brew install swiftlint` + `swiftlint lint --reporter github-actions-logging`

### `security-scan`

Runs on `self-hosted`. Steps: Checkout + `aquasecurity/trivy-action@master` (filesystem scan, SARIF output) + upload to GitHub Security tab.

---

## PR Build Comment

After the DMG is uploaded, a `actions/github-script@v7` step posts (or updates) a comment on the PR. This only runs for non-fork PRs (`github.event.pull_request.head.repo.full_name == github.repository`) because fork PRs receive a read-only token and cannot write comments.

**Comment identity:** An HTML comment marker `<!-- pr-build-comment -->` is embedded in the comment body. The step paginates all PR comments, finds the existing marker comment if present, and updates it rather than creating a new one. This ensures exactly one build comment per PR regardless of how many pushes are made.

**Download link:** The script calls `listWorkflowRunArtifacts` to retrieve the artifact ID and constructs a direct link (`<run-url>/artifacts/<id>`), falling back to the run URL if the artifact isn't found.

The step uses `continue-on-error: true` so a comment failure doesn't fail the build.

---

## `main-verification.yml` — Main Branch Verification

**Trigger:** Push to `main`, manual dispatch (`workflow_dispatch`)

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `main-build` | macOS | Debug + Release + Archive + DMG creation |
| `security-check` | self-hosted | Trivy filesystem scan (SARIF to Security tab) |
| `documentation-check` | self-hosted | Verifies required docs exist (`README.md`, `CONTRIBUTING.md`) |

---

## `release-tag.yml` — Release Build

**Trigger:** GitHub `release` events (`created`, `edited`), manual dispatch

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release-build` | macOS | Release build + Archive + DMG (named `TempoStatusBarApp-<version>.dmg`); uploads DMG as both an Actions artifact and a GitHub Release asset |
| `security-check` | self-hosted | Trivy scan |
| `documentation-check` | self-hosted | Docs presence check |

The `release-build` job uploads the DMG to the GitHub Release via `softprops/action-gh-release`, pinned to a full commit SHA (`3bb12739c298aeb8a4eeaf626c5b8d85266b0e65`, tag `v2.6.2`). SHA pinning is required here — this action writes to the public release page, so mutable refs (e.g. `@v2`, `@master`) are not acceptable. The upload step is gated with `if: github.event_name == 'release' && github.event.action == 'created'` so that manual `workflow_dispatch` runs (used for build testing) skip the upload and do not fail due to the absence of an associated release.

---

## Key Design Decisions

- **`xcode-version: '26.x'`** — uses semver range to pick up patch updates automatically within Xcode 26. Tracks the current year-based Xcode release (Apple adopted year-based naming starting with Xcode 26 in 2026).
- **`actions: read` on `build-and-test`** — The PR-comment step calls `listWorkflowRunArtifacts`, which requires `actions: read`. The job declares its own `permissions` block, which replaces the workflow-level permissions for that job — so `actions: read` must be listed explicitly on the job, not just at the workflow level.
- **`cancel-in-progress`** — `true` for PR and main workflows to prevent stale runs from blocking the queue; `false` for the release workflow so in-flight release builds are not interrupted.
- **DMG naming** — PR builds: `TempoStatusBarApp-pr-<N>-<sha>`; release builds: `TempoStatusBarApp-<version>`.
- **Artifact retention** — 7 days for all artifacts.
- **Fork PRs** — the PR comment step is skipped for forks (read-only `GITHUB_TOKEN`). The DMG is still built and uploaded; forks just don't get the auto-comment.
- **SwiftLint** — installed at CI runtime via `brew`; configuration in `.swiftlint.yml`.
- **Trivy action** — pinned to `@master` (mutable ref); consider pinning to a fixed tag in a future cleanup.
- **SHA pinning for release-publishing actions** — `softprops/action-gh-release` is pinned to a full commit SHA rather than a tag or moving ref. Actions that write to the public release page carry higher supply-chain risk if compromised; use full SHA pins for them. When updating the pin, verify the SHA with `gh api repos/softprops/action-gh-release/git/refs/tags/<version>` before committing.
- **PR comment body construction** — the `github-script` step in `pr-verification.yml` builds the PR comment using an array joined with `\n` rather than a template literal. Template literals with unindented multi-line content break YAML block scalars; the array approach keeps every JavaScript line at consistent indentation within the `script: |` block and avoids YAML parse errors.
