defmodule SpaceTraders.MarketSpendingAdmissionTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RecordedDispatchFixtures

  alias SpaceTraders.API
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.TestClock
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  setup do
    start_supervised!({TestClock, DateTime.utc_now()})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    :ok
  end

  test "worst-case exposure rounds the margin-loaded quote up and refuses a margin below the hard bound" do
    assert SpaceTraders.MarketSpending.worst_case_exposure(0, 1, 25) == 0
    assert SpaceTraders.MarketSpending.worst_case_exposure(1_000, 1, 25) == 1_250
    assert SpaceTraders.MarketSpending.worst_case_exposure(50, 1, 25) == 63
    assert SpaceTraders.MarketSpending.worst_case_exposure(50, 3, 50) == 225

    assert_raise FunctionClauseError, fn ->
      SpaceTraders.MarketSpending.worst_case_exposure(50, 1, 9)
    end
  end

  test "purchase preparation retains the acquired quote and calibrated exposure before any marker" do
    agent = operator_fixture() |> agent_fixture()
    stub_quote(agent, 10, 2_000)

    %{attempt: attempt} = prepare_action(agent, "BUYER", buy(), live_quote: true)

    assert %{
             "quote_observation_id" => quote_id,
             "quote_observed_at" => observed_at,
             "unit_price" => 10,
             "units" => 5,
             "calibration_version" => "market-purchase-v1-25pct",
             "margin_percent" => 25,
             "worst_case_exposure" => 63
           } = attempt.prepared_evidence["spending"]

    assert {:ok, quote} = Evidence.retained_binding(agent, quote_id)
    assert observed_at == DateTime.to_iso8601(quote.observation.observed_at)
    assert quote.value.symbol == agent.headquarters
    assert attempt.state == "prepared"
    assert attempt.sent_or_unknown_at == nil

    assert {:ok, admitted} = RecordedAction.admit_send(attempt)
    assert admitted.state == "sent_or_unknown"
    assert MutationAttempts.get!(attempt.id).prepared_evidence == attempt.prepared_evidence
  end

  test "a quote that ages after preparation withdraws the unchanged request before transport" do
    agent = operator_fixture() |> agent_fixture()
    stub_quote(agent, 10, 2_000)
    %{intent: intent, attempt: attempt} = prepare_action(agent, "BUYER", buy(), live_quote: true)
    TestClock.advance(31)
    Req.Test.stub(API, fn _ -> flunk("stale prepared purchase reached transport") end)

    assert {:error, :market_quote_stale_or_missing} = API.dispatch_recorded(attempt)
    withdrawn = MutationAttempts.get!(attempt.id)
    assert withdrawn.state == "not_sent"
    assert withdrawn.sent_or_unknown_at == nil
    assert withdrawn.prepared_evidence["request"]["body"]["units"] == 5

    assert %{in_flight_action: nil, mutation_attempt_id: nil, status: "superseded"} =
             Repo.get!(Intent, intent.id)
  end

  test "missing quote facts defer preparation without an attempt or transport" do
    agent = operator_fixture() |> agent_fixture()
    stub_quote(agent, nil, 2_000)

    assert %{error: {:error, :market_quote_unavailable}} =
             prepare_action(agent, "BUYER", buy(), live_quote: true)

    assert MutationAttempts.list_for_agent(agent) == []
  end

  test "a rejected quote read creates no prepared or sent attempt" do
    agent = operator_fixture() |> agent_fixture()

    Req.Test.stub(API, fn conn ->
      assert conn.method == "GET"

      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "retry later"}})
    end)

    assert %{error: {:error, _}} = prepare_action(agent, "BUYER", buy(), live_quote: true)
    assert MutationAttempts.list_for_agent(agent) == []
  end

  test "a newer balance makes prepared units unaffordable without resizing or sending" do
    {agent, intents, _portfolio} = claimed_purchases([63])
    stub_quote(agent, 10, 1_100)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, hd(intents), buy())
    TestClock.advance(1)
    stub_quote(agent, 10, 1_050)
    assert {:ok, _} = Evidence.get_agent_binding(agent)
    Req.Test.stub(API, fn _ -> flunk("unaffordable purchase reached transport") end)

    assert {:error, :insufficient_unreserved_headroom} = API.dispatch_recorded(attempt)

    assert %{state: "not_sent", sent_or_unknown_at: nil} =
             withdrawn = MutationAttempts.get!(attempt.id)

    assert withdrawn.prepared_evidence["request"]["body"]["units"] == 5
    assert {:error, :no_current_ship_claim} = FleetAllocation.current_ship_claim(agent, "BUYER-0")
    scope = Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
    assert %{commitments: []} = FleetAllocation.current_portfolio(scope, agent)
  end

  test "the current action consumes its own Reservation exactly once" do
    {agent, [intent], _portfolio} = claimed_purchases([63])
    stub_quote(agent, 10, 1_063)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, buy())
    assert {:ok, %{state: "sent_or_unknown"}} = RecordedAction.admit_send(attempt)
  end

  test "a different active Fleet Reservation protects headroom even when this Ship arrives first" do
    {agent, [intent | _], _portfolio} = claimed_purchases([63, 50])
    stub_quote(agent, 10, 1_100)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, buy())
    Req.Test.stub(API, fn _ -> flunk("purchase consumed another Commitment's Reservation") end)
    assert {:error, :insufficient_unreserved_headroom} = API.dispatch_recorded(attempt)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(attempt.id)
    assert {:ok, _} = FleetAllocation.current_ship_claim(agent, "BUYER-1")
  end

  test "admitted exposure replaces its Reservation rather than charging both" do
    {agent, [first, second], _portfolio} = claimed_purchases([63, 63])
    stub_quote(agent, 10, 1_126)
    assert {:ok, %{attempt: one}} = RecordedAction.prepare(agent, first, buy())
    assert {:ok, %{attempt: two}} = RecordedAction.prepare(agent, second, buy())
    assert {:ok, _} = RecordedAction.admit_send(one)

    # The existing Safety Fence still suppresses dependent credit mutations.
    # Reaching it proves spending admitted exactly 63 + 63, rather than 189.
    assert {:error, reason} = RecordedAction.admit_send(two)
    refute reason == :insufficient_unreserved_headroom
    assert %{state: "prepared", sent_or_unknown_at: nil} = MutationAttempts.get!(two.id)
  end

  test "Bounded Unknown purchase exposure survives durable reload and still consumes headroom" do
    {agent, [first, second], _portfolio} = claimed_purchases([0, 0])
    stub_quote(agent, 10, 1_100)
    assert {:ok, %{attempt: one}} = RecordedAction.prepare(agent, first, buy())
    assert {:ok, %{attempt: two}} = RecordedAction.prepare(agent, second, buy())
    assert {:ok, one} = RecordedAction.admit_send(one)
    TestClock.advance(1)

    Req.Test.stub(API, fn conn ->
      data =
        case conn.request_path do
          "/v2/my/agent" -> %{"symbol" => agent.symbol, "credits" => 1_100}
          _ -> SpaceTraders.ShipBody.ship_body("BUYER-0")
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    assert {:ok, ship} = Evidence.get_ship_binding(agent, "BUYER-0")
    assert {:ok, credits} = Evidence.get_agent_binding(agent)

    assert {:ok, proof} =
             Evidence.recovery_proof(
               one,
               :bounded_unknown,
               "At most one purchase at the retained exposure bound",
               [ship, credits]
             )

    accounting =
      Evidence.constraint_accounting("At most 63 credits", [
        %{
          constraint: "Keep at least 1,000 credits available",
          satisfied: true,
          evidence: "1,100 minus 63 leaves 1,037"
        }
      ])

    assert {:ok, _} =
             MutationAttempts.reconcile(one, :bounded_unknown, proof,
               constraint_accounting: accounting
             )

    Req.Test.stub(API, fn _ -> flunk("durable exposure reload acquired new facts or sent") end)
    two = MutationAttempts.get!(two.id)
    assert {:error, :insufficient_unreserved_headroom} = API.dispatch_recorded(two)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(two.id)
    assert %{state: "bounded_unknown"} = MutationAttempts.get!(one.id)
  end

  defp claimed_purchases(reservations) do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction
      })

    candidates =
      Enum.with_index(reservations, fn credits, index ->
        symbol = "BUYER-#{index}"
        {:ok, _} = SpaceTraders.Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")

        %PortfolioCandidate{
          id: "purchase-#{index}",
          strategy_revision_id: revision.id,
          objective_index: 0,
          claims: [symbol],
          reservations: %{credits: credits},
          pledges: [],
          dependencies: [],
          expected_value: 10,
          unwind_cost: 0
        }
      end)

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, candidates, %{
        as_of: SpaceTraders.Clock.utc_now(),
        source_version: 0,
        claims: Enum.flat_map(candidates, & &1.claims),
        reservations: %{credits: 2_000}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "market-purchase-v1-25pct"
      })

    intents =
      portfolio.commitments
      |> Enum.sort_by(& &1.candidate_id)
      |> Enum.map(fn commitment ->
        [symbol] = commitment.claims
        ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: agent.id, symbol: symbol)

        Repo.insert!(%Intent{
          ship_id: ship.id,
          caller: "commitment",
          type: "buy",
          status: "active",
          target_waypoint: agent.headquarters,
          parameters: %{"units" => 5, "trade_symbol" => "IRON_ORE"},
          fleet_commitment_id: commitment.id,
          fleet_commitment_portfolio_id: portfolio.id,
          fleet_commitment_portfolio_version: portfolio.version
        })
      end)

    {agent, intents, portfolio}
  end

  defp buy,
    do: %{"kind" => "buy", "trade_symbol" => "IRON_ORE", "units" => 5, "listing_price" => 10}

  defp stub_quote(agent, price, credits) do
    Req.Test.stub(API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

        _ ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.headquarters,
              "exports" => [],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{"symbol" => "IRON_ORE", "purchasePrice" => price, "tradeVolume" => 5}
              ]
            }
          })
      end
    end)
  end
end
