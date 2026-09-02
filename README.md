# spacetraders

SpaceTraders bot + dashboard — a programmable API game (https://spacetraders.io).

## Program roadmap

Phases 1–5 of the play effort, with status and per-phase maps, live on the always-open GitHub issue:

**https://github.com/bturney/spacetraders/issues/8** (SpaceTraders — Program Roadmap)

Phase 1 (Boot) is currently charting: [SpaceTraders Play Plan — Map](https://github.com/bturney/spacetraders/issues/1).

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
`PHX_HOST`, `PHX_CHECK_ORIGINS`, `SECRET_KEY_BASE`, and `ENCRYPTION_KEY`; never
copy those values into the repository. `PHX_CHECK_ORIGINS` is optional: when
set, it is a comma-separated Phoenix origin allowlist, for example
`//short-host:4000,//full-host.tailnet.ts.net:4000`. For access through both
Tailscale names, configure both origins, including their non-default port. The
named `spacetraders-data` volume holds the SQLite DB.

Every push to `main` publishes both `latest` and an immutable `sha-<commit>`
image tag. A successful publish automatically queues a deployment on the
`project-host` self-hosted GitHub Actions runner. Deployments run in order and
use the immutable image tag. The host routine validates the resolved Compose
image, pulls it, starts services, checks `GET /health`, and records the tag
only after that check succeeds. A failed check rolls back to the previously
recorded healthy image. The host retains the preceding healthy image for
`scripts/deploy rollback`.

Bootstrap the runner once on `project-host` as root, then run the printed
one-command GitHub registration command as an authenticated operator:

```sh
sudo scripts/install-runner
```

For a manual deployment or rollback from a Tailscale-connected machine, use
the same host routine as the workflow:

```sh
scripts/deploy deploy <sha|tag|digest>
scripts/deploy rollback
```

The one-shot `migrate` service completes before `web` starts. A successful
health check returns `{"status":"ok"}`. The production overlay accepts
`SPACETRADERS_IMAGE` so deploys can pin an immutable tag or digest. `.env`
stays on the host and is never printed by the installer or deployment scripts.
