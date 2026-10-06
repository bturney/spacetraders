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

Phoenix 1.8 app (Bandit + LiveView) with PostgreSQL via `postgrex`.
Erlang/OTP 27.3.4 + Elixir 1.18.4 (see `.tool-versions`).

Steps 1–3 are the sequence from a fresh checkout to a green **product gate**.
The rest are reference: reach for the one that matches your branch. Each step
states its completion criterion, because the gate's exit status is the only
verdict.

### 1. Bootstrap

```sh
scripts/bootstrap
source scripts/_toolchain.sh
```

`scripts/bootstrap` installs the pinned Erlang/Elixir toolchain (no sudo
required) and fetches dependencies. The pinned toolchain is not on `PATH`, so
every fresh shell needs `scripts/_toolchain.sh` sourced before any `mix`
command.

Done when `mix --version` reports the pinned toolchain.

### 2. Database

PostgreSQL is both the application store and the verification database. One
shared instance serves every checkout; start it once (it restarts itself):

```sh
docker compose -f compose.dev.yaml up -d
```

Each checkout gets its own database: the main checkout uses
`spacetraders_dev`/`spacetraders_test`; a worktree uses
`spacetraders_<env>_<dir>_<hash6>` (`config/checkout_db.exs`). `mix test`
creates and migrates it quietly before running. Set `DATABASE_URL` to select
another database.

Done when `mix test <file>` passes with no other setup.

### 3. Product gate

```sh
scripts/verify
```

The gate runs locally and in CI on every PR. It runs its checks in order and
stops at the first failure, so a red run names the check to fix. It reports its
verdict as the exit status — never recovered from, never inferred from output.
Its checks are `Mix.Tasks.Verify.required_checks/1` in
`lib/mix/tasks/verify.ex`; read that for the current list rather than trusting
one written down here.

Output is short: one line per check, the ExUnit summary, then
`verify: PASS 7/7 <s>`. On failure it shows the failing check's output, then
`verify: FAIL at <check>` and the rerun command. Locally `mix format` runs in
fix mode and the gate edits files (`verify: reformatted <n> files: commit
before push`); under `CI` it uses `--check-formatted`.

Release packaging and deployment verification sit outside this gate, under
their own CI job; `docs/agents/testing.md` has their commands.

Done when `scripts/verify` exits 0.

### Testing beyond the gate

The gate is the merge condition. Single-file runs, failures that look
environment-related, which seam owns which contract, and the standalone runtime
qualification diagnostic are documented in
[`docs/agents/testing.md`](docs/agents/testing.md) — read it before debugging a
failure or adding coverage.

Three runs sit outside the gate and are worth naming here:

```sh
# One file, against this checkout's database
mix test test/spacetraders/agent_test.exs

# Whole-runtime composition across a restart (diagnostic, owns its own setup)
mix test test/diagnostics/runtime_qualification.exs --seed 0 --trace

# Recorded Ship dispatch under interruption and authority loss
mix test test/spacetraders/recorded_ship_runtime_test.exs --seed 0 --trace
```

See [the qualification and rollout
boundary](docs/research/recorded-ship-qualification-507.md) for independently
observed evidence, compatibility and readiness scope.

### Game API client & codegen

The thin `SpaceTraders.API` Req client (structs in `SpaceTraders.API.Model.*`) is
generated from the official OpenAPI spec bundled at `priv/spec/` (v2.3.0). The
regenerated structs are committed, so API drift shows up as a diff. On spec
updates, regenerate and commit the output:

```sh
mix space_traders.gen.models               # rewrite lib/spacetraders/api/models/*.ex
mix space_traders.gen.operations           # rewrite the operation inventory
mix space_traders.gen.models --check       # fail if committed structs are stale
mix space_traders.gen.operations --check   # fail if the inventory is stale
```

The client is rate-limited (3 req/s, burst 10) and stubbed with `Req.Test` in
test env; see `test/spacetraders/api/`.

### Run the app

```sh
source scripts/_toolchain.sh
mix phx.server   # http://localhost:4000, GET /health returns {"status":"ok"}
```

First boot redirects to `/setup` — create the first operator (email + password,
optionally linking your my.spacetraders.io AccountToken to mint agents). Routes
live in `lib/spacetraders_web/router.ex`; the nav exposes sign-in, mint, and
settings.

### Isolated work

Routine work uses the current checkout. `scripts/_toolchain.sh` points
`MIX_DEPS_PATH` at a dependency directory shared across checkouts, so concurrent
work needs a private writable build: `scripts/task-start` creates a Task
Workspace from current `origin/main`, on branch `feature/<task-id>` with its own
build and port (see [ADR
0008](docs/adr/0008-concurrent-worktree-isolation.md)).

```sh
git fetch origin main
scripts/task-start 28 --base origin/main
```

Stop it once its changes are committed or removed:

```sh
scripts/task-stop 28
```

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
authoritative database. Read the
[project-host runbook](docs/operations/project-host.md) before changing or
running deployment, migration, backup, restore, or fresh-database recovery.