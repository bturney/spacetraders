defmodule SpaceTraders.CurrentFleetTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  alias SpaceTraders.{Agent, FleetGeneration, FleetStrategy}

  test "empty setup and a sole Operator without an Agent have distinct durable identities" do
    assert {:ok, %{state: :setup, operator: nil, agent: nil, generation: nil}} =
             FleetGeneration.adopt_current_fleet()

    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_SECRET")
    scope = operator_scope_fixture(operator)
    {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, draft.draft_version)

    assert {:ok, %{state: :empty, operator: adopted, agent: nil, generation: nil}} =
             FleetGeneration.adopt_current_fleet()

    assert adopted.id == operator.id
    assert adopted.account_token == nil
    assert Agent.get_operator!(operator.id).account_token == "ACCOUNT_SECRET"
    assert FleetStrategy.get(scope).active_revision == revision
    assert {:ok, %{state: :empty, operator: ^adopted}} = FleetGeneration.current_fleet()
    assert {:ok, %{operator: ^adopted}} = FleetGeneration.adopt_current_fleet()
  end

  test "a successful initial mint resolves current identity and another ordinary mint cannot compete" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_SECRET")
    scope = operator_scope_fixture(operator)
    {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _} = FleetStrategy.activate(scope, draft.draft_version)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "token" => "FLEET_SECRET",
          "agent" => %{
            "symbol" => "ORBITALIST",
            "headquarters" => "X1-UX81-A1",
            "credits" => 175_000,
            "startingFaction" => "COSMIC"
          },
          "ships" => [],
          "contract" => %{"id" => "c1"},
          "faction" => %{"symbol" => "COSMIC"}
        }
      })
    end)

    assert {:ok, %{agent: minted}} =
             FleetGeneration.mint(scope, %{symbol: "ORBITALIST", faction: "COSMIC"})

    assert {:ok, %{state: :current, agent: current, generation: generation}} =
             FleetGeneration.current_fleet(scope)

    assert current.id == minted.id
    assert current.agent_token == nil
    assert generation.agent_id == minted.id
    assert Agent.get_agent(scope, minted.id).agent_token == "FLEET_SECRET"

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("a healthy current identity forbids a competing mint")
    end)

    assert {:error, :current_fleet_exists} =
             FleetGeneration.mint(scope, %{symbol: "PARALLAX", faction: "COSMIC"})

    assert {:ok, %{agent: ^current, generation: ^generation}} =
             FleetGeneration.current_fleet(scope)
  end

  test "an initial AgentToken import establishes the sole current Fleet; another ordinary import cannot add an Agent" do
    operator = operator_fixture()
    scope = operator_scope_fixture(operator)
    {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, draft.draft_version)
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:game_request, conn.method, conn.request_path})
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer IMPORTED_SECRET"]

      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "ORBITALIST",
              "headquarters" => "X1-UX81-A1",
              "credits" => 42_000,
              "startingFaction" => "COSMIC",
              "shipCount" => 1
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{
            "data" => [SpaceTraders.ShipBody.ship_body("ORBITALIST-1")],
            "meta" => %{"total" => 1, "page" => 1, "limit" => 20}
          })
      end
    end)

    assert {:ok, imported} = FleetGeneration.import_agent(scope, "IMPORTED_SECRET", true)
    assert imported.agent_token == nil

    assert {:ok, %{state: :current, agent: current, generation: generation}} =
             FleetGeneration.current_fleet(scope)

    assert current.id == imported.id
    assert generation.agent_id == imported.id
    assert generation.symbol == "ORBITALIST"
    assert generation.faction == "COSMIC"
    assert generation.fleet_strategy_revision_id == revision.id
    # The imported Agent's own authoritative state is the generation baseline.
    assert generation.starting_credits == 42_000
    assert generation.strategy_capable_at

    assert ["ORBITALIST-1"] =
             Repo.all(
               from ship in SpaceTraders.Fleet.Ship,
                 where: ship.agent_id == ^imported.id,
                 select: ship.symbol
             )

    assert Agent.get_agent(scope, imported.id).agent_token == "IMPORTED_SECRET"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:game_request, conn.method, conn.request_path})
      flunk("an established current Fleet forbids another ordinary import")
    end)

    flush_game_requests()

    assert {:error, :current_fleet_exists} =
             FleetGeneration.import_agent(scope, "PARALLAX_SECRET", true)

    refute_received {:game_request, _, _}
    assert [%{id: only}] = Agent.list_agents(Agent.get_operator!(operator.id))
    assert only == imported.id

    assert {:ok, %{agent: ^current, generation: ^generation}} =
             FleetGeneration.current_fleet(scope)
  end

  test "invalid AgentTokens and missing mint authority create no local Fleet state" do
    operator = operator_fixture()
    scope = operator_scope_fixture(operator)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"error" => %{"code" => 4100, "message" => "Invalid token"}})
    end)

    assert {:error, %SpaceTraders.API.GameplayError{}} =
             FleetGeneration.import_agent(scope, "INVALID_SECRET", true)

    assert {:error, :account_token_not_linked} =
             FleetGeneration.mint(scope, %{symbol: "ORBITALIST", faction: "COSMIC"})

    assert {:error, %Ecto.Changeset{}} =
             FleetGeneration.mint(scope, %{symbol: "bad symbol", faction: "COSMIC"})

    assert Agent.list_agents(Agent.get_operator!(operator.id)) == []
    assert FleetGeneration.list_generations(scope) == []
    assert {:ok, %{state: :empty}} = FleetGeneration.current_fleet(scope)
  end

  test "import is not a mid-game replacement: a fenced Fleet keeps its own credential and history" do
    operator = operator_fixture()
    scope = operator_scope_fixture(operator)

    fenced =
      agent_fixture(operator, %{
        symbol: "ORBITALIST",
        agent_token: "PREDECESSOR_SECRET",
        stale_at: DateTime.utc_now(:second)
      })

    assert {:ok, %{state: :transition, generation: predecessor}} =
             FleetGeneration.current_fleet(scope)

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("a fenced transition forbids import reads")
    end)

    assert {:error, :fleet_transition_pending} =
             FleetGeneration.import_agent(scope, "SAME_SYMBOL_SECRET", true)

    assert Agent.get_agent(scope, fenced.id).agent_token == "PREDECESSOR_SECRET"
    assert [^predecessor] = FleetGeneration.list_generations(scope)

    assert {:ok, %{state: :transition, generation: ^predecessor}} =
             FleetGeneration.current_fleet(scope)
  end

  defp flush_game_requests do
    receive do
      {:game_request, _, _} -> flush_game_requests()
    after
      0 -> :ok
    end
  end

  test "ownership ambiguity fails adoption without selecting or removing records" do
    first = operator_fixture()
    agent = agent_fixture(first)
    second = legacy_operator_fixture()

    assert {:error, %{reason: :ambiguous_current_fleet, summary: summary}} =
             FleetGeneration.adopt_current_fleet()

    assert summary =~ "multiple plausible Operators"
    assert summary =~ "Resolve"
    assert Agent.get_operator!(second.id)
    assert Agent.get_agent(first, agent.id)
    assert FleetGeneration.list_generations(operator_scope_fixture(first)) == []
  end

  test "a successful replacement without an active Strategy still retires and publishes its predecessor" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_SECRET")
    scope = operator_scope_fixture(operator)
    old = agent_fixture(operator, %{symbol: "ORBITALIST", stale_at: DateTime.utc_now(:second)})

    assert {:ok, %{state: :transition, generation: predecessor}} =
             FleetGeneration.adopt_current_fleet()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "token" => "REPLACEMENT_SECRET",
          "agent" => %{
            "symbol" => "ORBITALIST",
            "startingFaction" => "COSMIC",
            "headquarters" => "X1-UX81-A1",
            "credits" => 175_000
          },
          "ships" => [],
          "contract" => %{"id" => "c1"},
          "faction" => %{"symbol" => "COSMIC"}
        }
      })
    end)

    assert {:ok, %{agent: replacement}} =
             FleetGeneration.mint(scope, %{symbol: "ORBITALIST", faction: "COSMIC"})

    assert replacement.id != old.id

    assert {:ok, %{state: :current, generation: generation}} =
             FleetGeneration.current_fleet(scope)

    assert generation.agent_id == replacement.id
    assert [current, retired] = FleetGeneration.list_generations(scope)
    assert current.id == generation.id
    assert retired.id == predecessor.id
    assert retired.retired_at
  end

  test "retired Generations with a repeated symbol are history; a fenced current Fleet is a transition" do
    operator = operator_fixture()
    scope = operator_scope_fixture(operator)
    agent = agent_fixture(operator, %{symbol: "ORBITALIST"})

    retired =
      Repo.insert!(%FleetGeneration.Generation{
        operator_id: operator.id,
        number: 1,
        symbol: "ORBITALIST",
        faction: "COSMIC",
        retired_at: DateTime.add(DateTime.utc_now(), -3600),
        agent_id: nil
      })

    assert {:ok, %{state: :current, agent: current, generation: generation}} =
             FleetGeneration.adopt_current_fleet()

    assert current.id == agent.id
    assert generation.number == 2
    assert generation.id != retired.id

    # Definitive reset evidence fences identity; ordinary auth errors do not.
    error = %SpaceTraders.API.GameplayError{
      code: 4113,
      type: :other,
      message:
        "Failed to parse token. Token reset_date does not match the server. Server resets happen weekly. After a reset, you should re-register your agent. Expected: 2026-10-11, Actual: 2026-10-01"
    }

    assert {:error, :stale_agent} = FleetGeneration.handle_game_result(agent, {:error, error})
    assert {:ok, %{state: :transition, generation: fenced}} = FleetGeneration.current_fleet(scope)
    assert fenced.id == generation.id
    assert fenced.fenced_at
    assert FleetGeneration.list_generations(scope) |> Enum.any?(&(&1.id == retired.id))
  end
end
