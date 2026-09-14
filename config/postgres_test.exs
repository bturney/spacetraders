import Config

import_config "test.exs"

# This environment exercises the same test suite against PostgreSQL. It is
# intentionally separate from :test so SQLite remains the production default.
config :spacetraders, :repo_adapter, Ecto.Adapters.Postgres

config :spacetraders, SpaceTraders.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost/spacetraders_test"),
  pool_size: 10,
  pool: Ecto.Adapters.SQL.Sandbox
