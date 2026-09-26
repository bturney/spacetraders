defmodule SpaceTraders.ConstructionExecutionTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.API.Model.Construction
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, StrategyDecisionEpisode}
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet

  test "a Construction delivery requires its current Ship Claim" do
    agent = agent_fixture(operator_fixture())

    assert {:error, :no_current_ship_claim} =
             Intents.request_commitment_construction_delivery(
               agent,
               %Commitment{id: 123, claims: ["SHIP-1"]},
               %Portfolio{id: 456, version: 1},
               "SHIP-1",
               %{system: "X1", waypoint: "X1-A2", trade_symbol: "IRON", units: 5}
             )
  end

  test "Construction completion is established only by the authoritative isComplete flag" do
    assert not FleetConstruction.completed?(construction(false, 10))
    assert FleetConstruction.completed?(construction(true, 9))
  end

  test "unknown material progress never reports zero remaining" do
    assert FleetConstruction.remaining(construction(false, 3), "MISSING") == :unknown
  end

  test "fresh Construction progress reduces the durable Pledge without another supply mutation" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-1", "SHIP_COMMAND_FRIGATE")
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-2", "SHIP_COMMAND_FRIGATE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Complete construction"}],
          "hard_constraints" => []
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    strategy |> Ecto.Changeset.change(active_revision_id: revision.id) |> Repo.update!()

    generation =
      %Generation{}
      |> Generation.changeset(%{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{},
        strategy_capable_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    candidate = %PortfolioCandidate{
      id: "construction-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{credits: 0},
      pledges: [
        %{outcome: {:construction, "X1-A2", "IRON"}, amount: 8, backing: {:claim, "SHIP-1"}}
      ],
      dependencies: [%{subject: "construction:X1:X1-A2", state: :satisfied}],
      expected_value: 1,
      unwind_cost: 0
    }

    second = %{
      candidate
      | id: "construction-2",
        claims: ["SHIP-2"],
        pledges: [
          %{outcome: {:construction, "X1-A2", "IRON"}, amount: 8, backing: {:claim, "SHIP-2"}}
        ]
    }

    assert {:ok, selection} =
             FleetAllocation.select_portfolio(revision, [candidate, second], %{
               as_of: DateTime.utc_now(),
               claims: ["SHIP-1", "SHIP-2"],
               reservations: %{credits: 1000}
             })

    assert {:ok, %Portfolio{}} =
             FleetAllocation.publish_portfolio(
               scope,
               generation.id,
               selection,
               %{
                 evidence_references: [],
                 expectations: %{},
                 calibration_version: "construction-v1"
               }
             )

    {:ok, progress} = Elixir.Agent.start_link(fn -> {7, false} end)
    {:ok, reads} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v2/systems/X1/waypoints/X1-A2/construction"
      Elixir.Agent.update(reads, &(&1 + 1))
      {fulfilled, complete} = Elixir.Agent.get(progress, & &1)

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => "X1-A2",
          "isComplete" => complete,
          "materials" => [%{"tradeSymbol" => "IRON", "required" => 10, "fulfilled" => fulfilled}]
        }
      })
    end)

    assert {:ok, pledges} = FleetConstruction.current_pledges(scope, agent)
    assert Enum.map(pledges, & &1.amount) == [3, 0]
    assert Elixir.Agent.get(reads, & &1) == 1

    Elixir.Agent.update(progress, fn _ -> {7, true} end)
    assert {:ok, [%{amount: 0}, %{amount: 0}]} = FleetConstruction.current_pledges(scope, agent)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/systems/X1/waypoints/X1-A2/construction" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-A2",
              "isComplete" => true,
              "materials" => [%{"tradeSymbol" => "IRON", "required" => 10, "fulfilled" => 7}]
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => []})

        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => agent.faction
            }
          })

        path ->
          flunk("unexpected game request: #{path}")
      end
    end)

    assert {:ok, %Portfolio{}} = FleetConstruction.reconcile(scope, agent, revision)
    assert FleetAllocation.current_portfolio(scope, agent) == nil
    assert Repo.one!(StrategyDecisionEpisode).classification == :realized
  end

  defp construction(complete, fulfilled) do
    Construction.from_json(%{
      "symbol" => "X1-A2",
      "isComplete" => complete,
      "materials" => [%{"tradeSymbol" => "IRON", "required" => 10, "fulfilled" => fulfilled}]
    })
  end
end
