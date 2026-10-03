defmodule SpaceTraders.FleetAcquisitionTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.API.Model.{Shipyard, Waypoint}
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
  @reserved_credits @price + @preparation_exposure

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

    assert {:error, {:ship_acquisition_unavailable, {:no_admissible_ship_offer, [limitation]}}} =
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert %{subject: "X1-UX81-A1", reason: :purchase_precondition_unmet} = limitation
    assert [] == Repo.all(StrategyDecisionEpisode)
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

    assert {:error, {:ship_acquisition_unavailable, {:no_admissible_ship_offer, [limitation]}}} =
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert %{reason: :purchase_precondition_unmet} = limitation
    assert [] == purchase_attempts(agent)
  end

  test "registers a purchased Ship once readiness matches, then releases the portfolio" do
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
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

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
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")

    # Failing readiness means the Ship never enters the registry, so it cannot
    # be claimed either.
    assert {:error, :no_current_ship_claim} =
             FleetAllocation.current_ship_claim(agent, "ACQUIRE-2")

    assert [episode] = Repo.all(StrategyDecisionEpisode)
    assert episode.classification == :partially_realized
    assert episode.actual_outcomes["readiness"] == "mismatch"
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
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert [%{state: "ambiguous"}] = purchase_attempts(agent)
    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")

    assert {:ok, %{ship: %Ship{symbol: "ACQUIRE-2"}}} =
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    # Append-only: the original ambiguity is preserved and the reconciliation
    # is recorded as an additional outcome on the same attempt.
    assert [%{state: "accepted", outcomes: [ambiguous, outcome]}] = purchase_attempts(agent)
    assert ambiguous.classification == "ambiguous"

    # The attempt was reconciled against both fenced resources.
    assert [credits, owned_fleet] = observation_payloads(outcome)

    assert credits["operation_id"] == "get-my-agent"
    assert credits["dependency_keys"] == ["agent_credits:#{agent.id}"]
    assert credits["facts"]["credits"] == @credits - @price

    assert owned_fleet["operation_id"] == "get-my-ships"
    assert owned_fleet["dependency_keys"] == ["owned_fleet:#{agent.id}"]

    assert owned_fleet["facts"]["ships"] == [
             %{"symbol" => "CRUISER-1"},
             %{"symbol" => "ACQUIRE-2"}
           ]

    assert owned_fleet["facts"]["unregistered"] == 1
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
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert {:error, :ship_purchase_not_completed} =
             FleetAcquisition.reconcile(scope, agent, revision, "X1-UX81")

    assert [%{state: "absent"}] = purchase_attempts(agent)
    assert nil == Repo.get_by(Ship, agent_id: agent.id, symbol: "ACQUIRE-2")
    assert nil == FleetAllocation.current_portfolio(scope, agent)
  end

  defp observation_payloads(outcome) do
    outcome.evidence
    |> Map.fetch!("observations")
    |> Enum.sort_by(& &1["dependency_keys"])
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
      "engine" => %{"speed" => engine_speed}
    })
  end

  defp ship(conn, engine_speed),
    do: Req.Test.json(conn, %{"data" => acquired(engine_speed)})

  defp overview(conn, agent, credits),
    do: Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => credits}})

  defp purchase(conn, agent) do
    Req.Test.json(conn, %{
      "data" => %{
        "agent" => %{"symbol" => agent.symbol, "credits" => @credits - @price},
        "ship" => acquired(@offered_speed),
        "transaction" => %{
          "agentSymbol" => agent.symbol,
          "price" => @price,
          "shipSymbol" => "ACQUIRE-2",
          "shipType" => "SHIP_LIGHT_HAULER",
          "waypointSymbol" => "X1-UX81-A1",
          "timestamp" => "2030-01-01T12:00:00Z"
        }
      }
    })
  end

  defp generation do
    operator = Repo.insert!(%Operator{email: "acquire-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%Agent{
        operator_id: operator.id,
        symbol: "ACQUIRE",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "TOKEN"
      })

    # Every owned Ship is registered, which is what lets recovery prove a
    # purchase by set difference against the authoritative Fleet.
    Repo.insert!(%Ship{agent_id: agent.id, symbol: "CRUISER-1", ship_type: "SHIP_COURIER"})

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: %{
          "objectives" => [
            %{"objective" => "Grow the Fleet", "kind" => "attain", "evaluation" => "Add a Ship"}
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        }
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
