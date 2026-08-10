# Concurrent worktrees use immutable warm caches and allocated ports

**Status:** proposed

Parallel ticket work uses one task-ID-based setup flow for humans and runners. Clean committed worktrees restore a private build from an immutable cache keyed by revision, lockfile, and toolchain; cache population is serialized, while dirty worktrees compile privately. A lock-protected registry assigns each live task a deterministic port, failing collisions unless `PORT` is explicitly overridden, so mutable build state and HTTP listeners never cross worktree boundaries.

## Consequences

The cache is pruned explicitly, retaining entries for at most 30 days and 10 GiB by default. The parallel-worktree contract is proven by a separate required CI job rather than the normal local verification gate.

## Task workspace lifecycle

A repository-owned, runner-neutral task workspace workflow creates the Git
worktree before any agent or other runner starts. A task is identified by either
an issue number or an explicit ad-hoc slug; its worktree is configured with the
same stable identifier used for port allocation and artifacts. The workflow may
run an arbitrary command from the prepared worktree, but it does not depend on
Kimaki or any other runner.

Creation refuses an existing task workspace unless resumption is explicit. A
failed first-time setup rolls back only resources it created. Stopping a task
releases its port and removes only a clean worktree, while preserving the branch
for review or a pull request. Runner completion alone does not stop the task,
so the workspace can be inspected or resumed deliberately.
