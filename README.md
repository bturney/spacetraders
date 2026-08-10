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
mix phx.server   # http://localhost:4000, GET /health returns {"status":"ok"}
```

### Parallel worktrees

Create every concurrent ticket or ad-hoc Task Workspace through the repository
workflow. The stable ID can be an issue number or a descriptive slug:

```sh
scripts/task-start 28
scripts/task-start diagnose-navigation-timeout
```

`task-start` creates `feature/<task-id>` from `main`, creates a sibling linked
worktree, and runs the task-scoped setup contract. Use `--base <ref>` for a
different starting point. It refuses existing task branches or worktrees unless
`--resume` is explicit. To hand the configured workspace to any runner, append
the command after `--`; the command runs there with `.worktree-env` loaded:

```sh
scripts/task-start diagnose-navigation-timeout -- your-runner --task diagnose-navigation-timeout
```

Stop a completed task only after committing or removing its changes. This
releases its port and removes its worktree but leaves its branch for review:

```sh
scripts/task-stop diagnose-navigation-timeout
```

The setup command serializes immutable warm-cache population and gives each task
a unique port in `41000-50999`. Cache entries are never mutated; prune them
explicitly when needed:

```sh
scripts/worktree-cache-prune                         # 30 days, 10 GiB
scripts/worktree-cache-prune --max-age-days 7 --max-size-gib 2
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
image tag. After the publish workflow succeeds, redeploy the host with the
merged commit's immutable tag:

```sh
git fetch origin main
SHA=$(git rev-parse origin/main)
IMAGE="ghcr.io/bturney/spacetraders:sha-$SHA"
tailscale ssh project-host "cd /srv/projects/spacetraders && test \"\$(SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml config --images | sort -u)\" = \"$IMAGE\" && SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml pull && SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml up -d && SPACETRADERS_IMAGE=$IMAGE docker compose -f compose.yaml -f compose.production.yaml ps && curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:4000/health"
```

The one-shot `migrate` service completes before `web` starts. A successful
health check returns `{"status":"ok"}`. The production overlay accepts
`SPACETRADERS_IMAGE` so deploys can pin an immutable tag or digest. For a
rollback, first pull and validate the reference with `SPACETRADERS_IMAGE` as a
command-level override, then persist it in the host `.env` only after that
validation succeeds.
