defmodule SpaceTraders.RuntimeBaselineProof do
  @moduledoc """
  Opt-in qualification, not a green regression claim. Run explicitly:

      mix test test/integration/runtime_baseline_proof.exs --seed 0 --trace

  #503 records current failures without authorizing recovery implementation.
  The filename deliberately leaves these unmet contracts out of the ordinary
  `_test.exs` suite; there are no skip tags or substituted coordinators.
  """

  use SpaceTraders.ScenarioCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.ShipServerBoot
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.RuntimeBaselineGame, as: Game

  @moduletag committed: true

  setup do
    advance_time(
      DateTime.diff(DateTime.utc_now(), SpaceTraders.Clock.utc_now(), :microsecond),
      :microsecond
    )

    on_exit(fn ->
      SpaceTraders.Fleet.ShipServer.stop_all()

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

    :ok
  end

  test "C05/C06: fresh Strategy activation discovers and realizes a profitable distant trade", %{
    conn: conn
  } do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    start_runtime()
    {conn, agent} = activate_fresh_generation(conn)

    assert_eventually(fn -> Game.snapshot(game).status == "IN_TRANSIT" end, 500)
    settle_runtime()

    assert Repo.exists?(
             from e in SpaceTraders.Timeline.Event,
               where:
                 e.owner_id == "BASELINE-1" and e.status == "pending" and
                   e.event_type == "arrival"
           )

    # The game clock passes arrival while the runtime processes are down. The
    # production boot and scheduler reconstruct authority and the overdue wait.
    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(Reconciler)
    assert :ok = SpaceTraders.Fleet.ShipServer.stop("BASELINE-1")
    advance_time(60)
    start_runtime()
    start_supervised!({ShipServerBoot, []})

    # Advance registered production wakes, including the demand scheduler's
    # capacity-deferral wake. Neither fixed fast-forward ticks nor only advancing
    # arrivals models that clock correctly. This controls time, not coordination.
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
    intents = Repo.all(from i in Intent, order_by: i.id, select: {i.type, i.status, i.blocker})
    counts = Enum.frequencies_by(state.requests, & &1.path)

    IO.inspect(
      %{
        credits: state.credits,
        fuel: state.fuel,
        requests: Enum.map(state.requests, &{&1.method, &1.path, &1.reply, &1.at}),
        intents: intents,
        as_of: SpaceTraders.Clock.utc_now(),
        listings:
          Enum.map(["X1-UX81-A1", "X1-UX81-A2"], fn waypoint ->
            {waypoint,
             SpaceTraders.World.intelligence(
               agent,
               :market,
               "X1-UX81",
               waypoint,
               SpaceTraders.Clock.utc_now(),
               300
             ).facts["trade_goods"]}
          end)
      },
      label: "C05/C06 baseline",
      limit: :infinity
    )

    {:ok, view, html} = live(conn, ~p"/mission-control")
    IO.puts("Operator-visible operating health: " <> render(element(view, "#operating-health")))
    assert html =~ agent.symbol
    assert Map.get(counts, "/v2/my/ships/BASELINE-1/purchase", 0) == 1
    assert Map.get(counts, "/v2/my/ships/BASELINE-1/sell", 0) == 1
    assert state.credits == 175_800
    assert state.units == 0
    refute Enum.any?(state.requests, &String.ends_with?(&1.path, "X1-UX81-A3/market"))

    assert Enum.any?(
             SpaceTraders.Evidence.list_open_demands(agent),
             &(&1.subject == "market:X1-UX81:X1-UX81-A3" and &1.owner == "fleet_planning")
           )

    assert Enum.any?(intents, fn {type, status, _} -> type == "sell" and status == "completed" end)
  end

  test "C04: a retry's sent evidence survives sender death and is independently visible", %{
    conn: conn
  } do
    game = start_supervised!({Game, orbit_timeout: true})
    test_pid = self()
    orbit_path = "/v2/my/ships/BASELINE-1/orbit"

    stub_api(fn conn ->
      reply = Game.call(game, conn)

      if conn.request_path == orbit_path and reply != {:timeout, :not_applied} do
        # The controlled game accepted this request. Pause before delivering its
        # response; the ledger is read through another actual pool connection.
        [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
        send(test_pid, {:retry_sent, self(), backend, Repo.in_transaction?()})

        receive do
          :deliver_response -> :ok
        after
          10_000 -> raise("dispatch interruption was not released")
        end
      end

      Game.reply(conn, reply)
    end)

    allow_game_runtime()
    start_runtime()
    {_conn, agent} = activate_fresh_generation(conn)

    assert_eventually(
      fn ->
        Repo.exists?(
          from a in Attempt,
            where:
              a.agent_id == ^agent.id and a.operation_id == "orbit-ship" and
                a.state == "ambiguous"
        )
      end,
      500
    )

    original =
      Repo.one!(
        from a in Attempt, where: a.agent_id == ^agent.id and a.operation_id == "orbit-ship"
      )

    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(Reconciler)

    # Hold a nontransactional observer connection before starting the sender.
    # Independence must still hold once dispatch no longer holds a transaction.
    observer =
      start_supervised!(
        {Task,
         fn ->
           :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

           try do
             [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
             send(test_pid, {:observer_ready, self(), backend})

             for _ <- 1..2 do
               receive do
                 {:observe_attempts, agent} ->
                   send(test_pid, {:attempt_states, self(), attempt_states(agent)})
               after
                 10_000 -> raise("independent observation was not requested")
               end
             end
           after
             Ecto.Adapters.SQL.Sandbox.checkin(Repo)
           end
         end}
      )

    assert_receive {:observer_ready, ^observer, observing_backend}

    # Re-enter through the production boot owner, not the Intent executor or a
    # hand-assembled retry. The controlled game's unchanged posture proves the
    # first timed-out action absent.
    {boot_caller, monitor} = spawn_monitor(fn -> ShipServerBoot.start_link([]) end)
    on_exit(fn -> if Process.alive?(boot_caller), do: Process.exit(boot_caller, :kill) end)
    assert_receive {:retry_sent, sender, sending_backend, inside_transaction}, 10_000
    assert observing_backend != sending_backend

    visible_at_send = observe_attempts(observer, agent)
    assert Game.snapshot(game).status == "IN_ORBIT"
    sender_monitor = Process.monitor(sender)
    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^sender_monitor, :process, ^sender, :killed}
    assert_receive {:DOWN, ^monitor, :process, ^boot_caller, _reason}

    # A new query after rollback cannot see the killed sender's transaction.
    visible_after_death = observe_attempts(observer, agent)
    persisted_intent = Repo.get!(Intent, original.provenance["intent_id"])

    IO.inspect(
      %{
        inside_transaction: inside_transaction,
        sending_backend: sending_backend,
        observing_backend: observing_backend,
        at_send: visible_at_send,
        after_death: visible_after_death,
        in_flight_action: persisted_intent.in_flight_action,
        game_posture: Game.snapshot(game).status
      },
      label: "C04 dispatch baseline",
      limit: :infinity
    )

    # This is the failing recovery contract. A nested Repo.transaction returning
    # successfully must not be mistaken for independently committed evidence.
    refute inside_transaction

    assert Enum.any?(
             visible_at_send,
             &(&1.retry_of_id == original.id and &1.state == "sent_or_unknown")
           )

    assert Enum.any?(
             visible_after_death,
             &(&1.retry_of_id == original.id and &1.state == "sent_or_unknown")
           )
  end

  defp observe_attempts(observer, agent) do
    send(observer, {:observe_attempts, agent})
    assert_receive {:attempt_states, ^observer, states}, 5_000
    states
  end

  defp attempt_states(agent) do
    Repo.all(
      from a in Attempt,
        where: a.agent_id == ^agent.id and a.operation_id == "orbit-ship",
        order_by: a.prepared_at,
        select: %{
          id: a.id,
          state: a.state,
          retry_of_id: a.retry_of_id,
          retry_authorized: a.retry_authorized
        }
    )
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
