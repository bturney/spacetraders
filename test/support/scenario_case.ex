defmodule SpaceTraders.ScenarioCase do
  @moduledoc """
  PostgreSQL scenario boundary for production Operator and autonomous runtime interfaces.

  Scenarios control game responses and time, restart reconstructable runtime
  processes, observe notifications and telemetry, and inspect durable state
  through `SpaceTraders.Repo`.
  """

  use ExUnit.CaseTemplate

  @telemetry_events [
    [:spacetraders, :api, :request],
    [:spacetraders, :fleet, :activity],
    [:spacetraders, :intent, :transition]
  ]

  using do
    quote do
      @endpoint SpaceTradersWeb.Endpoint
      @moduletag skip:
                   SpaceTraders.Repo.__adapter__() != Ecto.Adapters.Postgres &&
                     "autonomous runtime scenarios require PostgreSQL"

      use SpaceTradersWeb, :verified_routes

      alias SpaceTraders.Repo

      import Phoenix.ConnTest
      import Plug.Conn
      import SpaceTraders.ScenarioCase
    end
  end

  setup tags do
    SpaceTraders.DataCase.setup_sandbox(tags)

    now = Map.get(tags, :now, ~U[2026-09-14 12:00:00Z])
    start_supervised!({SpaceTraders.TestClock, now})

    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    handler_id = "scenario-signals-#{System.unique_integer([:positive])}"

    Enum.each(@telemetry_events, fn event ->
      :ok = :telemetry.attach(handler_id <> inspect(event), event, &__MODULE__.capture/4, self())
    end)

    on_exit(fn ->
      SpaceTraders.Fleet.ShipServer.stop_all()
      SpaceTraders.Contracts.DeadlineServer.stop_all()

      Enum.each(@telemetry_events, fn event ->
        :telemetry.detach(handler_id <> inspect(event))
      end)

      if previous_clock do
        Application.put_env(:spacetraders, :clock, previous_clock)
      else
        Application.delete_env(:spacetraders, :clock)
      end
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def stub_api(handler) when is_function(handler, 1) do
    Req.Test.stub(SpaceTraders.API, handler)
  end

  def advance_time(amount, unit \\ :second) do
    SpaceTraders.TestClock.advance(amount, unit)
  end

  def allow_runtime_api do
    test_pid = self()

    Req.Test.allow(SpaceTraders.API, test_pid, fn ->
      SpaceTraders.Fleet.ShipSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.flat_map(fn
        {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
        _ -> []
      end)
    end)
  end

  def restart_runtime_processes do
    allow_runtime_api()

    SpaceTraders.Fleet.ShipServer.stop_all()
    SpaceTraders.Contracts.DeadlineServer.stop_all()
    :ignore = SpaceTraders.Contracts.DeadlineServerBoot.start_link([])
    :ignore = SpaceTraders.Fleet.ShipServerBoot.start_link([])
    :ok
  end

  def subscribe_to_notifications(%SpaceTraders.Agent.Agent{id: agent_id}) do
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet:#{agent_id}")
  end

  def assert_eventually(fun, attempts \\ 100)
  def assert_eventually(_fun, 0), do: flunk("condition did not become true")

  def assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  def drain_external_signals(acc \\ []) do
    receive do
      {:scenario_telemetry, _, _, _} = signal -> drain_external_signals([signal | acc])
      {:ship_updated, _, _} = signal -> drain_external_signals([signal | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc false
  def capture(event, measurements, metadata, test_pid) do
    send(test_pid, {:scenario_telemetry, event, measurements, metadata})
  end
end
