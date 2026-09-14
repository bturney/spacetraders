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

Phoenix 1.8 app (Bandit + LiveView) with SQLite via `ecto_sqlite3`. Erlang/OTP
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

`mix verify` runs, in order:

1. `format --check-formatted` — formatting gate
2. `compile --warnings-as-errors` — warnings gate
3. `test` — the ExUnit suite
4. `space_traders.gen.models --check` — fail if committed API structs are stale
5. `verify.boot` — starts the full app on a real HTTP server and asserts `GET /health` → 200

### PostgreSQL compatibility verification

SQLite remains the production database until the approved authority cutover.
Maintainers can run the identical verification gate against PostgreSQL without
changing the production adapter:

```sh
docker run --rm --name spacetraders-postgres -p 5432:5432 \
  -e POSTGRES_DB=spacetraders_test -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres \
  postgres:17
scripts/verify-postgres
```

Set `DATABASE_URL` to use another PostgreSQL instance. The `postgres_test` Mix
environment is test-only; adapter-specific historical migration SQL is kept
explicitly branched and covered by this gate.

### Game API client & codegen

The thin `SpaceTraders.API` Req client (structs in `SpaceTraders.API.Model.*`) is
generated from the official OpenAPI spec bundled at `priv/spec/` (v2.3.0). On
spec updates, regenerate and commit the output:

```sh
mix space_traders.gen.models        # rewrite lib/spacetraders/api/models/*.ex
mix space_traders.gen.models --check  # fail if committed structs are stale
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
and local SQLite files (deps are shared across checkouts and left in place):

```sh
scripts/teardown
```

### Project-host deployment

The production deployment runs on the Tailscale machine `project-host`, reached
with `tailscale ssh`. The deployment checkout is `/srv/projects/spacetraders`.
Its `.env` stays on the host and contains
`PHX_HOST`, `PHX_CHECK_ORIGINS`, `SECRET_KEY_BASE`, `ENCRYPTION_KEY`, and
`POSTGRES_PASSWORD`; never copy those values into the repository.
`POSTGRES_DB` and `POSTGRES_USER` default to `spacetraders` when omitted.
`PHX_CHECK_ORIGINS` is optional: when set, it is a comma-separated Phoenix
origin allowlist, for example
`//short-host:4000,//full-host.tailnet.ts.net:4000`. For access through both
Tailscale names, configure both origins, including their non-default port. The
named `spacetraders-data` volume holds the authoritative SQLite DB. PostgreSQL
uses the separate `spacetraders-postgres` volume and is prepared for the later
authority cutover; `web` does not connect to it yet.

Every push to `main` publishes both `latest` and an immutable `sha-<commit>`
image tag. A successful publish automatically queues a deployment on the
`project-host` self-hosted GitHub Actions runner. Deployments run in order and
use the immutable image tag and the Compose files from the same commit. The host
routine validates the resolved images, pulls them, starts services, checks
`GET /health`, and records the application tag
only after that check succeeds. A failed check rolls back to the previously
recorded healthy image. The host retains the preceding healthy image for
`scripts/deploy rollback`.

Bootstrap the runner once on `project-host` as root, then run the printed
one-command GitHub registration command as an authenticated operator:

```sh
sudo scripts/install-runner
```

For a manual deployment or rollback from a Tailscale-connected checkout, use
the same versioned routine and Compose files as the workflow. The wrapper sends
files from the named commit or tag, never uncommitted working-tree changes. The
host `.env` and state files stay on the host:

```sh
scripts/deploy deploy <sha|tag>
scripts/deploy rollback
```

PostgreSQL must pass `pg_isready` before the one-shot `migrate` service runs.
That service migrates SQLite and PostgreSQL, is safe to repeat, and must succeed
before `web` starts. A migration failure therefore prevents a deployment from
accepting work and triggers the existing rollback path. A successful application
health check returns `{"status":"ok"}`. The production overlay accepts
`SPACETRADERS_IMAGE` so deploys can pin an immutable tag or digest. `.env`
stays on the host and is never printed by the installer or deployment scripts.

### PostgreSQL operations

Run these commands from a Tailscale-connected checkout. Each command emits an
`operation_id` that correlates its start, completion, backup checksum, and
rehearsal evidence without logging credentials:

```sh
# Readiness and repeatable schema migration
scripts/deploy postgres-health
scripts/deploy deploy <sha|tag|digest> # includes the one-shot migration

# Backup to a root-readable host directory
scripts/deploy postgres-backup backups/postgres-$(date -u +%Y%m%dT%H%M%SZ)

# Restore into an isolated temporary database and compare every table row count
scripts/deploy postgres-restore-rehearsal backups/<backup-directory>
```

Each atomically published backup directory contains `database.dump`, its SHA-256,
a value manifest, and the originating operation ID.
The rehearsal verifies the checksum before restoring, compares a value-level
hash and row count for every public table, reports the originating backup
operation ID plus recovered table and row totals, and always drops its temporary
database. Copy the complete backup directory to storage outside the project host, apply
the site's retention policy there, and rehearse the newest retained backup after
schema changes and at least monthly. PostgreSQL is not production authority yet,
so replacing its live database from a backup remains outside this phase; use the
isolated rehearsal to prove recoverability without risking SQLite authority.
This single-Operator deployment does not make the Compose bundle and database
an atomic rollback unit. If migration or recovery cannot restore a usable
database, stop the services, create fresh SQLite and PostgreSQL volumes, rerun
the migration service, and reseed SQLite before the application accepts work:

```sh
export COMPOSE_PROJECT_NAME=spacetraders
export COMPOSE_FILE=compose.yaml:compose.production.yaml
docker compose down
docker volume rm spacetraders_spacetraders-data spacetraders_spacetraders-postgres
docker compose run --rm migrate
docker compose run --rm web \
  bin/spacetraders eval 'Code.eval_file("priv/repo/seeds.exs")'
docker compose up -d
```

Run these destructive commands only on `project-host`, from the deployment
checkout, after you confirm that no usable backup remains. `web` stays stopped
until reseeding completes.
