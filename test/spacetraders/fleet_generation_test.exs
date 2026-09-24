defmodule SpaceTraders.FleetGenerationTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.Fleet.{Intent, Intents, Ship}
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.MissionControl
  alias SpaceTraders.Repo

  test "missing replacement authority remains a durable Intervention until authority is restored" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)

    assert {:error, :account_token_not_linked} =
             FleetGeneration.mint(scope, %{symbol: "NEEDSKEY", faction: "COSMIC"})

    assert [%{kind: :intervention, summary: summary}] =
             MissionControl.unresolved_conditions(scope)

    assert summary =~ "AccountToken"

    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN_SECRET")
    scope = Scope.for_operator(operator)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, registration_body("NEEDSKEY", "NEEDSKEY-1", "TOKEN"))
    end)

    assert {:ok, _} = FleetGeneration.mint(scope, %{symbol: "NEEDSKEY", faction: "COSMIC"})
    assert MissionControl.unresolved_conditions(scope) == []
  end

  test "a definitive Server Reset activates and bootstraps a fallback Fleet Generation" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN_SECRET")
    scope = Scope.for_operator(operator)

    assert {:ok, strategy} = FleetStrategy.select_preset(scope, "charted_expansion")
    assert {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path, conn.body_params["symbol"]} do
        {"POST", "/v2/register", "RESETME"} ->
          Req.Test.json(conn, registration_body("RESETME", "RESETME-1", "FIRST_TOKEN"))
      end
    end)

    assert {:ok, %{agent: stale_agent}} =
             FleetGeneration.mint(scope, %{
               symbol: "RESETME",
               faction: "COSMIC",
               replacement_symbols: ["RESETME", "FALLBACK"]
             })

    assert [first_generation] = FleetGeneration.list_generations(scope)
    assert first_generation.fleet_strategy_revision_id == revision.id
    assert %DateTime{} = first_generation.strategy_capable_at
    first_ship = Repo.get_by!(Ship, symbol: "RESETME-1")
    assert first_ship.agent_id == stale_agent.id
    assert first_ship.ship_type == "UNKNOWN"
    stale_agent = Repo.get!(SpaceTraders.Agent.Agent, stale_agent.id)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path, conn.body_params["symbol"]} do
        {"GET", "/v2/my/agent", nil} ->
          conn
          |> Map.put(:status, 401)
          |> Req.Test.json(%{
            "error" => %{
              "code" => 4113,
              "message" =>
                "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
            }
          })

        {"POST", "/v2/register", "RESETME"} ->
          fenced = Repo.get!(SpaceTraders.Agent.Agent, stale_agent.id)
          assert %DateTime{} = fenced.stale_at
          assert {:error, :stale_agent} = FleetGeneration.execution_allowed?(fenced)
          send(test_pid, :stale_agent_retained)

          conn
          |> Map.put(:status, 400)
          |> Req.Test.json(%{
            "error" => %{"code" => 4103, "message" => "Symbol is already in use"}
          })

        {"POST", "/v2/register", "FALLBACK"} ->
          assert Repo.get(SpaceTraders.Agent.Agent, stale_agent.id)
          Req.Test.json(conn, registration_body("FALLBACK", "FALLBACK-1", "SECOND_TOKEN"))
      end
    end)

    assert {:error, :stale_agent} = FleetGeneration.agent_overview(stale_agent)
    assert_receive :stale_agent_retained

    stale_token_reference =
      operator
      |> agent_fixture(%{agent_token: "FIRST_TOKEN"})
      |> AgentTokenReference.new()

    assert {:error, :stale_agent} =
             SpaceTraders.API.accept_contract(stale_token_reference, "contract-1")

    refute Repo.get(SpaceTraders.Agent.Agent, stale_agent.id)
    replacement = Repo.get_by!(SpaceTraders.Agent.Agent, symbol: "FALLBACK")
    assert Repo.get_by!(Ship, symbol: "FALLBACK-1").agent_id == replacement.id

    assert [second_generation, retired_generation] = FleetGeneration.list_generations(scope)
    assert second_generation.number == 2
    assert second_generation.agent_id == replacement.id
    assert second_generation.fleet_strategy_revision_id == revision.id
    assert %DateTime{} = second_generation.strategy_capable_at
    assert retired_generation.id == first_generation.id
    assert %DateTime{} = retired_generation.fenced_at
    assert %DateTime{} = retired_generation.retired_at
    assert FleetStrategy.get(scope).active_revision.id == revision.id
  end

  test "activating Strategy makes an already bootstrapped Fleet Generation Strategy-capable" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN_SECRET")
    scope = Scope.for_operator(operator)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, registration_body("READY", "READY-1", "READY_TOKEN"))
    end)

    assert {:ok, %{agent: agent}} =
             FleetGeneration.mint(scope, %{symbol: "READY", faction: "COSMIC"})

    assert [
             %{
               fleet_strategy_revision_id: nil,
               strategy_capable_at: nil,
               replacement_symbols: %{"symbols" => ["READY", "READY-2", "READY-3"]}
             }
           ] =
             FleetGeneration.list_generations(scope)

    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_intelligence_evidence")

    assert {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    assert_receive {:waypoint_intelligence_observed, agent_id, "X1-UX81"}
    assert agent_id == agent.id

    assert [%{fleet_strategy_revision_id: revision_id, strategy_capable_at: capable_at}] =
             FleetGeneration.list_generations(scope)

    assert revision_id == revision.id
    assert %DateTime{} = capable_at
  end

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
             SpaceTraders.API.accept_contract(AgentTokenReference.new(agent), "contract-1")

    assert {:error, :emergency_stopped} =
             FleetGeneration.mint(scope, %{symbol: "REPLACEMENT", faction: "COSMIC"})

    assert {:ok, game_agent} = FleetGeneration.agent_overview(agent)
    assert game_agent.symbol == agent.symbol
  end

  test "Emergency Stop survives definitive Server Reset detection" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "STOP_RESET_AGENT_TOKEN"})
    ship = Repo.insert!(%Ship{symbol: "RESET-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
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

    assert {:ok, prepared} = FleetStrategy.resume(scope, stopped.emergency_stop_version)
    assert prepared.emergency_stopped_at == stopped.emergency_stopped_at
    assert %DateTime{} = prepared.emergency_resume_prepared_at

    assert Enum.any?(Intents.history(agent), fn candidate ->
             candidate.id == intent.id and
               candidate.status == "superseded" and
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
      assert_receive :release_rate_limit_response

      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
    end)

    request =
      Task.async(fn ->
        SpaceTraders.API.navigate_ship(
          AgentTokenReference.new(agent),
          "SHIP-1",
          "X1-UX81-A2"
        )
      end)

    assert_receive :mutation_attempted
    assert {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)
    send(request.pid, :release_rate_limit_response)
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
             SpaceTraders.API.accept_contract(AgentTokenReference.new(imported), "contract-1")
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

  defp registration_body(agent_symbol, ship_symbol, token) do
    %{
      "data" => %{
        "token" => token,
        "agent" => %{
          "symbol" => agent_symbol,
          "credits" => 175_000,
          "headquarters" => "X1-UX81-A2",
          "startingFaction" => "COSMIC"
        },
        "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
        "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
        "ships" => [
          %{
            "symbol" => ship_symbol,
            "registration" => %{
              "name" => ship_symbol,
              "factionSymbol" => "COSMIC",
              "role" => "COMMAND"
            },
            "nav" => %{
              "systemSymbol" => "X1-UX81",
              "waypointSymbol" => "X1-UX81-A2",
              "route" => %{
                "destination" => %{
                  "symbol" => "X1-UX81-A2",
                  "type" => "PLANET",
                  "systemSymbol" => "X1-UX81",
                  "x" => 0,
                  "y" => 0
                },
                "origin" => %{
                  "symbol" => "X1-UX81-A2",
                  "type" => "PLANET",
                  "systemSymbol" => "X1-UX81",
                  "x" => 0,
                  "y" => 0
                },
                "departureTime" => "2026-09-15T00:00:00.000Z",
                "arrival" => "2026-09-15T00:00:00.000Z"
              },
              "status" => "DOCKED",
              "flightMode" => "CRUISE"
            },
            "crew" => %{
              "current" => 1,
              "required" => 1,
              "capacity" => 1,
              "rotation" => "STRICT",
              "morale" => 100,
              "wages" => 0
            },
            "frame" => %{
              "symbol" => "FRAME_PROBE",
              "name" => "Probe",
              "description" => "Probe",
              "condition" => 100,
              "integrity" => 100,
              "moduleSlots" => 0,
              "mountingPoints" => 0,
              "fuelCapacity" => 0,
              "requirements" => %{"power" => 0, "crew" => 0, "slots" => 0}
            },
            "reactor" => %{
              "symbol" => "REACTOR_SOLAR_I",
              "name" => "Solar",
              "description" => "Solar",
              "condition" => 100,
              "integrity" => 100,
              "powerOutput" => 1,
              "requirements" => %{"power" => 0, "crew" => 0, "slots" => 0}
            },
            "engine" => %{
              "symbol" => "ENGINE_IMPULSE_DRIVE_I",
              "name" => "Impulse",
              "description" => "Impulse",
              "condition" => 100,
              "integrity" => 100,
              "speed" => 1,
              "requirements" => %{"power" => 0, "crew" => 0, "slots" => 0}
            },
            "modules" => [],
            "mounts" => [],
            "cargo" => %{"capacity" => 0, "units" => 0, "inventory" => []},
            "fuel" => %{"current" => 0, "capacity" => 0, "consumed" => %{"amount" => 0}},
            "cooldown" => %{
              "shipSymbol" => ship_symbol,
              "totalSeconds" => 0,
              "remainingSeconds" => 0
            }
          }
        ]
      }
    }
  end
end
