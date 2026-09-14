defmodule SpaceTraders.FleetGenerationTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetGeneration

  test "mints through a credential reference without exposing the AccountToken" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN_SECRET")
    scope = Scope.for_operator(operator)

    assert scope.operator.account_token == nil

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ACCOUNT_TOKEN_SECRET"]

      Req.Test.json(conn, %{
        "data" => %{
          "token" => "AGENT_TOKEN_SECRET",
          "agent" => %{
            "symbol" => "NEWSYM",
            "credits" => 175_000,
            "headquarters" => "X1-UX81-A2",
            "startingFaction" => "COSMIC"
          },
          "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
          "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
          "ships" => []
        }
      })
    end)

    assert {:ok, %{agent: agent, retired_symbols: []}} =
             FleetGeneration.mint(scope, %{symbol: "NEWSYM", faction: "COSMIC"})

    assert agent.symbol == "NEWSYM"
    assert agent.agent_token == nil
    refute inspect(agent) =~ "ACCOUNT_TOKEN_SECRET"
    refute inspect(agent) =~ "AGENT_TOKEN_SECRET"
  end
end
