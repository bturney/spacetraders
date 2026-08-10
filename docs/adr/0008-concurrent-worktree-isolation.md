# Concurrent worktrees use immutable warm caches and allocated ports

**Status:** proposed

Parallel ticket work uses one task-ID-based setup flow for humans and runners. Clean committed worktrees restore a private build from an immutable cache keyed by revision, lockfile, and toolchain; cache population is serialized, while dirty worktrees compile privately. A lock-protected registry assigns each live task a deterministic port, failing collisions unless `PORT` is explicitly overridden, so mutable build state and HTTP listeners never cross worktree boundaries.

## Consequences

The cache is pruned explicitly, retaining entries for at most 30 days and 10 GiB by default. The parallel-worktree contract is proven by a separate required CI job rather than the normal local verification gate.
