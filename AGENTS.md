# TempoStatusBar

TempoStatusBar is primarily a macOS menu bar app that polls Jira Tempo Server/Data Center and shows how many days have elapsed since the user's last worklog. This repo also contains a separate Linux tray implementation in `linux/`; the two apps share API and UX intent, but not source code.

## Where to read first

- Start with [docs/PRODUCT.md](docs/PRODUCT.md) for what the product must do and why.
- Then [docs/OVERVIEW.md](docs/OVERVIEW.md) for the doc map, architecture, key patterns, configuration, and links to subsystem docs.
- For Tempo API work, read [docs/api-design.md](docs/api-design.md). For workflow or release changes, read [docs/ci-cd.md](docs/ci-cd.md). For Linux-specific work, read [docs/linux.md](docs/linux.md). For logging or diagnostics changes, read [docs/observability.md](docs/observability.md).

## Key Conventions

- The canonical repo is on Forgejo (`git.home.bstjohn.net/St-John-Software/TempoStatusBar`); the GitHub copy is archived. CI workflows live only in `.forgejo/workflows/`; `.github/actions/setup-nix` is still used. CI never uses `gh`; Forgejo API calls use `curl`. The Linux tarball is a Forgejo release asset, mirrored with the latest release to the public GitHub repo `stjohnb/TempoStatusBar` by Claws.
- All source files for the macOS app live flat at the repo root; `linux/` is a separate Rust crate and must not be treated as shared code.
- `WorklogStateManager.shared` is the macOS single source of truth, stays on the main actor, and drives UI through `@Published` state.
- Credentials are sensitive. Never log or print `apiToken`, `githubToken`, Linux `token_command` stdout, or any other credential value.
- `docs/claws-automation.md` is maintained automatically; do not edit or move it.
- All changes land via pull request; nothing is pushed directly to the default branch. See [docs/claws-automation.md](docs/claws-automation.md) for the full convention.

## Observability

- This repo emits no runtime telemetry. Logging is local only: `os.Logger` on macOS, stderr on Linux.
- Never log credentials.
- Before adding a timer, poll loop or external call, read [docs/observability.md](docs/observability.md) and follow its "What every change adds" rules.

## Automation Host Policy

Claws agents work in their own Kubernetes agent pod (Linux, 6 GiB memory limit), which has
no Xcode and no macOS toolchain. When working on this repo as an agent:

- **Do not start dev servers or other long-running processes** (`npm run dev`, `npm start`,
  `docker compose up`, watchers, tunnels). Verify with fast one-shot checks — lint, unit
  tests — and let CI run anything that needs a live app, a Mac or an end-to-end browser.
- **Do not install system packages or browser binaries** in the pod: no `sudo`, no
  `apt-get install`, no `npx playwright install`, no `brew install`. If a check needs a tool,
  add it to `flake.nix` in the same PR.
- **Never kill a process or free a port you do not own.** `lsof -ti:PORT | xargs kill` and
  `pkill -f node` kill the Claws helper processes that record your run.

### What an agent can run

- Workflow changes (`.forgejo/`): `nix develop .#lint --command actionlint` from the repo
  root (lints every workflow against `.forgejo/actionlint.yaml`).
- Rust changes (`linux/`), from `linux/`: `nix develop ..# --command cargo fmt --check`,
  `nix develop ..# --command cargo clippy --all-targets -- -D warnings` and
  `nix develop ..# --command cargo test`.

### Left to CI

- `./run_tests.sh`, `xcodebuild`, SwiftLint and code signing need Xcode on macOS and cannot
  run in the pod. The `Build and Test` and `Code Quality` jobs of
  `.forgejo/workflows/pr-verification.yml` run them on `[host, macos, tempo]`; say in the PR
  that CI is the gate for Swift changes rather than claiming the tests ran.

## Security

The security policy is in [docs/security.md](docs/security.md). Never commit or log credentials.
