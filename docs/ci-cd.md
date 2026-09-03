# CI/CD

**Depth: Reference.** Read this when changing a GitHub Actions workflow,
code signing/notarization, S3 release storage, or the shared self-hosted
runner setup. For app architecture, read [OVERVIEW.md](OVERVIEW.md); for
Linux-specific release steps, read [linux.md](linux.md#releases).

## Workflow Files

All workflows live in `.github/workflows/`. Eight workflows cover the full development lifecycle.

### Common Settings (all workflows)

- **Runners:** Self-hosted `[self-hosted, macos, tempo]` for build/test/quality jobs; `[self-hosted, linux]` for security scans, documentation checks, and PR cleanup. The `tempo` label pins these jobs to the Mac that does **not** run the real TempoStatusBarApp: signing jobs put a temp keychain into the runner user's keychain search list, and on a Mac where the real app is polling, that triggers keychain-unlock dialogs in the user's session. Machine-level documentation for the two shared Macs — inventory, runner-label semantics, registration and Xcode-install runbooks — is centralised in the nixos-config repo: [docs/macos-runners.md](https://github.com/St-John-Software/nixos-config/blob/main/docs/macos-runners.md).
- **Xcode:** every macOS job starts with a shared `Select Xcode` step that finds the newest non-beta Xcode under `/Applications` and exports a **job-scoped `DEVELOPER_DIR`**. It deliberately does *not* use `maxim-lobanov/setup-xcode` or `xcode-select`: those change the machine-global active Xcode via `sudo`, and the two Macs are shared with namey and bonkus CI (which use the same step). No job may mutate machine-global state.
- **Concurrency:** PR and main workflows use `cancel-in-progress: true` to cancel redundant runs; the release workflow uses `cancel-in-progress: false` to avoid interrupting in-flight release builds
- **DMG storage — S3 via OIDC (#177):** built DMGs are stored in the `tempo-statusbar-releases` S3 bucket (job env `S3_BUCKET`/`S3_REGION`/`DOWNLOAD_BASE`), not as GitHub Release assets — GitHub storage/bandwidth limits were being hit. Jobs authenticate with GitHub OIDC: `permissions: id-token: write` plus `aws-actions/configure-aws-credentials` (SHA-pinned) assuming the IAM role in the `AWS_ROLE_ARN` secret; no static AWS credentials are stored. Fork PRs skip all AWS steps (no OIDC access to the role). Stable releases land at `releases/TempoStatusBarApp-<version>.dmg` (plus a `TempoStatusBarApp-latest.dmg` copy); PR builds at `pr/<N>/TempoStatusBarApp-<version>.dmg`. Both prefixes are public-read over HTTPS. One-time provisioning is handled by [`s3-bootstrap.yml`](#s3-bootstrapyml--s3-bootstrap) (see below).

---

## `pr-verification.yml` — PR Verification

**Trigger:** `pull_request` targeting `main` (`paths-ignore`: `docs/**`, `**/*.md`, `linux/**`, `flake.nix`, `flake.lock`)

**Jobs:**

### `build-and-test`

Permissions: `contents: read`, `pull-requests: write`, `id-token: write`

Steps:
1. Checkout + Xcode setup
2. Generate version string: `<latest-tag>-pr-<PR number>-<short SHA>` (stored as step output `steps.version.outputs.version`)
3. **Import signing certificate** (see [Code Signing](#code-signing) below)
4. Debug build (`xcodebuild … -configuration Debug`)
5. Release build (`xcodebuild … -configuration Release`)
6. Unit tests via `./run_tests.sh`, with `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS: "1"` set on the step (see [Key Design Decisions](#key-design-decisions)) — uploads `test-results.xcresult` as artifact (3-day retention, `continue-on-error: true` in both PR and main workflows so org storage-quota exhaustion cannot fail the build)
7. Archive (`xcodebuild … archive -archivePath ./build/TempoStatusBarApp.xcarchive`)
8. Verify `.app` bundle structure
9. **Verify code signature** — confirms `Authority=Developer ID Application:` is present
10. Create DMG with `hdiutil create`
11. **Sign and notarize DMG** (skipped on fork PRs) — sign the DMG with the Developer ID identity, submit via `xcrun notarytool`, staple, and re-verify with `spctl --assess`
12. **Upload DMG to S3** (skipped on fork PRs) — `command -v aws || brew install awscli`, assume the OIDC role via `aws-actions/configure-aws-credentials`, then `aws s3 cp` to `s3://<bucket>/pr/<N>/TempoStatusBarApp-<version>.dmg`
13. **Post or update PR comment** with the S3 download link (see below)
14. **Clean up signing keychain + notarization key** (post-run step)

### `code-quality`

Permissions: default (`contents: read`)

Steps: Checkout + Xcode setup + install SwiftLint (`command -v swiftlint || brew install swiftlint` — self-hosted runners keep it installed between runs, so this only installs on a cold runner; a bare `brew install` would otherwise try to upgrade an existing copy and fail where the Homebrew prefix isn't user-writable) + `swiftlint lint --reporter github-actions-logging`

### `security-scan`

Runs on `[self-hosted, linux]`. Steps: Checkout + `aquasecurity/trivy-action@master` (filesystem scan, SARIF output, `cache: 'false'`) + upload to GitHub Security tab.

**Doc-only skip:** The workflow trigger uses `paths-ignore: ['docs/**', '**/*.md']`, so PRs that change only documentation files do not trigger the workflow at all — the build, lint, and scan jobs simply do not run. Branch protection on `main` must require the workflow name ("PR Verification") rather than individual job names; if individual job names are listed as required checks, doc-only PRs will be blocked in "Expected" state because those checks never report.

**Dependabot PRs (`IS_DEPENDABOT`):** Dependabot-triggered workflow runs read the **Dependabot secrets store**, not the repo's normal Actions secrets — so `SIGNING_CERT_P12_BASE64` and friends are empty on a Dependabot run, and importing an empty `.p12` fails immediately (this is what happened on #180's first run, in 15s). `build-and-test` sets a job-level `IS_DEPENDABOT: ${{ github.actor == 'dependabot[bot]' }}` env flag and branches on it (#182) rather than skipping the job outright, so Dependabot PRs still get real build+test coverage:

- **Still runs:** Debug build + unit tests (Debug already ad-hoc signs; keychain tests are already skipped via `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS`); Release build and archive, ad-hoc signed (`CODE_SIGN_IDENTITY=-`) in place of the unavailable Developer ID identity; app bundle structure check, `codesign --verify --deep --strict`, and the Hardened Runtime flag check (both valid against an ad-hoc signature); DMG creation.
- **Skipped only for Dependabot:** Import signing certificate step (the empty-cert failure); the `Authority=Developer ID Application:` check inside "Verify code signature" (ad-hoc signatures don't have one); Sign DMG / Notarize DMG / Staple notarization ticket; Ensure AWS CLI / Configure AWS credentials / Upload DMG to S3 / Comment PR with build artifact link — Dependabot runs get a read-only `GITHUB_TOKEN` and no `id-token`/`AWS_ROLE_ARN` access, so there is nothing to upload and no way to comment anyway.

Human and fork-PR behavior is unchanged: the pre-existing same-repo guard (`github.event.pull_request.head.repo.full_name == github.repository`) on the signing/upload/comment steps is simply extended with `&& env.IS_DEPENDABOT != 'true'`, since Dependabot branches live in this repo (same-repo) but lack signing/AWS secrets the same way a fork PR does.

`linux-ci.yml` also skips its PR-comment step for Dependabot for the same read-only-token reason.

---

## PR Build Comment

After the DMG is uploaded to S3, an `actions/github-script@v7` step posts (or updates) a comment on the PR. This only runs for non-fork PRs (`github.event.pull_request.head.repo.full_name == github.repository`) because fork PRs receive a read-only token and cannot write comments (nor assume the OIDC role for the upload).

**Comment identity:** An HTML marker `<!-- pr-build-comment -->` is embedded in the comment body. The step paginates all PR comments, finds the existing marker comment if present, and updates it rather than creating a new one. This ensures exactly one build comment per PR regardless of how many pushes are made.

**Download link:** The comment links to a deterministic S3 URL of the form `<DOWNLOAD_BASE>/pr/<N>/TempoStatusBarApp-<version>.dmg`. No API lookup is required because the prefix and filename are both known statically inside the workflow.

The step uses `continue-on-error: true` so a comment failure doesn't fail the build.

---

## `main-verification.yml` — Main Branch Verification

**Trigger:** Push to `main` (`paths-ignore`: `linux/**`, `flake.nix`, `flake.lock`), manual dispatch (`workflow_dispatch`)

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `main-build` | `[self-hosted, macos, tempo]` | Import signing cert → Release build + unit tests (real-keychain suite skipped, see below) + Archive + verify signature + DMG creation → clean up keychain |
| `security-check` | `[self-hosted, linux]` | Trivy filesystem scan (SARIF to Security tab) |
| `documentation-check` | `[self-hosted, linux]` | Verifies required docs exist (`README.md`, `CONTRIBUTING.md`) |

---

## `linux-ci.yml` — Linux App CI

**Trigger:** `pull_request` targeting `main` and pushes to `main`, restricted by `paths` to `linux/**`, `flake.nix`, `flake.lock`, the workflow itself, and `.github/actions/setup-nix/**`

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `build-and-test` | `[self-hosted, linux]` | `cargo fmt --check` → `cargo clippy --all-targets -- -D warnings` → `cargo test` → `cargo build --release` |

Every step runs through `nix $NIX_FLAGS develop ..# --command …` from the
`linux/` working directory (`..#` selects the root flake). The toolchain is
repo-owned: it comes from the `flake.nix` devShell, never from the runner. The
`.github/actions/setup-nix` composite action puts the runner's Nix on `PATH` and
fails loudly if there is none; it is copied verbatim from `St-John-Software/claws`,
the org reference implementation. `timeout-minutes: 30` covers the first run,
which pulls the Rust toolchain closure into the nix store.

`pr-verification.yml` and `main-verification.yml` list `linux/**`, `flake.nix`
and `flake.lock` in `paths-ignore` so Rust-only changes never occupy the shared
Macs. `paths-ignore` only skips when *every* changed file matches, so a mixed
Swift + Rust change still runs the macOS jobs.

On `pull_request` runs against a same-repo branch, a final step posts (or
updates) a PR comment confirming the Rust checks and release build passed for
the head SHA, under a `<!-- pr-build-comment-linux -->` marker — separate from
`pr-verification.yml`'s `<!-- pr-build-comment -->` DMG marker, so a mixed
Swift + Rust PR gets one comment per platform instead of one clobbering the
other. There is no DMG-equivalent download link — Linux binaries are published
per release rather than per PR, so the comment reports build status and points
at `linux-release.yml`'s version gate. Fork PRs skip this step (read-only
`GITHUB_TOKEN`), and `continue-on-error: true` keeps a comment failure from
failing the build.

---

## `linux-release.yml` — Linux Release

**Trigger:** Push to `main` restricted by `paths` to `linux/**`, `flake.nix`, `flake.lock` and the workflow itself; manual dispatch (`workflow_dispatch`)

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release` | `[self-hosted, linux]` | Version gate → `nix build .#static` → static-linkage and version assertions → tarball + `.sha256` → `gh release create linux-vX.Y.Z` (gh from the flake's `ci` devShell) |

`concurrency: linux-release` with `cancel-in-progress: false` — two rapid
merges must not cancel a run that has already created a tag.
`timeout-minutes: 90` covers the first `pkgsStatic` build, which compiles a
musl stdenv closure and `ring` from source; later runs hit the nix store.

**The gate is version-driven, not push-driven.** The first step resolves
`nix $NIX_FLAGS eval --raw .#static.version` — which reads `linux/Cargo.toml`,
the single source of truth — rejects anything that is not plain `X.Y.Z`, and
sets `release=false` with a `::notice::` if `linux-vX.Y.Z` already exists.
Every later step is `if: steps.gate.outputs.release == 'true'`, so a
`linux/**` merge without a version bump is a green no-op. The gate
distinguishes an HTTP 404 (tag absent) from a `gh` invocation failure and
fails the job loudly on the latter, rather than treating any non-zero
`gh api` exit as "tag absent".

Two assertions run before anything is published: `readelf -l | grep -q INTERP`
fails the job if `.#static` produced a dynamically-linked binary, and
`tempo-statusbar --version` must equal the tag's version. Only `--version` is
run — clap prints and exits 0 without touching D-Bus, whereas running the
binary bare would start the tray and exit non-zero on a runner with no session
bus. `readelf` comes from `pkgs.binutils` in the repo's own devShell, invoked
via `nix develop .# --command`; the whole artifact is built through the repo
flake rather than a `rustup` step, so the binary users download and the binary
Nix builds come from one expression.

The tarball `tempo-statusbar-<version>-x86_64-linux.tar.gz` carries the binary
plus `linux/packaging/`'s `.desktop` entry, systemd user unit and `INSTALL.md`,
and is built reproducibly (`--sort=name --owner=0 --group=0 --numeric-owner
--mtime='@0'`). There is **no S3 upload**: unlike the macOS DMG, the Linux
assets live on the GitHub release, which is what the Claws snapshot job copies
to the public mirror.

The `linux-v*` tag namespace is deliberately separate from the macOS `v1.3.x`
line. Because `release-tag.yml` triggers on `on: release` with no tag filter,
all three of its jobs carry
`if: ${{ !startsWith(github.event.release.tag_name, 'linux-v') }}` — otherwise
a `linux-v*` release would start a macOS sign+notarize build with
`MARKETING_VERSION=linux-0.1.0`. On `workflow_dispatch`,
`github.event.release` is null, so the guard evaluates true and behaviour is
unchanged. (In practice a `GITHUB_TOKEN`-created release does not start
workflows at all; the guard covers a hand- or PAT-created one.)

x86_64 only — both self-hosted runners are x86_64. `packages.static` is
defined for `aarch64-linux` in `flake.nix` but nothing builds it; aarch64
builds from source.

---

## `release-tag.yml` — Release Verification

**Trigger:** GitHub `release` events (`created`, `edited`), manual dispatch

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release-build` | `[self-hosted, macos, tempo]` | Import signing cert → Release build + Archive (both with `MARKETING_VERSION=<tag>` override) + verify signature + DMG (named `TempoStatusBarApp-<version>.dmg`) → upload DMG to S3 + write download link into the release notes → clean up keychain |
| `security-check` | `[self-hosted, linux]` | Trivy scan |
| `documentation-check` | `[self-hosted, linux]` | Docs presence check |

The `release-build` job uploads the DMG to `s3://<bucket>/releases/TempoStatusBarApp-<version>.dmg` (and copies it to `releases/TempoStatusBarApp-latest.dmg`) using the OIDC role, then appends a `**Download:** [<dmg>](<S3 URL>)` line to the GitHub Release body via `gh release edit` so the release page remains a discoverable download point. The release-notes edit uses `GITHUB_TOKEN`, and events caused by `GITHUB_TOKEN` never start new workflow runs — so the resulting `release: edited` event does not re-trigger this workflow. All AWS/upload steps are gated with `if: github.event_name == 'release' && github.event.action == 'created'` so that manual `workflow_dispatch` runs (used for build testing) skip the upload and do not fail due to the absence of an associated release.

### Release name / tag consistency check

The first step of `release-build` asserts that `github.event.release.tag_name` equals `github.event.release.name`. This catches the failure mode where a release is created in the GitHub UI with a title like `v1.3.0-RC1` but the underlying tag is left at `v1.3.0` — the release looks correct in the UI but the workflow extracts the wrong version from `GITHUB_REF`, and the stable `v1.3.0` tag gets pushed prematurely. The check fails the workflow before any build work runs and prints recovery instructions. It's gated on `if: github.event_name == 'release'` so `workflow_dispatch` runs are unaffected.

---

## `pr-cleanup.yml` — PR Cleanup

**Trigger:** `pull_request` with `types: [closed]` (fires on both merge and unmerged close)

Runs on `[self-hosted, linux]`. Installs the AWS CLI if missing (official installer, `sudo` is acceptable on the Linux runner), assumes the OIDC role, then `aws s3 rm s3://<bucket>/pr/<N>/ --recursive` (with `|| true` so a missing prefix is non-fatal). Skipped for fork PRs — they never uploaded.

This workflow exists so per-PR DMG builds do not accumulate in the bucket indefinitely. As a backstop for cleanup runs that never fire, the bucket has a lifecycle rule (created by `s3-bootstrap.yml`) that expires `pr/`-prefixed objects after 30 days.

---

## `s3-bootstrap.yml` — S3 Bootstrap

**Trigger:** `workflow_dispatch` only, with inputs `bucket` (default `tempo-statusbar-releases`), `region` (default `us-east-1`), and `role_name` (default `tempo-statusbar-github-actions`)

One-time — but idempotent, safe to re-run — provisioning of the AWS resources the release/PR workflows depend on. Runs on `[self-hosted, linux]` using **temporary static credentials** read from the `AWS_BOOTSTRAP_ACCESS_KEY_ID` / `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` secrets (it fails fast with a clear error if they are unset). It creates:

1. The S3 bucket, with a public-access-block configuration that blocks ACLs but permits a bucket policy, and a bucket policy granting anonymous `s3:GetObject` on `releases/*` and `pr/*` only
2. A lifecycle rule expiring `pr/`-prefixed objects after 30 days (backstop for missed PR-close cleanups)
3. The `token.actions.githubusercontent.com` OIDC identity provider in the account (skipped if it already exists — it is account-global and may be shared with other repos)
4. An IAM role whose trust policy is scoped to `repo:St-John-Software/TempoStatusBar:*` (audience `sts.amazonaws.com`), carrying an inline policy allowing only `s3:PutObject`/`GetObject`/`DeleteObject` on the bucket's objects and `s3:ListBucket` on the bucket

The final step prints the role ARN to the job summary along with the decommissioning checklist: store the ARN as the `AWS_ROLE_ARN` secret, revoke the temporary access key in IAM, and delete both bootstrap secrets. After that, no static AWS credentials exist anywhere — all recurring workflows authenticate via OIDC.

---

## Main Branch Failure Monitoring

There is no per-repo failure-notification workflow. Main-branch build failures are monitored centrally by Claws' `main-build-monitor` job ([St-John-Software/claws#2778](https://github.com/St-John-Software/claws/issues/2778)), which watches every `push`/`schedule`-triggered run of this repo's workflows on `main`. When a run fails it retries once if the failure looks transient; otherwise it files (or bumps) an issue titled `Build failure: <workflow name>` in this repo, one per workflow, and closes it with a comment once a later run of the same workflow goes green. PR-scoped runs are ignored, so fork PRs cannot file bogus issues. Nothing in this repo needs to change when the monitoring behaviour changes.

---

## `actions-storage-cleanup.yml` — Actions Storage Cleanup

**Trigger:** `push` to `main` (primary — runs on every merge), `schedule` (`cron: '0 5 * * *'` — daily 05:00 UTC backstop), `workflow_dispatch`. The push trigger was added in #152 because the schedule-only configuration never fired a single run after the workflow was introduced — GitHub's cron scheduler has registration latency and drops scheduled runs under load, so cleanup now hooks the reliable push-to-main event.

**Permissions:** `actions: write`, `contents: read`

**Concurrency:** group `actions-storage-cleanup`, `cancel-in-progress: true` (the purge is idempotent — cancelling an in-flight run in favour of the newest is safe)

**Job: `purge-caches`**

Runs on `[self-hosted, linux]`. The job now checks out the repo, runs
`./.github/actions/setup-nix`, and sets a job-level `defaults.run.shell` of
`nix … develop ${{ github.workspace }}#ci --command bash -euo pipefail {0}`,
so `gh`/`jq` come from the flake without any change to the step scripts
themselves. Two steps:

1. **Purge all caches** — `gh cache delete --all --repo ${{ github.repository }} || true`. The `|| true` guard prevents the job from failing when there are no caches to delete (the `gh` CLI exits non-zero on an empty list).
2. **Delete artifacts older than 3 days** — uses `gh api --paginate` to list all non-expired artifacts, filters for those whose `created_at` is more than 3 days old, and deletes each via `gh api -X DELETE`. Both PR and main `test-results` now use 3-day retention, so a 3-day cutoff deletes no live debugging artifact early. This step exists because legacy DMG artifacts uploaded before DMG distribution moved to per-PR pre-releases carried the 90-day default GitHub retention and accumulated against the org-shared quota (#146).

This workflow protects the org-shared 2 GB Actions storage quota. These workflows do not rely on GHA caching (Trivy DB and binary persist on the self-hosted Linux disk between runs), so purging all caches daily is safe. If a future workflow ever legitimately introduces cross-run caching, this scheduled job must be revisited — a comment in the workflow file notes this explicitly.

---

## `.github/dependabot.yml` — Dependency Updates

Not a workflow — a Dependabot config file, added in #173 in response to a repo-wide "missing dependency-update configuration" alert. Enables version updates for the `github-actions` ecosystem (`directory: /`) and the `cargo` ecosystem (`directory: /linux`, the Rust tray crate added in #190). Both use a weekly schedule (`03:00 Europe/London`), `open-pull-requests-limit: 5`, and a single `all-dependencies` group with pattern `"*"` that collapses all version bumps into one grouped PR rather than one PR per crate or action. Dependabot resolves each `directory` independently, so a new manifest in a new directory needs its own entry even when the ecosystem already appears elsewhere in the repo. Cargo PRs only touch `linux/**`, which `pr-verification.yml` `paths-ignore`s, so they run `linux-ci.yml` on `[self-hosted, linux]` and never occupy the shared Macs; `github-actions` PRs run the macOS jobs and are gated on the `IS_DEPENDABOT` condition described earlier in this doc. Dependabot PRs still go through the normal checks like any other PR.

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
| `AWS_ROLE_ARN` | ARN of the IAM role (created by `s3-bootstrap.yml`) that release/PR/cleanup jobs assume via GitHub OIDC for S3 access |

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
- **Shared-runner contract** — the two self-hosted Macs are shared by TempoStatusBar, namey, and bonkus CI. Every macOS job in all three repos follows the same rules: no `sudo`; never mutate machine-global state (`xcode-select`, system keychain search order, Homebrew upgrades); guard tool installs with `command -v <tool> || <user-scoped install>`; keep signing material in per-job temp keychains that are deleted in an `always()` cleanup step; set `timeout-minutes` on every macOS job so a wedged job can't starve the two-runner pool; and hold a job-scoped `caffeinate` sleep assertion — macOS idle sleep tracks user input, not CPU load, so a busy build can't keep a Mac awake by itself (bonkus#1550). Every macOS job here does this via `~/bin/keep-awake` from the nixos-config repo (`home/mac/keep_awake.sh`, installed into `~/bin` by `home-manager switch`): `keep-awake on <minutes>` right after checkout, `keep-awake off` in an `always()` final step; warn-only if the Mac lacks it — see nixos-config `docs/macos-runners.md`, "Power / keep-awake".
  - **Caveat — signing jobs mutate the user keychain state.** The signing step is the one sanctioned exception to "never mutate machine-global state": it replaces the user's keychain search list with only the temp keychain (`security list-keychains -d user -s "$KEYCHAIN_PATH"`) and sets it as the user default (`security default-keychain -d user`), because the runner user has no GUI login session and `codesign` otherwise fails with `errSecInternalComponent` when the signing keychain is only in the search list. Both mutations are reverted in the `always()` "Clean up signing keychain" step (restore the search list and default to `login.keychain-db` alone, delete the temp keychain). **Residual risk:** because the search list is fully replaced rather than prepended, any other keychain that happened to be in the user's search list before the job ran (potentially added by a concurrent namey/bonkus job on these same two shared Macs) is dropped for the job's duration, and if that cleanup never runs (runner disconnects mid-job, process killed out-of-band, post-steps skipped), the shared Mac's user search list and default keychain are left pointing at an orphaned temp keychain, which can break `security`/`codesign` in the next job from *any* of the three repos. A signing job on this repo self-heals on its next run (it re-sets the search list and default), but non-signing jobs and other repos do not — if that state is observed, reset it manually with `security list-keychains -d user -s login.keychain-db` and `security default-keychain -d user -s login.keychain-db`. A future hardening is a defensive reset as the first step of every macOS job; changing the signing flow that way needs coordination across all three repos first (see "Do not change the signing flow without coordinating").
- **DMG distribution via S3, not GitHub (#177)** — DMGs for both PR and tagged-release builds are uploaded to S3 with `aws s3 cp`, NOT attached as release assets (GitHub storage/bandwidth limits were being hit) and NOT via `actions/upload-artifact`. The artifact action always wraps its payload in a `.zip`; macOS treats a DMG extracted from a downloaded zip as a different quarantine origin than a DMG downloaded raw over HTTPS, causing Keychain re-prompts even with identical signing identities — the S3 links serve the raw `.dmg`, keeping the quarantine origin consistent. PR uploads are cleaned up by `pr-cleanup.yml` when the PR closes (plus a 30-day lifecycle backstop).
- **OIDC over static AWS keys** — CI never holds long-lived AWS credentials. Jobs that touch S3 declare `id-token: write` and assume the `AWS_ROLE_ARN` role via `aws-actions/configure-aws-credentials`; the role's trust policy only accepts tokens whose subject matches `repo:St-John-Software/TempoStatusBar:*`, and its permissions are limited to object read/write/delete in the release bucket. The `build-and-test` job's own `permissions` block replaces the workflow-level permissions, so `id-token: write` must be listed explicitly on the job; `contents` dropped back to `read` there when release publishing moved to S3.
- **`cancel-in-progress`** — `true` for PR and main workflows to prevent stale runs from blocking the queue; `false` for the release workflow so in-flight release builds are not interrupted.
- **DMG naming** — PR builds: `TempoStatusBarApp-pr-<N>-<sha>`; release builds: `TempoStatusBarApp-<version>`.
- **Artifact retention** — `test-results` (xcresult) artifacts: 3 days for both PRs and main. PR build DMGs live under `s3://<bucket>/pr/<N>/` and are deleted when the PR closes (`pr-cleanup.yml`; 30-day lifecycle backstop). Tagged-release DMGs live under `s3://<bucket>/releases/` and do not expire.
- **Fork PRs** — the S3 upload steps and the PR comment step are skipped for forks (read-only `GITHUB_TOKEN`, and no OIDC access to the AWS role). Fork contributors who need to test their build should either rebase onto the upstream repo or build locally with Xcode.
- **SwiftLint** — installed at CI runtime via `brew`; configuration in `.swiftlint.yml`.
- **Trivy action** — pinned to `@master` (mutable ref); consider pinning to a fixed tag in a future cleanup. GHA caching is explicitly disabled (`cache: 'false'`) on all three Trivy steps — the self-hosted Linux runners already persist the Trivy DB and binary on local disk between runs, so GHA cache is redundant and would otherwise accumulate ~112 MB of org-shared Actions storage quota (Trivy DB + binary cached per run). Any caches that do accumulate are purged daily by `actions-storage-cleanup.yml`.
- **SHA pinning for credential/publishing actions** — `aws-actions/configure-aws-credentials` is pinned to a full commit SHA (`e6de054238d6b7531b4efff3b6587d9aade6a06c`, tag `v6.2.3` as of #180's Dependabot bump) rather than a tag or moving ref. Actions that mint cloud credentials or write to public distribution points carry higher supply-chain risk if compromised; use full SHA pins for them. Dependabot's `github-actions` ecosystem update correctly bumps both the SHA and the trailing `# vX.Y.Z` comment together — the pin does not silently go stale. When updating the pin manually, verify the SHA with `gh api repos/aws-actions/configure-aws-credentials/git/refs/tags/<version>` before committing.
- **PR comment body construction** — the `github-script` step in `pr-verification.yml` builds the PR comment using an array joined with `\n` rather than a template literal. Template literals with unindented multi-line content break YAML block scalars; the array approach keeps every JavaScript line at consistent indentation within the `script: |` block and avoids YAML parse errors. The download URL is constructed deterministically from the PR number and version string — no `listWorkflowRunArtifacts` API call is needed.
- **`MARKETING_VERSION` CLI override** — Release and PR `xcodebuild` invocations pass `MARKETING_VERSION=<tag-version>` on the command line. This overrides the value hardcoded in `project.pbxproj` and ensures `appVersion`, `CFBundleShortVersionString`, and the About alert all report the release tag (e.g. `1.3.0`), not the stale project-file value (#105).
- **Developer ID signing with Hardened Runtime** — Release builds are signed with an Apple-issued Developer ID Application certificate and built with `ENABLE_HARDENED_RUNTIME = YES`. The cert is imported into a temporary keychain that is deleted at the end of each run — it is never written to the runner's permanent login keychain. Debug builds use ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) so local development doesn't depend on the production cert. The Apple **Developer ID Certification Authority** intermediate is also imported into the temp keychain so `codesign` can build the full chain; without it Xcode 26 runners fail with `errSecInternalComponent` (#133).
- **Notarization on PR and release builds** — both `pr-verification.yml` and `release-tag.yml` sign, notarize, and staple the DMG so users (including maintainers grabbing a PR build) don't hit Gatekeeper's first-launch warning. Main builds still skip notarization because their DMGs are not distributed. Notarization adds ~30s–2min per build. The PR notarization steps are gated on `github.event.pull_request.head.repo.full_name == github.repository` so that fork PRs (no secrets) skip them gracefully — those PRs still produce a signed DMG, just not a notarized one, and the publish + comment steps are already skipped for forks.
- **Signing verification in CI** — the "Verify code signature" step asserts both `Authority=Developer ID Application:` and the presence of the `runtime` flag in the signature. This catches accidental ad-hoc, self-signed, or unhardened builds before the DMG is packaged.
- **`spctl --assess` over `stapler validate` alone** — the release workflow runs both. `stapler validate` confirms a ticket exists locally; `spctl --assess --type open --context context:primary-signature` is what Gatekeeper actually runs when a user opens the file from a quarantined download. Asserting both protects against the case where stapling appeared to succeed but the ticket doesn't satisfy Gatekeeper.
- **Separate `linux-v*` tag namespace, GitHub assets not S3** — the Linux tray app releases on its own `linux-vX.Y.Z` line so its cadence is not welded to the macOS `v1.3.x` line, and its tarball is attached to the GitHub release rather than uploaded to S3. The DMG went to S3 because of its size and the macOS quarantine-origin problem (see above); neither applies to a ~10 MB tarball, and release assets are what the Claws snapshot job copies to the public mirror, which is the whole point of publishing it. The version is read from `linux/Cargo.toml` rather than from a tag the operator types, so the tag, the flake and the binary's `--version` cannot disagree — the workflow asserts all three. Because `release-tag.yml` triggers on `on: release` with no tag filter, every one of its jobs needs a `!startsWith(github.event.release.tag_name, 'linux-v')` guard; adding a job there without one restarts the macOS sign+notarize path on Linux releases.
- **Self-hosted runners — macOS and Linux** — build/test/quality jobs run on `[self-hosted, macos, tempo]`. The Linux-only utility jobs (Trivy scans, docs checks, PR cleanup) run on `[self-hosted, linux]` and declare an explicit OS label so they are never scheduled onto a macOS runner.
- **CI dependencies are repo-owned** — the self-hosted Linux runner baseline is `nix`/`git`/`docker` only; `gh`, `jq` and every other CLI must come from `flake.nix`'s `ci` devShell. A bare `gh` in a `[self-hosted, linux]` job dies with exit 127 (issue #218), and `|| true` guards turn that into a silent no-op rather than a visible failure — `actions-storage-cleanup.yml` reported success while purging nothing for weeks. Prefer a job-level `defaults.run.shell` over per-call wrapping for jobs that only shell out to CLI tools; it leaves the scripts untouched.
- **Real-keychain test skip on CI (`TEMPO_SKIP_KEYCHAIN_TESTS`)** — `CredentialManagerHasStoredCredentialsTests` (see [OVERVIEW.md](OVERVIEW.md#testing)) exercises the real Keychain via `CredentialManager.shared`, including deleting the item under the production service name in `setUp`/`tearDown`. On the shared self-hosted Macs, the runner user's login keychain holds genuine credentials, and headless keychain access blocks on an authorization dialog instead of failing fast (observed as multi-minute test hangs, and once an actual password prompt on the runner's screen). `pr-verification.yml` and `main-verification.yml` set `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS: "1"` on the "Run unit tests" step; `xcodebuild` only forwards environment variables prefixed `TEST_RUNNER_` into the test-host process (stripping the prefix), so the test suite sees plain `TEMPO_SKIP_KEYCHAIN_TESTS=1`. The gate lives in `setUpWithError` (via `XCTSkipIf`) rather than `setUp`, because it must run before any keychain access is attempted. Locally, without the env var, the suite runs unskipped against the real Keychain as before.
