# AGENTS.md

## Verification

- Done: `scripts/verify` before push. On exit 2, follow the preflight's fix line.
- Inner loop: targeted `mix test` (file, `--failed`, `--stale`, `--max-failures 1`); full gate at the end.
- After push, `gh pr merge --auto --merge`; branch protection decides.

## Rules

- Before implementation: `git fetch origin main`, then `git merge-base --is-ancestor origin/main HEAD`; branch names do not prove freshness. Preserve local changes; if the branch is already merged into `origin/main`, branch fresh from `origin/main`.
- `mix` missing → `mise install` (Debian: set `erlang.precompiled_os=ubuntu-24.04`).
- Grep `GLOSSARY.md` before naming a domain concept; retired terms are marked there.
- API client: `priv/spec/SpaceTraders.json` is ground truth; read `test/spacetraders/api/spec_conformance_test.exs`, then regenerate and commit with `mix space_traders.gen.models` and `mix space_traders.gen.operations`.
- LiveView forms: use `@form_drafts`; recurring patches must not overwrite a user's draft.

## Pointers

- Issue and PR work (create, triage, label, open PR, close): read `docs/agents/issue-tracker.md`.
- Running or debugging tests: read `docs/agents/testing.md`.
- Diagnosing Strategy outcomes or following Grafana drill-downs: read `docs/agents/observability.md`.
- Changing authentication, scopes, live_sessions, or pipelines: read `docs/agents/auth.md`.
- Production operations (deploy, migration, backup, restore, Compose on `project-host`): read `docs/operations/project-host.md` first.
