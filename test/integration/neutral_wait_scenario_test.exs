defmodule SpaceTraders.NeutralWaitScenarioTest do
  use SpaceTraders.ScenarioCase

  import Ecto.Query
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.CapacityGovernor.Snapshot, as: CapacitySnapshot
  alias SpaceTraders.API.Model
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.DemandScheduler
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{AllocationWaitPointer, Commitment, Portfolio, Reconciler}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.World

  @system "X1-UX81"
  @market_subject "market:X1-UX81:X1-UX81-A1"
  @market_path "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

  setup do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)

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

    %{agent: agent, operator: operator, revision: revision, scope: scope}
  end

  describe "a Neutral Wait persists across the autonomous runtime" do
    test "a zero-admissible market replan with future due evidence mints one durable wait",
         %{
           agent: agent,
           operator: operator,
           revision: revision,
           scope: scope
         } do
      # The market comparison's as-of follows the Capacity Governor's real
      # wall-clock observation, so the scenario clock is synced to real time
      # before any evidence is recorded: listings observed at the default
      # fake-clock start would read as weeks stale to the comparison.
      advance_time(
        max(DateTime.diff(DateTime.utc_now(), SpaceTraders.Clock.utc_now(), :second), 0)
      )

      {agent, ship} = observed_market_fixture(agent)
      _demand = request_future_demand(agent, revision, 60)

      insert_generation(operator, agent, revision)
      stub_game_reads(agent, ship)
      allow_runtime_api()

      # Boot pass: the runtime reconstructs its wakeup from durable state.
      start_supervised!({Reconciler, []})
      start_supervised!({DemandScheduler, []})

      advance_time(30)
      refute_received {:market_read, @market_path}

      # Process timer memory is not correctness state: the scheduler dies
      # before the demand comes due and the due instant passes while it is
      # down. A fresh boot reconstructs the wakeup from durable state alone.
      assert :ok = stop_supervised!(DemandScheduler)
      advance_time(60)
      start_supervised!({DemandScheduler, []})

      # The due demand wakes reconciliation into a governed Market read: the
      # observation contribution publishes, the Ship acquires the Listing, and
      # the fresh unprofitable evidence unwinds the portfolio at the evidence
      # boundary.
      assert_eventually(fn ->
        projection =
          World.intelligence(agent, :market, @system, "X1-UX81-A1", DateTime.utc_now(), 300)

        projection.facts["trade_goods"].freshness == :fresh
      end)

      assert_receive {:market_read, @market_path}

      # The observation portfolio unwinds at the evidence boundary. The
      # successor refresh demand that a settled synchronization leaves for the
      # still-relevant Strategy is arranged here through the public demand
      # API: the racing in-flight read can leave the successor momentarily due
      # now, and the synchronization never extends an already-due demand.
      assert_eventually(fn -> FleetAllocation.current_portfolio(scope, agent) == nil end)

      Enum.each(open_market_demands(agent), &Evidence.withdraw_demand/1)

      _successor = request_future_demand(agent, revision, 300)

      # The authoritative zero-admissible market replan (ADR 0012's single
      # mint site) records the wait from the pair: no admissible commitment
      # and a durable future Observation Demand for re-evaluation.
      portfolios_before = Repo.all(from p in Portfolio, select: p.id)
      commitments_before = Repo.all(from c in Commitment, select: c.id)

      assert {:ok, %{action: :no_admissible_commitment}} =
               FleetExecution.reconcile_market_evidence(
                 scope,
                 agent,
                 revision,
                 @system,
                 scenario_capacity()
               )

      assert %StrategyDecisionEpisode{
               selection_kind: :neutral_wait,
               classification: :still_evaluating
             } = episode = current_wait()

      assert episode.fleet_strategy_revision_id == revision.id

      assert episode.binding_limitation_kind in [
               :awaiting_scheduled_evidence,
               :no_admissible_candidate,
               :incomplete_coverage
             ]

      assert %DateTime{} = episode.next_observation_at
      assert DateTime.compare(episode.next_observation_at, SpaceTraders.Clock.utc_now()) == :gt
      assert is_list(episode.evidence_references) and episode.evidence_references != []

      pointer =
        Repo.get_by!(AllocationWaitPointer, fleet_generation_id: episode.fleet_generation_id)

      assert pointer.selection_kind == :neutral_wait
      assert pointer.strategy_decision_episode_id == episode.id

      assert FleetAllocation.current_neutral_wait_since(episode.fleet_generation_id) ==
               episode.inserted_at

      assert neutral_wait_count() == 1 and selected_plan_episodes_unsuperseded() == []

      # The wait creates no Commitment or portfolio material: the rows the
      # observation cycle already produced are exactly the rows that remain.
      assert Repo.all(from p in Portfolio, select: p.id) == portfolios_before
      assert Repo.all(from c in Commitment, select: c.id) == commitments_before
      assert FleetAllocation.current_portfolio(scope, agent) == nil

      # The wait survives a scheduler restart from durable state alone: the
      # timer holder dies and a fresh boot re-arms from persisted demands
      # without disturbing the episode, while the successor stays future.
      assert :ok = stop_supervised!(DemandScheduler)
      start_supervised!({DemandScheduler, []})

      advance_time(240)

      # The scheduler can consume the old demand while it restarts. Persist a
      # fresh successor so the equivalent allocation has future evidence.
      Enum.each(open_market_demands(agent), &Evidence.withdraw_demand/1)
      _successor = request_future_demand(agent, revision, 300)

      assert Repo.reload!(episode).id == episode.id
      assert Repo.reload!(episode).classification == :still_evaluating
      assert current_wait().id == episode.id
      assert FleetAllocation.current_neutral_wait_since(episode.fleet_generation_id) != nil

      # An equivalent reconciliation refreshes the same episode in place
      # instead of minting another row.
      assert {:ok, %{action: :no_admissible_commitment}} =
               FleetExecution.reconcile_market_evidence(
                 scope,
                 agent,
                 revision,
                 @system,
                 scenario_capacity()
               )

      refreshed = current_wait()
      assert refreshed.id == episode.id

      assert length(refreshed.actual_outcomes["re_evaluations"] || []) >= 2

      assert neutral_wait_count() == 1 and selected_plan_episodes_unsuperseded() == []
      assert Repo.reload!(episode).classification == :still_evaluating
    end
  end

  describe "look-alike dispositions never mint a Neutral Wait" do
    test "unknown governed availability reports its own disposition and records nothing", %{
      agent: agent
    } do
      stub_api(fn conn -> Req.Test.json(conn, %{"error" => "unavailable"}) end)

      assert {:error, :availability_unknown} = FleetExecution.governed_availability(agent)

      assert neutral_wait_count() == 0
    end

    test "API-capacity deferral retains its own disposition and records no wait", %{
      agent: agent,
      revision: revision,
      scope: scope
    } do
      ship = Repo.insert!(%Ship{symbol: "WAIT-1", ship_type: "SHIP_PROBE", agent_id: agent.id})
      stub_game_reads(agent, ship)

      capacity = %CapacitySnapshot{
        observed_at: SpaceTraders.Clock.utc_now(),
        available_slots: 0,
        evidence_fingerprint: "deferred",
        backpressure: :normal
      }

      assert {:ok, %{action: :deferred_for_capacity}} =
               FleetExecution.reconcile_market_evidence(
                 scope,
                 agent,
                 revision,
                 @system,
                 capacity
               )

      assert neutral_wait_count() == 0
    end

    test "objective infeasibility is a distinct producer outcome and records no wait" do
      operator = Repo.insert!(%SpaceTraders.Agent.Operator{email: "infeasible@example.com"})

      agent =
        Repo.insert!(%AgentRecord{
          symbol: "INFEASIBLE",
          faction: "COSMIC",
          headquarters: "X1-UX81-A1",
          agent_token: "AGENT_TOKEN",
          operator_id: operator.id
        })

      assert {:ok, _notification} =
               FleetAllocation.report_infeasibility(
                 agent,
                 "INFEASIBLE-1",
                 %{
                   "kind" => "objective_infeasibility",
                   "subject" => @market_subject,
                   "reason" => "destination_unreachable"
                 },
                 fn -> :ok end
               )

      assert neutral_wait_count() == 0
    end
  end

  defp current_wait do
    StrategyDecisionEpisode
    |> where(
      [episode],
      episode.selection_kind == :neutral_wait and episode.classification == :still_evaluating
    )
    |> order_by([episode], desc: episode.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp neutral_wait_count do
    Repo.one(
      from(episode in StrategyDecisionEpisode,
        where: episode.selection_kind == :neutral_wait,
        select: count()
      )
    )
  end

  defp selected_plan_episodes_unsuperseded do
    Repo.all(
      from(episode in StrategyDecisionEpisode,
        where: episode.selection_kind == :selected_plan and episode.classification != :superseded,
        select: episode.id
      )
    )
  end

  defp scenario_capacity do
    %CapacitySnapshot{
      observed_at: SpaceTraders.Clock.utc_now(),
      available_slots: 10,
      evidence_fingerprint: "neutral-wait-scenario",
      backpressure: :normal
    }
  end

  defp open_market_demands(agent) do
    Evidence.list_open_demands(agent)
    |> Enum.filter(&String.starts_with?(&1.subject, "market:"))
  end

  defp request_future_demand(agent, revision, seconds_from_now) do
    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: @market_subject,
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(SpaceTraders.Clock.utc_now(), seconds_from_now, :second),
        owner: "fleet_planning"
      })

    demand
  end

  defp observed_market_fixture(agent) do
    ship = Repo.insert!(%Ship{symbol: "WAIT-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => @system,
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

    {agent, ship}
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

    Intelligence.observe_market(agent, @system, listing,
      source: "get_market",
      observing_ship_symbol: ship.symbol,
      observed_at: observed_at
    )
  end

  defp stub_game_reads(agent, ship) do
    ship_path = "/v2/my/ships/#{ship.symbol}"
    market_path = @market_path
    test_pid = self()

    stub_api(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", ^ship_path <> "/orbit"} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"GET", ^market_path} ->
          send(test_pid, {:market_read, market_path})

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

        _other ->
          Req.Test.json(conn, %{"data" => %{"error" => "unexpected"}})
      end
    end)
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
end
