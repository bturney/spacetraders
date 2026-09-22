# AGENTS.md

## Agent skills

- Issue work (create, triage, label, close): read `docs/agents/issue-tracker.md`
  — it also holds the triage label vocabulary.
- Domain work (explore an area, name a concept): read `docs/agents/domain.md`;
  it points at `CONTEXT.md` and the ADRs.
- Unattended CI or runner work: read `docs/agents/readiness.md`.
- Running or debugging the test suite: read `docs/agents/testing.md`.

Merge and Issue closure require an explicit Operator request.

## Working in this repo

- Setup, run, and test commands: `README.md`'s Development section is the source
  of truth. `scripts/verify` is the pre-push gate.
- The pinned toolchain is not on PATH. In every fresh shell, source it first:
  `source scripts/_toolchain.sh`
- Before starting new implementation, run `git fetch origin main` and
  `git merge-base --is-ancestor origin/main HEAD`; branch names do not prove
  freshness. Preserve local changes rather than switching or resetting a dirty
  checkout. If the current branch is already merged into `origin/main`, branch
  fresh from `origin/main` instead of committing to it. Policy is under review
  in #267.
- Changing the API client: `priv/spec/SpaceTraders.json` is ground truth; read
  `test/spacetraders/api/spec_conformance_test.exs`, and regenerate and commit
  the generated code (`mix space_traders.gen.models`,
  `mix space_traders.gen.operations`).
- Changing a LiveView form: use the `@form_drafts` pattern; recurring patches
  must not overwrite a user's draft.
- Production operations (deploy, migration, backup, restore, Compose on
  `project-host`): read `docs/operations/project-host.md` first.

<!-- phoenix-gen-auth-start -->
## Authentication

Auth internals — scope, live_sessions, and pipelines — are covered in
`docs/agents/auth.md`. Sources of truth: `lib/spacetraders_web/router.ex`;
plugs and `on_mount`s in `lib/spacetraders_web/operator_auth.ex`.
<!-- phoenix-gen-auth-end -->