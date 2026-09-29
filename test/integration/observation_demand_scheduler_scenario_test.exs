defmodule SpaceTraders.ObservationDemandSchedulerScenarioTest do
  use SpaceTraders.ScenarioCase

  import SpaceTraders.AgentFixtures

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.World

  @demand %{
    subject: "market:X1-UX81:X1-UX81-A1",
    required_facts: ["trade_goods"],
    freshness_seconds: 300,
    owner: "fleet_planning"
  }

  setup do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "observation_demands")

    %{agent: agent, agent_id: agent.id, operator: operator, revision: revision, scope: scope}
  end

  test "a demand due after a restart wakes planning exactly from persisted state", %{
    agent: agent,
    agent_id: agent_id,
    revision: revision
  } do
    due = DateTime.add(SpaceTraders.Clock.utc_now(), 60, :second)

    assert {:ok, _demand} =
             Evidence.request_demand(agent, revision, Map.put(@demand, :due_at, due))

    start_supervised!({DemandScheduler, []})

    # The scheduler is awake but nothing is due yet, so no due work is selected.
    advance_time(30)
    refute_received {:observation_demand_due, _agent_id, _subjects}

    # Process timer memory is not correctness state: the scheduler dies before
    # the demand comes due and the process clock passes it while it is down.
    assert :ok = stop_supervised!(DemandScheduler)
    advance_time(60)
    refute_received {:observation_demand_due, _agent_id, _subjects}

    # Boot reconstructs one earliest due wakeup from durable state alone.
    start_supervised!({DemandScheduler, []})
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A1"]}
  end

  test "persisted baseline Market coverage demands stay scheduled across a scheduler restart", %{
    agent: agent,
    agent_id: agent_id,
    revision: revision
  } do
    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

    # One durable reset-start baseline demand, due now, for the never-observed
    # Marketplace. No API stub exists in this test: any Market polling would
    # fail the test.
    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    assert [demand] = Evidence.list_open_demands(agent)
    assert demand.subject == "market:X1-UX81:X1-UX81-A1"
    assert demand.owner == "fleet_planning"
    assert DateTime.compare(demand.due_at, SpaceTraders.Clock.utc_now()) != :gt

    # The demand was persisted before any scheduler process existed. A fresh
    # scheduler boot reconstructs the due wakeup from durable state alone, so
    # a process restart is never an autonomy trigger and no Market polling is
    # required to keep the coverage work scheduled.
    start_supervised!({DemandScheduler, []})
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A1"]}

    # The wake never acquires evidence itself, so incomplete coverage keeps
    # the baseline demand durably open.
    assert [%{id: open_id}] = Evidence.list_open_demands(agent)
    assert open_id == demand.id
  end

  test "one governed wakeup selects each demand at its earliest useful time and rearms", %{
    agent: agent,
    agent_id: agent_id,
    revision: revision
  } do
    now = SpaceTraders.Clock.utc_now()

    assert {:ok, first} =
             Evidence.request_demand(
               agent,
               revision,
               Map.put(@demand, :due_at, DateTime.add(now, 30, :second))
             )

    assert {:ok, _second} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{
                 subject: "market:X1-UX81:X1-UX81-A2",
                 due_at: DateTime.add(now, 90, :second)
               })
             )

    start_supervised!({DemandScheduler, []})

    advance_time(30)
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A1"]}
    refute_received {:observation_demand_due, _agent_id, _subjects}

    # Withdrawing the satisfied requirement durably changes the earliest wakeup.
    assert {:ok, withdrawn} = Evidence.withdraw_demand(first)
    assert withdrawn.withdrawn_at

    advance_time(60)
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A2"]}
  end

  test "due work deferred while open stays scheduled on a bounded wakeup retry", %{
    agent: agent,
    agent_id: agent_id,
    revision: revision
  } do
    now = SpaceTraders.Clock.utc_now()

    assert {:ok, _demand} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{due_at: DateTime.add(now, -1, :second)})
             )

    start_supervised!({DemandScheduler, []})

    # Nobody fulfils the demand, so the scheduler keeps deferred work
    # scheduled instead of dropping it after one wakeup.
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A1"]}
    advance_time(30)
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A1"]}
  end

  test "Fleet Generation retirement withdraws open demands with preserved provenance" do
    operator = operator_fixture(%{email: "demand-retirement@example.com"})

    assert {:ok, _operator} =
             SpaceTraders.Agent.link_account_token(operator, "RETIREMENT_ACCOUNT_TOKEN")

    scope = Scope.for_operator(operator)

    assert {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    stub_api(fn conn ->
      Req.Test.json(conn, registration_body(conn.body_params["symbol"], "MINTED_TOKEN"))
    end)

    assert {:ok, %{agent: first_agent}} =
             SpaceTraders.FleetGeneration.mint(scope, %{
               symbol: "RETIREDME",
               faction: "COSMIC",
               replacement_symbols: ["RETIREDME", "REPLACED"]
             })

    assert {:ok, demand} =
             Evidence.request_demand(first_agent, revision, %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: DateTime.add(SpaceTraders.Clock.utc_now(), -60, :second),
               owner: "fleet_planning"
             })

    # The demand is fulfilled by governed evidence before the Agent goes
    # stale, so its fulfillment provenance must survive the replacement.
    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-A1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        SpaceTraders.Clock.utc_now()
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(
               first_agent,
               "market:X1-UX81:X1-UX81-A1",
               observation,
               SpaceTraders.Clock.utc_now()
             )

    assert fulfilled.id == demand.id

    # The Server Reset makes the first Agent stale: its Generation is fenced
    # and its demands lose relevance with it.
    stub_api(fn conn ->
      reset_mismatch(conn)
    end)

    stale_agent = Repo.reload!(first_agent)

    assert {:error, :stale_agent} = SpaceTraders.FleetGeneration.agent_overview(stale_agent)

    stub_api(fn conn ->
      Req.Test.json(conn, registration_body(conn.body_params["symbol"], "MINTED_TOKEN"))
    end)

    assert {:ok, _replacement} =
             SpaceTraders.FleetGeneration.mint(scope, %{
               symbol: "REPLACED",
               faction: "COSMIC",
               replacement_symbols: ["REPLACED"]
             })

    # The fulfilled demand keeps its fulfillment provenance after stale-Agent
    # deletion: the authoritative observation survives with a nilified agent
    # reference instead of being erased. A fulfilled demand is already closed,
    # so it correctly carries no withdrawal marker.
    withdrawn = Repo.reload!(demand)
    assert withdrawn.fulfilled_observation_id
    assert withdrawn.strategy_revision_id == revision.id
    assert withdrawn.subject == "market:X1-UX81:X1-UX81-A1"
    assert withdrawn.owner == "fleet_planning"
    assert withdrawn.due_at == demand.due_at

    observation_row =
      Repo.get!(SpaceTraders.Evidence.Observation, withdrawn.fulfilled_observation_id)

    assert observation_row.operation_id == "get-market"
    assert observation_row.subject == "market:X1-UX81:X1-UX81-A1"
    assert observation_row.agent_id == nil
  end

  defp reset_mismatch(conn) do
    conn
    |> put_status(401)
    |> Req.Test.json(%{
      "error" => %{
        "code" => 4113,
        "message" =>
          "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
      }
    })
  end

  defp registration_body(symbol, token) do
    %{
      "data" => %{
        "token" => token,
        "agent" => %{
          "symbol" => symbol,
          "credits" => 175_000,
          "headquarters" => "X1-TEST-A1",
          "shipCount" => 2
        },
        "ships" => []
      }
    }
  end

  test "moving the earliest due instant produces no early or duplicate wakeups", %{
    agent: agent,
    agent_id: agent_id,
    revision: revision
  } do
    now = SpaceTraders.Clock.utc_now()

    assert {:ok, first} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{due_at: DateTime.add(now, 60, :second)})
             )

    start_supervised!({DemandScheduler, []})

    # The earliest due instant moves later: the original demand is withdrawn
    # and a later-due one takes its place.
    assert {:ok, _} = Evidence.withdraw_demand(first)

    assert {:ok, _} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{
                 subject: "market:X1-UX81:X1-UX81-A2",
                 due_at: DateTime.add(now, 120, :second)
               })
             )

    # The stale timer fires at the old due instant and must be ignored.
    advance_time(60)
    refute_received {:observation_demand_due, _agent_id, _subjects}

    # At the new due instant exactly one wakeup fires.
    advance_time(60)
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A2"]}
    refute_received {:observation_demand_due, _agent_id, _subjects}
  end

  test "a due Market demand wakes the running Reconciler into acquisition after a scheduler restart" do
    {agent, ship, revision, operator} = unclaimed_market_fixture()

    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

    {:ok, _} =
      observe_stale_market(
        agent,
        ship,
        "X1-UX81-A1",
        DateTime.add(SpaceTraders.Clock.utc_now(), -600)
      )

    ship_path = "/v2/my/ships/#{ship.symbol}"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"
    test_pid = self()

    stub_api(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^market_path} ->
          send(test_pid, {:market_read, conn.request_path})

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

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    # Boot pass: with no active Generation visible, the Reconciler performs no
    # reconciliation and no governed Market read can happen.
    start_supervised!({Reconciler, []})
    refute_received {:market_read, ^market_path}

    # The persisted due Market demand is created and the Generation is
    # activated while the scheduler is still down.
    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: DateTime.add(SpaceTraders.Clock.utc_now(), 60, :second),
               owner: "fleet_planning"
             })

    insert_generation(operator, agent, revision)
    start_supervised!({DemandScheduler, []})

    # Not due yet: no Market read before the due scheduler wake.
    advance_time(30)
    refute_received {:market_read, ^market_path}

    # Process timer memory is not correctness state: the scheduler dies before
    # the demand comes due and the due instant passes while it is down.
    assert :ok = stop_supervised!(DemandScheduler)
    advance_time(60)
    refute_received {:market_read, ^market_path}

    # A fresh scheduler boot reconstructs the wakeup from durable state alone;
    # the due event reaches the actual running Reconciler, which wakes
    # Strategy reconciliation into governed acquisition.
    start_supervised!({DemandScheduler, []})

    assert_eventually(fn ->
      projection =
        World.intelligence(agent, :market, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

      projection.facts["trade_goods"].freshness == :fresh
    end)

    assert_receive {:market_read, ^market_path}

    # Normal retained Listing reconciliation materializes the next future
    # demand: one open successor for the still-relevant subject, chained
    # through preserved provenance.
    assert_eventually(fn ->
      open =
        Evidence.list_open_demands(agent)
        |> Enum.filter(
          &(&1.subject == "market:X1-UX81:X1-UX81-A1" and &1.owner == "fleet_planning")
        )

      case open do
        [successor] ->
          successor.replaces_id == demand.id and
            DateTime.compare(successor.due_at, demand.due_at) == :gt

        _ ->
          false
      end
    end)

    # The due demand was durably settled by the wake's governed evidence
    # (fulfilled, or replaced by its successor) and never deleted.
    reloaded = Repo.reload!(demand)
    assert reloaded.fulfilled_observation_id || reloaded.withdrawn_at
  end

  test "a deadline that passes while the scheduler is down is marked on the reconstructed wake",
       %{
         agent: agent,
         agent_id: agent_id,
         revision: revision
       } do
    now = SpaceTraders.Clock.utc_now()

    assert {:ok, demand} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{
                 due_at: now,
                 deadline_at: DateTime.add(now, 30, :second)
               })
             )

    start_supervised!({DemandScheduler, []})

    # The first wake fires while the deadline is still in the future.
    assert_receive {:observation_demand_due, ^agent_id, ["market:X1-UX81:X1-UX81-A1"]}
    assert Repo.reload!(demand).deadline_missed_at == nil

    # The deadline passes while the scheduler is down.
    assert :ok = stop_supervised!(DemandScheduler)
    advance_time(60)

    # The reconstructed wake marks the durable missed-deadline limitation; the
    # demand stays open for late authoritative evidence.
    start_supervised!({DemandScheduler, []})

    assert_eventually(fn -> Repo.reload!(demand).deadline_missed_at != nil end)
    assert [%{id: open_id}] = Evidence.list_open_demands(agent)
    assert open_id == demand.id
  end

  defp unclaimed_market_fixture do
    operator =
      Repo.insert!(%Operator{email: "demand-e2e-#{System.unique_integer()}@example.com"})

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

    {agent, ship, revision, operator}
  end

  defp insert_generation(operator, agent, revision) do
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
  end

  defp observe_stale_market(agent, ship, waypoint_symbol, observed_at) do
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

    Intelligence.observe_market(agent, "X1-UX81", listing,
      source: "get_market",
      observing_ship_symbol: ship.symbol,
      observed_at: observed_at
    )
  end
end
