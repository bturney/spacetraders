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

    calibration_floor_id =
      Repo.one(from v in SpaceTraders.CreditCalibration.Version, select: max(v.id))

    on_exit(fn ->
      SpaceTraders.Quiesced.stop_all_ships()

      operator_ids =
        Repo.all(from o in Operator, where: like(o.email, "baseline-503-%"), select: o.id)

      agent_ids = Repo.all(from a in Agent, where: a.operator_id in ^operator_ids, select: a.id)

      topics =
        Enum.map(operator_ids, &"fleet_allocation:#{&1}") ++ Enum.map(agent_ids, &"fleet:#{&1}")

      attempt_ids =
        Repo.all(from a in Attempt, where: a.operator_id in ^operator_ids, select: a.id)

      # Gate 1 scenarios write global calibration and per-Agent credit evidence.
      Repo.delete_all(
        from r in SpaceTraders.CreditCalibration.Realization, where: r.agent_id in ^agent_ids
      )

      Repo.delete_all(
        from s in SpaceTraders.CreditCalibration.Shortfall, where: s.agent_id in ^agent_ids
      )

      Repo.delete_all(
        from v in SpaceTraders.CreditCalibration.Version, where: v.id > ^calibration_floor_id
      )

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

  # Gate 1 (#589): spending and capacity authority through the same seam.
  # Each scenario starts from authenticated Strategy activation (the Steady
  # Growth preset keeps a 50,000 credit floor) and lets the production runtime
  # plan, allocate, admit, and execute against the stateful game.
  describe "Gate 1 authority" do
    test "the credit floor bounds a Market purchase's worst-case exposure", %{conn: conn} do
      # 300 credits of headroom: at the 25% margin a 10-credit quote funds at
      # most 24 units, never the full 40-unit hold.
      game = start_game(credits: 50_300)
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, &sold?/1)

      state = Game.snapshot(game)
      purchases = requests(state, "/v2/my/ships/BASELINE-1/purchase")

      # Planning may size the purchase down or decline it; either way no
      # purchase whose worst case exceeds the headroom leaves transport.
      assert state.low_credits >= 50_000
      assert Enum.all?(purchases, &(&1.body["units"] * 10 * 125 <= 300 * 100))
    end

    # #589 finding: owned Agent/Fleet reads persisted Observation Demands that
    # the scheduler announced as due at once, waking reconciliation into the
    # same reads again; overdue unacquirable Market work re-announced on every
    # demand change. Together they spun reads for as long as the wait lasted.
    test "a Neutral Wait holds without spinning Agent and Fleet reads", %{conn: conn} do
      game = start_game(credits: 50_300)
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, fn _state -> false end, 8)
      Process.sleep(1_000)

      state = Game.snapshot(game)
      before = length(state.requests)
      Process.sleep(1_000)
      during_wait = length(Game.snapshot(game).requests) - before

      assert during_wait == 0,
             "#{during_wait} game requests in one second of frozen-clock Neutral Wait"
    end

    test "a pricing-model breach records evidence, widens calibration, and pauses only spending",
         %{conn: conn} do
      initial = SpaceTraders.CreditCalibration.active()
      # The game charges 15 per unit against a 10-credit quote: 600 against a
      # 500-credit worst-case bound for 40 units.
      game = start_game(purchase_charge: 15)
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &sold?/1)

      state = Game.snapshot(game)
      assert [_one] = requests(state, "/v2/my/ships/BASELINE-1/purchase")
      # Non-spending work continues: the purchased Cargo is still sold.
      assert [_sale] = requests(state, "/v2/my/ships/BASELINE-1/sell")

      assert [%{kind: "pricing_model_miss"} | _] =
               SpaceTraders.CreditCalibration.shortfalls(agent)

      widened = SpaceTraders.CreditCalibration.active()
      assert widened.margin_percent > initial.margin_percent
      assert widened.basis == "pricing_model_miss"

      assert Repo.exists?(
               from c in SpaceTraders.OperatorConditions.Condition,
                 where:
                   c.operator_id == ^agent.operator_id and
                     c.key == ^"credit-pricing-breach:#{agent.id}" and c.kind == :attention
             )
    end

    test "API Retry-After defers Market reads without Attention and the trade completes",
         %{conn: conn} do
      game = start_game(throttled_market_reads: 3)
      {_conn, agent} = activate_fresh_generation(conn)
      drive(game, &sold?/1)

      state = Game.snapshot(game)
      assert Enum.count(state.requests, &(&1.reply == :throttled)) == 3
      assert length(requests(state, "/v2/my/ships/BASELINE-1/purchase")) == 1, trace(state)
      assert length(requests(state, "/v2/my/ships/BASELINE-1/sell")) == 1, trace(state)
      assert state.credits == 175_800

      refute Repo.exists?(
               from c in SpaceTraders.OperatorConditions.Condition,
                 where: c.operator_id == ^agent.operator_id and c.kind == :attention
             )

      # Capacity Deferral never becomes Attention or objective infeasibility.
      # (A later trade may be infeasible for fuel; that is not capacity.)
      outcomes =
        Repo.all(
          from i in SpaceTraders.Fleet.Intent,
            join: ship in SpaceTraders.Fleet.Ship,
            on: ship.id == i.ship_id,
            where: ship.agent_id == ^agent.id and i.status in ["blocked", "infeasible"],
            select: {i.status, i.blocker, i.last_action_result}
        )

      refute Enum.any?(outcomes, &(inspect(&1) =~ ~r/capacity|429|retry/i)), inspect(outcomes)
    end

    test "below the floor no fuel or Market spending leaves transport", %{conn: conn} do
      # Credits already below the 50,000 floor and too little fuel to reach the
      # distant Market: there is no recovery-spend exception.
      game = start_game(credits: 49_000, fuel: 30)
      {_conn, _agent} = activate_fresh_generation(conn)
      drive(game, fn _state -> false end, 6)

      state = Game.snapshot(game)
      assert requests(state, "/v2/my/ships/BASELINE-1/purchase") == []
      assert requests(state, "/v2/my/ships/BASELINE-1/refuel") == []
      assert state.low_credits == 49_000
    end

    # A pricing-model breach on the purchase leaves credits below the floor.
    # The trade then needs fuel the Ship cannot buy: no recovery-spend
    # exception, so the Ship's work blocks for the Operator instead.
    test "below-floor fuel stranding raises Attention instead of refuelling", %{conn: conn} do
      # 500 credits of headroom funds the 40-unit hold at the 25% margin; the
      # game charges 15 per unit (600), leaving 49,900 below the floor. 130
      # fuel covers surveying the distant Market and returning (60 + 60), not
      # the second 60-fuel leg to sell.
      game = start_game(credits: 50_500, purchase_charge: 15, fuel: 130, fuel_price: 72)
      {conn, agent} = activate_fresh_generation(conn)
      drive(game, fn _state -> false end, 10)

      state = Game.snapshot(game)
      assert [_purchase] = requests(state, "/v2/my/ships/BASELINE-1/purchase")
      assert state.credits == 49_900
      assert requests(state, "/v2/my/ships/BASELINE-1/refuel") == []

      # The Cargo stays aboard: the Ship never leaves for the selling Market.
      after_purchase =
        Enum.drop_while(state.requests, &(&1.path != "/v2/my/ships/BASELINE-1/purchase"))

      refute Enum.any?(after_purchase, &(&1.path == "/v2/my/ships/BASELINE-1/navigate"))
      assert state.units == 40

      blocked =
        Repo.all(
          from i in SpaceTraders.Fleet.Intent,
            join: ship in SpaceTraders.Fleet.Ship,
            on: ship.id == i.ship_id,
            where: ship.agent_id == ^agent.id and i.status == "blocked",
            select: i.blocker
        )

      assert Enum.any?(blocked, &(&1 && &1.reason == "credit_spending_paused")),
             "no stranding Attention: blocked=#{inspect(blocked)} #{inspect(paths(state))}"

      {:ok, _view, html} = live(conn, ~p"/mission-control")
      assert html =~ "Spending stays paused"
    end
  end

  defp start_game(opts) do
    game = start_supervised!({Game, opts})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    start_runtime()
    game
  end

  # Advances controllable time to each next durable wakeup until the game
  # reaches the expected state or the rounds run out.
  defp drive(game, done?, rounds \\ 20) do
    Enum.reduce_while(1..rounds, :ok, fn _, :ok ->
      settle_or_busy()
      Process.sleep(20)
      settle_or_busy()

      if done?.(Game.snapshot(game)) do
        {:halt, :ok}
      else
        await_governor_window()

        case SpaceTraders.TestClock.next_due_at() do
          %DateTime{} = due_at ->
            advance_time(
              max(DateTime.diff(due_at, SpaceTraders.Clock.utc_now(), :microsecond), 0),
              :microsecond
            )

            {:cont, :ok}

          nil ->
            {:halt, :ok}
        end
      end
    end)

    settle_or_busy()
  end

  # The governor paces Retry-After on wall time while the runtime schedules on
  # the controllable clock. Synchronization only: let a server-imposed window
  # pass before waking deferred work, so rounds are not spent on early wakeups.
  defp await_governor_window do
    case SpaceTraders.API.CapacityGovernor.diagnostics() do
      %{retry_after_until: %DateTime{} = until} ->
        wait = DateTime.diff(until, DateTime.utc_now(), :millisecond)
        if wait > 0, do: Process.sleep(min(wait + 10, 2_000))

      _ ->
        :ok
    end
  end

  # Like settle_runtime/0, but a runtime process that stays busy (a blocking
  # Retry-After wait, or a Neutral Wait read loop) is reported by the
  # scenario's outcome assertions instead of aborting the drive.
  defp settle_or_busy do
    settle_runtime()
  catch
    :exit, {:timeout, _call} -> :busy
  end

  defp sold?(state), do: requests(state, "/v2/my/ships/BASELINE-1/sell") != []

  defp requests(state, path), do: Enum.filter(state.requests, &(&1.path == path))

  # Failure message only: the game transcript and the Agent's Intents.
  defp trace(state) do
    intents =
      Repo.all(
        from i in SpaceTraders.Fleet.Intent,
          join: ship in SpaceTraders.Fleet.Ship,
          on: ship.id == i.ship_id,
          where: ship.symbol == "BASELINE-1",
          order_by: i.id,
          select: {i.id, i.type, i.status, i.fleet_commitment_id, i.last_action_result}
      )

    inspect(%{requests: paths(state), intents: intents}, limit: :infinity, pretty: true)
  end

  defp paths(state), do: Enum.map(state.requests, &{&1.method, &1.path, &1.reply})

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
