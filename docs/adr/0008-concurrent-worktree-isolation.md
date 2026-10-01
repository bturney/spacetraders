# Concurrent worktrees use immutable warm caches and allocated ports

**Status:** implemented; routine workflow policy is under review in #267.

Parallel ticket work uses one task-ID-based setup flow for humans and runners. Clean committed worktrees restore a private build from an immutable cache keyed by revision, lockfile, and toolchain; cache population is serialized, while dirty worktrees compile privately. A lock-protected registry assigns each live task a deterministic port, failing collisions unless `PORT` is explicitly overridden. The same setup names a test database after the task, and teardown drops it, so mutable build state, HTTP listeners, and test databases never cross worktree boundaries.

The database is a per-task name rather than a per-run partition on purpose. The gate drops and recreates its database at the start of every run and never drops it at the end, so a partition that varies per invocation accumulates one database per run forever, while a task-scoped name is bounded by the number of live tasks and is released with them.

## Consequences

The cache is pruned explicitly, retaining entries for at most 30 days and 10 GiB by default. The worktree and Task Workspace integration scripts remain available for manual diagnosis, but are not a required CI gate; their maintenance cost and overlap with the canonical lifecycle outweighed the signal from running them on every change.

A bare gate invocation in an ordinary checkout keeps the single database name it has always used. Only a task with an allocated worktree environment gets its own database, so the gate command has one behaviour and the isolation is explicit rather than inferred from the environment.

## Task workspace lifecycle

The repository creates a Task Workspace before any runner starts. A task uses an
issue number or ad-hoc slug as its stable identifier for its worktree, port, and
artifacts. The runner starts in that prepared workspace; no runner-specific
integration is required.

Creation requires explicit resumption of an existing Task Workspace and rolls
back only resources it creates. Stopping releases the port and removes a clean
worktree while preserving its branch. Runner completion leaves the workspace
available for inspection or resumption.
