defmodule SpaceTraders.MissionControlTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.MissionControl

  describe "dashboard/1" do
    test "reads only Agents owned by the scoped Operator" do
      operator = operator_fixture()
      own_agent = agent_fixture(operator, %{agent_token: nil})

      other_operator = operator_fixture()
      _other_agent = agent_fixture(other_operator, %{agent_token: nil})

      assert [%{agent: %{id: agent_id}}] = MissionControl.dashboard(Scope.for_operator(operator))
      assert agent_id == own_agent.id
    end

    test "does not expose AgentTokens in Operator projections" do
      operator = operator_fixture()
      _agent = agent_fixture(operator, %{agent_token: "AGENT_TOKEN_SECRET"})
      Req.Test.stub(SpaceTraders.API, &unavailable_response/1)
      scope = Scope.for_operator(operator)

      assert [%{agent_token: nil} = agent_ref] = MissionControl.agents(scope)
      assert [%{agent: %{agent_token: nil}}] = MissionControl.dashboard(scope, [agent_ref])
    end

    test "ignores an Agent retired after its projection reference was listed" do
      operator = operator_fixture()
      agent = agent_fixture(operator, %{agent_token: nil})
      scope = Scope.for_operator(operator)
      [agent_ref] = MissionControl.agents(scope)
      Repo.delete!(agent)

      assert MissionControl.dashboard(scope, [agent_ref]) == []
    end

    test "uses only read requests and preserves unavailable values" do
      operator = operator_fixture()
      agent = agent_fixture(operator)
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        if conn.method != "GET",
          do: send(test_pid, {:mutation_request, conn.method, conn.request_path})

        unavailable_response(conn)
      end)

      assert [projection] = MissionControl.dashboard(Scope.for_operator(operator))
      assert projection.agent.id == agent.id
      assert {:error, _reason} = projection.overview
      assert {:error, _reason} = projection.ships
      assert {:error, _reason} = projection.contracts
      assert {:error, _reason} = projection.waypoints

      assert_received {:request, "GET", "/v2/my/agent"}
      assert_received {:request, "GET", "/v2/my/ships"}
      assert_received {:request, "GET", "/v2/my/contracts"}
      assert_received {:request, "GET", "/v2/systems/X1-UX81/waypoints"}
      refute_received {:mutation_request, _method, _path}
    end
  end

  describe "refresh_agent/3" do
    test "replaces previously current values with truthful unavailable results" do
      operator = operator_fixture()
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> :available end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case Agent.get(state, & &1) do
          :available -> available_response(conn, agent.symbol)
          :unavailable -> unavailable_response(conn)
        end
      end)

      scope = Scope.for_operator(operator)

      assert [%{overview: {:ok, _agent}, ships: {:ok, []}}] =
               projections = MissionControl.dashboard(scope)

      Agent.update(state, fn _ -> :unavailable end)

      assert [%{overview: {:error, _overview_reason}, ships: {:error, _ships_reason}}] =
               MissionControl.refresh_agent(scope, projections, agent.id)
    end

    test "does not refresh an Agent outside the scoped Operator" do
      operator = operator_fixture()
      _own_agent = agent_fixture(operator, %{agent_token: nil})
      projections = MissionControl.dashboard(Scope.for_operator(operator))

      other_operator = operator_fixture()
      other_agent = agent_fixture(other_operator, %{agent_token: nil})

      assert MissionControl.refresh_agent(
               Scope.for_operator(operator),
               projections,
               other_agent.id
             ) == projections
    end
  end

  describe "on-demand projections" do
    test "reject reads for an Agent outside the scoped Operator" do
      operator = operator_fixture()
      other_operator = operator_fixture()
      other_agent = agent_fixture(other_operator)
      scope = Scope.for_operator(operator)
      waypoint = %{symbol: "X1-UX81-A1", system_symbol: "X1-UX81", type: "JUMP_GATE"}

      assert MissionControl.waypoint_market(scope, other_agent, waypoint) ==
               {:error, :waypoint_unavailable}

      assert MissionControl.waypoint_readiness(scope, other_agent, waypoint) == %{}
      assert MissionControl.marketplace_waypoints(scope, other_agent, "X1-UX81") == []
      assert MissionControl.usable_survey(scope, other_agent, "X1-UX81-A1") == nil
    end
  end

  describe "market_execution/1" do
    test "reports nothing when no portfolio has been published" do
      operator = operator_fixture()
      scope = Scope.for_operator(operator)

      assert %{
               expected: nil,
               realized: %{
                 completed_round_trips: 0,
                 realized_net_credit_change: 0,
                 realized_sale_value: 0
               },
               contribution: %{commitment_count: 0, expected_value: 0},
               limitation: nil,
               attention: []
             } = MissionControl.market_execution(scope)
    end

    test "reports expected economics and contribution from the current portfolio" do
      %{scope: scope} = execution_fixture()
      report = MissionControl.market_execution(scope)

      assert report.expected.decision_episode_id != nil
      assert report.expected.expected_value == 100
      assert report.contribution.commitment_count == 1
      assert report.contribution.expected_value == 100
      assert report.contribution.claims == ["SHIP-1"]
      assert report.attention == []
      assert report.limitation == nil
    end

    test "reports realized net economics from completed buy and sell Intents" do
      %{scope: scope, commitment: commitment} = execution_fixture()
      ship_id = Repo.get_by!(SpaceTraders.Fleet.Ship, symbol: "SHIP-1").id

      Repo.insert!(%SpaceTraders.Fleet.Intent{
        ship_id: ship_id,
        caller: "commitment",
        type: "buy",
        target_waypoint: "X1-UX81-A1",
        status: "completed",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: commitment.fleet_commitment_portfolio_id,
        fleet_commitment_portfolio_version: 1,
        last_action_result: %{"transaction" => %{"total_price" => 50}}
      })

      Repo.insert!(%SpaceTraders.Fleet.Intent{
        ship_id: ship_id,
        caller: "commitment",
        type: "sell",
        target_waypoint: "X1-UX81-A2",
        status: "completed",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: commitment.fleet_commitment_portfolio_id,
        fleet_commitment_portfolio_version: 1,
        last_action_result: %{"transaction" => %{"total_price" => 150}}
      })

      report = MissionControl.market_execution(scope)
      assert report.realized.completed_round_trips == 1
      assert report.realized.realized_sale_value == 150
      assert report.realized.realized_net_credit_change == 100
    end
  end

  defp execution_fixture do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)

    Repo.insert!(%SpaceTraders.Fleet.Ship{
      symbol: "SHIP-1",
      ship_type: "SHIP_FRIGATE",
      agent_id: agent.id
    })

    strategy =
      Repo.insert!(%SpaceTraders.FleetStrategy.Strategy{
        operator_id: operator.id,
        revision_number: 1
      })

    revision =
      Repo.insert!(%SpaceTraders.FleetStrategy.Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => [%{"kind" => "credit_floor", "minimum" => 500}]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    strategy
    |> Ecto.Changeset.change(active_revision_id: revision.id)
    |> Repo.update!()

    generation =
      Repo.insert!(%SpaceTraders.FleetGeneration.Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    candidate = %SpaceTraders.FleetAllocation.PortfolioCandidate{
      id: "candidate-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{credits: 200},
      pledges: [],
      dependencies: [],
      expected_value: 100,
      unwind_cost: 0
    }

    {:ok, selection} =
      SpaceTraders.FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: ["SHIP-1"],
        reservations: %{credits: 200}
      })

    {:ok, portfolio} =
      SpaceTraders.FleetAllocation.publish_portfolio(scope, generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "market-v1"
      })

    [commitment] = portfolio.commitments
    %{scope: scope, portfolio: portfolio, commitment: commitment}
  end

  defp available_response(conn, symbol) do
    case conn.request_path do
      "/v2/my/agent" ->
        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "ACC",
            "symbol" => symbol,
            "headquarters" => "X1-UX81-A1",
            "credits" => 42_000,
            "startingFaction" => "COSMIC",
            "shipCount" => 0
          }
        })

      "/v2/my/ships" ->
        Req.Test.json(conn, %{"data" => []})

      "/v2/my/contracts" ->
        Req.Test.json(conn, %{"data" => []})

      "/v2/systems/X1-UX81/waypoints" ->
        Req.Test.json(conn, %{"data" => []})
    end
  end

  defp unavailable_response(conn) do
    conn
    |> Map.put(:status, 400)
    |> Req.Test.json(%{"error" => %{"message" => "Projection unavailable"}})
  end
end
