defmodule SpaceTraders.CoverageContributionScenarioTest do
  use SpaceTraders.ScenarioCase

  import Ecto.Query
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.World

  @system "X1-UX81"
  @freshness_seconds 300

  test "a distant Marketplace rejected by the previous heuristic is acquired one subject at a time" do
    {agent, ship, revision, operator} = coverage_fixture()
    scope = Scope.for_operator(operator)

    # Authoritative Waypoint facts make every known Marketplace a coverage
    # target. A1 already carries a retained Listing; A2 and A3 are never
    # observed and both lie far beyond the old per-Waypoint
    # `decision value - API cost - travel cost` heuristic.
    observe_marketplace(agent, "X1-UX81-A1", 1, 2)
    observe_marketplace(agent, "X1-UX81-A2", 60, 60)
    observe_marketplace(agent, "X1-UX81-A3", 5, 60)

    observe_listing(agent, ship, "X1-UX81-A1", SpaceTraders.Clock.utc_now())

    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, @system)

    now = SpaceTraders.Clock.utc_now()

    open_baseline =
      Evidence.list_open_demands(agent)
      |> Enum.filter(&(&1.owner == "fleet_planning" and DateTime.compare(&1.due_at, now) != :gt))
      |> Enum.map(& &1.subject)

    assert open_baseline == ["market:X1-UX81:X1-UX81-A2", "market:X1-UX81:X1-UX81-A3"]

    {:ok, world} =
      Agent.start_link(fn -> %{waypoint: "X1-UX81-A1", status: "DOCKED", arrival: nil} end)

    {:ok, counters} = Agent.start_link(fn -> %{} end)
    test_pid = self()

    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = "#{ship_path}/orbit"
    navigate_path = "#{ship_path}/navigate"
    market_a2_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/market"
    market_a3_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A3/market"

    stub_api(fn conn ->
      count = fn path ->
        Agent.update(counters, fn counts ->
          Map.update(counts, path, 1, &(&1 + 1))
        end)
      end

      count.(conn.request_path)

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_json(world)]})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_json(world)})

        {"POST", ^orbit_path} ->
          waypoint = Agent.get(world, & &1.waypoint)

          Req.Test.json(conn, %{
            "data" => %{"nav" => nav_body("IN_ORBIT", destination: waypoint)}
          })

        {"POST", ^navigate_path} ->
          destination = conn.body_params["waypointSymbol"]

          arrival_at =
            SpaceTraders.Clock.utc_now()
            |> DateTime.add(60)

          Agent.update(world, fn world ->
            %{world | waypoint: destination, status: "IN_TRANSIT", arrival: arrival_at}
          end)

          arrival = DateTime.to_iso8601(arrival_at)

          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 80},
              "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: destination)
            }
          })

        {"GET", ^market_a2_path} ->
          send(test_pid, {:market_read, conn.request_path})

          # A2 buys dear what A1 sells cheap, so completing this one
          # observation discovers a profitable route from partial coverage.
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "exports" => [],
              "imports" => [%{"symbol" => "IRON_ORE"}],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "IMPORT",
                  "tradeVolume" => 25,
                  "purchasePrice" => 35,
                  "sellPrice" => 30
                }
              ]
            }
          })

        {"GET", ^market_a3_path} ->
          # A3 stays an open coverage Demand: no full sweep may read it while
          # the planner's fixed order still has one subject per observation.
          flunk("A3 Market was read: coverage ran ahead of one-subject-at-a-time")

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "exports" => [%{"symbol" => "IRON_ORE"}],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "EXPORT",
                  "tradeVolume" => 20,
                  "purchasePrice" => 12,
                  "sellPrice" => 9
                }
              ]
            }
          })

        _other ->
          flunk("Unexpected API call: #{conn.method} #{conn.request_path}")
      end
    end)

    # The retained A1 Listing must also be governed evidence for Market
    # planning, not only an Intelligence projection for demand synchronization.
    assert {:ok, market_a1} =
             Evidence.get_market(
               SpaceTraders.API.AgentTokenReference.new(agent),
               @system,
               "X1-UX81-A1",
               owner: "ship_execution"
             )

    assert {:ok, _} =
             Intelligence.observe_market(agent, @system, market_a1,
               source: "get_market",
               observing_ship_symbol: ship.symbol,
               observed_at: SpaceTraders.Clock.utc_now()
             )

    # Start the timer owner before Reconciler holds the shared sandbox
    # connection. Production has a pool; the scenario intentionally has one.
    assert {:ok, _ship_server} = SpaceTraders.Fleet.ShipServer.ensure_started(agent, ship.symbol)
    allow_runtime_api()
    start_supervised!({Reconciler, []})

    # Reconciliation starts a claimed root Intent for the fixed first subject.
    # Grant the dynamically started ShipServer access to the controlled API
    # before the authoritative arrival re-read wakes it.
    assert_eventually(
      fn ->
        allow_runtime_api()

        match?(
          [{_pid, _value}],
          Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship.symbol)
        )
      end,
      100
    )

    assert_eventually(fn ->
      Enum.any?(drain_external_signals(), fn
        {:scenario_telemetry, [:spacetraders, :intent, :transition], _,
         %{intent_type: "acquire_intelligence", to_state: "waiting"}} ->
          true

        _ ->
          false
      end)
    end)

    ship_reads_before_arrival = call_count(counters, ship_path)

    # Advancing to the game-reported arrival lets Ship Execution revalidate
    # live Ship state and acquire exactly the selected Marketplace.
    advance_time(60)

    assert_eventually(fn -> call_count(counters, ship_path) > ship_reads_before_arrival end)
    assert_eventually(fn -> map_read?(counters, market_a2_path) end)

    # The distant A2 observation is admitted and acquired end to end: the
    # claimed Ship read the Market and the fresh Listing projects into World
    # evidence.
    assert_eventually(fn ->
      eventual(fn ->
        projection =
          World.intelligence(
            agent,
            :market,
            @system,
            "X1-UX81-A2",
            SpaceTraders.Clock.utc_now(),
            @freshness_seconds
          )

        projection.facts["trade_goods"] != nil and
          projection.facts["trade_goods"].freshness == :fresh
      end)
    end)

    assert_receive {:market_read, ^market_a2_path}

    # The governed observation fulfils exactly the selected demand.
    assert [a2_demand] =
             Enum.filter(
               Evidence.list_open_demands(agent) ++ closed_demands(agent),
               &(&1.subject == "market:X1-UX81:X1-UX81-A2" and &1.owner == "fleet_planning")
             )

    assert a2_demand.fulfilled_observation_id
    assert a2_demand.owner == "fleet_planning"
    assert a2_demand.strategy_revision_id == revision.id

    # Remaining baseline demands stay independently attributable and open.
    assert [a3_demand] =
             Enum.filter(
               Evidence.list_open_demands(agent),
               &(&1.subject == "market:X1-UX81:X1-UX81-A3")
             )

    assert is_nil(a3_demand.fulfilled_observation_id)
    assert is_nil(a3_demand.withdrawn_at)
    assert a3_demand.owner == "fleet_planning"
    assert a3_demand.strategy_revision_id == revision.id

    # The admitted Coverage Contribution was Strategy-provenanced and bounded
    # by its explicit finite, named subject set in the planner's fixed order.
    coverage_episode = coverage_episode(agent)

    assert %{"subjects" => subjects} = coverage_episode.expectations
    assert subjects == ["market:X1-UX81:X1-UX81-A2", "market:X1-UX81:X1-UX81-A3"]

    # Each completed observation is a reconciliation boundary: the profitable
    # route discovered from partial coverage takes the Ship without waiting
    # for the full sweep, and A3's coverage Demand stays open above.
    assert_eventually(fn ->
      Process.sleep(50)

      eventual(fn ->
        case FleetAllocation.current_portfolio(scope, agent) do
          %{commitments: [commitment]} ->
            commitment.decisive_reason in [nil, ""] == false and
              trading_commitment?(commitment)

          _ ->
            false
        end
      end)
    end)

    # One governed observation per subject: A2 was read exactly once and A3
    # never (its stub flunks), so no sweep script ran inside the contribution.
    assert Agent.get(counters, &Map.fetch!(&1, market_a2_path)) == 1
  end

  defp eventual(fun) do
    fun.()
  rescue
    DBConnection.ConnectionError -> false
  end

  defp map_read?(counters, path) do
    Agent.get(counters, fn counts -> Map.has_key?(counts, path) end)
  end

  defp call_count(counters, path) do
    Agent.get(counters, &Map.get(&1, path, 0))
  end

  defp trading_commitment?(commitment) do
    Repo.exists?(
      from intent in Intent,
        where:
          intent.fleet_commitment_id == ^commitment.id and intent.type == "buy" and
            intent.status in ["active", "waiting", "blocked"]
    )
  end

  defp coverage_episode(agent) do
    episode =
      Repo.one!(
        from episode in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
          join: portfolio in SpaceTraders.FleetAllocation.Portfolio,
          on: portfolio.strategy_decision_episode_id == episode.id,
          join: commitment in SpaceTraders.FleetAllocation.Commitment,
          on: commitment.fleet_commitment_portfolio_id == portfolio.id,
          where:
            portfolio.fleet_generation_id == ^generation_id(agent) and
              fragment("? -> 'subjects' IS NOT NULL", episode.expectations),
          order_by: [desc: episode.id],
          limit: 1,
          select: episode
      )

    assert episode.calibration_version != ""
    episode
  end

  defp generation_id(agent) do
    Repo.one!(
      from generation in Generation,
        where: generation.agent_id == ^agent.id and is_nil(generation.retired_at),
        select: generation.id
    )
  end

  defp closed_demands(agent) do
    Repo.all(
      from demand in SpaceTraders.Evidence.ObservationDemand,
        where:
          demand.agent_id == ^agent.id and
            (not is_nil(demand.fulfilled_observation_id) or not is_nil(demand.withdrawn_at)),
        select: demand
    )
  end

  defp ship_json(world) do
    state = Agent.get(world, & &1)

    case state.status do
      "IN_TRANSIT" ->
        if DateTime.compare(SpaceTraders.Clock.utc_now(), state.arrival) == :lt do
          # The game reports transit truth: the Ship stays IN_TRANSIT until
          # the scheduled arrival time passes, whatever the process clock does.
          ship_body("INTELACQ-1", %{
            "nav" =>
              nav_body("IN_TRANSIT",
                destination: state.waypoint,
                arrival: DateTime.to_iso8601(state.arrival)
              )
          })
        else
          arrived_ship_json(state)
        end

      _ ->
        arrived_ship_json(state)
    end
  end

  defp arrived_ship_json(state) do
    ship_body("INTELACQ-1", %{
      "nav" => nav_body("DOCKED", destination: state.waypoint)
    })
  end

  defp observe_marketplace(agent, symbol, x, y) do
    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => symbol,
        "systemSymbol" => @system,
        "type" => "PLANET",
        "x" => x,
        "y" => y,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
  end

  defp observe_listing(agent, ship, waypoint_symbol, observed_at) do
    listing =
      Model.Market.from_json(%{
        "symbol" => waypoint_symbol,
        "exports" => [%{"symbol" => "IRON_ORE"}],
        "imports" => [],
        "exchange" => [],
        "tradeGoods" => [
          %{
            "symbol" => "IRON_ORE",
            "type" => "EXPORT",
            "tradeVolume" => 20,
            "purchasePrice" => 12,
            "sellPrice" => 9
          }
        ]
      })

    {:ok, _} =
      Intelligence.observe_market(agent, @system, listing,
        source: "get_market",
        observing_ship_symbol: ship.symbol,
        observed_at: observed_at
      )
  end

  defp coverage_fixture do
    operator =
      Repo.insert!(%Operator{email: "coverage-e2e-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "INTELACQ",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN",
        operator_id: operator.id
      })

    ship = Repo.insert!(%Ship{symbol: "INTELACQ-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [
            %{
              "objective" => "Grow credits",
              "kind" => "continuous",
              "evaluation" => "Maximize net credit growth over time"
            }
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction,
      replacement_symbols: %{},
      objective_progress: %{}
    })

    {agent, ship, revision, operator}
  end
end
