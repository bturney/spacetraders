# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :spacetraders, :scopes,
  operator: [
    default: true,
    module: SpaceTraders.Agent.Scope,
    assign_key: :current_scope,
    access_path: [:operator, :id],
    schema_key: :operator_id,
    schema_type: :id,
    schema_table: :operators,
    test_data_fixture: SpaceTraders.AgentFixtures,
    test_setup_helper: :register_and_log_in_operator
  ]

config :spacetraders,
  namespace: SpaceTraders,
  ecto_repos: [SpaceTraders.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :spacetraders, SpaceTradersWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SpaceTradersWeb.ErrorHTML, json: SpaceTradersWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SpaceTraders.PubSub,
  live_view: [signing_salt: "AbSgPWYX"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :spacetraders, SpaceTraders.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  spacetraders: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  spacetraders: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :logger, :default_handler, formatter: {LoggerJSON.Formatters.Basic, metadata: :all}

config :spacetraders, SpaceTraders.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: []

# SpaceTraders API client: base URL for the v2 API. The rate limiter budget is
# the game's sustainable ceiling (3 req/s sustained, burst 10). Req 429 retry
# with Retry-After acts as a safety net on top of the client-side limiter.
config :spacetraders, SpaceTraders.API, base_url: "https://api.spacetraders.io/v2"

config :spacetraders, SpaceTraders.API.RateLimiter,
  rate: 3.0,
  burst: 10,
  enabled: true

# Game-secret encryption (ADR 0006). Dev/test use a committed development key;
# production overrides it from `ENCRYPTION_KEY` in config/runtime.exs.
config :spacetraders, SpaceTraders.Secret,
  key: :crypto.hash(:sha256, "spacetraders-dev-encryption-key")

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
