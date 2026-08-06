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

If `mix`/`erl` are already on your PATH, they are used as-is. The installed
toolchain lives in `$HOME/.local/opt/spacetraders-toolchain` (override with
`SPACETRADERS_TOOLCHAIN_DIR`).

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

### Teardown

Stops a running server rooted at this checkout and removes build artifacts,
deps, and local SQLite files:

```sh
scripts/teardown
```
