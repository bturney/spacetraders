# SpaceTraders Elixir API client — decision

Resolves wayfinder grilling ticket #6 "Lock the API client approach".

**Decision:** hand-rolled **Req** client + structs codegen'd from the official spec's `models/*.json` by an in-repo script (`scripts/generate_types.exs`). Phase-1 operations only, additive. Rate limit: token bucket **3 req/s sustained, burst 10**, with Req's built-in 429 / `Retry-After` backoff as the safety net. Thin `Spacetraders` module, no port ceremony (idiomatic Elixir — contexts call it directly).

## Why not off-the-shelf

- **No idiomatic Elixir SDK exists.** `space_mongers` (Hex) targets the retired v1 API, last published Mar 2021. `spacetraders_sdk` and `spacetraders_api` (Hex) are **Gleam**, not Elixir.
- **openapi-generator `-g elixir`**: emits a **Tesla**-based client (stack locked **Req** in #13; no Req support, no types-only mode), is alpha-status per its own help text, has a known 2026 path-param interpolation bug (OpenAPITools/openapi-generator#23339), and a long "rough" reputation. Its only value to us would be the structs — the part we'd have to gut from its full client.
- **AutoStruct 0.3.0**: unproven, per-schema `use AutoStruct.JsonSchema` macros, only top-level objects cast to structs.
- **Our script**: ~40 lines, zero runtime deps, output committed and fully under our control (module prefix, nil defaults, typespec style), regenerates on spec updates. Reversible cheaply — the artifact is committed output, so switching tools later (if the spec grows `allOf`/`oneOf`) costs nothing.

This is not NIH: Req, Jason, and the rate limiter are all off-the-shelf. The only hand-rolled piece is a trivial property walk that emits structs.

## Spec shape fact

All 76 `models/*.json` are flat `type: object` schemas — **zero `allOf` / `oneOf` / `anyOf`** in the model files. Properties are primitives, `$ref`s, or arrays of those. Codegen is a pure property walk; the openapi-generator `allOf` blocker is moot but irrelevant, since its output conflicts with the stack anyway.

## Feasibility spike

Generation ran against the real spec: **76 modules emitted cleanly** — nested `$ref`s and arrays handled. Sample output committed alongside this doc (`Waypoint.ex`, `ShipEngine.ex`, `SystemWaypoint.ex`).

## Sources

- https://hex.pm/packages/space_mongers · https://github.com/ericgroom/space_mongers (dead, v1)
- https://hex.pm/packages/spacetraders_sdk · https://hex.pm/packages/spacetraders_api (Gleam)
- https://openapi-generator.tech/docs/generators/elixir/ · https://github.com/OpenAPITools/openapi-generator/issues/12731 · https://github.com/OpenAPITools/openapi-generator/issues/23339
- https://hex.pm/packages/auto_struct
- https://hexdocs.pm/req (retry/429/Retry-After; no built-in throttle — custom step)
- Spec: https://github.com/SpaceTradersAPI/api-docs (models at `models/*.json`)
- Reference Phoenix project: https://codeberg.org/cosmicrose/spacetraders_client
