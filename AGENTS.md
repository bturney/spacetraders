# AGENTS.md

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles mapped to the labels `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## App

Phoenix 1.8 (Bandit + LiveView), SQLite via `ecto_sqlite3`. Erlang/OTP 27.3.4 + Elixir 1.18.4 (owned by `.tool-versions`).

- Bootstrap a clean checkout: `scripts/bootstrap` — installs the pinned toolchain without sudo, fetches deps.
- Canonical gate: `scripts/verify` (== `mix verify`) — format check, `compile --warnings-as-errors`, tests, real boot + `GET /health` → 200. Must pass before pushing; CI runs it on every PR.
- Teardown: `scripts/teardown` — stops a server rooted at this checkout, removes `_build`/`deps`/`*.db`.
- Serve the app: `mix phx.server` → http://localhost:4000.
- One test file: `mix test test/.../file_test.exs`.
