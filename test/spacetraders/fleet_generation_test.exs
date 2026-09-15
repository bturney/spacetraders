defmodule SpaceTraders.FleetGenerationTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.Fleet.{Intent, Intents, Ship}
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.Repo

  test "Emergency Stop blocks Agent mutations and replacement minting while reads continue" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN_SECRET")
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "AGENT_TOKEN_SECRET"})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => agent.symbol,
          "headquarters" => agent.headquarters,
          "credits" => 175_000,
          "startingFaction" => agent.faction,
          "shipCount" => 1
        }
      })
    end)

    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)
    assert :ok = Agent.execution_allowed?(agent)

    assert {:error, :emergency_stopped} =
             SpaceTraders.API.accept_contract(agent.agent_token, "contract-1")

    assert {:error, :emergency_stopped} =
             FleetGeneration.mint(scope, %{symbol: "REPLACEMENT", faction: "COSMIC"})

    assert {:ok, game_agent} = FleetGeneration.agent_overview(agent)
    assert game_agent.symbol == agent.symbol
  end

  test "Emergency Stop survives definitive Server Reset detection" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)
    ship = Repo.insert!(%Ship{symbol: "RESET-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate"}
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Map.put(:status, 401)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 4113,
          "message" =>
            "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
        }
      })
    end)

    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert {:error, :stale_agent} = FleetGeneration.agent_overview(agent)
    assert FleetStrategy.get(scope).emergency_stopped_at == stopped.emergency_stopped_at

    assert {:ok, resumed} = FleetStrategy.resume(scope, stopped.emergency_stop_version)
    assert resumed.emergency_stopped_at == nil

    assert Enum.any?(Intents.history(agent), fn candidate ->
             candidate.id == intent.id and
               candidate.last_action_result == %{"outcome" => "reset_censored"}
           end)
  end

  test "Emergency Stop suppresses a mutation retry waiting on Retry-After" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "RETRY_AGENT_TOKEN"})
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, :mutation_attempted)

      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
    end)

    request =
      Task.async(fn ->
        SpaceTraders.API.navigate_ship(agent.agent_token, "SHIP-1", "X1-UX81-A2")
      end)

    assert_receive :mutation_attempted
    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)
    assert Task.await(request, 2_000) == {:error, :emergency_stopped}
    refute_receive :mutation_attempted
  end

  test "an AgentToken imported during Emergency Stop remains suppressed" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => "IMPORTED",
          "headquarters" => "X1-UX81-A1",
          "credits" => 175_000,
          "startingFaction" => "COSMIC",
          "shipCount" => 0
        }
      })
    end)

    assert {:ok, imported} = Agent.import_agent(scope, "IMPORTED_AGENT_TOKEN", true)

    assert {:error, :emergency_stopped} =
             SpaceTraders.API.accept_contract(imported.agent_token, "contract-1")
  end

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
