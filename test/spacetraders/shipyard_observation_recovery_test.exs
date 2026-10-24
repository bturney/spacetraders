defmodule SpaceTraders.ShipyardObservationRecoveryTest do
  # Real commits outlive the interrupted dispatcher; clock/governor are shared.
  use ExUnit.Case, async: false

  import Ecto.Query
  import SpaceTraders.ShipBody
  import SpaceTraders.EvidenceFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Clock, Evidence, FleetAllocation, FleetStrategy, Intelligence, Repo, World}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet.{Intent, Intents, Ship, ShipServer, ShipServerBoot}
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.Quiesced
  alias SpaceTraders.Test.CapacityDispositions

  @t0 ~U[2026-10-22 00:00:00.000000Z]
  @system "X1-UX81"
  @yard "shipyard:X1-UX81:X1-UX81-A1"
  @observer "PROOF824-2"
  @yard_path "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
  end

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    restart_governor()
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({SpaceTraders.TestClock, @t0})
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)
    operator = SpaceTraders.AgentFixtures.operator_fixture()

    on_exit(fn ->
      for symbol <- ["PROOF824-1", @observer], do: Quiesced.stop_ship(symbol)

      agent_ids =
        Repo.all(
          from a in SpaceTraders.Agent.Agent, where: a.operator_id == ^operator.id, select: a.id
        )

      portfolio_ids =
        Repo.all(
          from p in SpaceTraders.FleetAllocation.Portfolio,
            where: p.operator_id == ^operator.id,
            select: p.id
        )
        |> Enum.map(&to_string/1)

      episode_ids =
        Repo.all(
          from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
            where: e.operator_id == ^operator.id,
            select: e.id
        )
        |> Enum.map(&to_string/1)

      topics = Enum.map(agent_ids, &"fleet:#{&1}")

      Repo.delete_all(
        from n in SpaceTraders.Outbox.Notification,
          where:
            n.topic in ^topics or
              fragment("?->>'portfolio_id'", n.payload) in ^portfolio_ids or
              fragment("?->>'decision_episode_id'", n.payload) in ^episode_ids
      )

      SpaceTraders.AgentFixtures.cleanup_operator_fixture(operator.id)
      SpaceTraders.FleetGenerationAdmission.clear()
      restart_governor()

      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      :ok = Sandbox.mode(Repo, :manual)
    end)

    %{operator: operator}
  end

  for preset <- FleetStrategy.presets() do
    test "#{preset.id}: boot resumes the same normally claimed Shipyard observation", %{
      operator: operator
    } do
      fleet = fixture(operator, unquote(preset.id))
      [retained] = publish_competing_trades(fleet).commitments
      assert [work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      assert work.strategy_revision_id == fleet.revision.id

      SpaceTraders.FleetAllocation.Acquisition.reconcile(
        fleet.scope,
        fleet.agent,
        fleet.revision,
        @system,
        CapacityDispositions.proceed()
      )

      assert [demand] = yard_demands(fleet)
      assert demand.strategy_revision_id == fleet.revision.id
      assert {:error, :evidence_pending} = Evidence.evidence_for_demand(demand)

      # The controlled GET pauses only once a real claimed Intent is persisted.
      # No replacement demand, injected Intent, or synthetic completion is used.
      sender =
        start_supervised!(
          {Task,
           fn ->
             receive do
               :dispatch ->
                 Reconciler.wake_due_demands(fleet.agent.id, CapacityDispositions.proceed())
             end
           end}
        )

      Req.Test.allow(SpaceTraders.API, self(), sender)
      send(sender, :dispatch)

      assert_receive {:durable_boundary, boundary_process, intent, sender_backend,
                      inside_transaction},
                     5_000

      assert boundary_process == sender
      refute inside_transaction
      [[observer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      assert sender_backend != observer_backend
      assert Repo.get!(Intent, intent.id) == intent
      assert intent.status == "active"
      assert intent.caller == "commitment"
      assert intent.type == "acquire_intelligence"
      assert intent.parameters["subject_type"] == "shipyard"
      assert intent.parameters["required_facts"] == ["ship_types", "ships"]
      assert {:ok, claim} = FleetAllocation.current_ship_claim(fleet.agent, @observer)
      assert claim.commitment_id == intent.fleet_commitment_id
      assert claim.portfolio_id == intent.fleet_commitment_portfolio_id
      assert claim.portfolio_version == intent.fleet_commitment_portfolio_version
      assert FleetAllocation.current_generation().id == fleet.generation.id
      assert FleetAllocation.current_generation().fleet_strategy_revision_id == fleet.revision.id
      assert [^demand] = yard_demands(fleet)
      refute Evidence.latest_observation(fleet.agent, @yard)
      refute_received {:request, "GET", @yard_path}
      before = durable_state(fleet, demand, intent)

      {:ok, old_ship_server} = ShipServer.ensure_started(fleet.agent, @observer)
      monitor = Process.monitor(sender)
      refute Quiesced.holds_connection?(sender)
      assert :ok = stop_supervised!(Task)
      assert_receive {:DOWN, ^monitor, :process, ^sender, :shutdown}
      Quiesced.stop_ship(@observer)
      refute Process.alive?(old_ship_server)
      assert Repo.get!(Intent, intent.id) == intent
      assert {:ok, ^claim} = FleetAllocation.current_ship_claim(fleet.agent, @observer)
      assert [^demand] = yard_demands(fleet)

      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_intelligence_evidence")
      # The production one-shot boot owner reconstructs the owned ShipServer
      # and reconciles this persisted Intent, rather than allocating new work.
      assert :ignore = ShipServerBoot.start_link([])
      assert [{new_ship_server, _}] = Registry.lookup(SpaceTraders.Fleet.ShipRegistry, @observer)
      assert new_ship_server != old_ship_server
      assert Repo.get!(Intent, intent.id).status == "completed"

      assert {:ok, observation} = Evidence.evidence_for_demand(demand)
      assert observation.operation_id == "get-shipyard"
      assert observation.agent_id == fleet.agent.id
      assert observation.fleet_generation_id == fleet.generation.id

      assert Repo.get!(Evidence.ObservationDemand, demand.id).fulfilled_observation_id ==
               observation.id

      projection =
        World.intelligence(fleet.agent, :shipyard, @system, "X1-UX81-A1", Clock.utc_now(), 300)

      assert projection.facts["ships"].observing_ship_symbol == @observer

      assert [%{"type" => "SHIP_LIGHT_HAULER", "purchase_price" => 100_000}] =
               Enum.map(
                 projection.facts["ships"].value,
                 &Map.take(&1, ["type", "purchase_price"])
               )

      facts = Intelligence.subject(fleet.agent, :shipyard, @system, "X1-UX81-A1")
      assert facts["ships"].observation.evidence_observation_id == observation.id

      assert DateTime.compare(projection.facts["ships"].observed_at, observation.observed_at) ==
               :eq

      assert_received {:request, "GET", @yard_path}
      refute_received {:request, "GET", @yard_path}
      assert_received {:waypoint_intelligence_observed, agent_id, @system}
      assert agent_id == fleet.agent.id

      for _ <- 1..2 do
        assert :ok = Intents.rearm_on_boot()

        assert [completed] =
                 Enum.filter(Intents.history(fleet.agent), &(&1.type == "acquire_intelligence"))

        assert completed.id == intent.id
        assert completed.status == "completed"
        assert completed.fleet_commitment_id == intent.fleet_commitment_id
        assert completed.fleet_commitment_portfolio_id == intent.fleet_commitment_portfolio_id

        assert completed.fleet_commitment_portfolio_version ==
                 intent.fleet_commitment_portfolio_version

        assert [] = Intents.current(fleet.agent)
        assert {:ok, ^observation} = Evidence.evidence_for_demand(demand)
        assert [] = yard_demands(fleet)
      end

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      assert Enum.any?(
               current.commitments,
               &(&1.id == retained.id and &1.claims == retained.claims and
                   &1.reservations == retained.reservations)
             )

      assert {:ok, ^claim} = FleetAllocation.current_ship_claim(fleet.agent, @observer)
      assert Repo.get!(FleetStrategy.Revision, fleet.revision.id) == fleet.revision
      refute_received {:request, "GET", @yard_path}
      refute_received {:request, "POST", _}
      refute_received {:unexpected_request, _}

      # Optional receipt for this bounded proof; not a shared fault framework.
      if path = System.get_env("SHIPYARD_RECOVERY_TRACE") do
        File.write!(
          path,
          Jason.encode!(%{
            preset: unquote(preset.id),
            before: before,
            after: durable_state(fleet, demand, Repo.get!(Intent, intent.id)),
            observation:
              Map.take(observation, [
                :id,
                :operation_id,
                :agent_id,
                :fleet_generation_id,
                :observed_at,
                :facts
              ]),
            retained_commitment_id: retained.id,
            requests: Elixir.Agent.get(fleet.world, &Enum.reverse(&1.requests))
          }) <> "\n",
          [:append]
        )
      end
    end
  end

  defp durable_state(fleet, demand, intent) do
    {:ok, claim} = FleetAllocation.current_ship_claim(fleet.agent, @observer)

    %{
      generation_id: FleetAllocation.current_generation().id,
      revision_id: FleetAllocation.current_generation().fleet_strategy_revision_id,
      demand:
        Map.take(Repo.get!(Evidence.ObservationDemand, demand.id), [
          :id,
          :owner,
          :strategy_revision_id,
          :due_at,
          :fulfilled_observation_id
        ]),
      intent:
        Map.take(intent, [
          :id,
          :status,
          :parameters,
          :fleet_commitment_id,
          :fleet_commitment_portfolio_id,
          :fleet_commitment_portfolio_version,
          :last_action_result
        ]),
      claim: Map.take(claim, [:commitment_id, :portfolio_id, :portfolio_version])
    }
  end

  defp restart_governor do
    SpaceTraders.Test.Governor.restart()
  end

  defp yard_demands(fleet),
    do: Enum.filter(Evidence.list_open_demands(fleet.agent), &(&1.subject == @yard))

  # Same approved seam/limitation as #832: publish real competing trades without
  # executing the starter buy, whose source refresh invalidates the first loser.
  # Full startup/productive acquisition proof remains outside this recovery test.
  defp publish_competing_trades(fleet) do
    {:ok, availability} = SpaceTraders.FleetExecution.governed_availability(fleet.agent)

    {:ok, planned} =
      SpaceTraders.FleetIntelligence.plan_contributions(fleet.agent, fleet.revision, @system, [])

    {:ok, plans} =
      SpaceTraders.FleetShadow.plan_market(planned.market, fleet.revision, availability)

    candidates = Enum.flat_map(plans, & &1.candidate_contributions)
    assert length(candidates) == 2

    {:ok, selected} =
      FleetAllocation.select_portfolio(
        fleet.revision,
        candidates,
        Map.put(availability, :source_version, 0)
      )

    assert length(selected.commitments) == 1
    assert [%{reasons: [:claim_conflict]}] = selected.rejected

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(fleet.scope, fleet.generation.id, selected, %{
        evidence_references: Enum.flat_map(candidates, & &1.dependencies),
        expectations: %{domain: "market"},
        calibration_version: FleetAllocation.market_calibration_version()
      })

    portfolio
  end

  defp fixture(operator, preset) do
    scope = Scope.for_operator(operator)
    {:ok, draft} = FleetStrategy.select_preset(scope, preset)
    {:ok, revision} = FleetStrategy.activate(scope, draft.draft_version)

    agent =
      SpaceTraders.AgentFixtures.established_agent_fixture(%SpaceTraders.Agent.Agent{
        symbol: "PROOF824",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "test-token",
        operator_id: operator.id
      })

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%SpaceTraders.FleetGeneration.Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    for {suffix, type} <- [{1, "SHIP_LIGHT_HAULER"}, {2, "SHIP_PROBE"}] do
      Repo.insert!(%Ship{symbol: "PROOF824-#{suffix}", ship_type: type, agent_id: agent.id})
    end

    for {suffix, x, y, traits} <- [
          {"A1", 0, 0, [%{"symbol" => "MARKETPLACE"}, %{"symbol" => "SHIPYARD"}]},
          {"A2", 62, 0, [%{"symbol" => "MARKETPLACE"}]},
          {"A3", 0, 62, [%{"symbol" => "MARKETPLACE"}]}
        ] do
      {:ok, _} =
        Intelligence.observe_waypoint(
          agent,
          Model.Waypoint.from_json(%{
            "symbol" => "#{@system}-#{suffix}",
            "systemSymbol" => @system,
            "type" => "PLANET",
            "x" => x,
            "y" => y,
            "traits" => traits,
            "chart" => %{"submittedBy" => agent.symbol, "submittedOn" => DateTime.to_iso8601(@t0)}
          }),
          source: "get_waypoint",
          observed_at: @t0
        )
    end

    for {waypoint, goods} <- markets(),
        do: retained_market_listing(agent, @system, waypoint, goods, observed_at: @t0)

    owner = self()

    world =
      start_supervised!(
        {Elixir.Agent, fn -> %{interrupted: false, ships: [trader(), probe()], requests: []} end}
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(owner, {:request, conn.method, conn.request_path})

      Elixir.Agent.update(
        world,
        &%{
          &1
          | requests: [
              %{method: conn.method, path: conn.request_path, at: Clock.utc_now()} | &1.requests
            ]
        }
      )

      state = Elixir.Agent.get(world, & &1)
      assert Plug.Conn.get_req_header(conn, "authorization") in [[], ["Bearer test-token"]]
      SpaceTraders.TestClock.advance(1)

      if conn.request_path == "/v2/" do
        Req.Test.json(conn, %{
          "status" => "online",
          "serverResets" => %{"next" => DateTime.to_iso8601(DateTime.add(@t0, 120 * 3600))}
        })
      else
        data =
          case {conn.method, conn.request_path} do
            {"GET", "/v2/my/agent"} ->
              %{"symbol" => agent.symbol, "credits" => 400_000}

            {"GET", "/v2/my/ships"} ->
              state.ships

            {"GET", "/v2/my/ships/PROOF824-1"} ->
              Enum.find(state.ships, &(&1["symbol"] == "PROOF824-1"))

            {"GET", "/v2/my/ships/PROOF824-2"} ->
              intent =
                Enum.find(
                  Intents.current(agent),
                  &(&1.type == "acquire_intelligence" and &1.status == "active")
                )

              if intent &&
                   !Elixir.Agent.get_and_update(
                     world,
                     &{&1.interrupted, %{&1 | interrupted: true}}
                   ) do
                [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
                send(owner, {:durable_boundary, self(), intent, backend, Repo.in_transaction?()})

                receive do
                  :unexpected_resume -> flunk("interrupted dispatcher must not resume")
                after
                  10_000 -> flunk("dispatcher was not interrupted at durable boundary")
                end
              end

              Enum.find(state.ships, &(&1["symbol"] == @observer))

            {"GET", @yard_path} ->
              assert Elixir.Agent.get(world, & &1.interrupted)
              # The game serves offers only to an owned, physically present Ship.
              assert Enum.any?(
                       state.ships,
                       &(&1["symbol"] == @observer and &1["nav"]["waypointSymbol"] == "X1-UX81-A1" and
                           &1["nav"]["status"] != "IN_TRANSIT")
                     )

              %{
                "symbol" => "X1-UX81-A1",
                "modificationsFee" => 2_000,
                "shipTypes" => [%{"type" => "SHIP_LIGHT_HAULER"}],
                "ships" => [
                  Map.merge(Map.take(trader(), ~w(frame reactor engine modules mounts crew)), %{
                    "type" => "SHIP_LIGHT_HAULER",
                    "purchasePrice" => 100_000
                  })
                ]
              }

            other ->
              send(owner, {:unexpected_request, other})
              flunk("unexpected observation-recovery request: #{inspect(other)}")
          end

        Req.Test.json(conn, %{"data" => data})
      end
    end)

    %{agent: agent, scope: scope, revision: revision, generation: generation, world: world}
  end

  defp markets do
    %{
      "X1-UX81-A1" => [
        good("IRON", 1_000, 900),
        good("COPPER", 1_000, 900),
        good("FUEL", 100, 90)
      ],
      "X1-UX81-A2" => [good("IRON", 1_600, 1_500), good("FUEL", 100, 90)],
      "X1-UX81-A3" => [good("COPPER", 1_600, 1_500), good("FUEL", 100, 90)]
    }
  end

  defp good(symbol, buy, sell),
    do: %{symbol: symbol, purchase_price: buy, sell_price: sell, trade_volume: 40}

  defp trader do
    body =
      ship_body("PROOF824-1", %{
        "nav" => nav_at_headquarters(),
        "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
        "fuel" => %{"capacity" => 100, "current" => 100},
        "crew" => %{"current" => 4, "required" => 4, "capacity" => 4, "rotation" => "STRICT"},
        "modules" => [
          %{
            "symbol" => "MODULE_CARGO_HOLD_I",
            "name" => "Cargo Hold",
            "description" => "Cargo",
            "capacity" => 40,
            "requirements" => %{"crew" => 1, "power" => 1, "slots" => 1}
          }
        ]
      })

    body
    |> Map.put(
      "frame",
      Map.merge(body["frame"], %{
        "fuelCapacity" => 100,
        "moduleSlots" => 4,
        "mountingPoints" => 2,
        "condition" => 1.0
      })
    )
    |> Map.put("reactor", Map.merge(body["reactor"], %{"powerOutput" => 4, "condition" => 1.0}))
  end

  defp probe do
    body = trader()

    body
    |> Map.put("symbol", @observer)
    |> Map.update!("registration", &Map.put(&1, "name", @observer))
    |> Map.update!("cooldown", &Map.put(&1, "shipSymbol", @observer))
    |> Map.put("cargo", %{"capacity" => 0, "units" => 0, "inventory" => []})
    |> Map.put("fuel", %{"capacity" => 0, "current" => 0})
    |> Map.put("modules", [])
    |> Map.put(
      "frame",
      Map.merge(body["frame"], %{"symbol" => "FRAME_PROBE", "fuelCapacity" => 0})
    )
  end

  defp nav_at_headquarters do
    waypoint = %{
      "symbol" => "X1-UX81-A1",
      "systemSymbol" => @system,
      "type" => "PLANET",
      "x" => 0,
      "y" => 0
    }

    Map.put(nav_body("DOCKED"), "route", %{
      "origin" => waypoint,
      "destination" => waypoint,
      "departureTime" => DateTime.to_iso8601(@t0),
      "arrival" => DateTime.to_iso8601(@t0)
    })
  end
end
