defmodule SpaceTraders.ScenarioCase do
  @moduledoc """
  Shared setup for the remaining runtime integration proofs.

  Recorded dispatch tests and the explicit runtime qualification use this case
  for PostgreSQL sandbox mode, a shared TestClock, a Phoenix connection, and
  controlled SpaceTraders API responses. Process-specific admission and
  observation helpers stay in the test that needs them rather than accumulating
  here as a general scenario framework.

  `@tag committed: true` opts a synchronous proof into real commits and
  independent pool connections. Such proofs must delete their own fixtures
  after stopping runtime processes; sandbox rollback does not clean them up.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SpaceTradersWeb.Endpoint
      @moduletag skip:
                   SpaceTraders.Repo.__adapter__() != Ecto.Adapters.Postgres &&
                     "runtime integration proofs require PostgreSQL"

      use SpaceTradersWeb, :verified_routes

      alias SpaceTraders.Repo

      import Phoenix.ConnTest
      import Plug.Conn
      import SpaceTraders.ScenarioCase
    end
  end

  setup tags do
    if tags[:committed] do
      if tags[:async], do: raise("committed scenarios must run synchronously")

      # Crash/dispatch proofs need real commits and separate connections. Shared
      # sandbox visibility would let an uncommitted attempt look durable.
      :ok = Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :auto)

      on_exit(fn ->
        SpaceTraders.EmergencyStopAdmission.clear()
        SpaceTraders.FleetGenerationAdmission.clear()
        Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :manual)
      end)
    else
      SpaceTraders.DataCase.setup_sandbox(tags)
    end

    now = Map.get(tags, :now, ~U[2026-09-14 12:00:00Z])
    start_supervised!({SpaceTraders.TestClock, now})

    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      SpaceTraders.Fleet.ShipServer.stop_all()
      SpaceTraders.Contracts.DeadlineServer.stop_all()

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
end
