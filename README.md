# spacetraders

SpaceTraders bot + dashboard — a programmable API game (https://spacetraders.io).

## Program roadmap

Phases 1–5 of the play effort, with status and per-phase maps, live on the
always-open GitHub issue:

**https://github.com/bturney/spacetraders/issues/8** (SpaceTraders — Program Roadmap)

Phase 1 (Boot) is currently charting: [SpaceTraders Play Plan — Map](https://github.com/bturney/spacetraders/issues/1).

## Architecture

[ADR 0010](docs/adr/0010-autonomous-runtime.md) is the accepted governing
decision for the target autonomous Fleet Strategy runtime. It identifies which
earlier decisions remain legacy implementation guidance and reaffirms
[ADR 0007](docs/adr/0007-game-truth-and-quality-of-life-guardrails.md) as the
gameplay authority boundary.

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

The source-controlled autonomous-runtime design is organized under
[docs/autonomy](docs/autonomy/README.md), with #502 retained as its tracking and
proof-history index.
