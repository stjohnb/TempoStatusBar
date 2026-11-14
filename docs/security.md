# Security

This is the repo's security policy under the St-John-Software security contract:
https://git.home.bstjohn.net/St-John-Software/claws/src/branch/main/docs/security-contract.md

### Scope

The repo ships a macOS menu bar app as a signed, notarized DMG (release and PR builds are stored in the S3 bucket `tempo-statusbar-releases`) and a Linux tray binary published as a Forgejo release asset (`linux-vX.Y.Z`), which Claws mirrors to the public GitHub repo `stjohnb/TempoStatusBar`. Both run on end-user desktops. Neither listens on a network port; both only make outbound HTTPS requests to the user's Jira/Tempo server, and the macOS app also calls `api.github.com` for update checks.

### Dependency and image vulnerabilities

`trivy fs` scans the repo (run from the flake `security` devShell) in `pr-verification.yml`, `main-verification.yml`, `release-tag.yml`, `linux-ci.yml` and `linux-release.yml` (the Linux release waits for its scan), so Rust-only changes are scanned too. The job logs HIGH and CRITICAL findings and fails on fixable CRITICAL findings. Renovate (configured in fleet-infra) opens dependency update PRs. The repo publishes no container image, so the image scan gate does not apply.

### Accepted findings

None. No container image is published and no finding has been accepted. A new accepted finding goes under `.vex/` as an OpenVEX `not_affected` statement with a justification and an impact statement.

### Secrets

- CI secrets are Forgejo Actions secrets read through `${{ secrets.* }}`: `SIGNING_CERT_P12_BASE64`, `SIGNING_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `DEVELOPMENT_TEAM`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, and `AC_API_KEY_P8_BASE64`.
- S3 access uses Forgejo OIDC into `ci-tempo-statusbar-pr` (PR builds, `pr/*`) and `ci-tempo-statusbar-release` (releases, `releases/*`, `main` only), owned by aws-account `tier1/tempo-statusbar.tf`. No AWS keys exist for this repo.
- The macOS user's Jira API token is stored in the Keychain under service `com.stjohnsoftware.TempoStatusBarApp`, account `credentials`, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- The Linux app reads its token from Secret Service, `token_command` or `TEMPO_API_TOKEN`.
- Rule for new code: never log or commit a credential value.

### Supply chain

`linux/Cargo.lock` and `flake.lock` are committed. All remote actions are pinned to commit SHAs. SwiftLint and the AWS CLI on the shared Macs come from the flake's darwin-only `macos-tools` package (run with `nix shell`) (the `nixpkgs-darwin` input on `nixpkgs-26.05-darwin`, kept because the Mac runner is Intel), pinned by `flake.lock`, not from `brew install`. Renovate (fleet-infra) updates GitHub Actions pins and cargo dependencies, and its nix manager (enabled in the repo's `renovate.json`) maintains `flake.lock`. The macOS app has no third-party packages. Rule for new changes: pin new dependencies through a lockfile and new CI actions to a full commit SHA.

### Exposure and authentication

Nothing is reachable from the network: no listener, no ingress and no network policy apply to this repo. Outbound Jira/Tempo calls authenticate with a Bearer token. The Linux app refuses non-`https://` Jira URLs in the settings form, in `set-credentials` and in the HTTP client itself (which also rejects redirects to http), so the token is never sent in cleartext; macOS App Transport Security enforces the same. Downloads are protected by Developer ID signing and notarization on macOS and by a `.sha256` file for the Linux tarball.

### Known gaps

- Accepted: no container image is published, so the Trivy fs gate fails only on fixable CRITICAL findings, not HIGH; the contract's High/Critical block applies to image pushes.
- Accepted: the only runner for this repo's Mac jobs (`[host, macos, tempo]`, one Intel MacBook Pro) is x86_64-darwin, and nixpkgs 26.05 is the last release that supports it, so SwiftLint and the AWS CLI there (`macos-tools`, from the `nixpkgs-darwin` input on `nixpkgs-26.05-darwin`) get no security fixes after the end of 2026. Both tools only read this repo's checkout and upload to the repo's own S3 bucket with short-lived OIDC credentials, on a LAN-only single-tenant forge. Move `nixpkgs-darwin` to a current branch when the runner is replaced by an Apple-silicon Mac.
- Accepted: a same-repo PR's Forgejo job token has repo write, so a PR workflow could create a `v*` release or dispatch `release-tag.yml` on `main` and get a release upload through `ci-tempo-statusbar-release`. This is a property of Forgejo job tokens, it existed before the move to per-role exact-subject trust and that move does not widen it; the dispatched build's "Verify release for tag" step (published, non-draft `v*` release whose name equals its tag, run on `main`) limits it to real releases.
