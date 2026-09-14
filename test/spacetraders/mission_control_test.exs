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
