# Hand-rolled Req API client with structs codegen'd from the OpenAPI spec

The SpaceTraders API client is hand-rolled Req with structs generated from the official OpenAPI spec's `models/*.json` by an in-repo script (`mix space_traders.gen.models`); generated output is committed and regenerated on spec updates. No off-the-shelf SDK: the official SDK is an unpublished dead scaffold, community SDKs are stale or Gleam, and openapi-generator's Elixir target is Tesla-based (the stack locked Req) and alpha. Designed additively; cheap to replace because the generated artifact is committed.
