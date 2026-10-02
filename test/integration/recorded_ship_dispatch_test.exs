defmodule SpaceTraders.RecordedShipDispatchTest do
  @moduledoc """
  #504 regression at the Operator-approved runtime seam (#503): authenticated
  Strategy activation, production coordination/boot, stateful game, real commits
  and a pinned independent PostgreSQL observer. Telemetry pauses interruption
  boundaries; it never selects work or substitutes a coordinator.
  """

  use SpaceTraders.ScenarioCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.API.RecordedDispatch
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.ShipServerBoot
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.RuntimeBaselineGame, as: Game

  @moduletag committed: true

  setup do
    # Sender-kill cases intentionally abandon process-local API admissions. Each
    # independent scenario starts a fresh production governor, as at VM boot;
    # this is isolation, not evidence-safe re-entry qualification (#506/#507).
    restart_capacity_governor()
    on_exit(&restart_capacity_governor/0)

    advance_time(
      DateTime.diff(DateTime.utc_now(), SpaceTraders.Clock.utc_now(), :microsecond),
      :microsecond
    )

    on_exit(fn ->
      SpaceTraders.Fleet.ShipServer.stop_all()

      operator_ids =
        Repo.all(from o in Operator, where: like(o.email, "dispatch-504-%"), select: o.id)

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

  defp restart_capacity_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _pid} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    :ok
  end

  for navigation_retry? <- [false, true] do
    @navigation_retry? navigation_retry?
    test "#{if navigation_retry?, do: "production boot navigation retry", else: "selected navigation"} send evidence is independently visible and survives sender death",
         %{
           conn: conn
         } do
      game = start_supervised!({Game, navigate_timeout: @navigation_retry?})
      test_pid = self()

      stub_api(fn conn ->
        reply = Game.call(game, conn)

        if String.ends_with?(conn.request_path, "/navigate") and reply != {:timeout, :not_applied} do
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(test_pid, {:navigation_accepted, self(), backend, Repo.in_transaction?()})

            receive do
              :deliver_response -> :ok
            after
              10_000 -> raise("navigation interruption was not released")
            end
          end)
        end

        Game.reply(conn, reply)
      end)

      allow_game_runtime()
      observer = start_observer()
      start_runtime()
      {_conn, agent} = activate_fresh_generation(conn)

      original =
        if @navigation_retry? do
          assert_eventually(
            fn ->
              Repo.exists?(
                from a in Attempt,
                  where:
                    a.agent_id == ^agent.id and a.operation_id == "navigate-ship" and
                      a.state == "ambiguous"
              )
            end,
            500
          )

          attempt =
            Repo.one!(
              from a in Attempt,
                where: a.agent_id == ^agent.id and a.operation_id == "navigate-ship"
            )

          assert :ok = stop_supervised!(DemandScheduler)
          assert :ok = stop_supervised!(Reconciler)
          {caller, _} = spawn_monitor(fn -> ShipServerBoot.start_link([]) end)
          on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
          attempt
        end

      assert_receive {:navigation_accepted, sender, backend, false}, 10_000
      at_send = observe(observer, agent, "navigate-ship")
      assert at_send.backend != backend
      assert Game.snapshot(game).status == "IN_TRANSIT"
      attempt = List.last(at_send.attempts)

      if @navigation_retry? do
        assert [absent, ^attempt] = at_send.attempts
        assert absent.id == original.id
        assert absent.state == "absent"
        refute absent.retry_authorized
        assert attempt.retry_of_id == absent.id
      else
        assert [^attempt] = at_send.attempts
        assert is_nil(attempt.retry_of_id)
      end

      assert attempt.state == "sent_or_unknown"
      assert %DateTime{} = attempt.sent_or_unknown_at
      assert [intent] = at_send.intents
      assert intent.in_flight_action["kind"] == "navigate"
      assert intent.mutation_attempt_id == attempt.id

      assert attempt.provenance["selected_action_fingerprint"] ==
               SpaceTraders.Evidence.fingerprint(intent.in_flight_action)

      assert attempt.prepared_evidence["request"]["body"] == %{
               "waypointSymbol" => intent.in_flight_action["waypoint"]
             }

      kill_sender(sender)
      assert at_send == observe(observer, agent, "navigate-ship")

      IO.inspect(
        %{
          operation: "navigate-ship",
          retry: @navigation_retry?,
          sending_backend: backend,
          observing_backend: at_send.backend,
          attempt_id: attempt.id,
          state_at_send: attempt.state,
          state_after_death: "sent_or_unknown",
          inside_transaction: false
        },
        label: "#505 independently committed navigation dispatch"
      )
    end
  end

  test "death inside preparation rolls back both the selected action and its attempt", %{
    conn: conn
  } do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    observer = start_observer()
    handler = "inside-preparation-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.pause_uncommitted/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    start_runtime()
    {_conn, agent} = activate_fresh_generation(conn)
    assert_receive {:uncommitted_preparation, sender, true}, 10_000
    %{attempts: [], intents: [intent]} = observe(observer, agent)
    assert is_nil(intent.in_flight_action)
    assert is_nil(intent.mutation_attempt_id)
    kill_sender(sender)
    assert %{attempts: [], intents: [^intent]} = observe(observer, agent)
    assert Game.snapshot(game).status == "DOCKED"
    refute Enum.any?(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit"))
  end

  def pause_uncommitted(_event, _measurements, metadata, test_pid) do
    if String.starts_with?(metadata.query, ~s(UPDATE "intents")) and
         String.contains?(metadata.query, "mutation_attempt_id") do
      send(test_pid, {:uncommitted_preparation, self(), Repo.in_transaction?()})

      receive do
        :continue_dispatch -> :ok
      after
        10_000 -> raise("uncommitted preparation interruption was not released")
      end
    end
  end

  test "first preparation is independently committed with its selected action before send", %{
    conn: conn
  } do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    observer = start_observer()
    pause_preparation()
    start_runtime()
    {_conn, agent} = activate_fresh_generation(conn)

    assert_receive {:prepared, sender, attempt_id, backend, inside_transaction}, 10_000
    %{backend: observing_backend, attempts: attempts, intents: intents} = observe(observer, agent)
    assert backend != observing_backend
    refute inside_transaction
    assert [attempt] = attempts
    assert attempt.id == attempt_id
    assert attempt.state == "prepared"
    assert [intent] = intents
    assert intent.mutation_attempt_id == attempt_id
    assert intent.in_flight_action["kind"] == "orbit"
    assert is_binary(intent.in_flight_action["selection_id"])

    assert attempt.provenance["selected_action_fingerprint"] ==
             SpaceTraders.Evidence.fingerprint(intent.in_flight_action)

    assert attempt.provenance["commitment_id"] == intent.fleet_commitment_id
    assert attempt.fleet_generation_id
    assert attempt.strategy_revision_id
    assert attempt.dependency_keys == ["ship:#{agent.id}:BASELINE-1"]
    assert attempt.expected_effects == ["Ship nav response"]
    assert Game.snapshot(game).status == "DOCKED"
    refute Enum.any?(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit"))

    kill_sender(sender)
    %{attempts: [after_death], intents: [selected]} = observe(observer, agent)
    assert after_death.id == attempt.id
    assert after_death.state == "prepared"
    assert selected.mutation_attempt_id == attempt.id
  end

  defp pause_preparation do
    handler = "recorded-preparation-#{System.unique_integer([:positive])}"
    event = [:spacetraders, :recorded_dispatch, :prepared]
    :ok = :telemetry.attach(handler, event, &__MODULE__.pause/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  test "rejected orbit is followed by linked recorded navigation evidence", %{
    conn: conn
  } do
    game = start_supervised!({Game, orbit_rejection: true})

    stub_api(fn conn ->
      reply = Game.call(game, conn)

      if String.ends_with?(conn.request_path, "/navigate"),
        do: Req.Test.transport_error(conn, :timeout),
        else: Game.reply(conn, reply)
    end)

    allow_game_runtime()
    start_runtime()
    {_conn, agent} = activate_fresh_generation(conn)

    assert_eventually(
      fn ->
        Repo.exists?(
          from a in Attempt,
            where:
              a.agent_id == ^agent.id and a.operation_id == "orbit-ship" and a.state == "rejected"
        )
      end,
      500
    )

    assert_eventually(fn ->
      Repo.exists?(
        from i in Intent,
          join: s in SpaceTraders.Fleet.Ship,
          on: s.id == i.ship_id,
          where: s.agent_id == ^agent.id and i.status == "blocked" and is_nil(i.in_flight_action)
      )
    end)

    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(Reconciler)

    # Authoritative posture changes independently after the rejected request.
    # Production boot then chooses navigation; no Intent/action is assembled here.
    :ok = Game.change_posture(game, "IN_ORBIT")
    test_pid = self()

    {caller, monitor} =
      spawn_monitor(fn -> send(test_pid, {:boot_result, ShipServerBoot.start_link([])}) end)

    assert_receive {:boot_result, :ignore}, 10_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    assert [intent] = SpaceTraders.Fleet.Intents.current(agent)

    assert %Attempt{id: attempt_id, operation_id: "navigate-ship", state: "ambiguous"} =
             SpaceTraders.MutationAttempts.unresolved_for_intent(intent)

    assert intent.mutation_attempt_id == attempt_id
    assert intent.in_flight_action["kind"] == "navigate"
    assert Game.snapshot(game).status == "IN_TRANSIT"
  end

  test "Emergency Stop after preparation suppresses transport with durable non-send evidence", %{
    conn: conn
  } do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    observer = start_observer()
    pause_preparation()
    start_runtime()
    {_conn, agent} = activate_fresh_generation(conn)
    assert_receive {:prepared, sender, attempt_id, _backend, false}, 10_000
    scope = SpaceTraders.Agent.Scope.for_operator(Repo.get!(Operator, agent.operator_id))
    assert {:ok, _} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)
    send(sender, :continue_dispatch)

    assert_eventually(fn ->
      SpaceTraders.MutationAttempts.get!(attempt_id).state == "not_sent"
    end)

    %{attempts: [attempt]} = observe(observer, agent)
    assert attempt.state == "not_sent"
    assert is_nil(attempt.sent_or_unknown_at)

    assert [%{classification: "not_sent", evidence: %{"reason" => "emergency_stopped"}}] =
             SpaceTraders.MutationAttempts.get!(attempt_id).outcomes

    assert Game.snapshot(game).status == "DOCKED"
    refute Enum.any?(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit"))
  end

  test "caller transactions cannot prepare or send recorded work", %{conn: conn} do
    {game, observer, agent, intent, attempt, sender} = paused_first_preparation(conn)
    kill_sender(sender)

    assert {:error, :caller_rollback} =
             Repo.transaction(fn ->
               assert {:error, :recorded_dispatch_requires_commit} =
                        SpaceTraders.API.dispatch_recorded(attempt)

               assert {:error, :recorded_dispatch_requires_commit} =
                        RecordedDispatch.prepare(agent, intent, intent.in_flight_action)

               assert {:error, :recorded_dispatch_requires_commit} =
                        RecordedDispatch.prepare_retry(agent, intent, attempt)

               Repo.rollback(:caller_rollback)
             end)

    assert %{attempts: [^attempt], intents: [^intent]} = observe(observer, agent)
    refute Enum.any?(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit"))
  end

  test "concurrent senders cannot reuse a recorded attempt", %{conn: conn} do
    {game, observer, agent, _intent, attempt, sender} = paused_first_preparation(conn)
    kill_sender(sender)
    test_pid = self()

    stub_api(fn conn ->
      reply = Game.call(game, conn)
      send(test_pid, {:concurrent_send, self()})

      receive do
        :deliver_response -> Game.reply(conn, reply)
      after
        10_000 -> raise("concurrent send was not released")
      end
    end)

    calls =
      for _ <- 1..2 do
        Task.async(fn -> SpaceTraders.API.dispatch_recorded(attempt) end)
      end

    assert_receive {:concurrent_send, accepted_sender}, 5_000
    refute_receive {:concurrent_send, _}, 50
    assert %{attempts: [%{state: "sent_or_unknown"}]} = observe(observer, agent)
    send(accepted_sender, :deliver_response)
    results = Enum.map(calls, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert {:error, :attempt_already_dispatched} in results
    assert Enum.count(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit")) == 1
    assert %{attempts: [%{state: "succeeded"}]} = observe(observer, agent)
  end

  test "retry preparation consumes absence once and survives interruption before send", %{
    conn: conn
  } do
    game = start_supervised!({Game, orbit_timeout: true})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    observer = start_observer()
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
    pause_preparation()
    test_pid = self()

    {boot_caller, _monitor} =
      spawn_monitor(fn -> send(test_pid, {:boot_result, ShipServerBoot.start_link([])}) end)

    on_exit(fn -> if Process.alive?(boot_caller), do: Process.exit(boot_caller, :kill) end)

    assert_receive {:prepared, sender, retry_id, backend, false}, 10_000

    snapshot = observe(observer, agent)
    assert snapshot.backend != backend
    assert [absent, retry] = snapshot.attempts
    assert absent.id == original.id
    assert absent.state == "absent"
    refute absent.retry_authorized
    assert retry.id == retry_id
    assert retry.state == "prepared"
    assert retry.retry_of_id == absent.id
    assert [intent] = snapshot.intents
    assert intent.mutation_attempt_id == retry_id
    kill_sender(sender)
    assert snapshot == observe(observer, agent)

    calls =
      for _ <- 1..2 do
        Task.async(fn -> RecordedDispatch.prepare_retry(agent, intent, absent) end)
      end

    assert Enum.map(calls, &Task.await(&1)) == [
             {:error, :retry_not_authorized},
             {:error, :retry_not_authorized}
           ]

    assert snapshot == observe(observer, agent)
    assert Game.snapshot(game).status == "DOCKED"
    assert Enum.count(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit")) == 1
  end

  for loss <- [
        :claim,
        :generation,
        :revision,
        :selection,
        :singleton,
        :intervention,
        :portfolio_version
      ] do
    @loss loss
    test "#{loss} authority lost after preparation suppresses stale dispatch", %{conn: conn} do
      {game, observer, agent, intent, attempt, sender} = paused_first_preparation(conn)
      revoke_authority(@loss, agent, intent)
      send(sender, :continue_dispatch)

      assert_eventually(fn ->
        SpaceTraders.MutationAttempts.get!(attempt.id).state == "not_sent"
      end)

      assert %{attempts: [%{state: "not_sent", sent_or_unknown_at: nil}]} =
               observe(observer, agent)

      assert [%{classification: "not_sent"}] =
               SpaceTraders.MutationAttempts.get!(attempt.id).outcomes

      refute Enum.any?(Game.snapshot(game).requests, &String.ends_with?(&1.path, "/orbit"))
      assert Game.snapshot(game).status == "DOCKED"
    end
  end

  defp revoke_authority(:claim, _agent, intent) do
    Repo.get!(SpaceTraders.FleetAllocation.Portfolio, intent.fleet_commitment_portfolio_id)
    |> Ecto.Changeset.change(superseded_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke_authority(:generation, agent, _intent) do
    Repo.get_by!(SpaceTraders.FleetGeneration.Generation, agent_id: agent.id)
    |> Ecto.Changeset.change(fenced_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke_authority(:revision, agent, _intent) do
    scope = SpaceTraders.Agent.Scope.for_operator(Repo.get!(Operator, agent.operator_id))
    {:ok, strategy} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, _revision} = SpaceTraders.FleetStrategy.activate(scope, strategy.draft_version)
  end

  defp revoke_authority(:selection, _agent, intent) do
    # A stale callback races a superseding selected result, not a new request.
    intent |> Ecto.Changeset.change(in_flight_action: nil) |> Repo.update!()
  end

  defp revoke_authority(:singleton, _agent, _intent) do
    previous = Application.get_env(:spacetraders, SpaceTraders.RuntimeAuthority)
    Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, enabled: true)
    on_exit(fn -> Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, previous) end)

    assert {:error, :runtime_authority_unavailable} =
             SpaceTraders.RuntimeAuthority.execution_allowed?()
  end

  defp revoke_authority(:intervention, _agent, intent) do
    intent
    |> Ecto.Changeset.change(
      caller: "intervention",
      fleet_commitment_id: nil,
      fleet_commitment_portfolio_id: nil,
      fleet_commitment_portfolio_version: nil
    )
    |> Repo.update!()
  end

  defp revoke_authority(:portfolio_version, _agent, intent) do
    intent
    |> Ecto.Changeset.change(
      fleet_commitment_portfolio_version: intent.fleet_commitment_portfolio_version + 1
    )
    |> Repo.update!()
  end

  defp paused_first_preparation(conn) do
    game = start_supervised!({Game, []})
    stub_api(fn conn -> Game.reply(conn, Game.call(game, conn)) end)
    allow_game_runtime()
    observer = start_observer()
    pause_preparation()
    start_runtime()
    {_conn, agent} = activate_fresh_generation(conn)
    assert_receive {:prepared, sender, attempt_id, _backend, false}, 10_000
    %{attempts: [attempt], intents: [intent]} = observe(observer, agent)
    assert attempt.id == attempt_id
    {game, observer, agent, intent, attempt, sender}
  end

  def pause(_event, _measurements, metadata, test_pid) do
    Repo.checkout(fn ->
      [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      send(test_pid, {:prepared, self(), metadata.attempt_id, backend, Repo.in_transaction?()})

      receive do
        :continue_dispatch -> :ok
      after
        10_000 -> raise("preparation interruption was not released")
      end
    end)
  end

  defp start_observer do
    test_pid = self()

    observer =
      start_supervised!(
        {Task,
         fn ->
           :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

           try do
             [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
             send(test_pid, {:observer_ready, self()})
             observe_loop(test_pid, backend)
           after
             Ecto.Adapters.SQL.Sandbox.checkin(Repo)
           end
         end}
      )

    assert_receive {:observer_ready, ^observer}
    observer
  end

  defp observe_loop(test_pid, backend) do
    receive do
      {:observe, agent, operation_id} ->
        attempts =
          Repo.all(
            from a in Attempt,
              where: a.agent_id == ^agent.id and a.operation_id == ^operation_id,
              order_by: a.prepared_at
          )

        intents =
          Repo.all(
            from i in Intent,
              join: s in SpaceTraders.Fleet.Ship,
              on: s.id == i.ship_id,
              where: s.agent_id == ^agent.id and i.status in ^Intent.unfinished_states()
          )

        send(
          test_pid,
          {:snapshot, self(), %{backend: backend, attempts: attempts, intents: intents}}
        )

        observe_loop(test_pid, backend)
    end
  end

  defp observe(observer, agent, operation_id \\ "orbit-ship") do
    send(observer, {:observe, agent, operation_id})
    assert_receive {:snapshot, ^observer, snapshot}, 5_000
    snapshot
  end

  defp kill_sender(sender) do
    monitor = Process.monitor(sender)
    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}
  end

  defp activate_fresh_generation(conn) do
    email = "dispatch-504-#{System.unique_integer([:positive])}@example.com"

    conn =
      post(conn, ~p"/setup", %{
        "operator" => %{
          "email" => email,
          "password" => "a long dispatch password",
          "password_confirmation" => "a long dispatch password",
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
    # Fault injection owns process lifetimes. Production modules still own all
    # planning and selection; killed coordinators do not restart mid-inspection.
    start_supervised!(Supervisor.child_spec({Reconciler, []}, restart: :temporary))
    start_supervised!({DemandScheduler, []})
  end

  defp allow_game_runtime do
    Req.Test.allow(SpaceTraders.API, self(), fn ->
      runtime_pids = [Process.whereis(Reconciler), Process.whereis(ShipServerBoot)]

      ships =
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

      Enum.filter(runtime_pids ++ ships, &is_pid/1)
    end)
  end
end
