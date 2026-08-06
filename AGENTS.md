# AGENTS.md

## Agent skills

### Issue tracker

Issues and PRDs live as GitHub issues, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles mapped to the labels `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — one `CONTEXT.md` plus `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## App

Phoenix 1.8 (Bandit + LiveView), SQLite via `ecto_sqlite3`. Toolchain versions owned by `.tool-versions`.

- `scripts/bootstrap` — from a clean checkout: installs the pinned OTP/Elixir toolchain without sudo, fetches deps.
- The gate: `scripts/verify` — format, warnings-as-errors compile, tests, real boot + `/health` 200. Run it before pushing; CI runs it on every PR.
- `scripts/teardown` — stops a server rooted here, removes `_build`/`deps`/`*.db`.
- Run/test commands live in README → Development.
