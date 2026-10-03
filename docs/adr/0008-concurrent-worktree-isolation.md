# Concurrent worktrees use immutable warm caches and allocated ports

**Status:** implemented; routine workflow policy is under review in #267.

Parallel ticket work uses one task-ID-based setup flow for humans and runners. Clean committed worktrees restore a private build from an immutable cache keyed by revision, lockfile, and toolchain; cache population is serialized, while dirty worktrees compile privately. A lock-protected registry assigns each live task a deterministic port, failing collisions unless `PORT` is explicitly overridden. The same setup names a test database after the task, and teardown drops it, so mutable build state, HTTP listeners, and test databases never cross worktree boundaries.

The database is a per-task name rather than a per-run partition on purpose. Ordinary `mix test` reuses its prepared database and gets isolation from the SQL sandbox; provisioning owns create/migrate, and teardown releases task-scoped databases. Separate task databases keep concurrent worktrees isolated without allocating a new database on each test invocation.

## Consequences

The cache is pruned explicitly, retaining entries for at most 30 days and 10 GiB by default. The worktree and Task Workspace integration scripts were removed by #538 pending a separate first-principles decision about whether workspace orchestration should exist and what guarantees it should own. Their former maintenance cost and overlap with the canonical lifecycle outweighed the signal from running them on every change.

A bare gate invocation in an ordinary checkout prepares the stable default test database before running checks. Only a task with an allocated worktree environment gets its own database, so the gate command has one behaviour and the isolation is explicit rather than inferred from the environment.

## Task workspace lifecycle

The repository creates a Task Workspace before any runner starts. A task uses an
issue number or ad-hoc slug as its stable identifier for its worktree, port, and
artifacts. The runner starts in that prepared workspace; no runner-specific
integration is required.

Creation requires explicit resumption of an existing Task Workspace and rolls
back only resources it creates. Stopping releases the port and removes a clean
worktree while preserving its branch. Runner completion leaves the workspace
available for inspection or resumption.
