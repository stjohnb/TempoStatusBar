# Security

This is the repo's security policy under the St-John-Software security contract:
https://git.home.bstjohn.net/St-John-Software/claws/src/branch/main/docs/security-contract.md

### Scope

The repo ships a macOS menu bar app as a signed, notarized DMG (release and PR builds are stored in the S3 bucket `tempo-statusbar-releases`) and a Linux tray binary published as a Forgejo release asset (`linux-vX.Y.Z`), which Claws mirrors to the public GitHub repo `stjohnb/TempoStatusBar`. Both run on end-user desktops. Neither listens on a network port; both only make outbound HTTPS requests to the user's Jira/Tempo server, and the macOS app also calls `api.github.com` for update checks.

### Dependency and image vulnerabilities

`trivy fs` scans the repo (run from the flake `security` devShell) in `pr-verification.yml`, `main-verification.yml` and `release-tag.yml`. The job logs HIGH and CRITICAL findings and fails on fixable CRITICAL findings. Renovate (configured in fleet-infra) opens dependency update PRs. The repo publishes no container image, so the image scan gate does not apply.

### Accepted findings

None. No container image is published and no finding has been accepted. A new accepted finding goes under `.vex/` as an OpenVEX `not_affected` statement with a justification and an impact statement.

### Secrets

- CI secrets are Forgejo Actions secrets read through `${{ secrets.* }}`: `SIGNING_CERT_P12_BASE64`, `SIGNING_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `DEVELOPMENT_TEAM`, `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64`, `AWS_ROLE_ARN`, and the one-off `AWS_BOOTSTRAP_ACCESS_KEY_ID` / `AWS_BOOTSTRAP_SECRET_ACCESS_KEY` used by `s3-bootstrap.yml`.
- S3 access uses Forgejo OIDC with `AWS_ROLE_ARN`; no long-lived AWS keys exist outside the bootstrap workflow.
- The macOS user's Jira API token is stored in the Keychain under service `com.stjohnsoftware.TempoStatusBarApp`, account `credentials`, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- The Linux app reads its token from Secret Service, `token_command` or `TEMPO_API_TOKEN`.
- Rule for new code: never log or commit a credential value.

### Supply chain

`linux/Cargo.lock` and `flake.lock` are committed. Remote actions are pinned to commit SHAs except the one listed under Known gaps. Renovate (fleet-infra) updates GitHub Actions pins and cargo dependencies. The macOS app has no third-party packages. Rule for new changes: pin new dependencies through a lockfile and new CI actions to a full commit SHA.

### Exposure and authentication

Nothing is reachable from the network: no listener, no ingress and no network policy apply to this repo. Outbound Jira/Tempo calls authenticate with a Bearer token. Downloads are protected by Developer ID signing and notarization on macOS and by a `.sha256` file for the Linux tarball.

### Known gaps

- `https://code.forgejo.org/forgejo/upload-artifact@v5` is pinned to a tag, not a commit SHA, in `pr-verification.yml` and `main-verification.yml`.
- `pr-verification.yml` and `release-tag.yml` install `awscli`, and `pr-verification.yml` installs `swiftlint`, with unpinned `brew install` on the shared Macs, outside any lockfile.
- Renovate does not refresh `flake.lock`; its last update came from the Dependabot era (#216). Only `linux/Cargo.lock` gets lock-file maintenance.
- Rust-only changes (`linux/**`, `flake.nix`, `flake.lock`) skip every Trivy scan: the macOS workflows `paths-ignore` them and `linux-ci.yml` / `linux-release.yml` run no Trivy.
- The Linux app accepts an `http://` Jira URL (`linux/src/uimodel.rs`), so the API token can be sent in cleartext. On macOS, App Transport Security blocks this.
- Accepted: no container image is published, so the Trivy fs gate fails only on fixable CRITICAL findings, not HIGH; the contract's High/Critical block applies to image pushes.
