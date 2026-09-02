# Concurrent worktrees use immutable warm caches and allocated ports

**Status:** implemented; routine workflow policy is under review in #267.

Parallel ticket work uses one task-ID-based setup flow for humans and runners. Clean committed worktrees restore a private build from an immutable cache keyed by revision, lockfile, and toolchain; cache population is serialized, while dirty worktrees compile privately. A lock-protected registry assigns each live task a deterministic port, failing collisions unless `PORT` is explicitly overridden, so mutable build state and HTTP listeners never cross worktree boundaries.

## Consequences

The cache is pruned explicitly, retaining entries for at most 30 days and 10 GiB by default. The parallel-worktree contract is proven by a separate required CI job rather than the normal local verification gate.

## Task workspace lifecycle

The repository creates a Task Workspace before any runner starts. A task uses an
issue number or ad-hoc slug as its stable identifier for its worktree, port, and
artifacts. The runner starts in that prepared workspace; no runner-specific
integration is required.

Creation requires explicit resumption of an existing Task Workspace and rolls
back only resources it creates. Stopping releases the port and removes a clean
worktree while preserving its branch. Runner completion leaves the workspace
available for inspection or resumption.
