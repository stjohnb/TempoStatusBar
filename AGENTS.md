# TempoStatusBar

TempoStatusBar is primarily a macOS menu bar app that polls Jira Tempo Server/Data Center and shows how many days have elapsed since the user's last worklog. This repo also contains a separate Linux tray implementation in `linux/`; the two apps share API and UX intent, but not source code.

## Where to read first

- Start with [docs/PRODUCT.md](docs/PRODUCT.md) for what the product must do and why.
- Then [docs/OVERVIEW.md](docs/OVERVIEW.md) for the doc map, architecture, key patterns, configuration, and links to subsystem docs.
- For Tempo API work, read [docs/api-design.md](docs/api-design.md). For workflow or release changes, read [docs/ci-cd.md](docs/ci-cd.md). For Linux-specific work, read [docs/linux.md](docs/linux.md).

## Key Conventions

- The canonical repo is on Forgejo (`git.home.bstjohn.net/St-John-Software/TempoStatusBar`); the GitHub copy is archived. CI workflows live in `.forgejo/workflows/` — `.github/workflows/` holds inert copies kept only for the migration, and `.github/actions/setup-nix` is still used. CI never uses `gh`; Forgejo API calls use `curl`. The Linux tarball is a Forgejo release asset, mirrored with the latest release to the public GitHub repo `stjohnb/TempoStatusBar` by Claws.
- All source files for the macOS app live flat at the repo root; `linux/` is a separate Rust crate and must not be treated as shared code.
- `WorklogStateManager.shared` is the macOS single source of truth, stays on the main actor, and drives UI through `@Published` state.
- Credentials are sensitive. Never log or print `apiToken`, `githubToken`, Linux `token_command` stdout, or any other credential value.
- `docs/claws-automation.md` is maintained automatically; do not edit or move it.
- All changes land via pull request; nothing is pushed directly to the default branch. See [docs/claws-automation.md](docs/claws-automation.md) for the full convention.

## Automation Host Policy

Claws agents work on a shared, resource-constrained automation host that also runs the
Claws service itself. When working on this repo as an agent:

- **Do not start dev servers or other long-running processes** (`npm run dev`, `npm start`,
  `docker compose up`, watchers, tunnels). Verify with fast one-shot checks — type-check,
  lint, unit tests — and let CI run anything that needs a live app or an end-to-end browser.
- **Do not install system packages or browser binaries** on the host: no `sudo`, no
  `apt-get install`, no `npx playwright install`, no `brew install`. If CI needs a tool,
  add it to `flake.nix` in the same PR.
- **Never kill a process or free a port you do not own.** `lsof -ti:PORT | xargs kill` and
  `pkill -f node` will take down the Claws service, whose dashboard listens on port 3000.
