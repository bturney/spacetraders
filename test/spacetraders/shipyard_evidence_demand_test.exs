defmodule SpaceTraders.ShipyardEvidenceDemandTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody
  import SpaceTraders.EvidenceFixtures

  alias SpaceTraders.{Clock, Evidence, FleetAllocation, FleetStrategy, Intelligence, World}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.Test.CapacityDispositions

  @t0 ~U[2026-10-22 00:00:00.000000Z]
  @system "X1-UX81"
  @yard "shipyard:X1-UX81:X1-UX81-A1"

  setup do
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({SpaceTraders.TestClock, @t0})
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      for symbol <- ["PROOF824-1", "PROOF824-2", "PROOF824-3"],
          do: SpaceTraders.Quiesced.stop_ship(symbol)

      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    :ok
  end

  for preset <- FleetStrategy.presets(), gaps? <- [false, true] do
    test "#{preset.id}: real unmet work observes Ship Offers with unrelated Market gaps #{gaps?}" do
      fleet = fixture(unquote(preset.id))

      if unquote(gaps?), do: observe_gap(fleet.agent)

      [retained] = publish_competing_trades(fleet).commitments
      assert [work] = FleetAllocation.ship_bound_unmet_work(fleet.agent)
      assert work.strategy_revision_id == fleet.revision.id
      assert work.trade_symbol in ["IRON", "COPPER"]

      SpaceTraders.FleetAllocation.Acquisition.reconcile(
        fleet.scope,
        fleet.agent,
        fleet.revision,
        @system,
        CapacityDispositions.proceed()
      )

      assert [demand] = yard_demands(fleet)
      assert demand.strategy_revision_id == work.strategy_revision_id
      assert demand.required_facts == ["ship_types", "ships"]
      assert DateTime.compare(demand.due_at, Clock.utc_now()) != :gt
      refute Evidence.latest_observation(fleet.agent, @yard)

      refusal =
        Repo.get_by!(SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
          fleet_generation_id: fleet.generation.id,
          selection_kind: :acquisition_refused
        )

      assert Enum.any?(
               refusal.expectations["considered_work"],
               &(&1["decision_episode_id"] == work.decision_episode_id)
             )

      assert %{"id" => demand.id, "subject" => @yard} in refusal.expectations[
               "observation_demands"
             ]

      SpaceTraders.TestClock.advance(1)

      for _ <- 1..2 do
        SpaceTraders.FleetAllocation.Acquisition.reconcile(
          fleet.scope,
          fleet.agent,
          fleet.revision,
          @system,
          CapacityDispositions.proceed()
        )

        assert [^demand] = yard_demands(fleet)
      end

      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_intelligence_evidence")
      assert :ok = Reconciler.wake_due_demands(fleet.agent.id, CapacityDispositions.proceed())
      assert {:ok, observation} = Evidence.evidence_for_demand(demand)
      assert observation.operation_id == "get-shipyard"

      projection =
        World.intelligence(fleet.agent, :shipyard, @system, "X1-UX81-A1", Clock.utc_now(), 300)

      assert [%{"type" => "SHIP_LIGHT_HAULER", "purchase_price" => 100_000}] =
               Enum.map(
                 projection.facts["ships"].value,
                 &Map.take(&1, ["type", "purchase_price"])
               )

      assert projection.facts["ships"].observing_ship_symbol == "PROOF824-2"
      facts = Intelligence.subject(fleet.agent, :shipyard, @system, "X1-UX81-A1")
      assert facts["ships"].observation.evidence_observation_id == observation.id

      assert DateTime.compare(projection.facts["ships"].observed_at, observation.observed_at) ==
               :eq

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      assert Enum.any?(
               current.commitments,
               &(&1.id == retained.id and &1.claims == retained.claims and
                   &1.reservations == retained.reservations)
             )

      if unquote(gaps?) do
        assert Enum.any?(
                 Evidence.list_open_demands(fleet.agent),
                 &(&1.subject == "market:#{@system}:#{@system}-A4")
               )
      end

      [intent] =
        Enum.filter(
          SpaceTraders.Fleet.Intents.history(fleet.agent),
          &(&1.type == "acquire_intelligence")
        )

      assert intent.status == "completed"
      assert intent.fleet_commitment_id
      assert_received {:request, "GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"}
      refute_received {:request, "GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"}
      assert_received {:waypoint_intelligence_observed, agent_id, @system}
      assert agent_id == fleet.agent.id
      # The next ordinary acquisition decision consumes the observed offer.
      # This is not productive-use/payback proof: the starter has not executed,
      # and the acquired Ship has earned nothing in this evidence-only slice.
      assert_received {:request, "POST", "/v2/my/ships"}
      refute_received {:request, "POST", "/v2/my/ships"}

      [purchase] =
        Enum.filter(
          SpaceTraders.MutationAttempts.list_for_agent(fleet.agent),
          &(&1.operation_id == "purchase-ship")
        )

      next_decision =
        Repo.get!(
          SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
          purchase.provenance["decision_episode_id"]
        )

      assert next_decision.fleet_strategy_revision_id == fleet.revision.id

      assert Enum.any?(next_decision.expectations["candidate"]["dependencies"], fn dependency ->
               dependency["subject"] == @yard and
                 dependency["evidence_id"] ==
                   "intelligence-observation:#{projection.facts["ships"].observation_id}"
             end)

      refute_received {:unexpected_request, _}
    end
  end

  for preset <- FleetStrategy.presets() do
    test "#{preset.id}: lost decision relevance withdraws only acquisition evidence demand" do
      fleet = fixture(unquote(preset.id))
      observe_gap(fleet.agent)
      [retained] = publish_competing_trades(fleet).commitments

      SpaceTraders.FleetAllocation.Acquisition.reconcile(
        fleet.scope,
        fleet.agent,
        fleet.revision,
        @system,
        CapacityDispositions.proceed()
      )

      assert [demand] = yard_demands(fleet)

      unrelated =
        Enum.find(
          Evidence.list_open_demands(fleet.agent),
          &(&1.subject == "market:#{@system}:#{@system}-A4")
        )

      assert unrelated

      assert {:ok, _} = Intelligence.invalidate(fleet.agent, :market, @system, "X1-UX81-A1")
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      SpaceTraders.FleetAllocation.Acquisition.reconcile(
        fleet.scope,
        fleet.agent,
        fleet.revision,
        @system,
        CapacityDispositions.proceed()
      )

      assert [] = yard_demands(fleet)
      assert Repo.get!(Evidence.ObservationDemand, demand.id).withdrawn_at
      assert unrelated in Evidence.list_open_demands(fleet.agent)

      assert Enum.any?(
               FleetAllocation.current_portfolio(fleet.scope, fleet.agent).commitments,
               &(&1.id == retained.id and &1.claims == retained.claims)
             )

      refute_received {:request, "GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"}
      refute_received {:unexpected_request, _}
    end

    test "#{preset.id}: no eligible unmet work creates no acquisition Shipyard polling" do
      fleet = fixture(unquote(preset.id))
      observe_gap(fleet.agent)
      assert [] = FleetAllocation.ship_bound_unmet_work(fleet.agent)

      for _ <- 1..2 do
        SpaceTraders.FleetAllocation.Acquisition.reconcile(
          fleet.scope,
          fleet.agent,
          fleet.revision,
          @system,
          CapacityDispositions.proceed()
        )

        assert {:ok, %{intelligence: planning}} =
                 SpaceTraders.FleetIntelligence.plan_contributions(
                   fleet.agent,
                   fleet.revision,
                   @system,
                   []
                 )

        refute Enum.any?(
                 planning.observation_demands,
                 &String.starts_with?(&1.subject, "shipyard:")
               )

        assert [] = yard_demands(fleet)
      end

      refute_received {:request, "GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"}
      refute_received {:unexpected_request, _}
    end
  end

  defp observe_gap(agent) do
    {:ok, _} =
      Intelligence.observe_waypoint(
        agent,
        Model.Waypoint.from_json(%{
          "symbol" => "#{@system}-A4",
          "systemSymbol" => @system,
          "type" => "PLANET",
          "x" => 62,
          "y" => 62,
          "traits" => [%{"symbol" => "MARKETPLACE"}],
          "chart" => %{"submittedBy" => agent.symbol, "submittedOn" => DateTime.to_iso8601(@t0)}
        }),
        source: "get_waypoint",
        observed_at: @t0
      )
  end

  defp yard_demands(fleet),
    do: Enum.filter(Evidence.list_open_demands(fleet.agent), &(&1.subject == @yard))

  # The scope here ends at observation. Construct and publish the starter's
  # competing trades through the real planning/selection seams, without driving
  # its buy (whose quote refresh invalidates this first decision's evidence).
  # The adjacent acquisition proof owns that execution/freshness limitation.
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

  defp fixture(preset) do
    operator = SpaceTraders.AgentFixtures.operator_fixture()
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

    for {waypoint, goods} <- markets() do
      retained_market_listing(agent, @system, waypoint, goods, observed_at: @t0)
    end

    test_pid = self()
    world = start_supervised!({Elixir.Agent, fn -> %{purchased: nil, credits: 400_000} end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})
      state = Elixir.Agent.get(world, & &1)
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
              %{"symbol" => agent.symbol, "credits" => state.credits}

            {"GET", "/v2/my/ships"} ->
              [trader(), probe()] ++ List.wrap(state.purchased)

            {"GET", "/v2/my/ships/PROOF824-1"} ->
              trader()

            {"GET", "/v2/my/ships/PROOF824-2"} ->
              probe()

            {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
              %{
                "symbol" => "X1-UX81-A1",
                "exports" => [],
                "imports" => [],
                "exchange" => [],
                "tradeGoods" =>
                  Enum.map(markets()["X1-UX81-A1"], fn good ->
                    %{
                      "symbol" => good.symbol,
                      "type" => "EXPORT",
                      "purchasePrice" => good.purchase_price,
                      "sellPrice" => good.sell_price,
                      "tradeVolume" => good.trade_volume
                    }
                  end)
              }

            {"POST", "/v2/my/ships"} ->
              assert state.purchased == nil

              assert conn.body_params == %{
                       "shipType" => "SHIP_LIGHT_HAULER",
                       "waypointSymbol" => "X1-UX81-A1"
                     }

              purchased =
                trader()
                |> Map.put("symbol", "PROOF824-3")
                |> Map.update!("registration", &Map.put(&1, "name", "PROOF824-3"))
                |> Map.update!("cooldown", &Map.put(&1, "shipSymbol", "PROOF824-3"))

              Elixir.Agent.update(
                world,
                &%{&1 | purchased: purchased, credits: &1.credits - 100_000}
              )

              %{
                "ship" => purchased,
                "agent" => %{"symbol" => agent.symbol, "credits" => state.credits - 100_000},
                "transaction" => %{
                  "agentSymbol" => agent.symbol,
                  "shipSymbol" => "PROOF824-3",
                  "shipType" => "SHIP_LIGHT_HAULER",
                  "waypointSymbol" => "X1-UX81-A1",
                  "price" => 100_000,
                  "timestamp" => DateTime.to_iso8601(Clock.utc_now())
                }
              }

            {"GET", "/v2/my/ships/PROOF824-3"} ->
              assert state.purchased
              state.purchased

            {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"} ->
              %{
                "symbol" => "X1-UX81-A1",
                "modificationsFee" => 2_000,
                "shipTypes" => [%{"type" => "SHIP_LIGHT_HAULER"}],
                "ships" =>
                  if(state.purchased,
                    do: [],
                    else: [
                      Map.merge(
                        Map.take(trader(), ~w(frame reactor engine modules mounts crew)),
                        %{"type" => "SHIP_LIGHT_HAULER", "purchasePrice" => 100_000}
                      )
                    ]
                  )
              }

            other ->
              send(test_pid, {:unexpected_request, other})
              flunk("unexpected request: #{inspect(other)}")
          end

        Req.Test.json(conn, %{"data" => data})
      end
    end)

    %{agent: agent, scope: scope, revision: revision, generation: generation}
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
    |> Map.put("symbol", "PROOF824-2")
    |> Map.update!("registration", &Map.put(&1, "name", "PROOF824-2"))
    |> Map.update!("cooldown", &Map.put(&1, "shipSymbol", "PROOF824-2"))
    |> Map.put("cargo", %{"capacity" => 0, "units" => 0, "inventory" => []})
    |> Map.put("fuel", %{"capacity" => 0, "current" => 0})
    |> Map.put("modules", [])
    |> Map.put(
      "frame",
      Map.merge(body["frame"], %{"symbol" => "FRAME_PROBE", "fuelCapacity" => 0})
    )
  end

  defp nav_at_headquarters do
    nav = nav_body("DOCKED")

    waypoint = %{
      "symbol" => "X1-UX81-A1",
      "systemSymbol" => @system,
      "type" => "PLANET",
      "x" => 0,
      "y" => 0
    }

    Map.put(nav, "route", %{
      "origin" => waypoint,
      "destination" => waypoint,
      "departureTime" => DateTime.to_iso8601(@t0),
      "arrival" => DateTime.to_iso8601(@t0)
    })
  end
end
