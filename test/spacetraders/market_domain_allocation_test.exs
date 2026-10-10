defmodule SpaceTraders.MarketDomainAllocationTest do
  # Commitment dispatch may start Ship servers in the shared registry.
  use SpaceTraders.DataCase, async: false

  import Ecto.Query
  import SpaceTraders.EvidenceFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, Reconciler, StrategyDecisionEpisode}
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Test.CapacityDispositions

  @system "X1"
  @frigate "FRIGATE"
  @probe "PROBE"

  setup do
    on_exit(fn -> SpaceTraders.Quiesced.stop_all_ships() end)
    :ok
  end

  describe "the Market trade and coverage pilot domain" do
    test "at a coverage completion boundary trade and due coverage are chosen in one decision" do
      fleet = fleet([@frigate, @probe])

      assert :ok = Reconciler.observe_waypoint_intelligence(fleet.agent.id, @system, proceed())
      assert :ok = Reconciler.observe_market_evidence(fleet.agent.id, @system, proceed())

      assert %{"market_trade" => [@frigate], "market_coverage" => [@probe]} =
               published_work(fleet)

      # Both Commitments came from one Strategy Decision Episode, so neither
      # capability published ahead of the comparison.
      assert [episode] = selected_episodes(fleet)
      assert length(commitments_of(episode)) == 2
    end

    test "reversing the evidence broadcast order selects the same portfolio" do
      # Each Fleet is decided before the next one's game stub replaces it.
      intelligence_first = fleet([@frigate, @probe])
      Reconciler.observe_waypoint_intelligence(intelligence_first.agent.id, @system, proceed())
      Reconciler.observe_market_evidence(intelligence_first.agent.id, @system, proceed())

      market_first = fleet([@frigate, @probe])
      Reconciler.observe_market_evidence(market_first.agent.id, @system, proceed())
      Reconciler.observe_waypoint_intelligence(market_first.agent.id, @system, proceed())

      assert published_work(intelligence_first) == published_work(market_first)
      assert published_work(market_first)["market_trade"] == [@frigate]
    end

    test "with one capable Ship the positive trade wins and the Episode explains coverage's loss" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)

      assert %{"market_trade" => [@frigate]} = published_work(fleet)
      assert [episode] = selected_episodes(fleet)

      assert Enum.any?(episode.alternatives, fn alternative ->
               alternative["reasons"] == ["claim_conflict"] and
                 is_binary(alternative["decisive_reason"])
             end)
    end

    test "a busy Ship keeps its retained Commitment while the free Ship receives new work" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      %Portfolio{id: portfolio_id} = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      # The coverage scout finished; the trader is still mid round trip.
      finish_intents(commitment_for(fleet, @probe))
      observe_marketplace(fleet.agent, "X1-A4", 4)

      assert {:ok, %{action: action}} = reconcile(fleet)
      assert action in [:published, :retained]

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.id == portfolio_id
      assert Enum.any?(current.commitments, &(&1.id == trade.id))
    end

    test "a rejected publication leaves a durable reason instead of a swallowed error" do
      fleet = fleet([@frigate, @probe])
      handler = attach_telemetry([:spacetraders, :fleet_allocation, :publication])

      # A newer Revision activates between the decision and its publication.
      stale = fleet.revision
      supersede_revision(fleet)

      assert {:ok, %{action: :publication_rejected, reason: :stale_source}} =
               FleetExecution.reconcile_market_domain(
                 fleet.scope,
                 fleet.agent,
                 stale,
                 @system,
                 proceed()
               )

      assert [
               %StrategyDecisionEpisode{
                 selection_kind: :publication_rejected,
                 rejection_reason: "stale_source",
                 classification: :superseded
               } = episode
             ] = Repo.all(StrategyDecisionEpisode)

      assert episode.alternatives != []
      assert Repo.aggregate(Portfolio, :count) == 0

      assert_receive {:telemetry, ^handler, %{count: 1},
                      %{result: :rejected, reason: :stale_source}}
    end

    test "every domain decision reports trade and coverage candidate counts" do
      fleet = fleet([@frigate, @probe])
      handler = attach_telemetry([:spacetraders, :fleet_allocation, :market_domain])

      assert {:ok, _} = reconcile(fleet)

      assert_receive {:telemetry, ^handler,
                      %{
                        trade_candidates: trade,
                        coverage_candidates: 1,
                        claimable_ships: 2,
                        selected: 2
                      }, %{result: :published, decisive_reason: _}}

      assert trade >= 1
    end

    test "G1 and G2 outcomes reach the metrics scrape with bounded labels only" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :published}} = reconcile(fleet)

      metrics = PromEx.get_metrics(SpaceTraders.PromEx)

      assert metrics =~
               ~s(spacetraders_fleet_allocation_market_domain_decisions_total{decisive_reason="trade_and_coverage_selected",result="published"})

      assert metrics =~
               ~s(spacetraders_fleet_allocation_publication_total{operation="publish",reason="none",result="published"})

      refute metrics =~ ~r/spacetraders_fleet_allocation_[a-z_]+\{[^}]*(agent_id|generation_id)/
    end

    test "API-capacity deferral is explicit and publishes nothing" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :deferred_for_capacity}} =
               FleetExecution.reconcile_market_domain(
                 fleet.scope,
                 fleet.agent,
                 fleet.revision,
                 @system,
                 CapacityDispositions.defer()
               )

      assert Repo.aggregate(Portfolio, :count) == 0
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end
  end

  describe "Observation Demand retention through Allocation" do
    test "a selected trade leaves never-observed coverage open with its original timing, then coverage resumes" do
      fleet = fleet([@frigate])

      :ok =
        SpaceTraders.FleetIntelligence.sync_market_observation_demands(
          fleet.agent,
          fleet.revision,
          @system
        )

      before = open_market_demands(fleet)
      assert Map.has_key?(before, "market:X1:X1-A3"), inspect(Map.keys(before))

      assert {:ok, %{action: :published}} = reconcile(fleet)
      assert %{"market_trade" => [@frigate]} = published_work(fleet)

      # The trade did not withdraw, refresh or re-time the unfulfilled Demand.
      assert open_market_demands(fleet)["market:X1:X1-A3"] == before["market:X1:X1-A3"]

      # Valid retained evidence is not reacquired: its refresh waits for the
      # freshness budget instead of being due now.
      {_id, due_at, _deadline, _revision} = open_market_demands(fleet)["market:X1:X1-A1"]
      assert DateTime.compare(due_at, DateTime.utc_now()) == :gt

      # The trade finishes and its spread disappears: the one capable Ship is
      # free for the coverage the Demand still asks for.
      finish_intents(commitment_for(fleet, @frigate), DateTime.add(DateTime.utc_now(), -600))
      listing(fleet.agent, "X1-A2", 10, 9)

      assert {:ok, %{action: :published, dispatched: dispatched}} = reconcile(fleet)
      assert %{"market_coverage" => [@frigate]} = published_work(fleet)
      assert [{:ok, _intent}] = Map.values(dispatched)
      assert Map.has_key?(open_market_demands(fleet), "market:X1:X1-A3")
    end
  end

  describe "capacity deferral and missing evidence" do
    test "a capacity-deferred request names its retry time and keeps the Demand's earliest-useful time" do
      fleet = fleet([@frigate, @probe])

      :ok =
        SpaceTraders.FleetIntelligence.sync_market_observation_demands(
          fleet.agent,
          fleet.revision,
          @system
        )

      before = open_market_demands(fleet)
      deferral = CapacityDispositions.defer()

      assert {:ok,
              %{
                action: :deferred_for_capacity,
                retry_at: retry_at,
                reason: :capacity_deferred,
                pending_demands: pending
              }} =
               FleetExecution.reconcile_market_domain(
                 fleet.scope,
                 fleet.agent,
                 fleet.revision,
                 @system,
                 deferral
               )

      assert retry_at == deferral.retry_at
      assert Enum.any?(pending, &(&1.subject == "market:X1:X1-A3"))
      assert open_market_demands(fleet) == before
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end

    test "invalid evidence is explained as a Market evidence limitation, not capacity or infeasibility" do
      fleet = fleet([@frigate])

      Repo.update_all(SpaceTraders.Intelligence.Fact, set: [invalidated_at: DateTime.utc_now()])

      assert {:ok,
              %{
                action: :no_admissible_commitment,
                reason: :market_evidence_unusable,
                neutral_wait: nil,
                evidence_limitations: limitations
              } = result} = reconcile(fleet)

      refute Map.has_key?(result, :retry_at)
      assert Enum.all?(limitations, &(&1.reason == :invalidated_market_evidence))

      # Neither a Neutral Wait nor an infeasibility verdict is recorded.
      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end
  end

  describe "price and source changes" do
    test "a changed price replans the affected trade and keeps unrelated retained Commitments" do
      fleet = fleet([@frigate, @probe])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      coverage = commitment_for(fleet, @probe)
      %Portfolio{id: portfolio_id} = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      # The trade leg finished long ago; the scout is still working.
      finish_intents(trade, DateTime.add(DateTime.utc_now(), -600))
      listing(fleet.agent, "X1-A1", 10, 9)
      listing(fleet.agent, "X1-A2", 40, 35)

      assert {:ok, %{action: :published, commitments: [replanned]}} = reconcile(fleet)

      current = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)
      assert current.id == portfolio_id
      kept = Enum.find(current.commitments, &(&1.id == coverage.id))
      assert kept.claims == coverage.claims
      assert kept.reservations == coverage.reservations

      assert replanned.claims == trade.claims
      assert replanned.dependencies != trade.dependencies
      assert replanned.reservations["credits"] > 0

      claims = Enum.flat_map(current.commitments, & &1.claims)
      assert claims == Enum.uniq(claims)
    end
  end

  describe "buy-to-sell continuation" do
    test "a completed buy whose sell was never requested sells on the next Market boundary, once" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "completed")

      # A new Market observation (or a restart) reaches the same entry.
      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)

      assert %{"buy" => 1, "sell" => 1} = intent_counts(trade)
      assert %Intent{} = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "sell")

      # A later boundary neither buys nor sells again.
      assert {:ok, %{action: :retained}} = reconcile(fleet)
      assert %{"buy" => 1, "sell" => 1} = intent_counts(trade)
    end

    test "a buy whose effect is unconfirmed is never replayed or continued" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)
      complete_buy(trade, "awaiting_confirmation")

      listing(fleet.agent, "X1-A2", 30, 25)
      assert {:ok, %{action: :retained}} = reconcile(fleet)

      assert %{"buy" => 1} = counts = intent_counts(trade)
      refute Map.has_key?(counts, "sell")
    end
  end

  defp complete_buy(commitment, status) do
    Repo.update_all(
      from(intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id and intent.type == "buy"
      ),
      set: [
        status: status,
        finished_at: DateTime.utc_now(:second),
        last_action_result: %{"units" => 40, "transaction" => %{"total_price" => 400}}
      ]
    )
  end

  defp intent_counts(commitment) do
    Repo.all(
      from intent in Intent,
        where: intent.fleet_commitment_id == ^commitment.id,
        group_by: intent.type,
        select: {intent.type, count(intent.id)}
    )
    |> Map.new()
  end

  describe "last-chance authority" do
    test "publication is refused when a newer Market observation superseded the planned evidence" do
      fleet = fleet([@frigate])
      assert {:ok, %{action: :published, commitments: [trade]}} = reconcile(fleet)

      listing(fleet.agent, "X1-A1", 10, 9)
      listing(fleet.agent, "X1-A2", 40, 35)

      assert {:error, :stale_evidence} =
               SpaceTraders.FleetAllocation.MarketDomain.revalidate_trade_evidence(fleet.agent, [
                 trade
               ])
    end

    test "the dispatched buy cannot spend above the quote the decision was planned on" do
      fleet = fleet([@frigate])

      assert {:ok, %{action: :published}} = reconcile(fleet)
      trade = commitment_for(fleet, @frigate)

      buy = Repo.get_by!(Intent, fleet_commitment_id: trade.id, type: "buy")
      assert buy.parameters["max_price"] == 10
    end
  end

  defp open_market_demands(fleet) do
    fleet.agent
    |> SpaceTraders.Evidence.list_open_demands()
    |> Map.new(&{&1.subject, {&1.id, &1.due_at, &1.deadline_at, &1.strategy_revision_id}})
  end

  defp reconcile(fleet) do
    FleetExecution.reconcile_market_domain(
      fleet.scope,
      fleet.agent,
      fleet.revision,
      @system,
      proceed()
    )
  end

  defp proceed, do: CapacityDispositions.proceed()

  # Persisted Commitment kind => the Ships it claims, read from the current
  # Portfolio and its dispatched root Intents.
  defp published_work(fleet) do
    case FleetAllocation.current_portfolio(fleet.scope, fleet.agent) do
      nil ->
        %{}

      portfolio ->
        portfolio.commitments
        |> Enum.group_by(&commitment_kind/1, & &1.claims)
        |> Map.new(fn {kind, claims} ->
          {kind, claims |> List.flatten() |> Enum.map(&role(fleet, &1)) |> Enum.sort()}
        end)
    end
  end

  defp role(fleet, symbol), do: String.replace_prefix(symbol, fleet.agent.symbol <> "-", "")

  defp commitment_kind(%Commitment{dependencies: dependencies}) do
    if Enum.any?(dependencies, &Map.has_key?(&1, "evidence_id")),
      do: "market_trade",
      else: "market_coverage"
  end

  defp selected_episodes(fleet) do
    Repo.all(
      from episode in StrategyDecisionEpisode,
        where:
          episode.operator_id == ^fleet.operator.id and episode.selection_kind == :selected_plan,
        order_by: episode.id
    )
  end

  defp commitments_of(episode) do
    Repo.all(
      from commitment in Commitment,
        join: portfolio in Portfolio,
        on: portfolio.id == commitment.fleet_commitment_portfolio_id,
        where: portfolio.strategy_decision_episode_id == ^episode.id
    )
  end

  defp commitment_for(fleet, ship_symbol) do
    fleet.scope
    |> FleetAllocation.current_portfolio(fleet.agent)
    |> Map.fetch!(:commitments)
    |> Enum.find(&(&1.claims == ["#{fleet.agent.symbol}-#{ship_symbol}"]))
  end

  defp finish_intents(commitment, finished_at \\ DateTime.utc_now()) do
    Repo.update_all(
      from(intent in Intent, where: intent.fleet_commitment_id == ^commitment.id),
      set: [status: "completed", finished_at: DateTime.truncate(finished_at, :second)]
    )
  end

  defp attach_telemetry(event) do
    handler = "domain-#{System.unique_integer()}"
    test = self()

    :telemetry.attach(
      handler,
      event,
      fn _event, measurements, metadata, _config ->
        send(test, {:telemetry, handler, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp supersede_revision(fleet) do
    strategy = Repo.get!(Strategy, fleet.revision.fleet_strategy_id)

    newer =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 2,
        document: fleet.revision.document,
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: newer.id))
  end

  # A frigate with a 40-unit hold and a fuel-free probe at X1-A1. X1-A1 and
  # X1-A2 hold current Listings with a positive IRON spread deeper than the
  # hold; X1-A3 is a known Marketplace never observed.
  defp fleet(ship_symbols) do
    operator = Repo.insert!(%Operator{email: "domain-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%SpaceTraders.Agent.Agent{
        symbol: "DOMAIN#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-A1",
        agent_token: "test-agent-token",
        operator_id: operator.id
      })

    for role <- ship_symbols,
        do:
          Repo.insert!(%Ship{
            symbol: "#{agent.symbol}-#{role}",
            ship_type: "SHIP_PROBE",
            agent_id: agent.id
          })

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
              "evaluation" => "Maximize net credit growth over time",
              "scope" => "recurring"
            }
          ],
          "hard_constraints" => ["Keep at least 500 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

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

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    observe_marketplace(agent, "X1-A1", 0)
    observe_marketplace(agent, "X1-A2", 3)
    observe_marketplace(agent, "X1-A3", 6)
    listing(agent, "X1-A1", 10, 9)
    listing(agent, "X1-A2", 30, 25)
    stub_game(agent, ship_symbols)

    %{operator: operator, agent: agent, revision: revision, scope: Scope.for_operator(operator)}
  end

  defp observe_marketplace(agent, symbol, x) do
    waypoint =
      Waypoint.from_json(%{
        "symbol" => symbol,
        "systemSymbol" => @system,
        "type" => "PLANET",
        "x" => x,
        "y" => 0,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
  end

  defp listing(agent, waypoint, purchase_price, sell_price) do
    retained_market_listing(agent, @system, waypoint, [
      %{
        symbol: "IRON",
        purchase_price: purchase_price,
        sell_price: sell_price,
        trade_volume: 60,
        supply: "MODERATE",
        activity: "STATIC"
      }
    ])
  end

  defp ship(@frigate, symbol) do
    ship_body(symbol, %{
      "nav" => nav_at("X1-A1"),
      "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
    })
  end

  defp ship(@probe, symbol) do
    body = ship_body(symbol)

    Map.merge(body, %{
      "nav" => nav_at("X1-A1"),
      "frame" => Map.put(body["frame"], "symbol", "FRAME_PROBE"),
      "fuel" => %{"capacity" => 0, "current" => 0},
      "cargo" => %{"capacity" => 0, "units" => 0, "inventory" => []}
    })
  end

  defp nav_at(waypoint) do
    nav_body("DOCKED")
    |> Map.put("systemSymbol", @system)
    |> Map.put("waypointSymbol", waypoint)
  end

  # The game answers Fleet reads; anything Ship execution attempts beyond
  # them is refused, which leaves dispatched Intents blocked but never
  # changes the allocation result under test.
  defp stub_game(agent, ship_symbols) do
    ships = Enum.map(ship_symbols, &ship(&1, "#{agent.symbol}-#{&1}"))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "accountId" => "ACC",
              "symbol" => agent.symbol,
              "headquarters" => agent.headquarters,
              "credits" => 5_000,
              "startingFaction" => "COSMIC",
              "shipCount" => length(ships)
            }
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => ships})

        {"GET", "/v2/my/ships/" <> symbol} ->
          case Enum.find(ships, &(&1["symbol"] == symbol)) do
            nil -> refuse(conn)
            body -> Req.Test.json(conn, %{"data" => body})
          end

        _other ->
          refuse(conn)
      end
    end)
  end

  defp refuse(conn) do
    conn
    |> Plug.Conn.put_status(400)
    |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "refused by test"}})
  end
end
