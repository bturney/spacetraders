# spacetraders

SpaceTraders bot + dashboard — a programmable API game (https://spacetraders.io).

## Product and roadmap

**[Autonomous Fleet: product, capability ledger and roadmap](docs/autonomy/README.md)** is the current source-controlled direction. Start there to choose an outcome, find its architectural owner, see what is actually proven, or design the next capability.

The [durable roadmap](docs/autonomy/roadmap.md) is intentionally separate from temporary implementation tickets. [#502](https://github.com/bturney/spacetraders/issues/502) preserves the superseded recovery specification and its evidence history; the older [program map #8](https://github.com/bturney/spacetraders/issues/8) is historical context rather than today's Fleet implementation queue.

## Architecture

[ADR 0010](docs/adr/0010-autonomous-runtime.md) governs autonomous runtime ownership; [ADR 0007](docs/adr/0007-game-truth-and-quality-of-life-guardrails.md) keeps the game authoritative. [ADR 0016](docs/adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md) defines surplus-first Ship investment; [ADR 0017](docs/adr/0017-nothing-needs-the-operator.md) defines the game-first Operator experience and service-level kill switch.

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
