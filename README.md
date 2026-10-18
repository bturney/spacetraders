# spacetraders

SpaceTraders bot + dashboard — a programmable API game (https://spacetraders.io).

## Program roadmap

Phases 1–5 of the play effort, with status and per-phase maps, live on the
always-open GitHub issue:

**https://github.com/bturney/spacetraders/issues/8** (SpaceTraders — Program Roadmap)

Phase 1 (Boot) is currently charting: [SpaceTraders Play Plan — Map](https://github.com/bturney/spacetraders/issues/1).

## Autonomous Fleet roadmap

[Agent-facing workstream index](docs/autonomy/README.md) connects the latest
engine, Operator Experience Recovery and actual-bot simulator work to their
owning issues and accepted ADRs. [#502](https://github.com/bturney/spacetraders/issues/502)
retains the original destination and qualification history.

## Architecture

[ADR 0010](docs/adr/0010-autonomous-runtime.md) governs the autonomous
runtime ownership model. Later decisions refine it: [ADR 0016](docs/adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md)
covers surplus-first Ship purchases; [ADR 0017](docs/adr/0017-nothing-needs-the-operator.md)
governs the new Operator journey and service-level kill switch.
[ADR 0007](docs/adr/0007-game-truth-and-quality-of-life-guardrails.md)
remains the gameplay authority boundary.

## Development

Phoenix + LiveView with PostgreSQL. Erlang/Elixir versions: `.tool-versions`.

Start shared dev Postgres before setup, which creates and migrates the database:

```sh
docker compose -f compose.dev.yaml up -d
mise install && mix setup
mix phx.server
```

Open http://localhost:4000; first boot redirects to `/setup` to establish the
sole Operator. Mint or import the initial Agent from Mission Control.

Check changes before pushing:

```sh
scripts/verify
```

See [testing](docs/agents/testing.md) for test lifecycle and opt-in diagnostics;
read the [production runbook](docs/operations/project-host.md) before deployment.
