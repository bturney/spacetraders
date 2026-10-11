# AGENTS.md

## Agent skills

- Issue and PR work (create, triage, label, open PR, close): read
  `docs/agents/issue-tracker.md` — it also holds the triage label vocabulary.
- Domain work (explore an area, name a concept): read `docs/agents/domain.md`;
  it points at `GLOSSARY.md` and the ADRs.
- Running or debugging the test suite: read `docs/agents/testing.md`.
- Diagnosing Strategy outcomes or following Grafana drill-downs: read
  `docs/agents/observability.md`.

## Supplemental design evidence for Fleet Strategy work

When the scoped work concerns Fleet Strategy economics, multi-Ship coordination,
adaptation, or behavioral qualification, consult
`docs/agents/strategic-reasoning-scenarios.md` for **non-normative** example
scenarios. When it concerns Mission Control explanations, Operator experience,
outcome observability, Grafana, or calibration, consult
`docs/agents/strategic-observability-ux-gaps.md` for **non-normative** evidence
and gaps.

These reports are not new implementation requirements. Issue #502 governs the
autonomous-runtime contracts and current bounded delivery frontier; issue #311
governs the accepted Operator information architecture. Use report findings only
where the assigned scope overlaps and current code/evidence confirms the gap.
Do not create work or enlarge a gate merely because a report proposes an example.

Merge requires an explicit Operator request.

## Working in this repo

- Setup, run, and the product gate: `README.md`'s Development section is the
  source of truth. `scripts/verify` is the pre-push gate; release and deployment
  verification is outside it, and `docs/agents/testing.md` holds those commands.
- Toolchain: mise pins it via `.tool-versions`; use `mix` straight from PATH.
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
