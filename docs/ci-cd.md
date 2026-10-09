# CI/CD

**Depth: Reference.** Read this when changing a Forgejo Actions workflow,
code signing/notarization, S3 release storage, or the shared self-hosted
runner setup. For app architecture, read [OVERVIEW.md](OVERVIEW.md); for
Linux-specific release steps, read [linux.md](linux.md#releases).

Product requirements: [product/distribution.md](product/distribution.md)

## Workflow Files

The canonical repo is `git.home.bstjohn.net/St-John-Software/TempoStatusBar`
on Forgejo, and all workflows live in `.forgejo/workflows/`. Seven workflows
cover the full development lifecycle: `pr-verification.yml`,
`main-verification.yml`, `linux-ci.yml`, `linux-release.yml`,
`release-tag.yml`, `pr-cleanup.yml` and `s3-bootstrap.yml`.

`.github/workflows/` still holds copies of `pr-verification.yml` and
`linux-ci.yml`, kept only so the last GitHub PR of the migration could pass
its required checks. Forgejo ignores `.github/workflows/` entirely once
`.forgejo/workflows/` exists, and the GitHub repo is archived after the
migration — never edit those copies. `.github/actions/setup-nix` is still
live: Forgejo workflows reference it by path.

### Common Settings (all workflows)

- **Runners:** Self-hosted `[self-hosted, macos, tempo]` for build/test/quality jobs; `[self-hosted, linux]` for security scans, documentation checks, Linux CI/release, PR cleanup and the S3 bootstrap. The Mac Forgejo runner declares exactly those labels. The `tempo` label pins these jobs to the Mac that does **not** run the real TempoStatusBarApp: signing jobs put a temp keychain into the runner user's keychain search list, and on a Mac where the real app is polling, that triggers keychain-unlock dialogs in the user's session. Signing no longer changes the default keychain (#234), but the `tempo` pin stays as defence in depth. Machine-level documentation for the two shared Macs — inventory, runner-label semantics, registration and Xcode-install runbooks — is centralised in the nixos-config repo: [docs/macos-runners.md](https://github.com/St-John-Software/nixos-config/blob/main/docs/macos-runners.md).
- **Xcode:** every macOS job starts with a shared `Select Xcode` step that finds the newest non-beta Xcode under `/Applications` and exports a **job-scoped `DEVELOPER_DIR`**. It deliberately does *not* use `maxim-lobanov/setup-xcode` or `xcode-select`: those change the machine-global active Xcode via `sudo`, and the two Macs are shared with namey and bonkus CI (which use the same step). No job may mutate machine-global state.
- **Homebrew on the Mac:** the Forgejo host runner's `PATH` omits Homebrew, so Mac jobs that need `swiftlint` or `aws` run an "Expose Homebrew" step that appends `/opt/homebrew/bin` and `/usr/local/bin` to `$GITHUB_PATH` when they exist. Mac jobs never use nix — the flake targets Linux only — so JSON/HTTP work on the Mac uses the Xcode CLT `/usr/bin/python3`.
- **Remote actions:** every `uses:` is a full URL pinned to a commit SHA — `https://github.com/actions/checkout@<sha>  # v7.0.1`, `https://github.com/aws-actions/configure-aws-credentials@<sha>  # v6.3.0` — plus `https://code.forgejo.org/forgejo/upload-artifact@v4` (upstream `actions/upload-artifact` v4+ does not work on Forgejo). `./.github/actions/setup-nix` is referenced by path.
- **No `gh` in CI:** release creation, tag checks, release-body edits and PR comments call the Forgejo API (`${{ github.api_url }}`) with `curl` and `${{ github.token }}`. On Linux, `curl`/`jq` come from the flake `ci` devShell; on the Mac, `/usr/bin/python3` does the work. Forgejo's PR comment endpoint is `/issues/{index}/comments`, so commenting jobs hold `issues: write` as well as `pull-requests: write`.
- **Concurrency:** PR and main workflows use `cancel-in-progress: true` to cancel redundant runs; the release workflow uses `cancel-in-progress: false` to avoid interrupting in-flight release builds
- **DMG storage — S3 via OIDC (#177):** built DMGs are stored in the `tempo-statusbar-releases` S3 bucket (job env `S3_BUCKET`/`S3_REGION`/`DOWNLOAD_BASE`), not as release assets. Jobs authenticate with Forgejo's OIDC issuer (`https://www.bstjohn.net/forgejo-oidc`): Forgejo only mints an ID token for a job that sets `enable-openid-connect: true`, so each S3 job carries that plus `permissions: id-token: write`, then `aws-actions/configure-aws-credentials` (SHA-pinned) assumes the IAM role in the `AWS_ROLE_ARN` secret; no static AWS credentials are stored. Fork PRs skip all AWS steps (Forgejo fork PRs get no secrets or OIDC token). Stable releases land at `releases/TempoStatusBarApp-<version>.dmg` (plus a `TempoStatusBarApp-latest.dmg` copy); PR builds at `pr/<N>/TempoStatusBarApp-<version>.dmg`. Both prefixes are public-read over HTTPS. One-time provisioning is handled by [`s3-bootstrap.yml`](#s3-bootstrapyml--s3-bootstrap) (see below).

---

## `pr-verification.yml` — PR Verification

**Trigger:** `pull_request` targeting `main` (`paths-ignore`: `docs/**`, `**/*.md`, `linux/**`, `flake.nix`, `flake.lock`)

**Jobs:**

### `build-and-test`

Permissions: `contents: read`, `pull-requests: write`, `issues: write`, `id-token: write`; `enable-openid-connect: true`

Steps:
1. Checkout + Expose Homebrew + Xcode setup
2. Generate version string: `<latest-tag>-pr-<PR number>-<short SHA>` (stored as step output `steps.version.outputs.version`)
3. **Import signing certificate** (see [Code Signing](#code-signing) below)
4. Debug build (`xcodebuild … -configuration Debug`)
5. Release build (`xcodebuild … -configuration Release`)
6. Unit tests via `./run_tests.sh`, with `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS: "1"` set on the step (see [Key Design Decisions](#key-design-decisions)) — uploads `test-results.xcresult` as an artifact via `forgejo/upload-artifact@v4` (3-day retention, `continue-on-error: true` in both PR and main workflows so an artifact-store failure cannot fail the build)
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

Steps: Checkout + Xcode setup + Expose Homebrew + install SwiftLint (`command -v swiftlint || brew install swiftlint` — self-hosted runners keep it installed between runs, so this only installs on a cold runner; a bare `brew install` would otherwise try to upgrade an existing copy and fail where the Homebrew prefix isn't user-writable) + `swiftlint lint --reporter github-actions-logging`

### `security-scan`

Runs on `[self-hosted, linux]`. Steps: Checkout + `setup-nix` + the Trivy pair described under [Trivy gating](#trivy-gating).

**Doc-only skip:** The workflow trigger uses `paths-ignore: ['docs/**', '**/*.md']`, so PRs that change only documentation files do not trigger the workflow at all — the build, lint, and scan jobs simply do not run. Branch protection on `main` must require the workflow name ("PR Verification") rather than individual job names; if individual job names are listed as required checks, doc-only PRs will be blocked in "Expected" state because those checks never report.

**Renovate PRs** are same-repo branches and run with the normal repo secrets, so they get the same signed, notarized build as any other same-repo PR.

---

## PR Build Comment

After the DMG is uploaded to S3, a step posts (or updates) a comment on the PR. This only runs for non-fork PRs (`github.event.pull_request.head.repo.full_name == github.repository`) because fork PRs get no write token (nor OIDC access for the upload).

**Implementation:** a `/usr/bin/python3` heredoc (no nix or `jq` on the Mac) lists `GET $API_URL/repos/$REPO/issues/$PR/comments?page=N&limit=50` page by page until an empty page, finds the comment whose body contains the marker, and PATCHes `/repos/$REPO/issues/comments/{id}` or POSTs a new comment. It matches on the marker rather than the author because Forgejo's API user object has no `type: "Bot"` field.

**Comment identity:** An HTML marker `<!-- pr-build-comment -->` is embedded in the comment body, so there is exactly one build comment per PR regardless of how many pushes are made.

**Download link:** The comment links to a deterministic S3 URL of the form `<DOWNLOAD_BASE>/pr/<N>/TempoStatusBarApp-<version>.dmg`. No API lookup is required because the prefix and filename are both known statically inside the workflow.

The step uses `continue-on-error: true` so a comment failure doesn't fail the build.

---

## `main-verification.yml` — Main Branch Verification

**Trigger:** Push to `main` (`paths-ignore`: `linux/**`, `flake.nix`, `flake.lock`), manual dispatch (`workflow_dispatch`)

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `main-build` | `[self-hosted, macos, tempo]` | Import signing cert → Release build + unit tests (real-keychain suite skipped, see below) + Archive + verify signature + DMG creation → clean up keychain |
| `security-check` | `[self-hosted, linux]` | Trivy filesystem scan (see [Trivy gating](#trivy-gating)) |
| `documentation-check` | `[self-hosted, linux]` | Verifies required docs exist (`README.md`, `CONTRIBUTING.md`) |

### Trivy gating

There is no code-scanning upload on Forgejo, so the GitHub SARIF upload is
gone. `pr-verification.yml`, `main-verification.yml` and `release-tag.yml`
each run the same pair inside the flake's `security` devShell:

1. `trivy fs --scanners vuln --severity HIGH,CRITICAL --format table .` —
   prints HIGH and CRITICAL findings to the job log, never fails.
2. `trivy fs --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 .`
   — fails the job on any CRITICAL finding that has a fix available.

If the gate goes red, fix the dependency rather than loosening the gate.

---

## `linux-ci.yml` — Linux App CI

**Trigger:** `pull_request` targeting `main` and pushes to `main`, restricted by `paths` to `linux/**`, `flake.nix`, `flake.lock`, `.forgejo/workflows/linux-ci.yml`, and `.github/actions/setup-nix/**`

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `build-and-test` | `[self-hosted, linux]` | `cargo fmt --check` → `cargo clippy --all-targets -- -D warnings` → `cargo test` → `cargo build --release` |

Every step runs through `nix $NIX_FLAGS develop ..# --command …` from the
`linux/` working directory (`..#` selects the root flake). The toolchain is
repo-owned: it comes from the `flake.nix` devShell, never from the runner. The
`.github/actions/setup-nix` composite action puts the runner's Nix on `PATH` and
fails loudly if there is none; it is copied verbatim from `St-John-Software/claws`,
the org reference implementation. `timeout-minutes: 45` covers the first run,
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
other. The step runs `curl` + `jq` inside `nix develop ..#ci`. There is no
DMG-equivalent download link — Linux binaries are published per release rather
than per PR, so the comment reports build status and points at
`linux-release.yml`'s version gate. Fork PRs skip this step, and
`continue-on-error: true` keeps a comment failure from failing the build.

---

## `linux-release.yml` — Linux Release

**Trigger:** Push to `main` restricted by `paths` to `linux/**`, `flake.nix`, `flake.lock` and the workflow itself; manual dispatch (`workflow_dispatch`)

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release` | `[self-hosted, linux]` | Version gate → `nix build .#static` → static-linkage and version assertions → tarball + `.sha256` → Forgejo release `linux-vX.Y.Z` with both files attached as assets |

Every run step executes inside the flake's `ci` devShell via a job-level
`defaults.run.shell`, so `curl`/`jq` are available without wrapping each call.
`concurrency: linux-release` with `cancel-in-progress: false` — two rapid
merges must not cancel a run that has already created a tag.
`timeout-minutes: 90` covers the first `pkgsStatic` build, which compiles a
musl stdenv closure and `ring` from source; later runs hit the nix store.

**The gate is version-driven, not push-driven.** The first step resolves
`nix $NIX_FLAGS eval --raw .#static.version` — which reads `linux/Cargo.toml`,
the single source of truth — rejects anything that is not plain `X.Y.Z`, and
checks `GET $API_URL/repos/$REPO/tags/linux-vX.Y.Z` with
`curl -sS -o /dev/null -w '%{http_code}'`: `200` sets `release=false` with a
`::notice::`, `404` sets `release=true`, and any other status fails the job
loudly rather than being read as "tag absent". Every later step is
`if: steps.gate.outputs.release == 'true'`, so a `linux/**` merge without a
version bump is a green no-op.

A job that fails in about 0 s with no step run means the runner could not
start the job container (on 2026-10-07 this was a swept `forgejo-runner-nix`
image tag). It is not a workflow defect. Once the runners are healthy,
re-run with `workflow_dispatch` on `main`.

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
--mtime='@0'`). Publishing is three API calls: `POST /repos/$REPO/releases` with
`draft: true`, `tag_name`, `target_commitish: $GITHUB_SHA`, `name` equal to the
tag and the body from `release-notes.md` (`jq -Rs`), which creates no tag yet;
`POST /repos/$REPO/releases/{id}/assets?name=<file>` (`-F attachment=@<file>`)
for the tarball and the `.sha256`; then `PATCH /repos/$REPO/releases/{id}` with
`{"draft": false}`, which creates the tag and fires `release: published` only
once the assets exist. An `ERR` trap deletes the draft if any call fails, and
the step also deletes any stale draft for the same tag before creating one (a
cancelled run leaves a draft the tag-based gate cannot see). There is **no S3
upload**: unlike the macOS DMG, the Linux assets live on the Forgejo release,
which is what Claws' snapshot job copies to the public GitHub mirror.

The `linux-v*` tag namespace is deliberately separate from the macOS `v1.3.x`
line. On Forgejo, a release created through the API with the job token
**does** fire `release: published` (GitHub suppresses `GITHUB_TOKEN` events;
Forgejo does not). Because `release-tag.yml` has no tag filter, all three of
its jobs carry
`if: ${{ !startsWith(github.event.release.tag_name, 'linux-v') }}` — this guard
is load-bearing: without it every Linux release would start a macOS
sign+notarize build with `MARKETING_VERSION=linux-0.1.0`. On
`workflow_dispatch`, `github.event.release` is null, so the guard evaluates
true and behaviour is unchanged.

x86_64 only — both self-hosted runners are x86_64. `packages.static` is
defined for `aarch64-linux` in `flake.nix` but nothing builds it; aarch64
builds from source.

---

## `release-tag.yml` — Release Verification

**Trigger:** Forgejo `release` events of type `published` only, manual dispatch

`published` is the only type listened to because Forgejo fires workflow events
for releases created or edited through the API with the job token: listening
to `edited` would make the job's own download-link PATCH re-run the build.

**Jobs:**

| Job | Runner | Description |
|---|---|---|
| `release-build` | `[self-hosted, macos, tempo]` | Import signing cert → Release build + Archive (both with `MARKETING_VERSION=<tag>` override) + verify signature + DMG (named `TempoStatusBarApp-<version>.dmg`) → upload DMG to S3 + write download link into the release notes → clean up keychain |
| `security-check` | `[self-hosted, linux]` | Trivy scan (see [Trivy gating](#trivy-gating)) |
| `documentation-check` | `[self-hosted, linux]` | Docs presence check |

The version comes from `github.event.release.tag_name` with the leading `v`
stripped (falling back to `github.ref_name` on `workflow_dispatch`), not from
`GITHUB_REF`. The `release-build` job (`enable-openid-connect: true`) uploads
the DMG to `s3://<bucket>/releases/TempoStatusBarApp-<version>.dmg` (and copies
it to `releases/TempoStatusBarApp-latest.dmg`) using the OIDC role, then
appends a `**Download:** [<dmg>](<S3 URL>)` line to the Forgejo release body
with `curl -X PATCH $API_URL/repos/$REPO/releases/<id>` (the JSON body is built
with `/usr/bin/python3`), so the release page remains a discoverable download
point. That PATCH fires `release: edited`, which this workflow does not listen
to. All AWS/upload/edit steps are gated with `if: github.event_name == 'release'`
so manual `workflow_dispatch` runs (used for build testing) skip the upload and
do not fail due to the absence of an associated release.

### Release name / tag consistency check

The first step of `release-build` asserts that `github.event.release.tag_name` equals `github.event.release.name`. This catches the failure mode where a release is created in the UI with a title like `v1.3.0-RC1` but the underlying tag is left at `v1.3.0` — the release looks correct in the UI but the workflow builds the wrong version, and the stable `v1.3.0` tag gets pushed prematurely. The check fails the workflow before any build work runs and prints recovery instructions. It's gated on `if: github.event_name == 'release'` so `workflow_dispatch` runs are unaffected.

---

## `pr-cleanup.yml` — PR Cleanup

**Trigger:** `pull_request` with `types: [closed]` (fires on both merge and unmerged close)

Runs on `[self-hosted, linux]` with `enable-openid-connect: true`. Checks out the repo, runs `setup-nix`, and executes every step inside the flake's `ci` devShell (`defaults.run.shell`), which supplies `aws` (`awscli2`) — there is no installer step. It assumes the OIDC role, then runs `aws s3 rm s3://<bucket>/pr/<N>/ --recursive` (with `|| true` so a missing prefix is non-fatal). Skipped for fork PRs — they never uploaded.

This workflow exists so per-PR DMG builds do not accumulate in the bucket indefinitely. As a backstop for cleanup runs that never fire, the bucket has a lifecycle rule (created by `s3-bootstrap.yml`) that expires `pr/`-prefixed objects after 30 days.

---

## `s3-bootstrap.yml` — S3 Bootstrap

**Trigger:** `workflow_dispatch` only, with inputs `bucket` (default `tempo-statusbar-releases`), `region` (default `us-east-1`), and `role_name` (default `tempo-statusbar-github-actions` — the historical name, kept so the existing `AWS_ROLE_ARN` stays valid)

One-time — but idempotent, safe to re-run — provisioning of the AWS resources the release/PR workflows depend on. Runs on `[self-hosted, linux]` inside the flake's `ci` devShell (for `aws`), using **temporary static credentials** read from the `AWS_BOOTSTRAP_ACCESS_KEY_ID` / `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` Forgejo Actions secrets (it fails fast with a clear error if they are unset). It creates or updates:

1. The S3 bucket, with a public-access-block configuration that blocks ACLs but permits a bucket policy, and a bucket policy granting anonymous `s3:GetObject` on `releases/*` and `pr/*` only
2. A lifecycle rule expiring `pr/`-prefixed objects after 30 days (backstop for missed PR-close cleanups)
3. The Forgejo OIDC identity provider `arn:aws:iam::<account>:oidc-provider/www.bstjohn.net/forgejo-oidc` (`https://www.bstjohn.net/forgejo-oidc`, client ID `sts.amazonaws.com`, no thumbprint), skipped if it already exists — it is account-global and may be shared with other repos
4. An IAM role whose trust policy accepts the Forgejo issuer only — `StringEquals www.bstjohn.net/forgejo-oidc:aud = sts.amazonaws.com` and `StringLike www.bstjohn.net/forgejo-oidc:sub = repo:St-John-Software/TempoStatusBar:*` — carrying an inline policy allowing only `s3:PutObject`/`GetObject`/`DeleteObject` on the bucket's objects and `s3:ListBucket` on the bucket. Re-running against an existing role rewrites its trust policy, which is how the role moved off GitHub's issuer after the migration.

The final step prints the role ARN and the decommissioning checklist to the job log: store the ARN as the `AWS_ROLE_ARN` Forgejo Actions secret, revoke the temporary access key in IAM, and delete both bootstrap secrets. After that, no static AWS credentials exist anywhere — all recurring workflows authenticate via OIDC.

---

## Main Branch Failure Monitoring

There is no per-repo failure-notification workflow. Main-branch build failures are monitored centrally by Claws' `main-build-monitor` job ([St-John-Software/claws#2778](https://github.com/St-John-Software/claws/issues/2778)), which watches every `push`/`schedule`-triggered run of this repo's workflows on `main`. When a run fails it retries once if the failure looks transient; otherwise it files (or bumps) an issue titled `Build failure: <workflow name>` in this repo, one per workflow, and closes it with a comment once a later run of the same workflow goes green. PR-scoped runs are ignored, so fork PRs cannot file bogus issues. Nothing in this repo needs to change when the monitoring behaviour changes.

---

## Dependency Updates — Renovate

Dependabot is gone with the move to Forgejo. Dependency updates come from the
Forgejo-side Renovate run configured in `St-John-Software/fleet-infra`
(`apps/renovate/configmap.yaml`, whose `repositories` list includes this repo).
Its `github-actions` manager covers `.forgejo/workflows/` (including the
SHA-pinned full-URL `uses:` entries and their `# vX.Y.Z` comments) and its
`cargo` manager covers `linux/Cargo.toml`. Renovate PRs are ordinary same-repo
PRs and go through the normal checks with the normal secrets. Cargo-only PRs
touch `linux/**`, which `pr-verification.yml` `paths-ignore`s, so they run
`linux-ci.yml` on `[self-hosted, linux]` and never occupy the shared Macs.

---

## Code Signing

All three Mac workflows sign the Release `.app` bundle with a **Developer ID Application** certificate issued by Apple. The Release configuration sets `CODE_SIGN_IDENTITY = "Developer ID Application"`, `CODE_SIGN_STYLE = Manual`, and `ENABLE_HARDENED_RUNTIME = YES`; the team ID is supplied at build time via the `DEVELOPMENT_TEAM` secret. The Debug configuration is signed ad-hoc (`CODE_SIGN_IDENTITY = "-"`) so local developers don't need access to the production cert.

The release and PR workflows additionally **notarize and staple** the DMG so Gatekeeper accepts the download silently. Main builds sign but do **not** notarize — see [Key Design Decisions](#key-design-decisions).

**Secrets required (configured as Forgejo Actions secrets on the repo):**

| Secret | Content |
|---|---|
| `SIGNING_CERT_P12_BASE64` | Base64-encoded `.p12` file containing the Developer ID Application certificate and its private key |
| `SIGNING_CERT_PASSWORD` | Password for the `.p12` archive |
| `KEYCHAIN_PASSWORD` | Password for the temporary CI keychain created during the run |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID (10-character alphanumeric, e.g. `ABC1234567`) — overrides the empty `DEVELOPMENT_TEAM` in `project.pbxproj` |
| `AC_API_KEY_ID` | App Store Connect API Key ID |
| `AC_API_ISSUER_ID` | App Store Connect API Issuer ID |
| `AC_API_KEY_P8_BASE64` | Base64-encoded `.p8` private key downloaded when the API key was created |
| `AWS_ROLE_ARN` | ARN of the IAM role (created by `s3-bootstrap.yml`) that release/PR/cleanup jobs assume via Forgejo OIDC for S3 access |

**Signing process (all workflows):**

1. Decode `SIGNING_CERT_P12_BASE64` to a `.p12` file in `$RUNNER_TEMP`
2. Create a temporary keychain (`$RUNNER_TEMP/build.keychain-db`) and unlock it
3. Import the `.p12` into the temporary keychain
4. Download and import the Apple **Developer ID Certification Authority** intermediate (`DeveloperIDG2CA.cer`) into the temp keychain so `codesign` can build the full chain to the system-trusted Apple Root CA (without it, `codesign` fails with `errSecInternalComponent` on Xcode 26 — #133)
5. Prepend the temp keychain to the user's keychain search list so Xcode finds the identity automatically during build; the default keychain is left untouched so GUI-session processes are unaffected
6. Delete the `.p12` file from disk immediately after import
7. Build — Xcode signs the `.app` bundle using the Developer ID identity (with Hardened Runtime)
8. Verify: `codesign --verify --deep --strict`, assert `Authority=Developer ID Application:` is present, and assert the `runtime` flag appears in the signature flags
9. Post-run: remove any `build.keychain-db` entries from the search list, reset the default keychain only if it currently points at one, and delete the temporary keychain (`security delete-keychain`)

**SIGPIPE pitfall:** steps run under `bash -e -o pipefail`, so never pipe `codesign`/`security` output into `grep -q` — `grep -q` exits on first match, the writer gets SIGPIPE (exit 141) and the pipeline fails. Capture the output into a variable first (`SIG_INFO=$(codesign … 2>&1)`) and grep it with a here-string. The signature checks and keychain cleanup in all three Mac workflows follow this pattern.

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
  - **Caveat — signing jobs mutate the user keychain search list (not the default).** The signing step prepends the temp keychain to the user's keychain search list (`security list-keychains -d user -s "$KEYCHAIN_PATH" <existing entries>`) so `codesign`/Xcode can find the identity, while leaving the login keychain searchable and as the default. Earlier versions of this step instead replaced the search list wholesale and set the temp keychain as the user default, on the theory that the runner user has no GUI login session; that was only true of Brendans-MacBook-Pro-3 before its runner was reinstalled, and TSB jobs no longer run there. On the `tempo` Mac, which runs as a logged-in GUI user, changing the default keychain made GUI-session daemons such as `assistantd` pick up the temp "build" keychain as their default and prompt for its password once it was locked or later deleted (#234). The search-list change is reverted in the `always()` "Clean up signing keychain" step: it rebuilds the search list from the current list minus any `build.keychain-db` entries (falling back to `login.keychain-db` alone if nothing remains). The default is only touched as a self-heal, and only if it currently points at a build keychain (left over from a run that predates #234) — the step never assumes the import step changed it, since it no longer does. The temp keychain is then deleted. **Residual risk:** because the search list is only prepended to rather than replaced, the worst case if cleanup never runs (runner disconnects mid-job, process killed out-of-band, post-steps skipped) is an orphaned `build.keychain-db` entry left in the search list — a harmless extra search-list entry rather than a hijacked default. The next signing job or cleanup run removes it. Removal matches on the `build.keychain-db` basename alone, not the full path, so it is scoped to entries with that exact name rather than to this repo's jobs specifically — a temp keychain from another repo's job that happened to share the name would also be swept up.
- **DMG distribution via S3, not release assets (#177)** — DMGs for both PR and tagged-release builds are uploaded to S3 with `aws s3 cp`, NOT attached as release assets (storage/bandwidth limits were being hit on GitHub) and NOT via an upload-artifact action. The artifact action always wraps its payload in a `.zip`; macOS treats a DMG extracted from a downloaded zip as a different quarantine origin than a DMG downloaded raw over HTTPS, causing Keychain re-prompts even with identical signing identities — the S3 links serve the raw `.dmg`, keeping the quarantine origin consistent. PR uploads are cleaned up by `pr-cleanup.yml` when the PR closes (plus a 30-day lifecycle backstop).
- **OIDC over static AWS keys** — CI never holds long-lived AWS credentials. Jobs that touch S3 set `enable-openid-connect: true` (Forgejo mints no ID token without it), declare `id-token: write`, and assume the `AWS_ROLE_ARN` role via `aws-actions/configure-aws-credentials`; the role's trust policy only accepts tokens from the Forgejo issuer whose subject matches `repo:St-John-Software/TempoStatusBar:*`, and its permissions are limited to object read/write/delete in the release bucket. The `build-and-test` job's own `permissions` block replaces the workflow-level permissions, so `id-token: write` must be listed explicitly on the job; `contents` dropped back to `read` there when release publishing moved to S3.
- **`cancel-in-progress`** — `true` for PR and main workflows to prevent stale runs from blocking the queue; `false` for the release workflow so in-flight release builds are not interrupted.
- **DMG naming** — PR builds: `TempoStatusBarApp-pr-<N>-<sha>`; release builds: `TempoStatusBarApp-<version>`.
- **Artifact retention** — `test-results` (xcresult) artifacts: 3 days for both PRs and main. PR build DMGs live under `s3://<bucket>/pr/<N>/` and are deleted when the PR closes (`pr-cleanup.yml`; 30-day lifecycle backstop). Tagged-release DMGs live under `s3://<bucket>/releases/` and do not expire. Forgejo runners have caches off and no org storage quota, so there is no storage-cleanup workflow.
- **Fork PRs** — the signing, S3 upload and PR comment steps are skipped for forks (Forgejo fork PRs get no secrets and no OIDC token). Fork contributors who need to test their build should either rebase onto the upstream repo or build locally with Xcode.
- **SwiftLint** — installed at CI runtime via `brew` (after the Expose Homebrew step); configuration in `.swiftlint.yml`.
- **Trivy** — comes from the repo's `flake.nix` `security` devShell, not a runtime download, so its version is pinned by `flake.lock` alongside the rest of the toolchain; bumping Trivy means bumping nixpkgs in `flake.lock` (issue #237, replacing `aquasecurity/trivy-action@master`, whose runtime download from GitHub releases had failed Main Verification). No Actions caching is used — the self-hosted Linux runners already persist the Trivy DB on local disk between runs. See [Trivy gating](#trivy-gating) for what fails the job.
- **SHA pinning for remote actions** — every remote `uses:` is a full `https://…@<sha>  # vX.Y.Z` URL, not a tag or moving ref. Actions that mint cloud credentials or write to public distribution points carry higher supply-chain risk if compromised. Renovate bumps both the SHA and the trailing comment together, so the pin does not silently go stale. When updating a pin manually, resolve the tag to its commit SHA on the action's upstream repo before committing.
- **PR comment body construction** — the Mac comment is built in a `/usr/bin/python3` heredoc (`<<'PY'`, so the shell does not expand anything inside) and the Linux comment in a bash heredoc passed through `jq --arg`, so neither has to fight YAML block-scalar indentation. The download URL is constructed deterministically from the PR number and version string — no artifact lookup is needed.
- **`MARKETING_VERSION` CLI override** — Release and PR `xcodebuild` invocations pass `MARKETING_VERSION=<tag-version>` on the command line. This overrides the value hardcoded in `project.pbxproj` and ensures `appVersion`, `CFBundleShortVersionString`, and the About alert all report the release tag (e.g. `1.3.0`), not the stale project-file value (#105).
- **Developer ID signing with Hardened Runtime** — Release builds are signed with an Apple-issued Developer ID Application certificate and built with `ENABLE_HARDENED_RUNTIME = YES`. The cert is imported into a temporary keychain that is deleted at the end of each run — it is never written to the runner's permanent login keychain. Debug builds use ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) so local development doesn't depend on the production cert. The Apple **Developer ID Certification Authority** intermediate is also imported into the temp keychain so `codesign` can build the full chain; without it Xcode 26 runners fail with `errSecInternalComponent` (#133).
- **Notarization on PR and release builds** — both `pr-verification.yml` and `release-tag.yml` sign, notarize, and staple the DMG so users (including maintainers grabbing a PR build) don't hit Gatekeeper's first-launch warning. Main builds still skip notarization because their DMGs are not distributed. Notarization adds ~30s–2min per build. The PR notarization steps are gated on `github.event.pull_request.head.repo.full_name == github.repository` so that fork PRs (no secrets) skip them gracefully — those PRs still produce a signed DMG, just not a notarized one, and the publish + comment steps are already skipped for forks.
- **Signing verification in CI** — the "Verify code signature" step asserts both `Authority=Developer ID Application:` and the presence of the `runtime` flag in the signature. This catches accidental ad-hoc, self-signed, or unhardened builds before the DMG is packaged.
- **`spctl --assess` over `stapler validate` alone** — the release workflow runs both. `stapler validate` confirms a ticket exists locally; `spctl --assess --type open --context context:primary-signature` is what Gatekeeper actually runs when a user opens the file from a quarantined download. Asserting both protects against the case where stapling appeared to succeed but the ticket doesn't satisfy Gatekeeper.
- **Separate `linux-v*` tag namespace, release assets not S3** — the Linux tray app releases on its own `linux-vX.Y.Z` line so its cadence is not welded to the macOS `v1.3.x` line, and its tarball is attached to the Forgejo release rather than uploaded to S3. The DMG went to S3 because of its size and the macOS quarantine-origin problem (see above); neither applies to a ~10 MB tarball, and release assets are what the Claws snapshot job copies to the public GitHub mirror, which is the whole point of publishing it. The version is read from `linux/Cargo.toml` rather than from a tag the operator types, so the tag, the flake and the binary's `--version` cannot disagree — the workflow asserts all three. Because `release-tag.yml` triggers on `on: release` with no tag filter, and Forgejo fires that event for `linux-release.yml`'s API-created release, every one of its jobs needs a `!startsWith(github.event.release.tag_name, 'linux-v')` guard; adding a job there without one restarts the macOS sign+notarize path on Linux releases.
- **Self-hosted runners — macOS and Linux** — build/test/quality jobs run on `[self-hosted, macos, tempo]`. The Linux-only jobs (Trivy scans, docs checks, Linux CI/release, PR cleanup, S3 bootstrap) run on `[self-hosted, linux]` and declare an explicit OS label so they are never scheduled onto a macOS runner.
- **CI dependencies are repo-owned** — the self-hosted Linux runner baseline is `nix`/`git`/`docker` only; `curl`, `jq`, `aws` and every other CLI must come from `flake.nix`'s `ci` devShell. A bare tool missing from the runner dies with exit 127 (issue #218), and `|| true` guards turn that into a silent no-op rather than a visible failure. Prefer a job-level `defaults.run.shell` over per-call wrapping for jobs that only shell out to CLI tools; it leaves the scripts untouched. Never install with `sudo` — NixOS runners have none.
- **Real-keychain test skip on CI (`TEMPO_SKIP_KEYCHAIN_TESTS`)** — `CredentialManagerHasStoredCredentialsTests` (see [OVERVIEW.md](OVERVIEW.md#testing)) exercises the real Keychain via `CredentialManager.shared`, including deleting the item under the production service name in `setUp`/`tearDown`. On the shared self-hosted Macs, the runner user's login keychain holds genuine credentials, and headless keychain access blocks on an authorization dialog instead of failing fast (observed as multi-minute test hangs, and once an actual password prompt on the runner's screen). `pr-verification.yml` and `main-verification.yml` set `TEST_RUNNER_TEMPO_SKIP_KEYCHAIN_TESTS: "1"` on the "Run unit tests" step; `xcodebuild` only forwards environment variables prefixed `TEST_RUNNER_` into the test-host process (stripping the prefix), so the test suite sees plain `TEMPO_SKIP_KEYCHAIN_TESTS=1`. The gate lives in `setUpWithError` (via `XCTSkipIf`) rather than `setUp`, because it must run before any keychain access is attempted. Locally, without the env var, the suite runs unskipped against the real Keychain as before. The same flag also short-circuits `WorklogStateManager.init()` (a private `isKeychainAccessDisabled` check), skipping `setupTimer()`, `setupNetworkMonitor()`, and `checkCredentialsAndRefresh()` — otherwise `AppDelegate`'s `WorklogStateManager.shared` would read the real login keychain under the production service name from the ad-hoc-signed test host app launching in the runner's GUI session, which could prompt for access (#234).
