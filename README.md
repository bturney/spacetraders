# spacetraders

SpaceTraders bot + dashboard — a programmable API game (https://spacetraders.io).

## Program roadmap

Phases 1–5 of the play effort, with status and per-phase maps, live on the always-open GitHub issue:

**https://github.com/bturney/spacetraders/issues/8** (SpaceTraders — Program Roadmap)

Phase 1 (Boot) is currently charting: [SpaceTraders Play Plan — Map](https://github.com/bturney/spacetraders/issues/1).

## Architecture

[ADR 0010](docs/adr/0010-autonomous-runtime.md) is the accepted governing
decision for the target autonomous Fleet Strategy runtime. It identifies which
earlier decisions remain legacy implementation guidance and reaffirms
[ADR 0007](docs/adr/0007-game-truth-and-quality-of-life-guardrails.md) as the
gameplay authority boundary.

## Development

Phoenix 1.8 app (Bandit + LiveView) with PostgreSQL via `postgrex`. Erlang/OTP
27.3.4 + Elixir 1.18.4 (see `.tool-versions`).

### Bootstrap

Installs the pinned Erlang/Elixir toolchain (no sudo required) and fetches deps:

```sh
scripts/bootstrap
```

Single-checkout development uses the installed dependency directory. Parallel
ticket work uses a private writable dependency/build copy restored from an
immutable cache instead.

Scripts use the pinned installation at `$HOME/.local/opt/spacetraders-toolchain`
(override with `SPACETRADERS_TOOLCHAIN_DIR`).

### Verify

The canonical gate, run locally and in CI on every PR:

```sh
scripts/verify   # == mix verify
```

`mix verify` runs the checks defined by the `verify` alias in `mix.exs`:
formatting, warnings-as-errors, the ExUnit suite, generated API struct and
operation inventory freshness, the transport-boundary check, and boot health
(the app started on a real HTTP server with `GET /health` → 200).

### PostgreSQL

PostgreSQL is the application store and the verification database. Start a local
instance, then run the same canonical gate used by CI:

```sh
docker run --rm --name spacetraders-postgres -p 5432:5432 \
  -e POSTGRES_DB=spacetraders_test -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  postgres:17
scripts/verify
```

Set `DATABASE_URL` to use another PostgreSQL instance.

Autonomous runtime scenarios use `SpaceTraders.ScenarioCase`. The case drives
authenticated Phoenix interfaces while providing controlled SpaceTraders API
responses, a shared fake clock, runtime process restarts, durable
`SpaceTraders.Repo` inspection, and captured telemetry and Fleet notifications.
Run the representative scenario directly with:

```sh
mix test test/integration/autonomous_runtime_scenario_test.exs
```

### Game API client & codegen

The thin `SpaceTraders.API` Req client (structs in `SpaceTraders.API.Model.*`) is
generated from the official OpenAPI spec bundled at `priv/spec/` (v2.3.0). On
spec updates, regenerate and commit the output:

```sh
mix space_traders.gen.models          # rewrite lib/spacetraders/api/models/*.ex
mix space_traders.gen.operations      # rewrite the operation inventory
mix space_traders.gen.models --check       # fail if committed structs are stale
mix space_traders.gen.operations --check   # fail if the inventory is stale
```

The regenerated structs are committed, so API drift shows up as a diff. The
client is rate-limited (3 req/s, burst 10) and stubbed with `Req.Test` in test
env; see `test/spacetraders/api/`.

### Run the app

```sh
source scripts/_toolchain.sh
mix phx.server   # http://localhost:4000, GET /health returns {"status":"ok"}
```

### Optional isolated work

Routine work uses the current checkout. For concurrent or explicitly isolated
work, create a Task Workspace from current `origin/main` rather than assuming a
local branch is current:

```sh
git fetch origin main
scripts/task-start 28 --base origin/main
```

The workspace uses `feature/<task-id>`, a private build, and an allocated port.
Stop it after its changes are committed or removed:

```sh
scripts/task-stop 28
```

First boot redirects to `/setup` — create the first operator (email + password,
optionally linking your my.spacetraders.io AccountToken to mint agents). Routes
live in `lib/spacetraders_web/router.ex`; the nav exposes sign-in, mint, and
settings.

### Game secrets (AccountToken / AgentToken)

AccountTokens and AgentTokens are stored in the database, encrypted with
AES-256-GCM (`SpaceTraders.Secret`); `.env` carries deployment secrets only
(ADR 0006). The key is a 32-byte binary from `ENCRYPTION_KEY` (base64) in
production; dev/test use a committed development key. Generate one with:

```sh
mix run -e 'IO.puts(Base.encode64(:crypto.strong_rand_bytes(32)))'
```

### Seed data

Idempotent; seeds the existing agent ORBITALIST (COSMIC, HQ `X1-UX81-A1`) and
its starter fleet (COMMAND_FRIGATE + PROBE). The agent's token comes from
`SPACETRADERS_AGENT_TOKEN` at seed time only; without it a placeholder is
stored:

```sh
mix run priv/repo/seeds.exs                 # placeholder token
SPACETRADERS_AGENT_TOKEN=<token> mix run priv/repo/seeds.exs   # real token
```

### Teardown

Stops a running server rooted at this checkout and removes build artifacts
(deps are shared across checkouts and left in place):

```sh
scripts/teardown
```

### Project-host deployment

Production runs on the Tailscale machine `project-host` with PostgreSQL as the
authoritative database.
Read the [project-host runbook](docs/operations/project-host.md) before changing
or running deployment, migration, backup, restore, or fresh-database recovery.
