import Config

Code.require_file("checkout_db.exs", __DIR__)

# Only in tests, remove the complexity from the password hashing algorithm
config :pbkdf2_elixir, :rounds, 1

config :spacetraders, :fleet_reconciler_enabled, false

# Evidence scheduling tests start their own scheduler to prove wakeup recovery
# from persisted demands with a controlled clock.
config :spacetraders, :demand_scheduler_enabled, false

# Configure your database
#
config :spacetraders, SpaceTraders.Repo,
  url: SpaceTraders.CheckoutDb.url(:test),
  pool_size: 10,
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

# Print only errors during test: warning-level retry/polling logs from Req and
# ShipServer recovery paths are expected stubbed-failure noise in this suite.
config :logger, level: :error

# Game API client: stub the HTTP transport with Req.Test in test env, and
# disable the token-bucket rate limiter so API tests are not throttled.
# Transient GET 5xx/transport retries skip Req's 1s/2s/4s backoff; 429 retries
# are unaffected.
config :spacetraders, SpaceTraders.API,
  plug: {Req.Test, SpaceTraders.API},
  transient_retry_delay_ms: 0

config :spacetraders, SpaceTraders.API.RateLimiter, enabled: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
