# Shared dev Postgres with checkout-derived names; the repo owns the checkout contract, not orchestration

**Status:** accepted. Supersedes [ADR-0008](0008-concurrent-worktree-isolation.md).

One long-lived Postgres (`compose.dev.yaml`) serves every checkout. Each
checkout derives its own database name from its path (`config/checkout_db.exs`),
so concurrent worktrees never share test data and no allocation step exists.
`mix test` creates and migrates that database when it is missing. The test suite
binds no port, and the dev server reads `PORT`.

A first `mix test` in a new worktree seeds `deps/` and `_build/<env>` from the
main checkout (`seed_from_main/1` in `mix.exs`) and lets Mix recompile only what
differs. There is no immutable warm cache.

The repo guarantees this zero-setup per-checkout contract. It does not create,
order, or tear down workspaces: harness-native worktrees bypass ADR-0008's Task
Workspace lifecycle, port registry, and warm-cache store, which are deleted.
Dispatch, ordering, and concurrency belong to the orchestrator.

## Cleanup

`scripts/prune` keeps the machine clear of finished work and runs whenever the
seed step populates a new worktree; it can also be run by hand. It removes
worktrees that are clean, idle, and merged into `origin/main`, prunes stale
worktree registrations, and drops checkout-derived databases whose worktree is
no longer listed. It only lists dirty, unmerged, locked, and recent worktrees
and leftover `*-postgres` containers, and never touches them. Because it runs
unattended in other agents' worktrees, it never removes a locked worktree, the
main checkout, or the current worktree, and it drops only databases that
`config/checkout_db.exs` does not derive for a live worktree. A prune failure
warns on one line and never fails `mix test`.

### Deviations from spec #607

- Database drops match only `spacetraders_(dev|test)_<name>_<hash6>`, narrower
  than the spec, so legacy `spacetraders_task_*` orphans are never dropped
  automatically; the Operator removes them by hand:
  `psql "$URL" -Atc "select format('drop database %I;', datname) from pg_database where datname like 'spacetraders\_task\_%'" | psql "$URL"`.
- The locked, strict-ancestor and 60-minute-idle guards exist because harness
  worktrees start at `origin/main`, so a brand-new worktree would otherwise look
  merged and be removed.
