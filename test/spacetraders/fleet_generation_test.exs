defmodule SpaceTraders.FleetGenerationTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.Repo

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

  test "is the sole production owner of registration" do
    callers =
      "lib/spacetraders/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ "SpaceTraders.API.register("))

    assert callers == ["lib/spacetraders/fleet_generation.ex"]
  end

  test "does not expose the AgentToken when the minted Agent cannot be stored" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN_SECRET")
    _conflicting_agent = operator_fixture() |> agent_fixture(%{symbol: "CONFLICT"})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "token" => "AGENT_TOKEN_SECRET",
          "agent" => %{
            "symbol" => "CONFLICT",
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

    assert {:error, %Ecto.Changeset{} = changeset} =
             FleetGeneration.mint(Scope.for_operator(operator), %{
               symbol: "NEWSYM",
               faction: "COSMIC"
             })

    assert Ecto.Changeset.get_change(changeset, :agent_token) == nil
    refute inspect(changeset) =~ "AGENT_TOKEN_SECRET"
    refute Repo.get_by(SpaceTraders.Agent.Agent, symbol: "NEWSYM")
  end
end
