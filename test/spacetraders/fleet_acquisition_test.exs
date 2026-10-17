defmodule SpaceTraders.FleetAcquisitionTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.API.Model.{Shipyard, Waypoint}
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAcquisition
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.Repo

  # The Shipyard promises engine speed 30, so a Ship reporting anything else
  # fails the readiness gate and must never enter the registry.
  @offered_speed 30
  @credits 20_000
  @price 10_000

  # The offered frame has 3 module slots and 2 mounting points, the template
  # fills none, and the shipyard charges 500 per modification, so acquiring the
  # Ship must also reserve 2,500 for the outfitting that follows.
  @modification_fee 500
  @preparation_exposure 2_500

  test "the purchase is inadmissible while no owned Ship is co-located" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A2")]})
        {"POST", "/v2/my/ships"} -> flunk("must not purchase without a co-located Ship")
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, {:error, :purchase_precondition_unmet}}} =
             execute_purchase(scope, agent, revision)

    assert [_published] = Repo.all(StrategyDecisionEpisode)
    assert [] == purchase_attempts(agent)
  end

  test "a Ship still in transit toward the Shipyard does not satisfy the precondition" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          overview(conn, agent, @credits)

        {"GET", "/v2/my/ships"} ->
          # An IN_TRANSIT Ship's waypoint_symbol is its destination, not a position.
          Req.Test.json(conn, %{"data" => [in_transit_to("X1-UX81-A1")]})

        {"POST", "/v2/my/ships"} ->
          flunk("a Ship in transit is not co-located")
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, {:error, :purchase_precondition_unmet}}} =
             execute_purchase(scope, agent, revision)

    assert [] == purchase_attempts(agent)
  end

  test "registers a purchased Ship once readiness matches, then releases its Commitment" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> purchase(conn, agent)
        {"GET", "/v2/my/ships/ACQUIRE-2"} -> ship(conn, @offered_speed)
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}, readiness: %{engine: %{speed: 30}}}} =
             execute_purchase(scope, agent, revision)

    assert %Ship{symbol: "ACQUIRE-2", ship_type: "SHIP_LIGHT_HAULER"} =
             Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")

    # Registration grants no Claim. Fleet Allocation must grant one separately,
    # so a new Ship can never be commanded before that happens.
    assert {:error, :no_current_ship_claim} =
             FleetAllocation.current_ship_claim(agent, "ACQUIRE-2")

    # The Commitment reserved the purchase plus its Preparation Exposure.
    assert [episode] = Repo.all(StrategyDecisionEpisode)
    assert episode.classification == :realized
    assert episode.expectations["preparation_credits"] == @preparation_exposure
    assert episode.expectations["purchase_price"] == @price

    assert episode.actual_outcomes == %{
             "ship_symbol" => "ACQUIRE-2",
             "ship_type" => "SHIP_LIGHT_HAULER",
             "purchase_price" => @price,
             "transaction" => %{
               "agent_symbol" => agent.symbol,
               "price" => @price,
               "ship_symbol" => "ACQUIRE-2",
               "ship_type" => "SHIP_LIGHT_HAULER",
               "waypoint_symbol" => "X1-UX81-A1",
               "timestamp" => "2030-01-01T12:00:00Z"
             },
             "readiness" => "ready"
           }

    # The portfolio is released, so a later cycle may claim the new Ship.
    assert nil == FleetAllocation.current_portfolio(scope, agent)
  end

  test "restart dispatches a published acquisition with no Attempt without needing a new investment case" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)
    {portfolio, _} = published_purchase(scope, agent, revision)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> purchase(conn, agent)
        {"GET", "/v2/my/ships/ACQUIRE-2"} -> ship(conn, @offered_speed)
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, agent)

    assert [attempt] = purchase_attempts(agent)
    assert attempt.provenance["decision_episode_id"] == portfolio.strategy_decision_episode_id
  end

  for {loss, reason} <- [
        {:presence, :purchase_precondition_unmet},
        {:offer, :ship_offer_evidence_unavailable}
      ],
      boundary <- [:execute, :resume] do
    test "#{boundary} concludes only the attempt-less purchase after #{loss} is lost" do
      {scope, agent, revision} = generation()
      stub_shipyard(agent)
      {portfolio, candidate} = published_purchase(scope, agent, revision)
      [purchase] = portfolio.commitments
      retained = retain_independent_work(scope, agent, revision, portfolio)

      if unquote(loss) == :offer do
        Repo.update_all(SpaceTraders.Intelligence.Observation,
          set: [observed_at: DateTime.add(DateTime.utc_now(), -301)]
        )
      end

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/ships"} ->
            waypoint = if unquote(loss) == :presence, do: "X1-UX81-A2", else: "X1-UX81-A1"
            Req.Test.json(conn, %{"data" => [docked(waypoint)]})

          _ ->
            flunk("definitive pre-send refusal must not dispatch or read credits")
        end
      end)

      result =
        if unquote(boundary) == :execute,
          do: FleetAcquisition.execute(agent, portfolio, purchase, candidate),
          else: FleetAcquisition.reconcile(scope, agent)

      assert result == {:error, unquote(reason)}
      assert purchase_attempts(agent) == []
      assert FleetAcquisition.open_purchase(agent) == nil

      assert %{commitments: [%{id: retained_id}]} =
               FleetAllocation.current_portfolio(scope, agent)

      assert retained_id == retained.id

      assert {:ok, %{commitment_id: ^retained_id}} =
               FleetAllocation.current_ship_claim(agent, "CRUISER-1")

      episode = Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id)
      assert episode.classification == :superseded
      assert episode.actual_outcomes == %{"reason" => Atom.to_string(unquote(reason))}

      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("concluded acquisition must never replay") end)

      assert {:error, :no_purchase_attempt} =
               FleetAcquisition.reconcile(scope, agent)

      generation = FleetAllocation.active_generation(agent)

      {:ok, selection} =
        FleetAllocation.select_portfolio(revision, [candidate], %{
          as_of: DateTime.utc_now(),
          claims: [],
          reservations: %{credits: @credits - 100}
        })

      assert {:ok, _} =
               FleetAllocation.replan_subgraph(
                 scope,
                 generation.id,
                 Map.put(selection, :source_version, generation.allocation_version),
                 [candidate.id],
                 %{
                   evidence_references: [],
                   calibration_version: "ship-acquisition-v2",
                   expectations: episode.expectations
                 }
               )

      assert {%{id: next_id}, nil} = FleetAcquisition.open_purchase(agent)
      assert next_id != purchase.id

      assert {:ok, %{commitment_id: ^retained_id}} =
               FleetAllocation.current_ship_claim(agent, "CRUISER-1")
    end
  end

  for failure <- [:timeout, :capacity] do
    test "#{failure} during the precondition read retains the attempt-less purchase" do
      {scope, agent, revision} = generation()
      stub_shipyard(agent)
      {portfolio, _} = published_purchase(scope, agent, revision)
      [purchase] = portfolio.commitments

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/my/ships"

        if unquote(failure) == :timeout do
          Req.Test.transport_error(conn, :timeout)
        else
          conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => %{"code" => 429}})
        end
      end)

      assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
      assert {%{id: id}, nil} = FleetAcquisition.open_purchase(agent)
      assert id == purchase.id
      assert purchase_attempts(agent) == []

      assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
               :still_evaluating
    end
  end

  for change <- [:revision] do
    test "#{change} withdraws a published unsent acquisition without game reads" do
      {scope, agent, revision} = generation()
      {portfolio, _} = published_purchase(scope, agent, revision)
      change_purchase_authority(revision, unquote(change))
      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("withdrawal must stay local") end)
      assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
      assert purchase_attempts(agent) == []

      assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
               :superseded

      assert FleetAllocation.current_portfolio(scope, agent) == nil
    end

    for state <- [:ambiguous, :accepted] do
      test "#{change} preserves #{state} purchase recovery and original Episode registration" do
        {scope, agent, revision} = ambiguous_purchase()
        portfolio = FleetAllocation.current_portfolio(scope, agent)

        if unquote(state) == :accepted do
          Req.Test.stub(SpaceTraders.API, fn conn ->
            assert conn.method == "GET"

            case conn.request_path do
              "/v2/my/agent" ->
                overview(conn, agent, @credits - @price)

              "/v2/my/ships" ->
                Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

              "/v2/my/ships/ACQUIRE-2" ->
                conn
                |> Plug.Conn.put_status(503)
                |> Req.Test.json(%{"error" => %{"code" => 5000}})
            end
          end)

          assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
          assert [%{state: "accepted"}] = purchase_attempts(agent)
        end

        active = change_purchase_authority(revision, unquote(change))

        if unquote(change) == :revision do
          generation = FleetAllocation.active_generation(agent)

          assert {:ok, %{settling: [_]}} =
                   FleetAllocation.retire_stale_portfolio(scope, generation.id, active.id)

          assert {:ok, []} = FleetAllocation.release_settled_commitments(generation.id)
          Repo.update!(Ecto.Changeset.change(generation, fleet_strategy_revision_id: active.id))

          assert {:ok, _} =
                   FleetAllocation.publish_portfolio(
                     scope,
                     generation.id,
                     %{
                       revision_id: active.id,
                       source_version: generation.allocation_version,
                       commitments: [retained_proposal(active)],
                       rejected: []
                     },
                     %{
                       evidence_references: [],
                       expectations: %{domain: "market"},
                       calibration_version: "market-v1"
                     }
                   )
        end

        Req.Test.stub(SpaceTraders.API, fn conn ->
          assert conn.method == "GET"

          case conn.request_path do
            "/v2/my/agent" ->
              overview(conn, agent, @credits - @price)

            "/v2/my/ships" ->
              Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

            "/v2/my/ships/ACQUIRE-2" ->
              ship(conn, @offered_speed)
          end
        end)

        assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
                 FleetAcquisition.reconcile(scope, agent)

        assert [%{state: "accepted"}] = purchase_attempts(agent)

        assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
                 :realized

        if unquote(change) == :revision do
          current = FleetAllocation.current_portfolio(scope, agent)
          assert current.fleet_strategy_revision_id == active.id

          assert Repo.get_by!(SpaceTraders.FleetAllocation.AllocationResultPointer,
                   fleet_generation_id: current.fleet_generation_id
                 ).strategy_decision_episode_id == current.strategy_decision_episode_id
        end
      end
    end
  end

  defp change_purchase_authority(revision, :revision) do
    newer =
      Repo.insert!(%Revision{
        fleet_strategy_id: revision.fleet_strategy_id,
        number: 2,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: revision.document
      })

    Repo.update_all(from(s in Strategy, where: s.id == ^revision.fleet_strategy_id),
      set: [active_revision_id: newer.id]
    )

    newer
  end

  for state <- [:prepared, :not_sent] do
    test "restart safely withdraws #{state} purchase on its original published Commitment" do
      {scope, agent, revision} = generation()
      {portfolio, _} = published_purchase(scope, agent, revision)
      [commitment] = portfolio.commitments

      assert {:ok, attempt} =
               MutationAttempts.prepare(
                 SpaceTraders.API.OperationInventory.fetch!("purchase-ship"),
                 "/my/ships",
                 agent_id: agent.id,
                 json: %{shipType: "SHIP_LIGHT_HAULER", waypointSymbol: "X1-UX81-A1"},
                 dispatch_context: %{
                   commitment_id: commitment.id,
                   decision_episode_id: portfolio.strategy_decision_episode_id
                 }
               )

      if unquote(state) == :not_sent,
        do: MutationAttempts.record_not_sent(attempt, "transport never started")

      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("unsent interruption cannot replay") end)

      assert {:error, :ship_purchase_not_completed} =
               FleetAcquisition.reconcile(scope, agent)

      assert [%{state: "not_sent"}] = purchase_attempts(agent)
      assert FleetAllocation.current_portfolio(scope, agent) == nil
    end
  end

  test "a Bounded Unknown purchase stays open and recovers on the same Attempt" do
    {scope, agent, revision} = ambiguous_purchase()
    [attempt] = purchase_attempts(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/agent" ->
          overview(conn, agent, @credits - @price)

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/ships/ACQUIRE-2" ->
          ship(conn, @offered_speed)
      end
    end)

    assert {:ok, fleet} = Evidence.recovery_fleet_binding(agent, attempt)
    assert {:ok, credits} = Evidence.recovery_agent_binding(agent, attempt)

    assert {:ok, proof} =
             Evidence.recovery_proof(
               attempt,
               :bounded_unknown,
               "Purchase consequence remains protected by its Reservation",
               [fleet, credits]
             )

    accounting =
      Evidence.constraint_accounting(
        "At most the admitted purchase exposure",
        Enum.map(
          revision.document["hard_constraints"],
          &%{
            constraint: &1,
            satisfied: true,
            evidence: "20,000 credits cover the 15,000 Reservation and 1,000 floor"
          }
        )
      )

    assert {:ok, bounded} =
             MutationAttempts.reconcile(attempt, :bounded_unknown, proof,
               constraint_accounting: accounting
             )

    assert {_commitment, %{id: id}} = FleetAcquisition.open_purchase(agent)
    assert id == bounded.id

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, agent)

    assert [%{id: ^id, state: "accepted"}] = purchase_attempts(agent)
  end

  test "a Ship charged above its recorded bound is a pricing-model breach that widens calibration" do
    {scope, agent, revision} = generation()
    initial = SpaceTraders.CreditCalibration.active()
    stub_shipyard(agent)

    # Offered at 10,000 (bound 12,500); the game charges 13,000.
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> purchase(conn, agent, 13_000)
        {"GET", "/v2/my/ships/ACQUIRE-2"} -> ship(conn, @offered_speed)
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             execute_purchase(scope, agent, revision)

    assert [attempt] = purchase_attempts(agent)

    assert [
             %{
               kind: "pricing_model_miss",
               mutation_attempt_id: attempt_id,
               worst_case_exposure: 12_500,
               realized_charge: 13_000,
               released_at: nil
             }
           ] = SpaceTraders.CreditCalibration.shortfalls(agent)

    assert attempt_id == attempt.id

    assert %{within_bound: false, operation_id: "purchase-ship", units: 1, unit_price: @price} =
             SpaceTraders.CreditCalibration.realization(attempt)

    # 13,000 is 30% over the 10,000 offer; widening clears it by one step.
    assert %{margin_percent: 40, previous_version_id: previous} =
             SpaceTraders.CreditCalibration.active()

    assert previous == initial.id

    assert [%{kind: :attention, summary: summary}] =
             SpaceTraders.OperatorConditions.unresolved(scope)

    assert summary =~ "Degraded Operation: a Ship purchase charged 13000 credits"
  end

  test "a Ship whose readiness misses the promised capability is never registered" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> purchase(conn, agent)
        {"GET", "/v2/my/ships/ACQUIRE-2"} -> ship(conn, 5)
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, {:error, :ship_readiness_mismatch}}} =
             execute_purchase(scope, agent, revision)

    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")

    # Failing readiness means the Ship never enters the registry, so it cannot
    # be claimed either.
    assert {:error, :no_current_ship_claim} =
             FleetAllocation.current_ship_claim(agent, "ACQUIRE-2")

    assert [episode] = Repo.all(StrategyDecisionEpisode)
    assert episode.classification == :partially_realized
    assert episode.actual_outcomes["readiness"] == "mismatch"
  end

  test "matching engine speed cannot hide a different promised Cargo configuration" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          overview(conn, agent, @credits)

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})

        {"POST", "/v2/my/ships"} ->
          purchase(conn, agent)

        {"GET", "/v2/my/ships/ACQUIRE-2"} ->
          body = acquired(@offered_speed)

          Req.Test.json(conn, %{
            "data" => Map.put(body, "cargo", %{"capacity" => 0, "units" => 0, "inventory" => []})
          })
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, {:error, :ship_readiness_mismatch}}} =
             execute_purchase(scope, agent, revision)

    refute Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")
  end

  test "admitted exposure from recorded Ship spending blocks an otherwise affordable purchase" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)
    other_spend(agent, "sent_or_unknown", 9_000)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> flunk("exposed headroom must prevent the purchase")
      end
    end)

    # 20,000 credits cover the 12,500 worst case alone, but not beside 9,000 in flight.
    assert {:error, {:ship_acquisition_unavailable, {:error, :insufficient_unreserved_headroom}}} =
             execute_purchase(scope, agent, revision)

    assert [%{state: "not_sent", sent_or_unknown_at: nil}] = purchase_attempts(agent)
    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")
  end

  test "send revalidation protects its own Preparation Exposure after credits fall" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, 14_000)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> flunk("purchase would consume preparation headroom")
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, {:error, :insufficient_unreserved_headroom}}} =
             execute_purchase(scope, agent, revision)

    assert [%{state: "not_sent"}] = purchase_attempts(agent)
  end

  test "an unbounded historical purchase fails closed instead of guessing a bound" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)
    other_spend(agent, "ambiguous", nil)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> flunk("unbounded exposure must prevent the purchase")
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, {:error, :unbounded_purchase_exposure}}} =
             execute_purchase(scope, agent, revision)
  end

  test "a purchase prepared without retained offer evidence is never sent" do
    {_scope, agent, _revision} = generation()
    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("no bound, no dispatch") end)

    assert {:error, _} =
             SpaceTraders.API.purchase_ship(
               SpaceTraders.API.AgentTokenReference.new(agent),
               "SHIP_LIGHT_HAULER",
               "X1-UX81-A1"
             )

    assert [%{state: "not_sent", sent_or_unknown_at: nil}] = purchase_attempts(agent)
  end

  test "the ambiguous purchase Attempt itself retains the durable spending bound" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, _}} =
             execute_purchase(scope, agent, revision)

    assert [%{state: "ambiguous", prepared_evidence: %{"spending" => spending}}] =
             purchase_attempts(agent)

    assert %{"unit_price" => @price, "worst_case_exposure" => 12_500, "margin_percent" => 25} =
             spending

    # Exposure is the ceiling of price * 125%, with no speculative offset applied.
    assert 12_500 == SpaceTraders.CreditSpending.worst_case_exposure(@price, 1, 25)
  end

  test "the acquisition Reservation charges the same active calibrated bound admission uses" do
    {scope, agent, revision} = generation()
    {:ok, _} = SpaceTraders.CreditCalibration.supersede(50, "test_widening", %{})
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, _}} =
             execute_purchase(scope, agent, revision)

    assert [%{prepared_evidence: %{"spending" => %{"worst_case_exposure" => 15_000}}}] =
             purchase_attempts(agent)

    # 10,000 at the active 50% margin, plus the 2,500 outfitting reserve.
    assert %{commitments: [commitment]} =
             scope |> FleetAllocation.current_portfolio(agent) |> Repo.preload(:commitments)

    assert commitment.reservations["credits"] == 15_000 + @preparation_exposure
  end

  test "a purchase prepared under a superseded Strategy revision is never sent" do
    {_scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"POST", "/v2/my/ships"} -> flunk("superseded authority must not dispatch")
      end
    end)

    assert {:ok, offer} = SpaceTraders.CreditSpending.acquire_ship_purchase(agent, candidate())

    # The Operator activates a newer revision before the purchase's send marker.
    newer =
      Repo.insert!(%Revision{
        fleet_strategy_id: revision.fleet_strategy_id,
        number: 2,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: revision.document
      })

    Repo.update_all(from(s in Strategy, where: s.id == ^revision.fleet_strategy_id),
      set: [active_revision_id: newer.id]
    )

    assert {:error, :strategy_revision_superseded} =
             SpaceTraders.Observability.with_context(
               [
                 operator_id: agent.operator_id,
                 agent_id: agent.id,
                 strategy_revision_id: revision.id
               ],
               fn ->
                 SpaceTraders.API.purchase_ship(
                   SpaceTraders.API.AgentTokenReference.new(agent),
                   "SHIP_LIGHT_HAULER",
                   "X1-UX81-A1",
                   spending: offer
                 )
               end
             )

    assert [%{state: "not_sent", sent_or_unknown_at: nil, strategy_revision_id: id}] =
             purchase_attempts(agent)

    assert id == revision.id
  end

  test "fresh spending evidence cannot admit a purchase after the Fleet is fenced" do
    {_scope, agent, _revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      overview(conn, agent, @credits)
    end)

    assert {:ok, offer} = SpaceTraders.CreditSpending.acquire_ship_purchase(agent, candidate())
    assert {:ok, %{generation: generation}} = SpaceTraders.FleetGeneration.current_fleet()
    Repo.update!(Ecto.Changeset.change(generation, fenced_at: DateTime.utc_now()))
    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("fenced Fleet spending reached the game") end)

    assert {:error, :generation_not_current} =
             SpaceTraders.API.purchase_ship(
               SpaceTraders.API.AgentTokenReference.new(agent),
               "SHIP_LIGHT_HAULER",
               "X1-UX81-A1",
               spending: offer
             )

    # The current-Fleet gate refuses before a Mutation Attempt is even prepared.
    assert [] = purchase_attempts(agent)
  end

  test "Shipyard evidence that ages before the send marker prevents the purchase" do
    {_scope, agent, _revision} = generation()
    start_supervised!({SpaceTraders.TestClock, DateTime.utc_now()})
    previous = Application.fetch_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"POST", "/v2/my/ships"} -> flunk("stale offer evidence must not dispatch")
      end
    end)

    assert {:ok, _} =
             SpaceTraders.Evidence.get_agent(SpaceTraders.API.AgentTokenReference.new(agent))

    assert {:ok, offer} = SpaceTraders.CreditSpending.acquire_ship_purchase(agent, candidate())
    SpaceTraders.TestClock.advance(301)
    # Credits are fresh again, so only the aged Shipyard evidence can refuse.
    assert {:ok, _} =
             SpaceTraders.Evidence.get_agent(SpaceTraders.API.AgentTokenReference.new(agent))

    assert {:error, :ship_offer_evidence_unavailable} =
             SpaceTraders.API.purchase_ship(
               SpaceTraders.API.AgentTokenReference.new(agent),
               "SHIP_LIGHT_HAULER",
               "X1-UX81-A1",
               spending: offer
             )

    assert [%{state: "not_sent", sent_or_unknown_at: nil}] = purchase_attempts(agent)
  end

  test "recovers a lost purchase response from authoritative Fleet and Agent evidence" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    # The game accepts the purchase and deducts the price, but the response is
    # lost in transit, so the app must discover both facts from fresh reads.
    {:ok, spent} = Elixir.Agent.start_link(fn -> false end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          overview(
            conn,
            agent,
            if(Elixir.Agent.get(spent, & &1), do: @credits - @price, else: @credits)
          )

        {"POST", "/v2/my/ships"} ->
          Elixir.Agent.update(spent, fn _previous -> true end)
          Req.Test.transport_error(conn, :timeout)

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        {"GET", "/v2/my/ships/ACQUIRE-2"} ->
          ship(conn, @offered_speed)
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, _}} =
             execute_purchase(scope, agent, revision)

    assert [%{state: "ambiguous"}] = purchase_attempts(agent)
    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, agent)

    # Append-only: the original ambiguity is preserved and the reconciliation
    # is recorded as an additional outcome on the same attempt.
    assert [%{state: "accepted", outcomes: [ambiguous, outcome]} = attempt] =
             purchase_attempts(agent)

    assert ambiguous.classification == "ambiguous"

    # Fleet-level ownership: recovery never enters the Ship-scoped lifecycle.
    assert [attempt.id] == Enum.map(MutationAttempts.list_for_agent(agent), & &1.id)
    assert attempt.prepared_evidence["selected_action"] == nil
    assert Repo.aggregate(SpaceTraders.Fleet.Intent, :count) == 0

    # The attempt was reconciled against both fenced resources.
    assert [credits, owned_fleet] = observation_payloads(outcome)

    for proof <- [credits, owned_fleet] do
      assert %{"id" => id, "observed_at" => acquired_at} = proof["source"]
      source = Repo.get!(SpaceTraders.Evidence.Observation, id)
      assert proof["observed_at"] == acquired_at
      assert source.agent_id == agent.id
      assert source.fleet_generation_id == hd(purchase_attempts(agent)).fleet_generation_id
      assert proof["source"]["response_fingerprint"] == source.response_fingerprint
    end

    assert credits["operation_id"] == "get-my-agent"
    assert credits["dependency_keys"] == ["agent_credits:#{agent.id}"]
    assert credits["facts"]["response"]["credits"] == @credits - @price

    assert owned_fleet["operation_id"] == "get-my-ships"
    assert owned_fleet["dependency_keys"] == ["owned_fleet:#{agent.id}"]

    assert Enum.map(owned_fleet["facts"]["response"], & &1["symbol"]) ==
             ["CRUISER-1", "ACQUIRE-2"]

    assert [episode] = Repo.all(StrategyDecisionEpisode)
    assert episode.classification == :realized
  end

  test "a purchase the game never performed is proven absent and released for replanning" do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"POST", "/v2/my/ships"} -> Req.Test.transport_error(conn, :timeout)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, _}} =
             execute_purchase(scope, agent, revision)

    assert {:error, :ship_purchase_not_completed} =
             FleetAcquisition.reconcile(scope, agent)

    assert [%{state: "absent"}] = purchase_attempts(agent)
    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")
    assert nil == FleetAllocation.current_portfolio(scope, agent)
    assert [episode] = Repo.all(StrategyDecisionEpisode)
    assert episode.classification == :superseded
    assert episode.actual_outcomes == %{"reason" => "ship_purchase_not_completed"}
  end

  test "restart concludes an already absent purchase Attempt without releasing retained work" do
    {scope, agent, revision} = ambiguous_purchase()
    portfolio = FleetAllocation.current_portfolio(scope, agent)
    retained = retain_independent_work(scope, agent, revision, portfolio)
    [attempt] = purchase_attempts(agent)
    {:ok, fleet} = Evidence.get_ships(agent, bind: true)
    {:ok, credits} = Evidence.get_agent(agent, bind: true)
    {:ok, proof} = Evidence.recovery_proof(attempt, :absent, "No new Ship", [fleet, credits])
    assert {:ok, %{state: "absent"}} = MutationAttempts.reconcile(attempt, :absent, proof)

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("the absent Attempt is already authoritative")
    end)

    assert {:error, :ship_purchase_not_completed} =
             FleetAcquisition.reconcile(scope, Repo.get!(Agent, agent.id))

    assert %{commitments: [%{id: retained_id}]} = FleetAllocation.current_portfolio(scope, agent)
    assert retained_id == retained.id

    assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
             :superseded
  end

  for classification <- [:realized, :partially_realized, :superseded] do
    test "a #{classification} purchase keeps an unrelated retained Commitment current" do
      {scope, agent, revision} = ambiguous_purchase()
      portfolio = FleetAllocation.current_portfolio(scope, agent)
      [acquisition] = portfolio.commitments
      retained = retain_independent_work(scope, agent, revision, portfolio)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        case conn.request_path do
          "/v2/my/ships" ->
            fleet =
              if unquote(classification) == :superseded,
                do: [docked("X1-UX81-A1")],
                else: [docked("X1-UX81-A1"), acquired(@offered_speed)]

            Req.Test.json(conn, %{"data" => fleet})

          "/v2/my/agent" ->
            overview(conn, agent, @credits - @price)

          "/v2/my/ships/ACQUIRE-2" ->
            ship(conn, if(unquote(classification) == :realized, do: @offered_speed, else: 5))
        end
      end)

      result = FleetAcquisition.reconcile(scope, agent)

      case unquote(classification) do
        :realized -> assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} = result
        :partially_realized -> assert {:error, :ship_readiness_mismatch} = result
        :superseded -> assert {:error, :ship_purchase_not_completed} = result
      end

      assert %{id: portfolio_id, commitments: [%{id: retained_id}]} =
               FleetAllocation.current_portfolio(scope, agent)

      assert portfolio_id == portfolio.id
      assert retained_id == retained.id

      assert {:ok, %{commitment_id: ^retained_id}} =
               FleetAllocation.current_ship_claim(agent, "CRUISER-1")

      assert Repo.get!(SpaceTraders.FleetAllocation.Commitment, acquisition.id).unwind_state ==
               :released

      assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
               unquote(classification)

      assert Repo.get!(StrategyDecisionEpisode, retained.replan_decision_episode_id).classification ==
               :still_evaluating
    end
  end

  test "resume uses the acquisition Commitment's Episode rather than the portfolio's Episode" do
    {scope, agent, revision} = generation()
    generation = Repo.get_by!(Generation, agent_id: agent.id)
    stub_shipyard(agent)
    retained = retained_proposal(revision)

    market_decision = %{
      evidence_references: [],
      expectations: %{trade: "retained"},
      calibration_version: "retained-work-test"
    }

    selection = %{
      revision_id: revision.id,
      source_version: 0,
      commitments: [retained],
      rejected: []
    }

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, market_decision)

    acquisition = %{
      retained
      | id: {revision.id, "acquisition"},
        candidate_id: "acquisition",
        claims: [],
        reservations: %{credits: 15_000}
    }

    decision = %{
      market_decision
      | expectations: %{
          ship_type: "SHIP_LIGHT_HAULER",
          purchase_price: @price,
          preparation_credits: @preparation_exposure,
          readiness: promised_readiness()
        },
        calibration_version: "ship-acquisition-v1"
    }

    assert {:ok, updated} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{selection | source_version: 1, commitments: [acquisition]},
               [acquisition.candidate_id],
               decision
             )

    commitment = Enum.find(updated.commitments, &(&1.candidate_id == acquisition.candidate_id))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"POST", "/v2/my/ships"} -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:ok, spending} = SpaceTraders.CreditSpending.acquire_ship_purchase(agent, candidate())

    assert {:error, _} =
             SpaceTraders.Observability.with_context(
               [
                 operator_id: agent.operator_id,
                 agent_id: agent.id,
                 fleet_generation_id: generation.id,
                 strategy_revision_id: revision.id,
                 decision_episode_id: commitment.replan_decision_episode_id,
                 commitment_id: commitment.id
               ],
               fn ->
                 SpaceTraders.API.purchase_ship(
                   SpaceTraders.API.AgentTokenReference.new(agent),
                   "SHIP_LIGHT_HAULER",
                   "X1-UX81-A1",
                   spending: spending
                 )
               end
             )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/agent" ->
          overview(conn, agent, @credits - @price)

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/ships/ACQUIRE-2" ->
          ship(conn, @offered_speed)
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, agent)

    assert Repo.get!(StrategyDecisionEpisode, commitment.replan_decision_episode_id).classification ==
             :realized

    assert Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id).classification ==
             :still_evaluating

    assert {:ok, _} = FleetAllocation.current_ship_claim(agent, "CRUISER-1")
  end

  defp retain_independent_work(scope, agent, revision, portfolio) do
    generation = Repo.get_by!(Generation, agent_id: agent.id)

    retained = retained_proposal(revision)

    assert {:ok, updated} =
             FleetAllocation.replan_subgraph(
               scope,
               generation.id,
               %{
                 revision_id: revision.id,
                 source_version: generation.allocation_version,
                 commitments: [retained],
                 rejected: []
               },
               [retained.candidate_id],
               %{
                 evidence_references: [],
                 expectations: %{trade: "retained"},
                 calibration_version: "retained-work-test"
               }
             )

    assert updated.id == portfolio.id
    Enum.find(updated.commitments, &(&1.candidate_id == retained.candidate_id))
  end

  defp retained_proposal(revision) do
    %FleetAllocation.FleetCommitment{
      id: {revision.id, "retained-trade"},
      candidate_id: "retained-trade",
      objective_index: 0,
      claims: ["CRUISER-1"],
      reservations: %{credits: 100},
      pledges: [],
      dependencies: [],
      expected_value: 100.0,
      unwind_cost: 0.0,
      decisive_reason: "independent productive work"
    }
  end

  defp observation_payloads(outcome) do
    outcome.evidence
    |> Map.fetch!("observations")
    |> Enum.sort_by(& &1["dependency_keys"])
  end

  test "restart reuses the exact Fleet read retained before a failed credit read" do
    {scope, agent, _revision} = ambiguous_purchase()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/agent" ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
    original = SpaceTraders.Evidence.latest_observation(agent, "fleet:#{agent.symbol}")
    assert [%{state: "ambiguous"}] = purchase_attempts(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" -> flunk("restart must reuse the retained Fleet component")
        "/v2/my/agent" -> overview(conn, agent, @credits - @price)
        "/v2/my/ships/ACQUIRE-2" -> ship(conn, @offered_speed)
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, Repo.get!(Agent, agent.id))

    assert [%{state: "accepted", outcomes: [_, outcome]}] = purchase_attempts(agent)
    assert [_, fleet] = observation_payloads(outcome)
    assert fleet["source"]["id"] == original.id
    assert fleet["observed_at"] == DateTime.to_iso8601(original.observed_at)
  end

  defp ambiguous_purchase do
    {scope, agent, revision} = generation()
    stub_shipyard(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} -> overview(conn, agent, @credits)
        {"GET", "/v2/my/ships"} -> Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1")]})
        {"POST", "/v2/my/ships"} -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, {:ship_acquisition_unavailable, _}} =
             execute_purchase(scope, agent, revision)

    {scope, agent, revision}
  end

  test "Fleet proof derives coverage from the retained owned subject, not claimed dependencies" do
    {_scope, agent, _revision} = ambiguous_purchase()
    [attempt] = purchase_attempts(agent)
    {:ok, fleet} = SpaceTraders.Evidence.get_ships(agent, bind: true)
    {:ok, credits} = SpaceTraders.Evidence.get_agent(agent, bind: true)

    assert {:ok, proof} =
             SpaceTraders.Evidence.recovery_proof(attempt, :absent, "No new Ship", [
               fleet,
               credits
             ])

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :absent, Enum.map(proof, &%{&1 | source: nil}))

    wrong_subject = Repo.update!(Ecto.Changeset.change(fleet.observation, subject: "fleet:OTHER"))

    assert {:incomplete, %{missing: [key]}} =
             SpaceTraders.Evidence.recovery_proof(attempt, :absent, "No new Ship", [
               %{fleet | observation: wrong_subject},
               credits
             ])

    assert key == "owned_fleet:#{agent.id}"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "accepted purchase survives interruption before capability registration without another mutation" do
    {scope, agent, _revision} = ambiguous_purchase()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/agent" ->
          overview(conn, agent, @credits - @price)

        "/v2/my/ships/ACQUIRE-2" ->
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
    assert [%{state: "accepted"}] = purchase_attempts(agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/ships/ACQUIRE-2" ->
          ship(conn, @offered_speed)
      end
    end)

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, agent)

    assert [%{state: "accepted", outcomes: [_, _]}] = purchase_attempts(agent)
  end

  for {balance_credits, fits?} <- [{16_062, false}, {16_063, true}] do
    test "a Revision-retired purchase protects exactly its Reservation with #{balance_credits} credits" do
      {scope, agent, revision} = ambiguous_purchase()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

          "/v2/my/agent" ->
            overview(conn, agent, @credits - @price)

          "/v2/my/ships/ACQUIRE-2" ->
            Req.Test.transport_error(conn, :timeout)
        end
      end)

      assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
      assert [%{state: "accepted"} = purchase_attempt] = purchase_attempts(agent)
      active = change_purchase_authority(revision, :revision)
      generation = FleetAllocation.active_generation(agent)

      assert {:ok, %{settling: [_]}} =
               FleetAllocation.retire_stale_portfolio(scope, generation.id, active.id)

      Repo.update!(Ecto.Changeset.change(generation, fleet_strategy_revision_id: active.id))

      # A newer balance absorbs the accepted Attempt's charge. The retained
      # 15,000 Reservation (12,500 purchase + 2,500 Preparation Exposure) still
      # leaves only 62 above the 1,000 floor, one short of this 63-credit refuel.
      refuel = %{"kind" => "refuel", "waypoint" => "X1-UX81-A1", "units" => 100}

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            overview(conn, agent, unquote(balance_credits))

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{"symbol" => "FUEL", "purchasePrice" => 50, "tradeVolume" => 100}
                ]
              }
            })
        end
      end)

      assert {:ok, balance} = Evidence.get_agent_binding(agent)
      assert DateTime.compare(balance.observation.observed_at, purchase_attempt.updated_at) == :gt

      %{attempt: refuel_attempt} =
        SpaceTraders.RecordedDispatchFixtures.prepare_action(agent, "OTHER-1", refuel,
          live_quote: true
        )

      Req.Test.stub(SpaceTraders.API, fn _ ->
        flunk("refuel must not consume retained acquisition credits")
      end)

      if unquote(fits?) do
        assert {:ok, %{state: "sent_or_unknown"}} =
                 SpaceTraders.Fleet.Intents.RecordedAction.admit_send(refuel_attempt)
      else
        assert {:error, :insufficient_unreserved_headroom} =
                 SpaceTraders.API.dispatch_recorded(refuel_attempt)

        assert %{state: "not_sent", sent_or_unknown_at: nil} =
                 MutationAttempts.get!(refuel_attempt.id)
      end

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

          "/v2/my/ships/ACQUIRE-2" ->
            ship(conn, @offered_speed)
        end
      end)

      assert {:ok, _} = FleetAcquisition.reconcile(scope, agent)
      assert FleetAllocation.settling_commitments(generation.id) == []

      unless unquote(fits?) do
        %{attempt: next} =
          SpaceTraders.RecordedDispatchFixtures.prepare_action(agent, "OTHER-2", refuel,
            live_quote: true
          )

        Req.Test.stub(SpaceTraders.API, fn _ ->
          flunk("admission uses retained quote and balance")
        end)

        assert {:ok, %{state: "sent_or_unknown"}} =
                 SpaceTraders.Fleet.Intents.RecordedAction.admit_send(next)
      end
    end
  end

  for subject <- ["fleet", "agent"] do
    test "failed #{subject} retention leaves the purchase unresolved and fenced" do
      {scope, agent, _revision} = ambiguous_purchase()

      Repo.query!(
        "ALTER TABLE authoritative_observations ADD CONSTRAINT purchase_retention_gap CHECK (subject <> '#{unquote(subject)}:#{agent.symbol}') NOT VALID"
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

          "/v2/my/agent" ->
            overview(conn, agent, @credits - @price)
        end
      end)

      assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
      assert [attempt] = purchase_attempts(agent)
      assert attempt.state == "ambiguous"
      assert SpaceTraders.SafetyFence.active?(attempt)
      assert FleetAllocation.current_portfolio(scope, agent)
      assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")
    end
  end

  test "Fleet and credit proof rejects invalid age, Generation, missing coverage and malformed credits without reads" do
    {_scope, agent, _revision} = ambiguous_purchase()
    [attempt] = purchase_attempts(agent)
    {:ok, fleet} = Evidence.get_ships(agent, bind: true)
    {:ok, credits} = Evidence.get_agent(agent, bind: true)
    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("proof assembly must perform no reads") end)

    assert {:ok, proof} =
             Evidence.recovery_proof(attempt, :absent, "No new Ship", [fleet, credits])

    assert {:incomplete, %{missing: ["agent_credits:" <> _], usable: [^fleet]}} =
             Evidence.recovery_proof(attempt, :absent, "No new Ship", [fleet])

    for acquired_at <- [
          DateTime.add(attempt.sent_or_unknown_at, -1, :second),
          DateTime.add(DateTime.utc_now(), -31, :second),
          DateTime.add(DateTime.utc_now(), 60, :second)
        ] do
      source = Repo.update!(Ecto.Changeset.change(fleet.observation, observed_at: acquired_at))
      invalid = %{fleet | observation: source}

      assert {:incomplete, %{usable: [^credits], unusable: [^invalid]}} =
               Evidence.recovery_proof(attempt, :absent, "No new Ship", [invalid, credits])

      forged =
        Enum.map(proof, fn observation ->
          if observation.operation_id == "get-my-ships",
            do: %{observation | source: source, observed_at: acquired_at},
            else: observation
        end)

      assert {:error, :authoritative_evidence_required} =
               MutationAttempts.reconcile(attempt, :absent, forged)
    end

    other_agent =
      SpaceTraders.AgentFixtures.agent_fixture(
        Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id),
        %{symbol: "OTHER"}
      )

    other_generation = Repo.get_by!(Generation, agent_id: other_agent.id)

    source =
      Repo.update!(
        Ecto.Changeset.change(fleet.observation, fleet_generation_id: other_generation.id)
      )

    assert {:incomplete, %{unusable: [_]}} =
             Evidence.recovery_proof(attempt, :absent, "No new Ship", [
               %{fleet | observation: source},
               credits
             ])

    facts = put_in(credits.observation.facts, ["response", "credits"], nil)

    source =
      Repo.update!(
        Ecto.Changeset.change(credits.observation,
          facts: facts,
          response_fingerprint: Evidence.fingerprint(facts)
        )
      )

    invalid = %{credits | observation: source, value: %{credits.value | credits: nil}}

    assert {:incomplete, %{missing: ["owned_fleet:" <> _, "agent_credits:" <> _]}} =
             Evidence.recovery_proof(attempt, :absent, "No new Ship", [invalid])

    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "identical newer Fleet facts cannot replace the source of an already bound purchase conclusion" do
    {scope, agent, _revision} = ambiguous_purchase()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/agent" ->
          original = Evidence.latest_observation(agent, "fleet:#{agent.symbol}")

          newer =
            original
            |> Map.from_struct()
            |> Map.take([
              :agent_id,
              :fleet_generation_id,
              :subject,
              :operation_id,
              :facts,
              :response_fingerprint,
              :dependency_keys
            ])

          Repo.insert!(struct!(Observation, Map.put(newer, :observed_at, DateTime.utc_now())))
          send(self(), {:original_fleet, original})
          overview(conn, agent, @credits - @price)

        "/v2/my/ships/ACQUIRE-2" ->
          ship(conn, @offered_speed)
      end
    end)

    assert {:ok, _} = FleetAcquisition.reconcile(scope, agent)
    assert_receive {:original_fleet, original}
    assert Evidence.latest_observation(agent, "fleet:#{agent.symbol}").id != original.id
    assert [%{outcomes: [_, outcome]}] = purchase_attempts(agent)
    assert [_, fleet] = observation_payloads(outcome)
    assert fleet["source"]["id"] == original.id
    assert fleet["observed_at"] == DateTime.to_iso8601(original.observed_at)
  end

  test "partial expiry replaces only the unusable Fleet component on the next recovery" do
    {scope, agent, _revision} = ambiguous_purchase()
    [attempt] = purchase_attempts(agent)
    previous = Application.fetch_env(:spacetraders, :clock)

    start_supervised!(
      {SpaceTraders.TestClock, DateTime.add(attempt.sent_or_unknown_at, 1, :second)}
    )

    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/agent" ->
          SpaceTraders.TestClock.advance(31)
          overview(conn, agent, @credits - @price)
      end
    end)

    assert {:incomplete, %{usable: [credits], unusable: [_fleet]}} =
             FleetAcquisition.reconcile(scope, agent)

    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => [docked("X1-UX81-A1"), acquired(@offered_speed)]})

        "/v2/my/agent" ->
          flunk("fresh credits must not be reacquired")

        "/v2/my/ships/ACQUIRE-2" ->
          ship(conn, @offered_speed)
      end
    end)

    assert {:ok, _} = FleetAcquisition.reconcile(scope, agent)
    assert [%{outcomes: [_, outcome]}] = purchase_attempts(agent)
    assert [credit_proof, _fleet] = observation_payloads(outcome)
    assert credit_proof["source"]["id"] == credits.observation.id
  end

  test "multiple unregistered Ships remain unattributable despite valid retained reads" do
    {scope, agent, _revision} = ambiguous_purchase()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships" ->
          Req.Test.json(conn, %{
            "data" => [docked("X1-UX81-A1"), acquired(@offered_speed), ship_body("ACQUIRE-3")]
          })

        "/v2/my/agent" ->
          overview(conn, agent, @credits - @price)
      end
    end)

    assert {:error, :ship_purchase_unattributable} =
             FleetAcquisition.reconcile(scope, agent)

    assert [attempt] = purchase_attempts(agent)
    assert attempt.state == "ambiguous"
    assert SpaceTraders.SafetyFence.active?(attempt)
  end

  test "exact purchase proof leaves Bounded Unknown accounting and fence authority with MutationAttempts" do
    {_scope, agent, revision} = ambiguous_purchase()
    [attempt] = purchase_attempts(agent)
    {:ok, fleet} = Evidence.get_ships(agent, bind: true)
    {:ok, credits} = Evidence.get_agent(agent, bind: true)

    {:ok, proof} =
      Evidence.recovery_proof(attempt, :bounded_unknown, "Purchase remains unattributable", [
        fleet,
        credits
      ])

    assert {:error, :hard_constraint_accounting_required} =
             MutationAttempts.reconcile(attempt, :bounded_unknown, proof)

    accounting =
      Evidence.constraint_accounting(
        "At most one 10,000-credit purchase",
        Enum.map(revision.document["hard_constraints"], fn constraint ->
          %{
            constraint: constraint,
            satisfied: true,
            evidence:
              "20,000 available before purchase; at least 10,000 remain under this test bound"
          }
        end)
      )

    assert {:ok, bound} =
             MutationAttempts.reconcile(attempt, :bounded_unknown, proof,
               constraint_accounting: accounting
             )

    assert bound.state == "bounded_unknown"
    assert SpaceTraders.SafetyFence.active?(bound)
    assert Enum.map(bound.outcomes, & &1.classification) == ["ambiguous", "bounded_unknown"]
  end

  test "governed purchase recovery preserves definitive Server Reset handling" do
    {scope, agent, _revision} = ambiguous_purchase()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 4113,
          "message" =>
            "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
        }
      })
    end)

    assert {:error, _} = FleetAcquisition.reconcile(scope, agent)
    assert Repo.get!(Agent, agent.id).stale_at
    assert Repo.get_by!(Generation, agent_id: agent.id).fenced_at
  end

  defp candidate,
    do: %{source_waypoint: "X1-UX81-A1", ship: %{type: "SHIP_LIGHT_HAULER"}}

  # These are execution/recovery scenarios, not investment planning scenarios.
  # Start with a published purchase; economics lives at FleetPlanning's seam,
  # and coherent selection/publication is qualified by #735.
  defp execute_purchase(scope, agent, revision) do
    {portfolio, candidate} = published_purchase(scope, agent, revision)

    case FleetAcquisition.execute(agent, portfolio, hd(portfolio.commitments), candidate) do
      {:ok, result} -> {:ok, result}
      error -> {:error, {:ship_acquisition_unavailable, error}}
    end
  end

  defp published_purchase(scope, agent, revision) do
    generation = FleetAllocation.active_generation(agent)
    margin = SpaceTraders.CreditCalibration.active().margin_percent
    exposure = SpaceTraders.CreditSpending.worst_case_exposure(@price, 1, margin)

    candidate = %SpaceTraders.FleetPlanning.CandidateContribution{
      id: "published-acquisition",
      strategy_revision_id: revision.id,
      objective_index: 0,
      objective: hd(revision.document["objectives"]),
      kind: :ship_acquisition,
      trade_symbol: nil,
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A1",
      expected_outcomes: %{
        decision_value: 24_000,
        purchase_price: @price,
        preparation_credits: @preparation_exposure
      },
      uncertainty: %{},
      required_roles: [],
      required_capabilities: [],
      required_resources: %{credits: exposure + @preparation_exposure},
      dependencies: [],
      validity: %{as_of: DateTime.utc_now(), expires_at: DateTime.add(DateTime.utc_now(), 300)},
      alternatives: [],
      ship: %{
        type: "SHIP_LIGHT_HAULER",
        purchase_price: @price,
        preparation_credits: @preparation_exposure,
        readiness: promised_readiness()
      }
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        claims: [],
        reservations: %{credits: @credits}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        scope,
        generation.id,
        Map.put(selection, :source_version, generation.allocation_version),
        %{
          evidence_references: [],
          calibration_version: "ship-acquisition-v2",
          expectations:
            Map.merge(candidate.expected_outcomes, %{
              ship_type: candidate.ship.type,
              source_waypoint: candidate.source_waypoint,
              readiness: candidate.ship.readiness
            })
        }
      )

    {portfolio, candidate}
  end

  # A recorded Ship purchase another caller already admitted for this Agent.
  defp other_spend(agent, state, bound) do
    generation = Repo.get_by!(Generation, agent_id: agent.id)

    Repo.insert!(%SpaceTraders.MutationAttempts.Attempt{
      operator_id: agent.operator_id,
      agent_id: agent.id,
      fleet_generation_id: generation.id,
      operation_id: "purchase-cargo",
      operation_owner: "ship_execution",
      state: state,
      request_fingerprint: "other-spend-#{System.unique_integer([:positive])}",
      prepared_at: DateTime.utc_now(),
      sent_or_unknown_at: DateTime.utc_now(),
      prepared_evidence:
        if(bound, do: %{"spending" => %{"worst_case_exposure" => bound}}, else: %{})
    })
  end

  defp purchase_attempts(agent) do
    MutationAttempts.list_for_agent(agent)
    |> Enum.filter(&(&1.operation_id == "purchase-ship"))
  end

  defp stub_shipyard(agent) do
    Intelligence.observe_waypoint(agent, Waypoint.from_json(waypoint()))

    Intelligence.observe_shipyard(
      agent,
      "X1-UX81",
      Shipyard.from_json(%{
        "symbol" => "X1-UX81-A1",
        "modificationsFee" => @modification_fee,
        "shipTypes" => [%{"type" => "SHIP_LIGHT_HAULER"}],
        "ships" => [
          %{
            "type" => "SHIP_LIGHT_HAULER",
            "purchasePrice" => @price,
            "engine" => %{"speed" => @offered_speed},
            "frame" => %{"moduleSlots" => 3, "mountingPoints" => 2},
            "modules" => [],
            "mounts" => []
          }
        ]
      }),
      source: "get_shipyard",
      offers_visible: true
    )
  end

  # An already-registered owned Ship. The API never reports a Ship's type, so the
  # planner matches on position and recovery matches on registry difference.
  defp docked(waypoint) do
    ship_body("CRUISER-1", %{"nav" => nav_body("DOCKED", destination: waypoint)})
  end

  defp in_transit_to(waypoint) do
    ship_body("CRUISER-1", %{"nav" => nav_body("IN_TRANSIT", destination: waypoint)})
  end

  defp acquired(engine_speed) do
    ship_body("ACQUIRE-2", %{
      "registration" => %{
        "name" => "ACQUIRE-2",
        "factionSymbol" => "COSMIC",
        "role" => "HAULER"
      },
      "engine" => %{"speed" => engine_speed},
      "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
    })
  end

  defp promised_readiness do
    ready = SpaceTraders.API.Model.Ship.from_json(acquired(@offered_speed))
    profile = SpaceTraders.FleetAllocation.MarketWorkRate.ship_profile(ready)

    %{
      engine_speed: @offered_speed,
      configuration: SpaceTraders.FleetPlanning.ShipInvestment.configuration(ready),
      work_profile: put_in(profile, ["fuel", "current"], 0)
    }
  end

  defp ship(conn, engine_speed),
    do: Req.Test.json(conn, %{"data" => acquired(engine_speed)})

  defp overview(conn, agent, credits),
    do: Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

  defp purchase(conn, agent, price \\ @price) do
    Req.Test.json(conn, %{
      "data" => %{
        "agent" => %{"symbol" => agent.symbol, "credits" => @credits - price},
        "ship" => acquired(@offered_speed),
        "transaction" => %{
          "agentSymbol" => agent.symbol,
          "price" => price,
          "shipSymbol" => "ACQUIRE-2",
          "shipType" => "SHIP_LIGHT_HAULER",
          "waypointSymbol" => "X1-UX81-A1",
          "timestamp" => "2030-01-01T12:00:00Z"
        }
      }
    })
  end

  defp generation(symbol \\ "ACQUIRE") do
    operator = Repo.insert!(%Operator{email: "acquire-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%Agent{
        operator_id: operator.id,
        symbol: symbol,
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "TOKEN"
      })

    # Every owned Ship is registered, which is what lets recovery prove a
    # purchase by set difference against the authoritative Fleet.
    Repo.insert!(%Ship{
      agent_id: agent.id,
      symbol: if(symbol == "ACQUIRE", do: "CRUISER-1", else: "#{symbol}-1"),
      ship_type: "SHIP_COURIER"
    })

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: %{
          "objectives" => [
            %{
              "objective" => "Grow credits",
              "kind" => "continuous",
              "evaluation" => "Maximize net credit growth"
            }
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        }
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    SpaceTraders.AgentFixtures.generation_fixture(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction,
      replacement_symbols: %{},
      objective_progress: %{}
    })

    {Scope.for_operator(operator), agent, revision}
  end

  defp waypoint,
    do: %{
      "symbol" => "X1-UX81-A1",
      "systemSymbol" => "X1-UX81",
      "type" => "PLANET",
      "x" => 0,
      "y" => 0,
      "traits" => [%{"symbol" => "SHIPYARD"}]
    }
end
