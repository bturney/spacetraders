defmodule SpaceTraders.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SpaceTradersWeb.Telemetry,
        SpaceTraders.PromEx,
        SpaceTraders.Repo,
        {Ecto.Migrator,
         repos: Application.fetch_env!(:spacetraders, :ecto_repos), skip: skip_migrations?()},
        {DNSCluster, query: Application.get_env(:spacetraders, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SpaceTraders.PubSub},
        SpaceTraders.API.ShadowAdmission,
        SpaceTraders.EmergencyStopAdmission,
        SpaceTraders.FleetGenerationAdmission
      ] ++
        runtime_authority_children() ++
        [
          {Registry, keys: :unique, name: SpaceTraders.Contracts.Registry},
          {DynamicSupervisor, strategy: :one_for_one, name: SpaceTraders.Contracts.Supervisor},
          SpaceTraders.Contracts.DeadlineServerBoot,
          {Registry, keys: :unique, name: SpaceTraders.Fleet.ShipRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: SpaceTraders.Fleet.ShipSupervisor},
          SpaceTraders.Fleet.ShipServerBoot
        ] ++ rate_limiter_children() ++ [SpaceTradersWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SpaceTraders.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The API rate limiter is a child of the app in dev/prod but disabled in test
  # (its own tests start a dedicated instance under a custom name).
  defp rate_limiter_children do
    if Application.get_env(:spacetraders, SpaceTraders.API.RateLimiter, [])
       |> Keyword.get(:enabled, true) do
      [SpaceTraders.API.RateLimiter]
    else
      []
    end
  end

  defp runtime_authority_children do
    if SpaceTraders.RuntimeAuthority.enabled?() do
      [SpaceTraders.RuntimeAuthority, SpaceTraders.Outbox.Deliverer]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SpaceTradersWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # Releases run migrations through the dedicated migration service.
    System.get_env("RELEASE_NAME") == nil
  end
end
