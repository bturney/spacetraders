defmodule SpaceTraders.RecordedShipRuntimeTest do
  @moduledoc """
  Recorded dispatch qualification through authenticated Strategy activation and
  production coordination/boot. The game owns transport receipts; a separate
  PostgreSQL session observes committed evidence. Semantic telemetry only interrupts
  the running sender; it never supplies a selection or recovery decision.
  """
  use ExUnit.Case, async: false

  @endpoint SpaceTradersWeb.Endpoint
  use SpaceTradersWeb, :verified_routes
  import Ecto.Query
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Plug.Conn

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.{Intent, ShipServer, ShipServerBoot}
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.{Repo, RuntimeAuthority, TestClock}
  alias SpaceTraders.RuntimeBaselineGame, as: Game

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
  end

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    start_supervised!({TestClock, DateTime.utc_now()})
    previous_clock = Application.fetch_env(:spacetraders, :clock)
    previous_authority = Application.fetch_env(:spacetraders, RuntimeAuthority)
    Application.put_env(:spacetraders, :clock, TestClock)
    Application.put_env(:spacetraders, RuntimeAuthority, enabled: true)
    start_supervised!({RuntimeAuthority, lock_key: System.unique_integer([:positive])})
    assert RuntimeAuthority.execution_allowed?() == :ok

    observer = start_supervised!({Postgrex, connection_options()})
    game = start_supervised!({Game, []})
    barrier = :ets.new(:qualification_barrier, [:public, :set])
    gate = :atomics.new(1, [])
    owner = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      if conn.method == "POST" and String.ends_with?(conn.request_path, "/orbit") do
        transport_barrier(owner, :transport_before_accept, barrier, gate)
        reply = Game.call(game, conn)
        transport_barrier(owner, :accepted, barrier, gate)
        Game.reply(conn, reply)
      else
        if conn.method == "GET" and conn.request_path == "/v2/my/ships/BASELINE-1",
          do: transport_barrier(owner, :before_preparation, barrier, gate)

        Game.reply(conn, Game.call(game, conn))
      end
    end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      ships =
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)

      Enum.filter(
        [Process.whereis(Reconciler), Process.whereis(ShipServerBoot) | ships],
        &is_pid/1
      )
    end)

    restart_capacity()

    on_exit(fn ->
      ShipServer.stop_all()
      SpaceTraders.Contracts.DeadlineServer.stop_all()
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()

      Sandbox.unboxed_run(Repo, fn ->
        ids =
          Repo.all(from o in Operator, where: like(o.email, "qualification-507-%"), select: o.id)

        agents = Repo.all(from a in Agent, where: a.operator_id in ^ids, select: a.id)
        attempts = Repo.all(from a in Attempt, where: a.agent_id in ^agents, select: a.id)
        Repo.delete_all(from o in Outcome, where: o.mutation_attempt_id in ^attempts)
        Repo.delete_all(from a in Attempt, where: a.id in ^attempts)

        Repo.delete_all(
          from d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id in ^agents
        )

        Repo.delete_all(from o in SpaceTraders.Evidence.Observation, where: o.agent_id in ^agents)
        topics = Enum.map(ids, &"fleet_allocation:#{&1}") ++ Enum.map(agents, &"fleet:#{&1}")
        Repo.delete_all(from n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics)
        Repo.delete_all(from o in Operator, where: o.id in ^ids)
        Repo.delete_all(from e in SpaceTraders.Timeline.Event, where: e.owner_id == "BASELINE-1")
      end)

      restart_capacity()
      restore_env(:clock, previous_clock)
      restore_env(RuntimeAuthority, previous_authority)
      Sandbox.mode(Repo, :manual)
    end)

    start_runtime()
    {conn, agent} = mint_generation()
    {:ok, conn: conn, agent: agent, game: game, observer: observer, barrier: barrier, gate: gate}
  end

  test "Emergency Stop overlaps a checked final authorization transaction; admitted work completes once",
       context do
    install_barrier(:transport_authorization_checked, context)
    activate(context.conn)

    assert_receive {:boundary, sender, :transport_authorization_checked, authorization_backend},
                   5_000

    assert_receive {:authorization_transaction, true}
    assert orbit_count(context.game) == 0
    scope = Scope.for_operator(Repo.get!(Operator, context.agent.operator_id))
    owner = self()

    stop =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:stop_backend, backend})
          SpaceTraders.FleetStrategy.engage_emergency_stop(scope)
        end)
      end)

    assert_receive {:stop_backend, stop_backend}, 5_000

    eventually(
      fn ->
        SpaceTraders.EmergencyStopAdmission.mutation_allowed?(context.agent.agent_token) ==
          {:error, :emergency_stopped}
      end,
      500,
      context
    )

    assert authorization_backend != stop_backend

    eventually(
      fn ->
        Postgrex.query!(context.observer, "SELECT $1::int = ANY(pg_blocking_pids($2::int))", [
          authorization_backend,
          stop_backend
        ]).rows == [[true]]
      end,
      500,
      context
    )

    # The stop's durable write waits behind final authorization's Strategy lock.
    send(sender, :continue)
    assert {:ok, _} = Task.await(stop, 5_000)
    eventually(fn -> orbit_count(context.game) == 1 end, 500, context)

    eventually(
      fn ->
        Enum.any?(
          SpaceTraders.MutationAttempts.list_for_agent(context.agent),
          &(&1.operation_id == "orbit-ship" and &1.state == "succeeded")
        )
      end,
      500,
      context
    )

    assert [[id, "succeeded", _]] = observe_attempts(context.observer, context.agent.id)
    stop_supervised(DemandScheduler)
    stop_supervised(Reconciler)
    ShipServer.stop_all()
    restart_runtime()
    assert orbit_count(context.game) == 1

    refute Enum.any?(
             SpaceTraders.MutationAttempts.list_for_agent(context.agent),
             &(&1.retry_of_id == id)
           )
  end

  for {phase, committed_state, accepted} <- [
        {:before_preparation, nil, false},
        {:preparation_write, nil, false},
        {:prepared, "prepared", false},
        {:marker_write, "prepared", false},
        {:marker_committed, "sent_or_unknown", false},
        {:transport_authorized, "sent_or_unknown", false},
        {:transport_before_accept, "sent_or_unknown", false},
        {:accepted, "sent_or_unknown", true},
        {:response_delivered, "sent_or_unknown", true},
        {:outcome_write, "sent_or_unknown", true},
        {:outcome_committed, "succeeded", true}
      ] do
    @phase phase
    @committed_state committed_state
    @accepted accepted
    test "runtime death at #{@phase} reconstructs committed evidence without blind replay",
         context do
      install_barrier(@phase, context)
      activate(context.conn)
      assert_receive {:boundary, sender, @phase, sender_backend}, 5_000
      assert observer_backend(context.observer) != sender_backend
      before = observe_attempts(context.observer, context.agent.id)

      if @committed_state do
        assert [[_id, @committed_state, sent_at]] = before
        assert is_nil(sent_at) == (@committed_state == "prepared")
      else
        assert before == []
      end

      assert orbit_count(context.game) == if(@accepted, do: 1, else: 0)
      kill_runtime(sender)
      assert observe_attempts(context.observer, context.agent.id) == before
      restart_runtime()
      eventually(fn -> orbit_count(context.game) == 1 end, 500, context)

      eventually(
        fn ->
          SpaceTraders.MutationAttempts.list_for_agent(context.agent)
          |> Enum.any?(
            &(&1.operation_id == "orbit-ship" and &1.state in ["succeeded", "accepted"])
          )
        end,
        500,
        context
      )

      assert orbit_count(context.game) == 1

      orbits =
        SpaceTraders.MutationAttempts.list_for_agent(context.agent)
        |> Enum.filter(&(&1.operation_id == "orbit-ship"))

      assert_retry_history(orbits, @committed_state, @accepted)

      IO.inspect(
        %{
          phase: @phase,
          observer_backend: observer_backend(context.observer),
          sender_backend: sender_backend,
          before: before,
          after: Enum.map(orbits, &{&1.id, &1.state, &1.retry_of_id}),
          expected_orbits: 1,
          actual_orbits: orbit_count(context.game)
        },
        label: "507 interruption receipt"
      )
    end
  end

  for winner <- [:revocation, :authorization], loss <- [:emergency_stop, :claim] do
    @winner winner
    @loss loss
    test "#{@loss} race: #{@winner} linearizes first and boot never adds a send", context do
      phase = if @winner == :revocation, do: :marker_committed, else: :transport_authorized
      install_barrier(phase, context)
      activate(context.conn)
      assert_receive {:boundary, sender, ^phase, _}, 5_000
      assert [[id, "sent_or_unknown", _]] = observe_attempts(context.observer, context.agent.id)
      original = Repo.get_by!(Intent, mutation_attempt_id: id)
      revoke(@loss, context, original)
      assert orbit_count(context.game) == 0
      send(sender, :continue)
      expected_state = if @winner == :revocation, do: "ambiguous", else: "succeeded"

      eventually(
        fn -> SpaceTraders.MutationAttempts.get!(id).state == expected_state end,
        500,
        context
      )

      expected_count = if @winner == :revocation, do: 0, else: 1
      assert orbit_count(context.game) == expected_count
      stop_supervised(DemandScheduler)
      stop_supervised(Reconciler)
      ShipServer.stop_all()
      restart_runtime()

      for {_, pid, _, _} <- DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor),
          do: :sys.get_state(pid)

      assert orbit_count(context.game) == expected_count

      refute Enum.any?(
               SpaceTraders.MutationAttempts.list_for_agent(context.agent),
               &(&1.retry_of_id == id)
             )
    end
  end

  for phase <- [:prepared, :marker_committed],
      loss <- [:claim, :selection, :revision, :emergency_stop, :generation, :singleton] do
    @phase phase
    @loss loss
    test "#{@loss} lost at #{@phase} suppresses obsolete runtime transport", context do
      install_barrier(@phase, context)
      activate(context.conn)
      assert_receive {:boundary, sender, @phase, _backend}, 5_000
      assert [[id, _state, _sent]] = observe_attempts(context.observer, context.agent.id)
      original = Repo.get_by!(Intent, mutation_attempt_id: id)
      revoke(@loss, context, original)
      send(sender, :continue)
      expected = if @phase == :prepared, do: "not_sent", else: "ambiguous"
      eventually(fn -> SpaceTraders.MutationAttempts.get!(id).state == expected end, 500, context)
      assert orbit_count(context.game) == 0
      retained = SpaceTraders.MutationAttempts.get!(id)
      refute retained.retry_authorized
      assert Enum.map(retained.outcomes, & &1.classification) == [expected]
      assert is_nil(retained.sent_or_unknown_at) == (@phase == :prepared)

      # Re-entry under lost authority cannot release the captured obsolete action.
      stop_supervised(DemandScheduler)
      stop_supervised(Reconciler)
      ShipServer.stop_all()

      advance_observation_clock_to_now()

      start_supervised!({ShipServerBoot, []})

      for {_, pid, _, _} <- DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor),
          do: :sys.get_state(pid)

      assert orbit_count(context.game) == 0

      if SpaceTraders.MutationAttempts.get!(id).retry_authorized do
        assert {:error, _} =
                 SpaceTraders.Fleet.Intents.RecordedAction.prepare_retry(
                   context.agent,
                   original,
                   SpaceTraders.MutationAttempts.get!(id)
                 )
      end

      IO.inspect(
        %{
          loss: @loss,
          phase: @phase,
          disposition: expected,
          expected_orbits: 0,
          actual_orbits: orbit_count(context.game)
        },
        label: "507 authority receipt"
      )
    end
  end

  test "explicit Emergency Stop resume preparation reconciles without releasing its obsolete action",
       context do
    install_barrier(:marker_committed, context)
    activate(context.conn)
    assert_receive {:boundary, sender, :marker_committed, _}, 5_000
    assert [[id, "sent_or_unknown", _]] = observe_attempts(context.observer, context.agent.id)
    scope = Scope.for_operator(Repo.get!(Operator, context.agent.operator_id))
    assert {:ok, stopped} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)
    send(sender, :continue)

    eventually(
      fn -> SpaceTraders.MutationAttempts.get!(id).state == "ambiguous" end,
      500,
      context
    )

    assert orbit_count(context.game) == 0

    advance_observation_clock_to_now()

    assert {:error, :reconciliation_required} =
             SpaceTraders.FleetStrategy.resume(scope, stopped.emergency_stop_version)

    assert :ok = SpaceTraders.Fleet.Intents.rearm_on_boot()
    assert orbit_count(context.game) == 0

    assert {:ok, prepared} =
             SpaceTraders.FleetStrategy.resume(scope, stopped.emergency_stop_version)

    assert %DateTime{} = prepared.emergency_stopped_at
    assert %DateTime{} = prepared.emergency_resume_prepared_at

    old = SpaceTraders.MutationAttempts.get!(id)
    assert old.state == "absent"
    refute old.retry_authorized

    refute Enum.any?(
             SpaceTraders.MutationAttempts.list_for_agent(context.agent),
             &(&1.retry_of_id == id)
           )

    assert Repo.get!(Intent, old.provenance["intent_id"]).status in Intent.terminal_states()
    assert {:error, :attempt_already_dispatched} = SpaceTraders.API.dispatch_recorded(old)
    assert orbit_count(context.game) == 0
  end

  defp revoke(:emergency_stop, context, _intent) do
    scope = Scope.for_operator(Repo.get!(Operator, context.agent.operator_id))
    assert {:ok, _} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)
  end

  defp revoke(:singleton, _context, _intent), do: stop_supervised!(RuntimeAuthority)

  defp revoke(:claim, _context, intent) do
    Repo.get!(SpaceTraders.FleetAllocation.Portfolio, intent.fleet_commitment_portfolio_id)
    |> Ecto.Changeset.change(superseded_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke(:selection, _context, intent) do
    intent
    |> Ecto.Changeset.change(
      in_flight_action: Map.put(intent.in_flight_action, "selection_id", Ecto.UUID.generate())
    )
    |> Repo.update!()
  end

  defp revoke(:revision, context, _intent) do
    scope = Scope.for_operator(Repo.get!(Operator, context.agent.operator_id))
    {:ok, strategy} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, _} = SpaceTraders.FleetStrategy.activate(scope, strategy.draft_version)
  end

  defp revoke(:generation, context, _intent) do
    SpaceTraders.FleetGenerationAdmission.fence(context.agent.agent_token)

    Repo.get_by!(SpaceTraders.FleetGeneration.Generation, agent_id: context.agent.id)
    |> Ecto.Changeset.change(fenced_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp mint_generation do
    email = "qualification-507-#{System.unique_integer([:positive])}@example.com"

    conn =
      post(build_conn(), ~p"/setup", %{
        "operator" => %{
          "email" => email,
          "password" => "a long qualification password",
          "password_confirmation" => "a long qualification password",
          "account_token" => "BASELINE_ACCOUNT_TOKEN"
        }
      })

    assert get_session(conn, :operator_token)
    {:ok, mint, _} = live(conn, ~p"/agents/new")

    assert {:error, {:redirect, %{to: "/mission-control", status: 302}}} =
             mint
             |> form("#mint_form", %{"agent" => %{"symbol" => "BASELINE", "faction" => "COSMIC"}})
             |> render_submit()

    {conn, Repo.get_by!(Agent, symbol: "BASELINE")}
  end

  defp activate(conn) do
    {:ok, strategy, _} = live(conn, ~p"/strategy")
    strategy |> element("#select-preset-steady_growth") |> render_click()
    strategy |> element("#activate-strategy") |> render_click()
    assert render(strategy) =~ "Active revision 1"
  end

  defp start_runtime do
    start_supervised!(Supervisor.child_spec({Reconciler, []}, restart: :temporary))
    start_supervised!(Supervisor.child_spec({DemandScheduler, []}, restart: :temporary))
  end

  defp kill_runtime(sender) do
    monitor = Process.monitor(sender)
    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}
    stop_supervised(DemandScheduler)
    stop_supervised(Reconciler)
    ShipServer.stop_all()
  end

  defp restart_runtime do
    restart_capacity()

    advance_observation_clock_to_now()

    start_runtime()
    start_supervised!({ShipServerBoot, []})
  end

  defp restart_capacity do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
  end

  defp advance_observation_clock_to_now do
    TestClock.advance(
      DateTime.diff(DateTime.utc_now(), TestClock.utc_now(), :microsecond),
      :microsecond
    )
  end

  defp connection_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database, :ssl, :socket_options])
  end

  defp observer_backend(observer) do
    %{rows: [[pid]]} = Postgrex.query!(observer, "SELECT pg_backend_pid()", [])
    pid
  end

  defp observe_attempts(observer, agent_id) do
    Postgrex.query!(
      observer,
      "SELECT id::text, state, sent_or_unknown_at FROM mutation_attempts WHERE agent_id = $1 AND operation_owner = 'ship_execution' ORDER BY prepared_at",
      [agent_id]
    ).rows
  end

  defp orbit_count(game) do
    Game.snapshot(game).requests
    |> Enum.count(&(&1.method == "POST" and String.ends_with?(&1.path, "/orbit")))
  end

  defp install_barrier(phase, context) do
    id = "qualification-507-#{System.unique_integer([:positive])}"
    owner = self()
    :ets.insert(context.barrier, {:phase, phase})

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:spacetraders, :recorded_dispatch, :prepared],
          [:spacetraders, :recorded_dispatch, :preparation_written],
          [:spacetraders, :recorded_dispatch, :marker_written],
          [:spacetraders, :recorded_dispatch, :marker_committed],
          [:spacetraders, :recorded_dispatch, :transport_authorized],
          [:spacetraders, :recorded_dispatch, :transport_authorization_checked],
          [:spacetraders, :mutation_attempts, :outcome_written],
          [:spacetraders, :mutation_attempts, :outcome_committed],
          [:spacetraders, :api, :request]
        ],
        &boundary/4,
        {owner, phase, context.gate}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp boundary(
         [:spacetraders, owner_module, event],
         _,
         %{operation_id: "orbit-ship"} = metadata,
         {owner, phase, gate}
       )
       when owner_module in [:recorded_dispatch, :mutation_attempts] do
    matches = %{
      preparation_write: :preparation_written,
      marker_write: :marker_written,
      outcome_write: :outcome_written
    }

    if event == Map.get(matches, phase, phase) and
         Map.get(metadata, :classification, :succeeded) == :succeeded,
       do: pause_once(owner, phase, gate)
  end

  defp boundary([:spacetraders, :api, :request], _, metadata, {owner, :response_delivered, gate}) do
    if metadata.operation_id == "orbit-ship", do: pause_once(owner, :response_delivered, gate)
  end

  defp boundary(_, _, _, _), do: :ok

  defp restore_env(key, {:ok, value}), do: Application.put_env(:spacetraders, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:spacetraders, key)

  defp transport_barrier(owner, phase, barrier, gate) do
    if :ets.lookup(barrier, :phase) == [{:phase, phase}], do: pause_once(owner, phase, gate)
  end

  defp pause_once(owner, phase, gate) do
    if :atomics.compare_exchange(gate, 1, 0, 1) == :ok, do: pause(owner, phase)
  end

  defp pause(owner, phase) do
    if phase == :transport_authorization_checked,
      do: send(owner, {:authorization_transaction, Repo.in_transaction?()})

    [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    send(owner, {:boundary, self(), phase, backend})

    receive do
      :continue -> :ok
    after
      10_000 -> raise "qualification boundary was not released: #{phase}"
    end
  end

  defp assert_retry_history(orbits, "sent_or_unknown", false) do
    assert [%{state: "absent", retry_authorized: false}, %{retry_of_id: original}] = orbits
    assert original == hd(orbits).id
  end

  defp assert_retry_history(orbits, _, _), do: assert(length(orbits) == 1)

  defp eventually(fun, attempts, context)

  defp eventually(_fun, 0, context) do
    if context do
      IO.inspect(SpaceTraders.MutationAttempts.list_for_agent(context.agent),
        label: "failed runtime attempts",
        limit: :infinity
      )

      IO.inspect(Repo.all(Intent), label: "failed runtime intents", limit: :infinity)
      IO.inspect(Game.snapshot(context.game), label: "failed runtime game", limit: :infinity)
    end

    flunk("production runtime did not reach expected state")
  end

  defp eventually(fun, attempts, context) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1, context)
        )
  end
end
