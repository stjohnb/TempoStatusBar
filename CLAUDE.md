@AGENTS.md

## Automation host policy

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
