defmodule SpaceTraders.FleetGenerationTest do
  # Admission caches are shared and DataCase clears them after each sandbox closes.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.Fleet.{Intent, Intents, Ship}
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.OperatorConditions
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Repo

  import Ecto.Query, only: [from: 2]

  test "missing replacement authority remains a durable Intervention until authority is restored" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)

    assert {:error, :account_token_not_linked} =
             FleetGeneration.mint(scope, %{symbol: "NEEDSKEY", faction: "COSMIC"})

    assert [%{kind: :intervention, summary: summary}] =
             OperatorConditions.unresolved(scope)

    assert summary =~ "AccountToken"

    {:ok, operator} =
      Agent.link_account_token(Scope.for_operator(operator), "ACCOUNT_TOKEN_SECRET")

    scope = Scope.for_operator(operator)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, registration_body("NEEDSKEY", "NEEDSKEY-1", "TOKEN"))
    end)

    assert {:ok, _} = FleetGeneration.mint(scope, %{symbol: "NEEDSKEY", faction: "COSMIC"})
    assert OperatorConditions.unresolved(scope) == []
  end

  test "only a complete owned Objective evaluation can create Attention" do
    owner = operator_fixture()
    scope = Scope.for_operator(owner)
    other_scope = Scope.for_operator(%SpaceTraders.Agent.Operator{id: -1})
    {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    agent = agent_fixture(owner, %{agent_token: nil})

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%FleetGeneration.Generation{
        operator_id: owner.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{"symbols" => [agent.symbol]},
        starting_credits: 175_000
      })

    assert {:error, :invalid_objective_progress} =
             FleetGeneration.record_objective_progress(scope, generation.id, 0, %{
               "feasible?" => false
             })

    evidence = objective_evidence(agent)

    facts = %{
      "change" => 0,
      "elapsed_seconds" => 60,
      "horizon_seconds" => 3600,
      "feasible?" => false,
      "evidence_id" => evidence.id
    }

    assert {:error, :invalid_objective_progress} =
             FleetGeneration.record_objective_progress(other_scope, generation.id, 0, facts)

    assert Repo.get!(FleetGeneration.Generation, generation.id).objective_progress == %{}
    assert SpaceTraders.OperatorConditions.unresolved(scope) == []
  end

  describe "Server Reset" do
    setup context do
      faction = Map.get(context, :reset_faction, "COSMIC")

      if context[:recap_clock] do
        start_supervised!({SpaceTraders.TestClock, DateTime.add(DateTime.utc_now(:second), -60)})
        previous = Application.get_env(:spacetraders, :clock)
        Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:spacetraders, :clock, previous),
            else: Application.delete_env(:spacetraders, :clock)
        end)
      end

      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(Scope.for_operator(operator), "ACCOUNT_TOKEN_SECRET")

      scope = Scope.for_operator(operator)
      {:ok, strategy} = FleetStrategy.select_preset(scope, "charted_expansion")
      {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {conn.method, conn.request_path, conn.body_params["symbol"]} ==
                 {"POST", "/v2/register", "RESETME"}

        Req.Test.json(conn, registration_body("RESETME", "RESETME-1", "FIRST_TOKEN", faction))
      end)

      {:ok, %{agent: minted}} =
        FleetGeneration.mint(scope, %{symbol: "RESETME", faction: faction})

      %{scope: scope, revision: revision, agent: Repo.get!(SpaceTraders.Agent.Agent, minted.id)}
    end

    test "same-name replacement is a distinct Generation; the predecessor and its Ships remain history",
         %{scope: scope, revision: revision, agent: agent} do
      {:ok, predecessor_ship} = Fleet.owned_ship(agent, "RESETME-1")
      [predecessor] = FleetGeneration.list_generations(scope)

      assert {:ok, _} =
               FleetGeneration.record_objective_progress(scope, predecessor.id, 0, %{
                 "current" => 4,
                 "target" => 10,
                 "expected_seconds_to_target" => 500,
                 "feasible?" => true,
                 "evidence_id" => objective_evidence(agent).id
               })

      game(fn
        %{method: "GET", request_path: "/v2/my/agent"} = conn ->
          reset_mismatch(conn)

        %{method: "POST", request_path: "/v2/register"} = conn ->
          Req.Test.json(conn, registration_body("RESETME", "RESETME-1", "SECOND_TOKEN"))
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert registrations() == [{"RESETME", "COSMIC"}]

      assert {:ok, %{state: :current, agent: replacement, generation: current}} =
               FleetGeneration.current_fleet()

      assert replacement.symbol == "RESETME"
      assert replacement.id != agent.id
      assert current.agent_id == replacement.id
      assert current.number == 2
      assert current.symbol == "RESETME"
      assert current.faction == "COSMIC"
      assert current.fleet_strategy_revision_id == revision.id
      assert current.objective_progress["0"] == nil

      assert %{"current" => 4} =
               List.last(FleetGeneration.list_generations(scope)).objective_progress["0"]

      assert SpaceTraders.FleetAllocation.active_generation(replacement).id == current.id
      assert SpaceTraders.FleetAllocation.active_generation(agent) == nil

      # Fresh resources: the reused Ship symbol is the replacement's own Ship.
      assert {:ok, ship} = Fleet.owned_ship(replacement, "RESETME-1")
      assert ship.id != predecessor_ship.id

      # The predecessor is retained, stale and retired, as attributable history.
      assert {:ok, %{agent: retained, generation: retired}} =
               FleetGeneration.generation_evidence(scope, predecessor.id)

      assert FleetGeneration.stale?(retained)
      assert retired.number == 1
      assert %DateTime{} = retired.fenced_at
      assert %DateTime{} = retired.retired_at
      assert Repo.get!(Ship, predecessor_ship.id).agent_id == agent.id

      # Its credential carries no authority over anything, including reused symbols.
      assert {:error, :stale_agent} =
               SpaceTraders.API.accept_contract(AgentTokenReference.new(retained), "c1")

      assert {:error, :stale_agent} = FleetGeneration.execution_allowed?(retained)
    end

    test "late predecessor navigation retains evidence without replacing the successor arrival",
         %{scope: scope, agent: agent} do
      alias SpaceTraders.{ShipReservation, Timeline}
      alias SpaceTraders.Fleet.ShipServer

      {:ok, ship} = Fleet.owned_ship(agent, "RESETME-1")
      {:ok, reservation} = ShipReservation.reserve(scope, ship.id, "Late navigation")

      intent =
        Repo.insert!(%Intent{
          ship_id: ship.id,
          caller: "intervention",
          type: "navigate",
          status: "active",
          target_waypoint: "X1-UX81-A2",
          parameters: %{"reason" => "Late navigation"}
        })

      Repo.insert!(%SpaceTraders.ManualIntervention{
        ship_reservation_id: reservation.id,
        intent_id: intent.id,
        reason: "Late navigation",
        target_waypoint: "X1-UX81-A2"
      })

      live_ship =
        SpaceTraders.API.Model.Ship.from_json(SpaceTraders.ShipBody.ship_body(ship.symbol))

      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            reset_mismatch(conn)

          "/v2/register" ->
            Req.Test.json(conn, registration_body("RESETME", ship.symbol, "SECOND_TOKEN"))

          "/v2/my/ships/RESETME-1/navigate" ->
            send(parent, {:accepted_navigation, self()})

            receive do
              :deliver -> :ok
            after
              5000 -> flunk("Navigation response was not released")
            end

            nav =
              SpaceTraders.ShipBody.nav_body("IN_TRANSIT",
                arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                destination: "X1-UX81-A2"
              )

            Req.Test.json(conn, %{
              "data" => %{"nav" => nav, "fuel" => %{"capacity" => 200, "current" => 80}}
            })
        end
      end)

      sender =
        Task.async(fn ->
          Intents.execute_action(agent, intent, live_ship, %{
            "kind" => "navigate",
            "waypoint" => "X1-UX81-A2"
          })
        end)

      Req.Test.allow(SpaceTraders.API, self(), sender.pid)
      assert_receive {:accepted_navigation, pid}, 5000
      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      {:ok, %{agent: successor}} = FleetGeneration.current_fleet(scope)
      {:ok, _} = ShipServer.ensure_started(successor, ship.symbol)

      {:ok, arrival} =
        Timeline.schedule_event(
          :ship,
          ship.symbol,
          :arrival,
          DateTime.add(DateTime.utc_now(), 600),
          %{"intent_id" => -1}
        )

      send(pid, :deliver)
      Task.await(sender)
      assert Timeline.pending?(arrival)

      refute Enum.any?(
               Timeline.pending_events(:ship, ship.symbol),
               &(&1.payload["intent_id"] == intent.id)
             )

      assert Repo.get!(Ship, ship.id).agent_id == agent.id
      completed = Repo.get!(Intent, intent.id)
      attempt = SpaceTraders.MutationAttempts.get!(completed.mutation_attempt_id)
      assert attempt.agent_id == agent.id
      assert attempt.state == "succeeded"

      assert [%{classification: "succeeded", evidence: %{"nav_status" => "IN_TRANSIT"}}] =
               attempt.outcomes
    end

    @tag reset_faction: "VOID"
    test "definitive conflicts preserve faction through distinct banked names in order, without suffixes",
         %{scope: scope, revision: revision, agent: agent} do
      {:ok, _} = SpaceTraders.AgentNameBank.save(["ORBITALIST", "RESETME", "PARALLAX", "LIMINAL"])

      game(fn
        %{method: "GET"} = conn ->
          reset_mismatch(conn)

        %{body_params: %{"symbol" => symbol}} = conn when symbol in ["RESETME", "ORBITALIST"] ->
          symbol_unavailable(conn)

        %{body_params: %{"symbol" => "PARALLAX"}} = conn ->
          Req.Test.json(conn, registration_body("PARALLAX", "PARALLAX-1", "SECOND_TOKEN", "VOID"))
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)

      assert registrations() == [
               {"RESETME", "VOID"},
               {"ORBITALIST", "VOID"},
               {"PARALLAX", "VOID"}
             ]

      assert [current, retired] = FleetGeneration.list_generations(scope)
      assert current.symbol == "PARALLAX"
      assert current.faction == "VOID"
      assert current.fleet_strategy_revision_id == revision.id
      assert retired.agent_id == agent.id
      assert %DateTime{} = retired.retired_at
      assert FleetStrategy.get(scope).active_revision == revision
      assert OperatorConditions.unresolved(scope) == []
    end

    test "exhausted names leave a durable Intervention with no retry loop until the Operator retries",
         %{scope: scope, revision: revision, agent: agent} do
      {:ok, _} = SpaceTraders.AgentNameBank.save(["ORBITALIST", "PARALLAX"])

      game(fn
        %{method: "GET"} = conn -> reset_mismatch(conn)
        %{method: "POST"} = conn -> symbol_unavailable(conn)
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)

      assert registrations() == [
               {"RESETME", "COSMIC"},
               {"ORBITALIST", "COSMIC"},
               {"PARALLAX", "COSMIC"}
             ]

      assert [%{kind: :intervention, summary: summary}] = OperatorConditions.unresolved(scope)
      assert summary =~ "Agent Name Bank"
      assert {:ok, %{state: :transition, generation: fenced}} = FleetGeneration.current_fleet()
      assert fenced.agent_id == agent.id
      assert %DateTime{} = fenced.fenced_at
      assert is_nil(fenced.retired_at)

      # The fenced predecessor sends nothing more, so nothing re-triggers minting.
      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert {:error, :stale_agent} = Agent.handle_game_result(agent, {:error, reset_error()})
      refute_received {:game_request, _, _, _}

      {:ok, _} = SpaceTraders.AgentNameBank.save(["SIDEREAL"])

      game(fn %{body_params: %{"symbol" => symbol}} = conn ->
        if symbol == "SIDEREAL",
          do: Req.Test.json(conn, registration_body("SIDEREAL", "SIDEREAL-1", "NEXT_TOKEN")),
          else: symbol_unavailable(conn)
      end)

      assert {:ok, %{agent: %{symbol: "SIDEREAL"}}} = FleetGeneration.replace_after_reset(scope)
      assert registrations() == [{"RESETME", "COSMIC"}, {"SIDEREAL", "COSMIC"}]
      assert OperatorConditions.unresolved(scope) == []

      assert {:ok, %{state: :current, generation: %{fleet_strategy_revision_id: revision_id}}} =
               FleetGeneration.current_fleet()

      assert revision_id == revision.id
    end

    test "an uncertain registration is never followed by another candidate or a remint",
         %{scope: scope, agent: agent} do
      game(fn
        %{method: "GET"} = conn -> reset_mismatch(conn)
        %{method: "POST"} = conn -> Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert registrations() == [{"RESETME", "COSMIC"}]

      assert %{status: :unresolved, symbol: "RESETME"} =
               FleetGeneration.registration_recovery(scope)

      assert {:error, :registration_unresolved} = FleetGeneration.replace_after_reset(scope)
      assert {:error, :registration_unresolved} = FleetGeneration.replace_after_reset(scope)
      refute_received {:game_request, _, _, _}
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet()
    end

    test "an unrelated rejection stops at that candidate without trying another name",
         %{scope: scope, agent: agent} do
      game(fn
        %{method: "GET"} = conn ->
          reset_mismatch(conn)

        %{method: "POST"} = conn ->
          conn
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{"error" => %{"code" => 422, "message" => "Invalid faction"}})
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert registrations() == [{"RESETME", "COSMIC"}]
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet()
      assert %{status: :clear} = FleetGeneration.registration_recovery(scope)

      assert [%{kind: :intervention, summary: summary}] = OperatorConditions.unresolved(scope)
      assert summary =~ "Retry replacement"
    end

    test "recovering a lost replacement response clears earlier replacement Interventions",
         %{scope: scope, agent: agent} do
      {:ok, _} = SpaceTraders.AgentNameBank.save(["ORBITALIST"])

      game(fn
        %{method: "GET"} = conn -> reset_mismatch(conn)
        %{method: "POST"} = conn -> symbol_unavailable(conn)
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert [%{key: "replacement-symbols"}] = OperatorConditions.unresolved(scope)
      assert registrations() == [{"RESETME", "COSMIC"}, {"ORBITALIST", "COSMIC"}]

      game(fn conn -> Req.Test.transport_error(conn, :timeout) end)
      assert {:error, :registration_unresolved} = FleetGeneration.replace_after_reset(scope)
      assert registrations() == [{"RESETME", "COSMIC"}]

      game(fn conn ->
        body = registration_body("RESETME", "RESETME-1", "RECOVERED_TOKEN")["data"]

        case conn.request_path do
          "/v2/my/agent" -> Req.Test.json(conn, %{"data" => body["agent"]})
          "/v2/my/ships" -> Req.Test.json(conn, %{"data" => body["ships"]})
        end
      end)

      assert {:ok, %{agent: replacement}} =
               FleetGeneration.adopt_registered_agent(scope, "RECOVERED_TOKEN", true)

      assert replacement.id != agent.id
      assert {:ok, %{state: :current}} = FleetGeneration.current_fleet(scope)
      assert registrations() == []
      assert OperatorConditions.unresolved(scope) == []
    end

    test "ordinary authentication and network failures are not Server Reset evidence",
         %{scope: scope, agent: agent} do
      game(fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => 4104, "message" => "Token is invalid"}})
      end)

      assert {:error, %SpaceTraders.API.GameplayError{}} = FleetGeneration.agent_overview(agent)

      game(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:error, _network} = FleetGeneration.agent_overview(agent)

      assert Enum.all?(drain_requests(), &match?({"GET", "/v2/my/agent", _}, &1))
      assert {:ok, %{state: :current, agent: %{id: id}}} = FleetGeneration.current_fleet()
      assert id == agent.id
      refute FleetGeneration.stale?(Repo.get!(SpaceTraders.Agent.Agent, agent.id))
      assert {:error, :no_server_reset} = FleetGeneration.replace_after_reset(scope)
    end

    test "missing AccountToken authority raises a durable Intervention before any registration",
         %{scope: scope, agent: agent} do
      Repo.update_all(
        from(o in SpaceTraders.Agent.Operator, where: o.id == ^scope.operator.id),
        set: [account_token: nil]
      )

      game(&reset_mismatch/1)
      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert registrations() == []
      assert [%{kind: :intervention, summary: summary}] = OperatorConditions.unresolved(scope)
      assert summary =~ "AccountToken"
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet()
    end

    test "late predecessor results after replacement neither fence nor replace the successor",
         %{scope: scope, agent: agent} do
      game(fn
        %{method: "GET"} = conn ->
          reset_mismatch(conn)

        %{method: "POST"} = conn ->
          Req.Test.json(conn, registration_body("RESETME", "RESETME-1", "SECOND_TOKEN"))
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert {:ok, %{state: :current, generation: successor}} = FleetGeneration.current_fleet()
      _ = drain_requests()

      # A response dispatched before the fence arrives late with reset evidence.
      assert {:error, :stale_agent} =
               FleetGeneration.handle_game_result(agent, {:error, reset_error()})

      assert {:ok, %{state: :current, generation: still}} = FleetGeneration.current_fleet()
      assert still.id == successor.id
      assert is_nil(still.fenced_at)
      assert registrations() == []
      assert {:error, :no_server_reset} = FleetGeneration.replace_after_reset(scope)
    end

    test "Strategy-lifetime contributions carry forward; generation and recurring progress restart",
         %{scope: scope, agent: agent} do
      strategy = FleetStrategy.get(scope)
      {:ok, draft} = FleetStrategy.select_preset(scope, "charted_expansion")

      preset = Enum.find(FleetStrategy.presets(), &(&1.id == "charted_expansion"))
      [first | rest] = preset.objectives

      document = %{
        "objectives" => [Map.put(first, "scope", "strategy_lifetime") | rest],
        "hard_constraints" => preset.hard_constraints,
        "preferences" => preset.preferences,
        "consequences" => preset.consequences
      }

      {:ok, saved} = FleetStrategy.save_draft(scope, document, draft.draft_version)
      {:ok, lifetime} = FleetStrategy.activate(scope, saved.draft_version)
      assert lifetime.number == strategy.active_revision.number + 1
      [generation] = FleetGeneration.list_generations(scope)

      assert {:ok, _} =
               FleetGeneration.record_objective_progress(scope, generation.id, 0, %{
                 "current" => 4,
                 "target" => 10,
                 "expected_seconds_to_target" => 500,
                 "feasible?" => true,
                 "evidence_id" => objective_evidence(agent).id
               })

      assert {:ok, _} =
               FleetGeneration.record_objective_progress(scope, generation.id, 1, %{
                 "change" => 120,
                 "elapsed_seconds" => 60,
                 "horizon_seconds" => 3600,
                 "feasible?" => true,
                 "evidence_id" => objective_evidence(agent, 175_120).id
               })

      game(fn
        %{method: "GET"} = conn ->
          reset_mismatch(conn)

        %{method: "POST"} = conn ->
          Req.Test.json(conn, registration_body("RESETME", "RESETME-1", "SECOND_TOKEN"))
      end)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert [current, retired] = FleetGeneration.list_generations(scope)
      assert current.fleet_strategy_revision_id == lifetime.id
      assert %{"current" => 4} = current.objective_progress["0"]
      assert current.objective_progress["1"] == %{"recurrence_id" => nil, "progress" => nil}
      assert %{"current" => 4} = retired.objective_progress["0"]
      assert %{"change" => 120} = retired.objective_progress["1"]
    end

    @tag recap_clock: true
    test "a Revision activated after replacement governs only the current Generation; history keeps its original Revision",
         %{scope: scope, revision: revision, agent: agent} do
      Req.Test.stub(SpaceTraders.API, &reset_then_fallback_response/1)
      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert [current, retired] = FleetGeneration.list_generations(scope)

      assert {:ok, %{state: :current, generation: %{id: current_id}}} =
               FleetGeneration.current_fleet()

      assert current_id == current.id

      # The first Revision predates establishment. Activate the next one in
      # exactly the successor's establishment second, independent of wall time.
      SpaceTraders.TestClock.advance(
        DateTime.diff(current.inserted_at, SpaceTraders.TestClock.utc_now(), :second)
      )

      {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
      assert {:ok, next} = FleetStrategy.activate(scope, draft.draft_version)
      assert next.number == revision.number + 1

      assert [current_after, retired_after] = FleetGeneration.list_generations(scope)
      assert current_after.id == current.id
      assert current_after.fleet_strategy_revision_id == next.id
      assert current_after.initial_fleet_strategy_revision_id == revision.id
      assert retired_after.id == retired.id
      assert retired_after.fleet_strategy_revision_id == revision.id
      assert retired_after.retired_at == retired.retired_at

      recaps =
        Map.new(SpaceTraders.MissionControl.generation_recaps(scope), &{&1.generation.id, &1})

      assert recaps[retired.id].revisions == [revision.number]
      assert recaps[current.id].revisions == [revision.number, next.number]

      game(fn conn ->
        Req.Test.json(conn, registration_body("ORBITALIST", "ORBITALIST-1", "THIRD_TOKEN"))
      end)

      successor_agent = Repo.get!(SpaceTraders.Agent.Agent, current.agent_id)

      assert {:error, :stale_agent} =
               FleetGeneration.handle_game_result(successor_agent, {:error, reset_error()})

      [third | _] = FleetGeneration.list_generations(scope)
      assert third.initial_fleet_strategy_revision_id == next.id
      [third_recap | _] = SpaceTraders.MissionControl.generation_recaps(scope)
      assert third_recap.revisions == [next.number]
    end

    test "Emergency Stop suppresses replacement minting until resume, preserving the Strategy",
         %{scope: scope, revision: revision, agent: agent} do
      assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)
      game(&reset_then_fallback_response/1)

      assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
      assert registrations() == []
      assert {:error, :emergency_stopped} = FleetGeneration.replace_after_reset(scope)
      assert {:error, :emergency_stopped} = FleetGeneration.replace_after_reset(scope)
      assert registrations() == []

      assert {:ok, %{state: :transition, generation: fenced}} = FleetGeneration.current_fleet()
      assert fenced.agent_id == agent.id
      assert FleetStrategy.get(scope).active_revision == revision
      assert FleetStrategy.get(scope).emergency_stopped_at == stopped.emergency_stopped_at

      assert {:ok, prepared} = FleetStrategy.resume(scope, stopped.emergency_stop_version)

      assert {:ok, _resumed} =
               FleetStrategy.complete_emergency_stop_resume(
                 scope,
                 prepared.emergency_stop_version
               )

      assert registrations() == [{"RESETME", "COSMIC"}, {"ORBITALIST", "COSMIC"}]

      assert {:ok, %{state: :current, agent: %{symbol: "ORBITALIST"}}} =
               FleetGeneration.current_fleet()
    end
  end

  test "activating Strategy makes an already bootstrapped Fleet Generation Strategy-capable" do
    operator = operator_fixture()

    {:ok, operator} =
      Agent.link_account_token(Scope.for_operator(operator), "ACCOUNT_TOKEN_SECRET")

    scope = Scope.for_operator(operator)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, registration_body("READY", "READY-1", "READY_TOKEN"))
    end)

    assert {:ok, %{agent: agent}} =
             FleetGeneration.mint(scope, %{symbol: "READY", faction: "COSMIC"})

    assert [
             %{
               fleet_strategy_revision_id: nil,
               strategy_capable_at: nil,
               replacement_symbols: %{"symbols" => ["READY"]}
             }
           ] =
             FleetGeneration.list_generations(scope)

    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_intelligence_evidence")

    assert {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    assert_receive {:waypoint_intelligence_observed, agent_id, "X1-UX81"}
    assert agent_id == agent.id

    assert [%{fleet_strategy_revision_id: revision_id, strategy_capable_at: capable_at}] =
             FleetGeneration.list_generations(scope)

    assert revision_id == revision.id
    assert %DateTime{} = capable_at
  end

  test "Emergency Stop blocks Agent mutations and replacement minting while reads continue" do
    operator = operator_fixture()

    {:ok, operator} =
      Agent.link_account_token(Scope.for_operator(operator), "ACCOUNT_TOKEN_SECRET")

    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "AGENT_TOKEN_SECRET"})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => agent.symbol,
          "headquarters" => agent.headquarters,
          "credits" => 175_000,
          "startingFaction" => agent.faction,
          "shipCount" => 1
        }
      })
    end)

    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)
    assert :ok = Agent.execution_allowed?(agent)

    assert {:error, :emergency_stopped} =
             SpaceTraders.API.accept_contract(AgentTokenReference.new(agent), "contract-1")

    assert {:error, :emergency_stopped} =
             FleetGeneration.mint(scope, %{symbol: "REPLACEMENT", faction: "COSMIC"})

    assert {:ok, game_agent} = FleetGeneration.agent_overview(agent)
    assert game_agent.symbol == agent.symbol
  end

  test "Emergency Stop survives definitive Server Reset detection" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "STOP_RESET_AGENT_TOKEN"})
    ship = Repo.insert!(%Ship{symbol: "RESET-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate"}
      })

    Req.Test.stub(SpaceTraders.API, &reset_mismatch/1)

    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
    assert FleetStrategy.get(scope).emergency_stopped_at == stopped.emergency_stopped_at

    assert {:ok, prepared} = FleetStrategy.resume(scope, stopped.emergency_stop_version)
    assert prepared.emergency_stopped_at == stopped.emergency_stopped_at
    assert %DateTime{} = prepared.emergency_resume_prepared_at

    assert Enum.any?(Intents.history(agent), fn candidate ->
             candidate.id == intent.id and
               candidate.status == "superseded" and
               candidate.last_action_result == %{"outcome" => "reset_censored"}
           end)
  end

  test "Emergency Stop suppresses a mutation retry waiting on Retry-After" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "RETRY_AGENT_TOKEN"})
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, :mutation_attempted)
      assert_receive :release_rate_limit_response

      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
    end)

    %{attempt: attempt} =
      SpaceTraders.RecordedDispatchFixtures.prepare_action(agent, "SHIP-1", %{
        "kind" => "navigate",
        "waypoint" => "X1-UX81-A2"
      })

    request = Task.async(fn -> SpaceTraders.API.dispatch_recorded(attempt) end)

    assert_receive :mutation_attempted
    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)
    send(request.pid, :release_rate_limit_response)
    assert Task.await(request, 2_000) == {:error, :emergency_stopped}
    refute_receive :mutation_attempted
  end

  test "an AgentToken imported during Emergency Stop remains suppressed" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "IMPORTED",
              "headquarters" => "X1-UX81-A1",
              "credits" => 175_000,
              "startingFaction" => "COSMIC",
              "shipCount" => 0
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{
            "data" => [],
            "meta" => %{"total" => 0, "page" => 1, "limit" => 20}
          })
      end
    end)

    assert {:ok, imported} = FleetGeneration.import_agent(scope, "IMPORTED_AGENT_TOKEN", true)

    assert {:error, :emergency_stopped} =
             SpaceTraders.API.accept_contract(AgentTokenReference.new(imported), "contract-1")
  end

  test "mints through a credential reference without exposing the AccountToken" do
    operator = operator_fixture()

    {:ok, operator} =
      Agent.link_account_token(Scope.for_operator(operator), "ACCOUNT_TOKEN_SECRET")

    scope = Scope.for_operator(operator)

    assert scope.operator.account_token == nil

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ACCOUNT_TOKEN_SECRET"]

      Req.Test.json(conn, %{
        "data" => %{
          "token" => "AGENT_TOKEN_SECRET",
          "agent" => %{
            "symbol" => "NEWSYM",
            "credits" => 175_000,
            "headquarters" => "X1-UX81-A2",
            "startingFaction" => "COSMIC"
          },
          "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
          "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
          "ships" => []
        }
      })
    end)

    assert {:ok, %{agent: agent, retired_symbols: []}} =
             FleetGeneration.mint(scope, %{symbol: "NEWSYM", faction: "COSMIC"})

    assert agent.symbol == "NEWSYM"
    assert agent.agent_token == nil
    refute inspect(agent) =~ "ACCOUNT_TOKEN_SECRET"
    refute inspect(agent) =~ "AGENT_TOKEN_SECRET"
  end

  test "is the sole production owner of registration" do
    callers =
      "lib/spacetraders/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "SpaceTraders.API.register("))

    assert callers == ["lib/spacetraders/fleet_generation.ex"]
  end

  test "does not expose the AgentToken when the minted Agent cannot be stored" do
    operator = operator_fixture()

    {:ok, operator} =
      Agent.link_account_token(Scope.for_operator(operator), "ACCOUNT_TOKEN_SECRET")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "token" => "AGENT_TOKEN_SECRET",
          "agent" => %{
            "symbol" => "NEWSYM",
            "credits" => 175_000,
            "headquarters" => "X1-UX81-A2",
            "startingFaction" => ""
          },
          "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
          "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
          "ships" => []
        }
      })
    end)

    assert {:error, %Ecto.Changeset{} = changeset} =
             FleetGeneration.mint(Scope.for_operator(operator), %{
               symbol: "NEWSYM",
               faction: "COSMIC"
             })

    assert Ecto.Changeset.get_change(changeset, :agent_token) == nil
    refute inspect(changeset) =~ "AGENT_TOKEN_SECRET"
    refute Repo.get_by(SpaceTraders.Agent.Agent, symbol: "NEWSYM")
  end

  defp registration_body(agent_symbol, ship_symbol, token, faction \\ "COSMIC") do
    %{
      "data" => %{
        "token" => token,
        "agent" => %{
          "symbol" => agent_symbol,
          "credits" => 175_000,
          "headquarters" => "X1-UX81-A2",
          "startingFaction" => faction
        },
        "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
        "faction" => %{"symbol" => faction, "name" => faction, "isRecruiting" => true},
        "ships" => [
          %{
            "symbol" => ship_symbol,
            "registration" => %{
              "name" => ship_symbol,
              "factionSymbol" => faction,
              "role" => "COMMAND"
            },
            "nav" => %{
              "systemSymbol" => "X1-UX81",
              "waypointSymbol" => "X1-UX81-A2",
              "route" => %{
                "destination" => %{
                  "symbol" => "X1-UX81-A2",
                  "type" => "PLANET",
                  "systemSymbol" => "X1-UX81",
                  "x" => 0,
                  "y" => 0
                },
                "origin" => %{
                  "symbol" => "X1-UX81-A2",
                  "type" => "PLANET",
                  "systemSymbol" => "X1-UX81",
                  "x" => 0,
                  "y" => 0
                },
                "departureTime" => "2026-09-15T00:00:00.000Z",
                "arrival" => "2026-09-15T00:00:00.000Z"
              },
              "status" => "DOCKED",
              "flightMode" => "CRUISE"
            },
            "crew" => %{
              "current" => 1,
              "required" => 1,
              "capacity" => 1,
              "rotation" => "STRICT",
              "morale" => 100,
              "wages" => 0
            },
            "frame" => %{
              "symbol" => "FRAME_PROBE",
              "name" => "Probe",
              "description" => "Probe",
              "condition" => 100,
              "integrity" => 100,
              "moduleSlots" => 0,
              "mountingPoints" => 0,
              "fuelCapacity" => 0,
              "requirements" => %{"power" => 0, "crew" => 0, "slots" => 0}
            },
            "reactor" => %{
              "symbol" => "REACTOR_SOLAR_I",
              "name" => "Solar",
              "description" => "Solar",
              "condition" => 100,
              "integrity" => 100,
              "powerOutput" => 1,
              "requirements" => %{"power" => 0, "crew" => 0, "slots" => 0}
            },
            "engine" => %{
              "symbol" => "ENGINE_IMPULSE_DRIVE_I",
              "name" => "Impulse",
              "description" => "Impulse",
              "condition" => 100,
              "integrity" => 100,
              "speed" => 1,
              "requirements" => %{"power" => 0, "crew" => 0, "slots" => 0}
            },
            "modules" => [],
            "mounts" => [],
            "cargo" => %{"capacity" => 0, "units" => 0, "inventory" => []},
            "fuel" => %{"current" => 0, "capacity" => 0, "consumed" => %{"amount" => 0}},
            "cooldown" => %{
              "shipSymbol" => ship_symbol,
              "totalSeconds" => 0,
              "remainingSeconds" => 0
            }
          }
        ]
      }
    }
  end

  # Records every game request at the HTTP boundary, then answers with `respond`.
  defp game(respond) do
    parent = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(
        parent,
        {:game_request, conn.method, conn.request_path,
         {conn.body_params["symbol"], conn.body_params["faction"]}}
      )

      respond.(conn)
    end)
  end

  defp drain_requests(acc \\ []) do
    receive do
      {:game_request, method, path, body} -> drain_requests([{method, path, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp registrations do
    for {"POST", "/v2/register", body} <- drain_requests(), do: body
  end

  defp reset_error do
    %SpaceTraders.API.GameplayError{
      code: 4113,
      type: :other,
      message:
        "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
    }
  end

  defp reset_then_fallback_response(conn) do
    case {conn.method, conn.request_path, conn.body_params["symbol"]} do
      {"GET", "/v2/my/agent", nil} ->
        reset_mismatch(conn)

      {"POST", "/v2/register", "RESETME"} ->
        symbol_unavailable(conn)

      {"POST", "/v2/register", "ORBITALIST"} ->
        Req.Test.json(conn, registration_body("ORBITALIST", "ORBITALIST-1", "SECOND_TOKEN"))
    end
  end

  defp reset_mismatch(conn) do
    conn
    |> Plug.Conn.put_status(401)
    |> Req.Test.json(%{
      "error" => %{
        "code" => 4113,
        "message" =>
          "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
      }
    })
  end

  defp symbol_unavailable(conn) do
    conn
    |> Plug.Conn.put_status(400)
    |> Req.Test.json(%{"error" => %{"code" => 4103, "message" => "Symbol is already in use"}})
  end

  defp objective_evidence(agent, credits \\ 175_000) do
    observation =
      SpaceTraders.Evidence.authoritative_observation(
        "get-my-agent",
        ["agent:#{agent.id}"],
        %{"response" => %{"credits" => credits}}
      )

    %Observation{
      agent_id: agent.id,
      subject: "agent:#{agent.id}",
      operation_id: observation.operation_id,
      dependency_keys: observation.dependency_keys,
      facts: observation.facts,
      response_fingerprint: observation.response_fingerprint,
      observed_at: observation.observed_at
    }
    |> Repo.insert!()
  end
end
