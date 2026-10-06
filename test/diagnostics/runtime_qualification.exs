defmodule SpaceTraders.RuntimeQualification do
  @moduledoc """
  Explicit diagnostic qualification for whole-runtime composition.

  This retains one behavior that cheaper seams do not prove: a fresh authenticated
  Strategy activation composes production reconciliation, Evidence, Fleet Planning,
  Fleet Allocation, Ship Execution, runtime restart, and Mission Control into a
  profitable distant trade.

  Seam-level correctness belongs to the deterministic merge suite instead:
  Observation Demand restart in `evidence_scheduling_test.exs`, incomplete Market
  coverage planning in `fleet_planning_test.exs`, and first/lost-response Ship
  dispatch recovery in `ship_execution_durability_test.exs`.

  This file intentionally does not end in `_test.exs`; ordinary `mix test` and
  `scripts/verify` do not discover it. Run the timing-sensitive qualification only
  when whole-runtime composition is the question:

      mix test test/diagnostics/runtime_qualification.exs --seed 0 --trace
  """

  use ExUnit.Case, async: false

  @endpoint SpaceTradersWeb.Endpoint

  use SpaceTradersWeb, :verified_routes

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Plug.Conn

  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.ShipServerBoot
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo
  alias SpaceTraders.RuntimeBaselineGame, as: Game
  alias SpaceTraders.TestClock
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag committed: true
  @moduletag skip: Repo.__adapter__() != Ecto.Adapters.Postgres && "requires PostgreSQL"

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    start_supervised!({TestClock, ~U[2026-09-14 12:00:00Z]})

    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_all_ships()
      SpaceTraders.Contracts.DeadlineServer.stop_all()
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()
      Sandbox.mode(Repo, :manual)

      if previous_clock do
        Application.put_env(:spacetraders, :clock, previous_clock)
      else
        Application.delete_env(:spacetraders, :clock)
      end
    end)

    advance_time(
      DateTime.diff(DateTime.utc_now(), SpaceTraders.Clock.utc_now(), :microsecond),
      :microsecond
    )

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_all_ships()

      operator_ids =
        Repo.all(from o in Operator, where: like(o.email, "baseline-503-%"), select: o.id)

      agent_ids = Repo.all(from a in Agent, where: a.operator_id in ^operator_ids, select: a.id)

      topics =
        Enum.map(operator_ids, &"fleet_allocation:#{&1}") ++ Enum.map(agent_ids, &"fleet:#{&1}")

      attempt_ids =
        Repo.all(from a in Attempt, where: a.operator_id in ^operator_ids, select: a.id)

      Repo.delete_all(from o in Outcome, where: o.mutation_attempt_id in ^attempt_ids)
      Repo.delete_all(from a in Attempt, where: a.id in ^attempt_ids)

      Repo.delete_all(
        from d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id in ^agent_ids
      )

      Repo.delete_all(
        from o in SpaceTraders.Evidence.Observation, where: o.agent_id in ^agent_ids
      )

      Repo.delete_all(from n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics)
      Repo.delete_all(from o in Operator, where: o.id in ^operator_ids)
      Repo.delete_all(from e in SpaceTraders.Timeline.Event, where: e.owner_id == "BASELINE-1")
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp stub_api(handler), do: Req.Test.stub(SpaceTraders.API, handler)

  defp advance_time(amount, unit \\ :second), do: TestClock.advance(amount, unit)

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  test "fresh Strategy activation completes a profitable distant trade across runtime restart", %{
    conn: conn
  } do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    start_runtime()
    {conn, agent} = activate_fresh_generation(conn)

    assert_eventually(fn -> Game.snapshot(game).status == "IN_TRANSIT" end, 500)
    settle_runtime()

    # Cross-seam qualification only: interrupt the production runtime while the
    # trade is in flight, then let production boot reconstruct enough work for
    # the same Strategy activation to finish. Narrow tests own the individual
    # scheduling, dispatch, and recovery guarantees exercised underneath.
    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(Reconciler)
    assert :ok = SpaceTraders.Quiesced.stop_ship("BASELINE-1")
    advance_time(60)
    start_runtime()
    start_supervised!({ShipServerBoot, []})

    Enum.reduce_while(1..20, :ok, fn _, :ok ->
      settle_runtime()
      Process.sleep(20)
      settle_runtime()

      if Game.snapshot(game).credits > 175_000 do
        {:halt, :ok}
      else
        due_at = SpaceTraders.TestClock.next_due_at()
        assert %DateTime{} = due_at

        advance_time(
          max(DateTime.diff(due_at, SpaceTraders.Clock.utc_now(), :microsecond), 0),
          :microsecond
        )

        {:cont, :ok}
      end
    end)

    settle_runtime()
    state = Game.snapshot(game)
    counts = Enum.frequencies_by(state.requests, & &1.path)

    IO.inspect(
      %{
        credits: state.credits,
        fuel: state.fuel,
        requests: Enum.map(state.requests, &{&1.method, &1.path, &1.reply, &1.at}),
        as_of: SpaceTraders.Clock.utc_now()
      },
      label: "runtime qualification",
      limit: :infinity
    )

    {:ok, view, html} = live(conn, ~p"/mission-control")
    IO.puts("Operator-visible operating health: " <> render(element(view, "#operating-health")))
    assert html =~ agent.symbol
    assert Map.get(counts, "/v2/my/ships/BASELINE-1/purchase", 0) == 1
    assert Map.get(counts, "/v2/my/ships/BASELINE-1/sell", 0) == 1
    assert state.credits == 175_800
    assert state.units == 0
  end

  defp activate_fresh_generation(conn) do
    email = "baseline-503-#{System.unique_integer([:positive])}@example.com"

    conn =
      post(conn, ~p"/setup", %{
        "operator" => %{
          "email" => email,
          "password" => "a long baseline password",
          "password_confirmation" => "a long baseline password",
          "account_token" => "BASELINE_ACCOUNT_TOKEN"
        }
      })

    assert get_session(conn, :operator_token)
    {:ok, mint, _html} = live(conn, ~p"/agents/new")

    assert {:error, {:redirect, %{to: "/mission-control", status: 302}}} =
             mint
             |> form("#mint_form", %{"agent" => %{"symbol" => "BASELINE", "faction" => "COSMIC"}})
             |> render_submit()

    {:ok, strategy, _html} = live(conn, ~p"/strategy")
    strategy |> element("#select-preset-steady_growth") |> render_click()
    strategy |> element("#activate-strategy") |> render_click()
    assert render(strategy) =~ "Active revision 1"

    {conn, Repo.get_by!(Agent, symbol: "BASELINE")}
  end

  defp start_runtime do
    start_supervised!({Reconciler, []})
    start_supervised!({DemandScheduler, []})
  end

  # Synchronization only: observe that already-delivered work has been handled.
  # These system messages neither wake reconciliation nor select a continuation.
  defp settle_runtime do
    :sys.get_state(DemandScheduler)
    :sys.get_state(Reconciler)

    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor) do
      :sys.get_state(pid)
    end

    :sys.get_state(Reconciler)
  end

  defp allow_game_runtime do
    Req.Test.allow(SpaceTraders.API, self(), fn ->
      runtime_pids = [
        Process.whereis(Reconciler),
        Process.whereis(SpaceTraders.Fleet.ShipServerBoot)
      ]

      ships =
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

      Enum.filter(runtime_pids ++ ships, &is_pid/1)
    end)
  end
end
