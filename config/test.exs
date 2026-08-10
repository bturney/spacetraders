import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :spacetraders, SpaceTraders.Repo,
  database: Path.expand("../spacetraders_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :spacetraders, SpaceTradersWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4002"))],
  secret_key_base: "NMpfB2nkBHGzqpHkrCqWPvaVxdRgtGleW6P22FZ+VJqfNKIgqeoQDcSf7bnYFqr3",
  server: false

# In test we don't send emails
config :spacetraders, SpaceTraders.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Game API client: stub the HTTP transport with Req.Test in test env, and
# disable the token-bucket rate limiter so API tests are not throttled.
config :spacetraders, SpaceTraders.API, plug: {Req.Test, SpaceTraders.API}

config :spacetraders, SpaceTraders.API.RateLimiter, enabled: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
