defmodule SpaceTraders.FleetTest do
  # navigate_ship and boot re-arm start ship GenServers, which read and write the
  # timeline as separate processes, so the sandbox must be shared (not async).
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.Job
  alias SpaceTraders.Fleet.JobBlocker
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Fleet.Activity
  alias SpaceTraders.Fleet.ManualIntent
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  import Phoenix.PubSub
  import SpaceTraders.ShipBody

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  defp agent_fixture(token \\ "AGENT_TOKEN") do
    Repo.insert!(%AgentRecord{
      symbol: "FLEET-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: token
    })
  end

  defp ship_fixture(agent, symbol) do
    Repo.insert!(%Ship{symbol: symbol, ship_type: "SHIP_COMMAND_FRIGATE", agent_id: agent.id})
  end

  defp future_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp contract_delivery_entry(overrides \\ %{}) do
    Map.merge(
      %{
        "tradeSymbol" => "IRON_ORE",
        "destinationSymbol" => "X1-UX81-A1",
        "unitsRequired" => 100,
        "unitsFulfilled" => 0
      },
      overrides
    )
  end

  defp active_contract_body(id, deliver_entries \\ [contract_delivery_entry()]) do
    %{
      "id" => id,
      "accepted" => true,
      "fulfilled" => false,
      "factionSymbol" => "COSMIC",
      "type" => "PROCUREMENT",
      "deadlineToAccept" => future_iso(),
      "terms" => %{
        "deadline" => future_iso(),
        "deliver" => deliver_entries,
        "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
      }
    }
  end

  defp market_at_market(inventory, fuel_full \\ true) do
    %Model.Ship{
      symbol: "FLEET-SHIP",
      nav: %Model.ShipNav{
        status: "DOCKED",
        waypoint_symbol: "X1-UX81-A1",
        system_symbol: "X1-UX81"
      },
      cargo: %Model.ShipCargo{
        capacity: 40,
        units: Enum.reduce(inventory, 0, fn item, acc -> acc + item.units end),
        inventory: inventory
      },
      fuel: %Model.ShipFuel{capacity: 200, current: if(fuel_full, do: 200, else: 5)}
    }
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp navigate_response(status), do: navigate_response(status, future_iso())

  defp navigate_response(status, arrival), do: navigate_response(status, arrival, "X1-UX81-A2")

  defp navigate_response(status, arrival, destination) do
    %{
      "fuel" => %{"capacity" => 200, "current" => 80},
      "nav" => nav_body(status, arrival: arrival, destination: destination)
    }
  end

  defp assert_confirmed_market_action_recovery(action, ship_overrides) do
    agent = agent_fixture()
    ship_fixture(agent, "FLEET-SHIP")

    {:ok, config} =
      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

    Repo.update!(
      Ecto.Changeset.change(config,
        desired_mode: "active",
        status: "active",
        in_flight_action: action
      )
    )

    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:api_request, conn.request_path})

      case conn.request_path do
        "/v2/my/contracts" ->
          Req.Test.json(conn, %{"data" => []})

        "/v2/my/ships/FLEET-SHIP" ->
          Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP", ship_overrides)})

        "/v2/my/ships/FLEET-SHIP/orbit" ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        "/v2/my/ships/FLEET-SHIP/navigate" ->
          Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
      end
    end)

    assert {:ok, _} = Fleet.recover_job_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

    assert_receive {:api_request, "/v2/my/ships/FLEET-SHIP"}
    assert_receive {:api_request, "/v2/my/ships/FLEET-SHIP/orbit"}
    assert_receive {:api_request, "/v2/my/ships/FLEET-SHIP/navigate"}
    refute_receive {:api_request, _}
  end

  describe "list_ships/1" do
    test "pulls the agent's live fleet from the game API" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships"

        Req.Test.json(conn, %{
          "data" => [
            ship_body("ORBITALIST-1"),
            ship_body("ORBITALIST-2", %{
              "registration" => %{
                "name" => "ORBITALIST-2",
                "factionSymbol" => "COSMIC",
                "role" => "SATELLITE"
              },
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "IN_ORBIT",
                "flightMode" => "CRUISE"
              }
            })
          ]
        })
      end)

      agent = %AgentRecord{agent_token: "AGENT_TOKEN"}

      assert {:ok,
              [
                %Model.Ship{symbol: "ORBITALIST-1", nav: %Model.ShipNav{status: "DOCKED"}},
                %Model.Ship{
                  symbol: "ORBITALIST-2",
                  registration: %Model.ShipRegistration{role: "SATELLITE"},
                  nav: %Model.ShipNav{status: "IN_ORBIT"}
                }
              ]} = Fleet.list_ships(agent)
    end

    test "authorizes the request with the agent's token" do
      import Plug.Conn, only: [get_req_header: 2]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert get_req_header(conn, "authorization") == ["Bearer AGENT_TOKEN"]
        Req.Test.json(conn, %{"data" => []})
      end)

      assert {:ok, []} = Fleet.list_ships(%AgentRecord{agent_token: "AGENT_TOKEN"})
    end

    test "returns an error when the agent has no stored token" do
      assert {:error, :agent_token_missing} = Fleet.list_ships(%AgentRecord{agent_token: nil})
    end

    test "propagates gameplay errors from the API" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{"error" => %{"code" => 4011, "message" => "Invalid token"}})
      end)

      assert {:error, %SpaceTraders.API.GameplayError{}} =
               Fleet.list_ships(%AgentRecord{agent_token: "BAD"})
    end
  end

  describe "transfer_cargo/5" do
    test "validates both live ships before transferring cargo" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/SOURCE" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("SOURCE", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                  }
                })
            })

          "/v2/my/ships/TARGET" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("TARGET", %{
                  "cargo" => %{"capacity" => 40, "units" => 10, "inventory" => []}
                })
            })

          "/v2/my/ships/SOURCE/transfer" ->
            Req.Test.json(conn, %{
              "data" => %{"cargo" => %{"capacity" => 40, "units" => 2, "inventory" => []}}
            })
        end
      end)

      assert {:ok, %{cargo: %Model.ShipCargo{units: 2}}} =
               Fleet.transfer_cargo(agent, "SOURCE", "TARGET", "IRON_ORE", 3)
    end

    test "rejects ships at different waypoints before the transfer request" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/SOURCE" ->
            Req.Test.json(conn, %{"data" => ship_body("SOURCE")})

          "/v2/my/ships/TARGET" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("TARGET", %{
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-A2",
                    "status" => "DOCKED",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          path ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:error, :transfer_waypoint_mismatch} =
               Fleet.transfer_cargo(agent, "SOURCE", "TARGET", "IRON_ORE", 1)
    end
  end

  describe "Miner Job" do
    test "projects a saved Miner Job loop as the Ship's Miner Job" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{} = config} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      persisted =
        Repo.update!(
          Ecto.Changeset.change(Repo.get!(Job, config.id),
            desired_mode: "active",
            status: "waiting",
            in_flight_action: %{"kind" => "cooldown"},
            last_action_result: %{"kind" => "extract", "units" => 4},
            progress: %{"last_completed" => "extract"},
            recovery_attempts: 2,
            last_validated_at: ~U[2030-01-01 00:00:00Z],
            blocked_reason: "Awaiting cooldown"
          )
        )

      assert %Job{
               type: "miner",
               gather_mode: "extract",
               extraction_waypoint: "X1-UX81-A2",
               market_waypoint: "X1-UX81-A1",
               cargo_threshold: 30,
               desired_mode: "active",
               status: "waiting",
               in_flight_action: %{"kind" => "cooldown"},
               last_action_result: %{"kind" => "extract", "units" => 4},
               progress: %{"last_completed" => "extract"},
               recovery_attempts: 2,
               last_validated_at: ~U[2030-01-01 00:00:00Z],
               blocked_reason: "Awaiting cooldown"
             } = Fleet.ship_job(agent, "FLEET-SHIP")

      assert Fleet.ship_job(agent, "FLEET-SHIP").id == persisted.id

      assert {:ok, %Job{status: "paused"}} =
               Fleet.pause_miner_job(agent, "FLEET-SHIP")
    end

    test "persists a siphon gather mode on the configured Waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{gather_mode: "siphon"}} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A3",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30,
                 gather_mode: "siphon"
               })

      assert Fleet.ship_job(agent, "FLEET-SHIP").gather_mode == "siphon"
    end

    test "pauses and resumes the Miner Job without losing its configured loop" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{}} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert {:ok, %Job{status: "paused", desired_mode: "manual"}} =
               Fleet.pause_miner_job(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{"error" => %{"code" => 4011, "message" => "Invalid token"}})
      end)

      assert {:error, {:miner_job_blocked, _reason}} = Fleet.resume_miner_job(agent, "FLEET-SHIP")

      assert %Job{
               extraction_waypoint: "X1-UX81-A2",
               status: "blocked",
               blocker: %JobBlocker{
                 reason: reason,
                 evidence: evidence,
                 observed_at: %DateTime{},
                 resolver: "game_state",
                 retry_condition: "authoritative_read_succeeds",
                 corrective_actions: ["resume"]
               }
             } =
               Fleet.ship_job(agent, "FLEET-SHIP")

      assert is_binary(reason)
      assert is_binary(evidence)
    end

    test "replaces the assigned Miner Job and preserves the predecessor as terminal history" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{id: predecessor_id}} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert {:ok, %Job{id: successor_id, status: "paused"}} =
               Fleet.replace_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A3",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 20,
                 gather_mode: "siphon"
               })

      refute predecessor_id == successor_id

      assert %Job{id: ^successor_id, extraction_waypoint: "X1-UX81-A3"} =
               Fleet.ship_job(agent, "FLEET-SHIP")

      assert [%Job{id: ^predecessor_id, status: "replaced", finished_at: %DateTime{}}] =
               Fleet.ship_job_history(agent, "FLEET-SHIP")

      predecessor = Repo.get!(Job, predecessor_id)

      assert_raise Exqlite.Error, ~r/terminal jobs are immutable/, fn ->
        Repo.update!(Ecto.Changeset.change(predecessor, status: "active"))
      end

      refreshed = %Model.Ship{
        symbol: "FLEET-SHIP",
        cooldown: %Model.Cooldown{remaining_seconds: 0}
      }

      assert :ok =
               Fleet.revalidate_miner_job_cooldown(
                 agent.id,
                 "FLEET-SHIP",
                 refreshed,
                 predecessor_id
               )

      assert %Job{id: ^successor_id, status: "paused"} =
               Fleet.ship_job(agent, "FLEET-SHIP")
    end

    test "stops the Miner Job and preserves it as immutable terminal history" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{id: job_id}} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert :ok = Fleet.stop_miner_job(agent, "FLEET-SHIP")
      assert Fleet.ship_job(agent, "FLEET-SHIP") == nil

      assert [%Job{id: ^job_id, status: "stopped", finished_at: %DateTime{}}] =
               Fleet.ship_job_history(agent, "FLEET-SHIP")

      assert {:error, :miner_job_not_configured} =
               Fleet.resume_miner_job(agent, "FLEET-SHIP")

      assert [%{kind: "stop"} | _] = Fleet.recent_activity(agent)
    end

    test "terminal history does not block stale Agent retirement" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{id: job_id}} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert :ok = Fleet.stop_miner_job(agent, "FLEET-SHIP")
      assert Repo.get!(Job, job_id).status == "stopped"

      assert %{id: id} = Repo.delete!(agent)
      assert id == agent.id
      refute Repo.get(Job, job_id)
      refute Repo.get(Ship, ship.id)
    end

    test "manual navigation pauses active Miner Job before dispatch" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      config = Fleet.ship_job(agent, "FLEET-SHIP")
      Repo.update!(Ecto.Changeset.change(config, desired_mode: "active", status: "waiting"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => navigate_response("DOCKED")})
      end)

      assert {:ok, _} = Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A1")

      assert %{status: "paused", blocked_reason: "Paused by direct navigation"} =
               Fleet.ship_job(agent, "FLEET-SHIP")

      assert Enum.any?(Fleet.recent_activity(agent), &(&1.kind == "manual_override"))
      assert Enum.any?(Fleet.recent_activity(agent), &(&1.kind == "navigate"))
    end

    test "direct navigation refuses an in-flight Job-owned Intent before dispatch" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      {:ok, job} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(job, status: "active"))

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        job_id: job.id,
        caller: "job",
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "active",
        in_flight_action: %{"kind" => "navigate"}
      })

      Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("direct navigation was dispatched") end)

      assert {:error, :job_action_reconciliation_required} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A1")

      assert %{status: "active"} = Repo.get!(Job, job.id)
    end

    test "pausing during an arrival wait preserves the in-flight navigation" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      in_flight = %{
        "kind" => "navigate",
        "waypoint" => "X1-UX81-A2",
        "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A2"}
      }

      Repo.update!(Ecto.Changeset.change(config, status: "waiting", in_flight_action: in_flight))

      assert {:ok, %Job{status: "paused", in_flight_action: ^in_flight}} =
               Fleet.pause_miner_job(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}],
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A2", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Job{status: "waiting", in_flight_action: ^in_flight}} =
               Fleet.resume_miner_job(agent, "FLEET-SHIP")

      assert [%Event{event_type: "arrival", payload: %{"job_id" => job_id}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")

      assert job_id == config.id
    end

    test "persists a loop without starting it" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{} = config} =
               Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert config.desired_mode == "manual"
      assert config.status == "paused"
      assert Fleet.ship_job(agent, "FLEET-SHIP").cargo_threshold == 30
    end

    test "starts only after validating authoritative ship, waypoints and market" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")}
            })
        end
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"},
                last_action_result: %{"status" => "IN_TRANSIT"},
                last_validated_at: %DateTime{}
              }} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert [%Event{event_type: "arrival"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "arrival revalidation completes the attempt without replaying navigation" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
        end
      end)

      assert {:ok, %Job{status: "waiting"} = config} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      arrived = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A2"},
        cargo: %Model.ShipCargo{capacity: 40, units: 30, inventory: []}
      }

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} =
               Fleet.revalidate_miner_job_arrival(agent.id, "FLEET-SHIP", arrived)

      assert {:ok, %Job{status: "waiting"}} =
               Fleet.advance_miner_job(agent, Repo.get!(Job, config.id), arrived)

      assert {:ok, %Job{status: "waiting"}} =
               Fleet.advance_miner_job(agent, Repo.get!(Job, config.id), arrived)
    end

    test "extracts once below the cargo threshold at the configured waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      expiration = future_iso(60)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/my/ships/FLEET-SHIP/extract" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => expiration
                },
                "extraction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                }
              }
            })
        end
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "extract"},
                last_action_result: %{
                  "kind" => "extract",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                }
              }} = Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert [%Event{event_type: "cooldown", payload: %{"job_id" => job_id}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")

      assert job_id == Fleet.ship_job(agent, "FLEET-SHIP").id
    end

    test "the own extraction does not preempt the started job and the loop continues" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      expiration = future_iso(60)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "imports" => [%{"symbol" => "IRON_ORE"}],
                "tradeGoods" => [%{"symbol" => "FUEL"}]
              }
            })

          "/v2/my/ships/FLEET-SHIP/extract" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => expiration
                },
                "extraction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                }
              }
            })
        end
      end)

      assert {:ok, _job} = Fleet.start_miner_job(agent, "FLEET-SHIP")

      stored = Repo.get!(Job, config.id)

      assert stored.status == "waiting"
      assert stored.blocked_reason == nil
      assert %{"kind" => "extract"} = stored.in_flight_action

      refute Repo.exists?(
               from a in SpaceTraders.Fleet.Activity,
                 where: a.ship_id == ^stored.ship_id and a.kind == "manual_override"
             )

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "FLEET-SHIP")

      refreshed = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A2"},
        cargo: %Model.ShipCargo{capacity: 40, units: 0, inventory: []},
        cooldown: %Model.Cooldown{
          ship_symbol: "FLEET-SHIP",
          total_seconds: 0,
          remaining_seconds: 0,
          expiration: future_iso(60)
        }
      }

      assert {:ok, %Job{status: "waiting"}} =
               Fleet.revalidate_miner_job_cooldown(agent.id, "FLEET-SHIP", refreshed)

      assert %Job{status: "waiting", blocked_reason: nil} =
               Repo.get!(Job, config.id)
    end

    test "siphons once below the cargo threshold at the configured waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A3",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        gather_mode: "siphon"
      })

      expiration = future_iso(60)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A3"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                  "mounts" => [%{"symbol" => "MOUNT_GAS_SIPHON_I"}],
                  "modules" => [%{"symbol" => "MODULE_GAS_PROCESSOR_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A3" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A3", "type" => "GAS_GIANT", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/my/ships/FLEET-SHIP/siphon" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => expiration
                },
                "siphon" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 5}]
                },
                "events" => []
              }
            })
        end
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "siphon"},
                last_action_result: %{
                  "kind" => "siphon",
                  "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
                }
              }} = Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "cooldown wakeup records siphon completion before another siphon" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A3",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          gather_mode: "siphon"
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "waiting",
          in_flight_action: %{"kind" => "siphon"},
          last_action_result: %{
            "kind" => "siphon",
            "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
          }
        )
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/siphon"

        Req.Test.json(conn, %{
          "data" => %{
            "cooldown" => %{
              "shipSymbol" => "FLEET-SHIP",
              "totalSeconds" => 0,
              "remainingSeconds" => 0,
              "expiration" => future_iso()
            },
            "siphon" => %{
              "shipSymbol" => "FLEET-SHIP",
              "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
            },
            "cargo" => %{
              "capacity" => 40,
              "units" => 10,
              "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 10}]
            },
            "events" => []
          }
        })
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "siphon"},
                progress: progress
              }} =
               Fleet.revalidate_miner_job_cooldown(
                 agent.id,
                 "FLEET-SHIP",
                 %Model.Ship{
                   symbol: "FLEET-SHIP",
                   nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A3"},
                   cargo: %Model.ShipCargo{capacity: 40, units: 5, inventory: []},
                   cooldown: %Model.Cooldown{remaining_seconds: 0}
                 }
               )

      assert progress == %{"last_completed" => "siphon"}
    end

    test "boot recovery confirms an in-flight siphon and re-arms the loop" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A3",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          gather_mode: "siphon"
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "active",
          in_flight_action: %{
            "kind" => "siphon",
            "waypoint" => "X1-UX81-A3",
            "expected" => %{"cargo_units_at_least" => 1}
          }
        )
      )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:api_request, conn.request_path})

        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A3"),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 5}]
                  }
                })
            })

          "/v2/my/ships/FLEET-SHIP/siphon" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 0,
                  "remainingSeconds" => 0,
                  "expiration" => future_iso()
                },
                "siphon" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 10,
                  "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 10}]
                },
                "events" => []
              }
            })
        end
      end)

      assert {:ok, _} = Fleet.recover_job_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      assert_receive {:api_request, "/v2/my/ships/FLEET-SHIP"}
      assert_receive {:api_request, "/v2/my/ships/FLEET-SHIP/siphon"}
      refute_receive {:api_request, _}

      recovered = Fleet.ship_job(agent, "FLEET-SHIP")
      assert recovered.status == "waiting"
      assert recovered.in_flight_action["kind"] == "siphon"

      assert recovered.last_action_result["yield"] == %{
               "symbol" => "LIQUID_HYDROGEN",
               "units" => 5
             }

      assert [%{kind: "miner_job_recovery", metadata: %{"outcome" => "confirmed"}} | _] =
               Fleet.recent_activity(agent)
    end

    test "departs the gas giant when siphoned cargo reaches the sellable threshold" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A3",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          gather_mode: "siphon"
        })

      Repo.update!(Ecto.Changeset.change(config, sellable_goods: ["LIQUID_HYDROGEN"]))

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A3"},
        cargo: %Model.ShipCargo{
          capacity: 40,
          units: 30,
          inventory: [%Model.ShipCargoItem{symbol: "LIQUID_HYDROGEN", units: 30}]
        }
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "imports" => [%{"symbol" => "LIQUID_HYDROGEN"}],
                "tradeGoods" => []
              }
            })

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} =
               Fleet.advance_miner_job(agent, %{config | desired_mode: "active"}, live_ship)

      assert [%Event{event_type: "arrival"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "sells siphoned cargo at the configured market and returns to the gas giant" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A3",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          gather_mode: "siphon"
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "imports" => [%{"symbol" => "LIQUID_HYDROGEN"}],
                "tradeGoods" => [%{"symbol" => "FUEL"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "x" => 0, "y" => 0}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A3" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A3", "x" => 10, "y" => 0}})

          "/v2/my/ships/FLEET-SHIP/sell" ->
            assert conn.body_params == %{"symbol" => "LIQUID_HYDROGEN", "units" => 30}

            Req.Test.json(conn, %{
              "data" => %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
            })

          "/v2/my/ships/FLEET-SHIP/refuel" ->
            Req.Test.json(conn, %{
              "data" => %{"fuel" => %{"capacity" => 200, "current" => 200}}
            })

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{
              "data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A3")
            })

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A3")}
            })
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{
          capacity: 40,
          units: 30,
          inventory: [%Model.ShipCargoItem{symbol: "LIQUID_HYDROGEN", units: 30}]
        },
        fuel: %Model.ShipFuel{capacity: 200, current: 5}
      }

      config = %{config | desired_mode: "active", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)
    end

    test "navigates to the configured market when cargo reaches the threshold" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A2"},
        cargo: %Model.ShipCargo{capacity: 40, units: 30, inventory: []}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/navigate"
        Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} =
               Fleet.advance_miner_job(agent, %{config | desired_mode: "active"}, live_ship)

      assert [%Event{event_type: "arrival"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "sells accepted cargo, jettisons rejected cargo, and returns to extraction" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "imports" => [%{"symbol" => "IRON_ORE"}],
                "tradeGoods" => [%{"symbol" => "FUEL"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "x" => 0, "y" => 0}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A2", "x" => 10, "y" => 0}})

          "/v2/my/ships/FLEET-SHIP/sell" ->
            assert conn.body_params == %{"symbol" => "IRON_ORE", "units" => 10}

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "COPPER_ORE", "units" => 5}]
                }
              }
            })

          "/v2/my/ships/FLEET-SHIP/jettison" ->
            assert conn.body_params == %{"symbol" => "COPPER_ORE", "units" => 5}

            Req.Test.json(conn, %{
              "data" => %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
            })

          "/v2/my/ships/FLEET-SHIP/refuel" ->
            Req.Test.json(conn, %{"data" => %{"fuel" => %{"capacity" => 200, "current" => 200}}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")}
            })
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{
          capacity: 40,
          units: 15,
          inventory: [
            %Model.ShipCargoItem{symbol: "IRON_ORE", units: 10},
            %Model.ShipCargoItem{symbol: "COPPER_ORE", units: 5}
          ]
        },
        fuel: %Model.ShipFuel{capacity: 200, current: 5}
      }

      config = %{
        config
        | desired_mode: "active",
          progress: %{"waypoint" => "X1-UX81-A1"}
      }

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)
    end

    test "blocks at the configured market when it cannot refill the Ship" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "x" => 0, "y" => 0}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A2", "x" => 10, "y" => 0}})
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{capacity: 40, units: 0, inventory: []},
        fuel: %Model.ShipFuel{capacity: 200, current: 0}
      }

      config = %{config | desired_mode: "active", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:error, {:market_fuel_unavailable, "X1-UX81-A1"}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert %Job{status: "blocked", blocker: %JobBlocker{reason: reason}} =
               Repo.get!(Job, config.id)

      assert reason == "market_fuel_unavailable"
    end

    test "blocks when configured market refueling remains below return-leg fuel" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => [%{"symbol" => "FUEL"}]}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "x" => 0, "y" => 0}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A2", "x" => 10, "y" => 0}})

          "/v2/my/ships/FLEET-SHIP/refuel" ->
            Req.Test.json(conn, %{"data" => %{"fuel" => %{"capacity" => 200, "current" => 198}}})
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{capacity: 40, units: 0, inventory: []},
        fuel: %Model.ShipFuel{capacity: 200, current: 0}
      }

      config = %{config | desired_mode: "active", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:error, {:market_fuel_insufficient, "X1-UX81-A1", 198, 200}} =
               Fleet.advance_miner_job(agent, config, live_ship)
    end

    test "does not require market fuel when a Ship is already full" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "x" => 0, "y" => 0}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A2", "x" => 10, "y" => 0}})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81",
          flight_mode: "DRIFT"
        },
        cargo: %Model.ShipCargo{capacity: 40, units: 0, inventory: []},
        fuel: %Model.ShipFuel{capacity: 200, current: 200}
      }

      config = %{config | desired_mode: "active", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)
    end

    test "waits for an authoritative cooldown before extracting" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A2"},
        cargo: %Model.ShipCargo{capacity: 40, units: 0, inventory: []},
        cooldown: %Model.Cooldown{
          remaining_seconds: 20,
          expiration: DateTime.add(DateTime.utc_now(), 20, :second) |> DateTime.to_iso8601()
        }
      }

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "cooldown"}}} =
               Fleet.advance_miner_job(agent, %{config | desired_mode: "active"}, live_ship)

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "cooldown wakeup records extraction completion before another action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "waiting",
          in_flight_action: %{"kind" => "extract"},
          last_action_result: %{
            "kind" => "extract",
            "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
          }
        )
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/navigate"
        Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
      end)

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"},
                progress: progress
              }} =
               Fleet.revalidate_miner_job_cooldown(
                 agent.id,
                 "FLEET-SHIP",
                 %Model.Ship{
                   symbol: "FLEET-SHIP",
                   nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A2"},
                   cargo: %Model.ShipCargo{capacity: 40, units: 30, inventory: []},
                   cooldown: %Model.Cooldown{remaining_seconds: 0}
                 }
               )

      assert progress == %{"last_completed" => "extract", "waypoint" => "X1-UX81-A1"}
    end

    test "ShipServer arrival wakeup resumes extraction after returning from market" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "waiting",
          in_flight_action: %{
            "kind" => "navigate",
            "waypoint" => "X1-UX81-A2",
            "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A2"}
          }
        )
      )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:api_request, conn.request_path})

        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A2"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
                })
            })

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")}
            })

          "/v2/my/ships/FLEET-SHIP/extract" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => future_iso(60)
                },
                "extraction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                }
              }
            })
        end
      end)

      {:ok, event} =
        Timeline.schedule_event(
          :ship,
          "FLEET-SHIP",
          :arrival,
          DateTime.add(DateTime.utc_now(), -1, :second)
        )

      subscribe(SpaceTraders.PubSub, "fleet:#{agent.id}")
      agent_id = agent.id

      start_supervised!(
        {ShipServer, symbol: "FLEET-SHIP", agent_id: agent.id, agent_token: agent.agent_token}
      )

      assert_receive {:ship_updated, ^agent_id, "FLEET-SHIP"}, 1_000

      assert Repo.get!(Event, event.id).status == "done"

      assert_receive {:api_request, "/v2/my/ships/FLEET-SHIP/extract"}, 1_000

      assert eventually(fn ->
               current = Repo.get_by!(Job, ship_id: config.ship_id)

               current.status == "waiting" and
                 current.in_flight_action["kind"] == "extract"
             end)
    end

    test "blocks an invalid extraction waypoint without a game action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })
        end
      end)

      assert {:error, {:miner_job_blocked, :invalid_extraction_waypoint}} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert Fleet.ship_job(agent, "FLEET-SHIP").status == "blocked"
    end

    test "blocks a siphon-mode Job at a non-gas-giant waypoint without a game action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        gather_mode: "siphon"
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "mounts" => [%{"symbol" => "MOUNT_GAS_SIPHON_I"}],
                  "modules" => [%{"symbol" => "MODULE_GAS_PROCESSOR_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })
        end
      end)

      assert {:error, {:miner_job_blocked, :invalid_siphon_waypoint}} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert Fleet.ship_job(agent, "FLEET-SHIP").status == "blocked"
    end

    test "blocks a siphon-mode Job without gas siphon capability" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A3",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        gather_mode: "siphon"
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A3" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A3", "type" => "GAS_GIANT", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})
        end
      end)

      assert {:error, {:miner_job_blocked, :siphon_capability_missing}} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert Fleet.ship_job(agent, "FLEET-SHIP").status == "blocked"
    end

    test "extract mode still requires a mineral-bearing waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A3",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "mounts" => [%{"symbol" => "MOUNT_GAS_SIPHON_I"}],
                  "modules" => [%{"symbol" => "MODULE_GAS_PROCESSOR_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A3" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A3", "type" => "GAS_GIANT", "traits" => []}
            })
        end
      end)

      assert {:error, {:miner_job_blocked, :invalid_extraction_waypoint}} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert Fleet.ship_job(agent, "FLEET-SHIP").status == "blocked"
    end

    test "boot recovery confirms an in-flight navigation without replaying it" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "waiting",
          in_flight_action: %{
            "kind" => "navigate",
            "waypoint" => "X1-UX81-A2",
            "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A2"}
          }
        )
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP"

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "nav" =>
                nav_body("IN_TRANSIT", destination: "X1-UX81-A2", arrival: "2030-01-01T00:00:00Z")
            })
        })
      end)

      assert {:ok, _} = Fleet.recover_job_on_boot("FLEET-SHIP", agent.id, agent.agent_token)
      recovered = Fleet.ship_job(agent, "FLEET-SHIP")
      assert recovered.last_action_result == %{"kind" => "recovery", "outcome" => "confirmed"}
      assert recovered.recovery_attempts == 0

      assert [%{kind: "miner_job_recovery", metadata: %{"outcome" => "confirmed"}} | _] =
               Fleet.recent_activity(agent)
    end

    test "boot recovery confirms an in-flight sell without replaying it" do
      assert_confirmed_market_action_recovery(
        %{
          "kind" => "sell",
          "trade_symbol" => "IRON_ORE",
          "expected" => %{"units_at_most" => 0}
        },
        %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
      )
    end

    test "boot recovery confirms an in-flight jettison without replaying it" do
      assert_confirmed_market_action_recovery(
        %{
          "kind" => "jettison",
          "trade_symbol" => "COPPER_ORE",
          "expected" => %{"units_at_most" => 0}
        },
        %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
      )
    end

    test "boot recovery confirms an in-flight refuel without replaying it" do
      assert_confirmed_market_action_recovery(
        %{"kind" => "refuel", "expected" => %{"fuel_full" => true}},
        %{
          "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
          "fuel" => %{"capacity" => 200, "current" => 200}
        }
      )
    end

    test "ambiguous boot recovery blocks without replaying a game action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "active",
          in_flight_action: %{"kind" => "unknown_action"}
        )
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP"
        Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})
      end)

      assert {:error, :miner_job_recovery_blocked} =
               Fleet.recover_job_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      recovered = Fleet.ship_job(agent, "FLEET-SHIP")
      assert recovered.status == "blocked"
      assert recovered.last_action_result["outcome"] == "ambiguous"

      assert recovered.blocker == %JobBlocker{
               reason: "ambiguous",
               summary: "The game did not confirm whether the in-flight action completed.",
               evidence: "\"ambiguous\"",
               observed_at: recovered.blocker.observed_at,
               resolver: "game_state",
               retry_condition: "authoritative_action_outcome_available",
               corrective_actions: ["inspect_activity", "reconcile_and_retry"]
             }

      assert [%{kind: "miner_job_recovery", metadata: %{"outcome" => "ambiguous"}} | _] =
               Fleet.recent_activity(agent)
    end

    defp sorting_market_body(imports, overrides \\ %{}) do
      Map.merge(
        %{
          "symbol" => "X1-UX81-A1",
          "imports" => Enum.map(imports, &%{"symbol" => &1}),
          "exchange" => [],
          "exports" => [],
          "tradeGoods" => []
        },
        overrides
      )
    end

    defp mining_ship_at_extraction(inventory) do
      units = Enum.reduce(inventory, 0, fn item, acc -> acc + item.units end)

      %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "IN_ORBIT",
          waypoint_symbol: "X1-UX81-A2",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{capacity: 40, units: units, inventory: inventory},
        cooldown: %Model.Cooldown{remaining_seconds: 0}
      }
    end

    defp cargo_item(symbol, units), do: %Model.ShipCargoItem{symbol: symbol, units: units}

    defp activate_for_extraction(config, sellable_goods) do
      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "active",
          status: "active",
          sellable_goods: sellable_goods,
          progress: %{"waypoint" => "X1-UX81-A2"}
        )
      )
    end

    test "start persists the configured Market's accepted sellable goods" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => sorting_market_body(["IRON_ORE"])})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      assert {:ok, %Job{}} = Fleet.start_miner_job(agent, "FLEET-SHIP")
      assert Fleet.ship_job(agent, "FLEET-SHIP").sellable_goods == ["IRON_ORE"]
    end

    test "jettisons unsellable cargo at the mining waypoint before a sellable threshold departure" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config = activate_for_extraction(config, ["IRON_ORE"])
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => sorting_market_body(["IRON_ORE"])})

          "/v2/my/ships/FLEET-SHIP/jettison" ->
            send(test_pid, {:jettison_request, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 30,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 30}]
                }
              }
            })

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship =
        mining_ship_at_extraction([
          cargo_item("IRON_ORE", 30),
          cargo_item("COPPER_ORE", 6)
        ])

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} = Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:jettison_request, %{"symbol" => "COPPER_ORE", "units" => 6}}
      refute_receive {:jettison_request, _}

      assert [%{kind: "miner_job_jettison", metadata: %{"jettison" => _}} | _] =
               Fleet.recent_activity(agent)
    end

    test "keeps gathering while sellable cargo is below the threshold" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config = activate_for_extraction(config, ["IRON_ORE"])
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => sorting_market_body(["IRON_ORE"])})

          "/v2/my/ships/FLEET-SHIP/jettison" ->
            send(test_pid, {:jettison_request, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 10,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 10}]
                }
              }
            })

          "/v2/my/ships/FLEET-SHIP/extract" ->
            send(test_pid, {:extract_request})

            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => future_iso(60)
                },
                "extraction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 15}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 25,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 25}]
                }
              }
            })
        end
      end)

      live_ship =
        mining_ship_at_extraction([
          cargo_item("IRON_ORE", 10),
          cargo_item("COPPER_ORE", 6)
        ])

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "extract"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:jettison_request, %{"symbol" => "COPPER_ORE", "units" => 6}}
      assert_receive {:extract_request}

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "keeps gathering when total cargo clears the threshold but sellable cargo does not" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config = activate_for_extraction(config, ["IRON_ORE"])
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP/jettison" ->
            send(test_pid, {:jettison_request, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{
                  "capacity" => 60,
                  "units" => 10,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 10}]
                }
              }
            })

          "/v2/my/ships/FLEET-SHIP/extract" ->
            send(test_pid, {:extract_request})

            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => future_iso(60)
                },
                "extraction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 60,
                  "units" => 15,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 15}]
                }
              }
            })
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "IN_ORBIT",
          waypoint_symbol: "X1-UX81-A2",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{
          capacity: 60,
          units: 50,
          inventory: [cargo_item("IRON_ORE", 10), cargo_item("COPPER_ORE", 40)]
        },
        cooldown: %Model.Cooldown{remaining_seconds: 0}
      }

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "extract"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:jettison_request, %{"symbol" => "COPPER_ORE", "units" => 40}}
      assert_receive {:extract_request}
      refute_receive {:navigate_request, _}
    end

    test "falls back to the total-cargo loop when the market's goods are unknown" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config = activate_for_extraction(config, [])
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/navigate"
        send(test_pid, {:navigate_request})
        Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
      end)

      live_ship =
        mining_ship_at_extraction([
          cargo_item("IRON_ORE", 30),
          cargo_item("QUARTZ_SAND", 10)
        ])

      assert {:ok, %Job{in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:navigate_request}
      refute_receive {:jettison_request, _}
    end

    test "revalidates accepted goods before departure and jettisons newly unsellable cargo" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config = activate_for_extraction(config, ["IRON_ORE", "COPPER_ORE"])
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => sorting_market_body(["IRON_ORE"])})

          "/v2/my/ships/FLEET-SHIP/jettison" ->
            send(test_pid, {:jettison_request, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 30,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 30}]
                }
              }
            })

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship =
        mining_ship_at_extraction([
          cargo_item("IRON_ORE", 30),
          cargo_item("COPPER_ORE", 4)
        ])

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:jettison_request, %{"symbol" => "COPPER_ORE", "units" => 4}}

      assert %Job{sellable_goods: ["IRON_ORE"]} = Fleet.ship_job(agent, "FLEET-SHIP")
    end

    test "departs when the pre-departure market revalidation is unavailable" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config = activate_for_extraction(config, ["IRON_ORE"])
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            conn
            |> Map.put(:status, 500)
            |> Req.Test.json(%{})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            send(test_pid, {:navigate_request})
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = mining_ship_at_extraction([cargo_item("IRON_ORE", 30)])

      assert {:ok,
              %Job{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} = Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:navigate_request}

      assert %Job{status: "waiting"} = Fleet.ship_job(agent, "FLEET-SHIP")
      refute Fleet.ship_job(agent, "FLEET-SHIP").status == "blocked"
    end

    test "sells the sellable payload at the market and never hauls rejected goods there" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "active",
            status: "active",
            sellable_goods: ["IRON_ORE"],
            progress: %{"waypoint" => "X1-UX81-A1"}
          )
        )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" =>
                sorting_market_body(["IRON_ORE"], %{
                  "tradeGoods" => [%{"symbol" => "FUEL"}]
                })
            })

          "/v2/my/ships/FLEET-SHIP/sell" ->
            send(test_pid, {:sell_request, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
              }
            })

          "/v2/my/ships/FLEET-SHIP/refuel" ->
            Req.Test.json(conn, %{"data" => %{"fuel" => %{"capacity" => 200, "current" => 200}}})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cargo: %Model.ShipCargo{
          capacity: 40,
          units: 30,
          inventory: [cargo_item("IRON_ORE", 30)]
        },
        fuel: %Model.ShipFuel{capacity: 200, current: 5}
      }

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:sell_request, %{"symbol" => "IRON_ORE", "units" => 30}}
      refute_receive {:jettison_request, _}
    end

    test "delivers contract cargo before selling the same good at its destination market" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "active",
            status: "active",
            sellable_goods: ["IRON_ORE"],
            progress: %{"waypoint" => "X1-UX81-A1"}
          )
        )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => [active_contract_body("ctr-1")]})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" =>
                sorting_market_body(["IRON_ORE"], %{"tradeGoods" => [%{"symbol" => "FUEL"}]})
            })

          "/v2/my/contracts/ctr-1/deliver" ->
            send(test_pid, {:deliver_request, "ctr-1", "IRON_ORE", 40})

            Req.Test.json(conn, %{
              "data" => %{
                "contract" =>
                  active_contract_body("ctr-1", [
                    contract_delivery_entry(%{"unitsFulfilled" => 40})
                  ]),
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
              }
            })

          "/v2/my/ships/FLEET-SHIP/sell" ->
            send(test_pid, {:sell_request, conn.body_params})
            flunk("owed good was sold before delivery")

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = market_at_market([cargo_item("IRON_ORE", 40)])

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:deliver_request, "ctr-1", "IRON_ORE", 40}
      refute_receive {:sell_request, _}

      assert [%Activity{kind: "miner_job_deliver", message: message}] =
               Repo.all(from a in Activity, order_by: [desc: a.id], limit: 1)

      assert message =~ "Delivered 40 IRON_ORE"
      assert message =~ "contract ctr-1"
      assert message =~ "60 remain"

      assert %Job{contract_deliverables: [%{"units_remaining" => 60}]} = Repo.get!(Job, config.id)
    end

    test "sells only units beyond the contract's remaining requirement" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "active",
            status: "active",
            sellable_goods: ["IRON_ORE"],
            progress: %{"waypoint" => "X1-UX81-A1"}
          )
        )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{
              "data" => [
                active_contract_body("ctr-1", [contract_delivery_entry(%{"unitsFulfilled" => 60})])
              ]
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" =>
                sorting_market_body(["IRON_ORE"], %{"tradeGoods" => [%{"symbol" => "FUEL"}]})
            })

          "/v2/my/contracts/ctr-1/deliver" ->
            send(test_pid, {:deliver_request, "ctr-1", "IRON_ORE", 40})

            Req.Test.json(conn, %{
              "data" => %{
                "contract" =>
                  active_contract_body("ctr-1", [
                    contract_delivery_entry(%{"unitsRequired" => 100, "unitsFulfilled" => 100})
                  ]),
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 60,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 60}]
                }
              }
            })

          "/v2/my/ships/FLEET-SHIP/sell" ->
            send(test_pid, {:sell_request, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
            })

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = market_at_market([cargo_item("IRON_ORE", 100)])

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:deliver_request, "ctr-1", "IRON_ORE", 40}
      assert_receive {:sell_request, %{"symbol" => "IRON_ORE", "units" => 60}}
      refute_receive {:sell_request, %{"symbol" => "IRON_ORE", "units" => 100}}

      assert [%Activity{message: message}] =
               Repo.all(from a in Activity, order_by: [desc: a.id], limit: 1)

      assert message =~ "Delivered 40 IRON_ORE"
      assert message =~ "0 remain"
    end

    test "never sells a good an active contract still owes with multiple outstanding contracts" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "active",
            status: "active",
            sellable_goods: ["IRON_ORE"],
            progress: %{"waypoint" => "X1-UX81-A1"}
          )
        )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{
              "data" => [
                active_contract_body("ctr-1", [contract_delivery_entry(%{"unitsRequired" => 10})]),
                active_contract_body("ctr-2", [
                  contract_delivery_entry(%{"unitsRequired" => 25, "unitsFulfilled" => 10})
                ])
              ]
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" =>
                sorting_market_body(["IRON_ORE"], %{"tradeGoods" => [%{"symbol" => "FUEL"}]})
            })

          "/v2/my/contracts/ctr-1/deliver" ->
            send(test_pid, {:deliver_request, "ctr-1", "IRON_ORE", 10})

            Req.Test.json(conn, %{
              "data" => %{
                "contract" =>
                  active_contract_body("ctr-1", [
                    contract_delivery_entry(%{"unitsRequired" => 10, "unitsFulfilled" => 10})
                  ]),
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 15,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 15}]
                }
              }
            })

          "/v2/my/contracts/ctr-2/deliver" ->
            send(test_pid, {:deliver_request, "ctr-2", "IRON_ORE", 15})

            Req.Test.json(conn, %{
              "data" => %{
                "contract" =>
                  active_contract_body("ctr-2", [
                    contract_delivery_entry(%{"unitsRequired" => 25, "unitsFulfilled" => 25})
                  ]),
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
              }
            })

          "/v2/my/ships/FLEET-SHIP/sell" ->
            send(test_pid, {:sell_request, conn.body_params})
            flunk("owed good was sold before delivery")

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = market_at_market([cargo_item("IRON_ORE", 25)])

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:deliver_request, "ctr-1", "IRON_ORE", 10}
      assert_receive {:deliver_request, "ctr-2", "IRON_ORE", 15}
      refute_receive {:sell_request, _}

      assert %Job{contract_deliverables: deliverables} = Repo.get!(Job, config.id)

      assert %{"contract_id" => "ctr-1", "units_remaining" => 0} =
               Enum.find(deliverables, &(&1["contract_id"] == "ctr-1"))

      assert %{"contract_id" => "ctr-2", "units_remaining" => 0} =
               Enum.find(deliverables, &(&1["contract_id"] == "ctr-2"))
    end

    test "delivers from persisted deliverables when the contracts refresh is unavailable" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "active",
            status: "active",
            sellable_goods: ["IRON_ORE"],
            progress: %{"waypoint" => "X1-UX81-A1"},
            contract_deliverables: [
              %{
                "contract_id" => "ctr-1",
                "destination_symbol" => "X1-UX81-A1",
                "trade_symbol" => "IRON_ORE",
                "units_required" => 100,
                "units_fulfilled" => 0,
                "units_remaining" => 100
              }
            ]
          )
        )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            send(test_pid, {:contracts_request, conn.request_path})

            conn
            |> Map.put(:status, 500)
            |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "boom"}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" =>
                sorting_market_body(["IRON_ORE"], %{"tradeGoods" => [%{"symbol" => "FUEL"}]})
            })

          "/v2/my/contracts/ctr-1/deliver" ->
            send(test_pid, {:deliver_request, "ctr-1", "IRON_ORE", 30})

            Req.Test.json(conn, %{
              "data" => %{
                "contract" =>
                  active_contract_body("ctr-1", [
                    contract_delivery_entry(%{"unitsFulfilled" => 30})
                  ]),
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
              }
            })

          "/v2/my/ships/FLEET-SHIP/sell" ->
            send(test_pid, {:sell_request, conn.body_params})
            flunk("owed good was sold before delivery")

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
        end
      end)

      live_ship = market_at_market([cargo_item("IRON_ORE", 30)])

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_miner_job(agent, config, live_ship)

      assert_receive {:contracts_request, "/v2/my/contracts"}
      assert_receive {:deliver_request, "ctr-1", "IRON_ORE", 30}
      refute_receive {:sell_request, _}
    end

    test "preserves known deliverables when the start refresh is unavailable" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            contract_deliverables: [
              %{
                "contract_id" => "ctr-1",
                "destination_symbol" => "X1-UX81-A1",
                "trade_symbol" => "IRON_ORE",
                "units_required" => 100,
                "units_fulfilled" => 0,
                "units_remaining" => 100
              }
            ]
          )
        )

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A2", "type" => "ASTEROID_FIELD", "traits" => []}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          "/v2/my/contracts" ->
            send(test_pid, {:contracts_request, conn.request_path})

            conn
            |> Map.put(:status, 500)
            |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "boom"}})

          "/v2/my/ships/FLEET-SHIP/extract" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 0,
                  "remainingSeconds" => 0,
                  "expiration" => future_iso()
                },
                "extraction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                }
              }
            })
        end
      end)

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "extract"}}} =
               Fleet.start_miner_job(agent, "FLEET-SHIP")

      assert_receive {:contracts_request, "/v2/my/contracts"}

      assert %Job{contract_deliverables: [%{"contract_id" => "ctr-1", "units_remaining" => 100}]} =
               Repo.get!(Job, config.id)
    end

    test "recovers a half-completed in-flight delivery on boot" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "active",
            status: "active",
            in_flight_action: %{
              "kind" => "deliver",
              "waypoint" => "X1-UX81-A1",
              "trade_symbol" => "IRON_ORE",
              "expected" => %{"units_at_most" => 60}
            }
          )
        )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 40,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 40}]
                  }
                })
            })

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => [%{"symbol" => "FUEL"}]}
            })

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          "/v2/my/ships/FLEET-SHIP/navigate" ->
            Req.Test.json(conn, %{
              "data" => navigate_response("IN_TRANSIT")
            })
        end
      end)

      assert {:ok, %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.recover_job_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      assert [%Activity{kind: "miner_job_recovery", message: message}] =
               Repo.all(from a in Activity, order_by: [desc: a.id], limit: 1)

      assert message =~ "confirmed after restart"

      assert %Job{status: "waiting", in_flight_action: %{"kind" => "navigate"}} =
               Repo.get!(Job, config.id)
    end
  end

  describe "Procurement Job" do
    setup do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/" <> ship_symbol, "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body(ship_symbol)})

          {path, method} ->
            flunk("unexpected request #{method} #{path}")
        end
      end)

      :ok
    end

    test "captures the Ship's fixed current System and rejects a remote destination" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      ship_fixture(agent, "FLEET-SHIP-2")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"GET", "/v2/my/ships/" <> ship_symbol} = {conn.method, conn.request_path}
        Req.Test.json(conn, %{"data" => ship_body(ship_symbol)})
      end)

      assert {:ok, %Job{progress: %{"target_system" => "X1-UX81"}}} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP-2", %{
                 recipient_type: "market",
                 trade_symbol: "IRON_ORE",
                 quantity: 30,
                 destination_waypoint: "X1-UX81-A1"
               })

      assert {:error,
              {:remote_destination_system_unsupported,
               %{current_system: "X1-UX81", destination_system: "X1-DF55"}}} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 recipient_type: "market",
                 trade_symbol: "IRON_ORE",
                 quantity: 30,
                 destination_waypoint: "X1-DF55-A1"
               })
    end

    test "persists a fixed Market recipient and sale floor" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{} = job} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 recipient_type: "market",
                 trade_symbol: "IRON_ORE",
                 quantity: 30,
                 destination_waypoint: "X1-UX81-A1",
                 source_systems: ["X1-UX81"],
                 minimum_sale_price: 25
               })

      assert job.progress == %{
               "recipient_type" => "market",
               "trade_symbol" => "IRON_ORE",
               "requested" => 30,
               "destination_waypoint" => "X1-UX81-A1",
               "target_system" => "X1-UX81",
               "source_systems" => ["X1-UX81"],
               "reserve_credits" => 0,
               "price_ceiling" => nil,
               "minimum_sale_price" => 25,
               "minimum_sale_value" => nil,
               "compatible_existing_cargo" => false,
               "acquired" => 0,
               "aboard" => 0,
               "sold" => 0,
               "accepted" => 0,
               "shared_fulfilled" => 0,
               "external_progress" => 0,
               "spent" => 0
             }
    end

    test "sells at the fixed Market from a fresh listing and completes from the transaction" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 30,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 30}]
                  }
                })
            })

          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1_000}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            send(test_pid, :fresh_sale_listing)

            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "sellPrice" => 25,
                    "purchasePrice" => 10,
                    "tradeVolume" => 30
                  }
                ]
              }
            })

          "/v2/my/ships/FLEET-SHIP/sell" ->
            send(test_pid, {:sale, conn.body_params})

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 1_750},
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "transaction" => %{
                  "type" => "SELL",
                  "tradeSymbol" => "IRON_ORE",
                  "shipSymbol" => "FLEET-SHIP",
                  "waypointSymbol" => "X1-UX81-A1",
                  "units" => 30
                }
              }
            })
        end
      end)

      assert {:ok, configured_job} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 recipient_type: "market",
                 trade_symbol: "IRON_ORE",
                 quantity: 30,
                 destination_waypoint: "X1-UX81-A1",
                 minimum_sale_price: 25,
                 compatible_existing_cargo?: true
               })

      assert {:ok,
              %Job{
                status: "completed",
                progress: %{"acquired" => 0, "sold" => 30, "accepted" => 30}
              }} =
               Fleet.start_procurement_job(agent, "FLEET-SHIP")

      assert_receive :fresh_sale_listing
      assert_receive {:sale, %{"symbol" => "IRON_ORE", "units" => 30}}
      assert Fleet.ship_manual_intent(agent, "FLEET-SHIP") == nil
      configured_job_id = configured_job.id

      assert %ManualIntent{
               caller: "job",
               job_id: ^configured_job_id,
               type: "sell",
               status: "completed",
               last_action_result: %{"transaction" => %{"type" => "SELL", "units" => 30}}
             } =
               Repo.one!(
                 from intent in ManualIntent,
                   where: intent.job_id == ^configured_job.id,
                   order_by: [desc: intent.id],
                   limit: 1
               )
    end

    test "persists the fixed delivery constraints and initial progress" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{} = job} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 contract_id: "CONTRACT-1",
                 trade_symbol: "IRON_ORE",
                 quantity: 30,
                 destination_waypoint: "X1-UX81-A1",
                 source_systems: ["X1-UX81"],
                 reserve_credits: 500,
                 price_ceiling: 75,
                 compatible_existing_cargo?: true
               })

      assert job.type == "procurement"
      assert job.status == "paused"

      assert job.progress == %{
               "contract_id" => "CONTRACT-1",
               "recipient_type" => "contract",
               "trade_symbol" => "IRON_ORE",
               "requested" => 30,
               "destination_waypoint" => "X1-UX81-A1",
               "target_system" => "X1-UX81",
               "source_systems" => ["X1-UX81"],
               "reserve_credits" => 500,
               "price_ceiling" => 75,
               "minimum_sale_price" => nil,
               "minimum_sale_value" => nil,
               "compatible_existing_cargo" => true,
               "acquired" => 0,
               "aboard" => 0,
               "sold" => 0,
               "accepted" => 0,
               "shared_fulfilled" => 0,
               "external_progress" => 0,
               "spent" => 0
             }
    end

    test "persists a fixed Construction recipient and initial progress" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %Job{} = job} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 recipient_type: "construction",
                 construction_system: "X1-UX81",
                 trade_symbol: "IRON_ORE",
                 quantity: 30,
                 destination_waypoint: "X1-UX81-A1",
                 source_systems: ["X1-UX81"],
                 reserve_credits: 500,
                 price_ceiling: 75,
                 compatible_existing_cargo?: true
               })

      assert job.progress == %{
               "recipient_type" => "construction",
               "construction_system" => "X1-UX81",
               "trade_symbol" => "IRON_ORE",
               "requested" => 30,
               "destination_waypoint" => "X1-UX81-A1",
               "target_system" => "X1-UX81",
               "source_systems" => ["X1-UX81"],
               "reserve_credits" => 500,
               "price_ceiling" => 75,
               "minimum_sale_price" => nil,
               "minimum_sale_value" => nil,
               "compatible_existing_cargo" => true,
               "acquired" => 0,
               "aboard" => 0,
               "sold" => 0,
               "accepted" => 0,
               "shared_fulfilled" => 0,
               "external_progress" => 0,
               "spent" => 0
             }
    end

    test "rejects incomplete procurement constraints" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:error, :invalid_procurement_configuration} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 contract_id: "CONTRACT-1",
                 trade_symbol: "IRON_ORE",
                 quantity: 0,
                 destination_waypoint: "X1-UX81-A1"
               })
    end

    test "preserves waypoint API failures while sourcing a Procurement Job" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, _job} =
               Fleet.configure_procurement_job(agent, "FLEET-SHIP", %{
                 contract_id: "CONTRACT-1",
                 trade_symbol: "DIAMONDS",
                 quantity: 10,
                 destination_waypoint: "X1-UX81-A1"
               })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                active_contract_body(
                  "CONTRACT-1",
                  [contract_delivery_entry(%{"tradeSymbol" => "DIAMONDS", "unitsRequired" => 10})]
                )
              ]
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Plug.Conn.send_resp(conn, 500, ~s({"error":"boom"}))
        end
      end)

      assert {:error, %SpaceTraders.API.Error{status: 500}} =
               Fleet.start_procurement_job(agent, "FLEET-SHIP")
    end

    test "uses the persisted Buy Goods Intent without preempting itself" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      {:ok, job} =
        Fleet.configure_procurement_job(agent, ship.symbol, %{
          contract_id: "CONTRACT-1",
          trade_symbol: "IRON_ORE",
          quantity: 5,
          destination_waypoint: "X1-UX81-A1",
          source_systems: ["X1-UX81"],
          reserve_credits: 0,
          compatible_existing_cargo?: true
        })

      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            reads = Process.get(:procurement_ship_reads, 0)
            Process.put(:procurement_ship_reads, reads + 1)

            cargo =
              if reads == 0 do
                %{"capacity" => 40, "units" => 0, "inventory" => []}
              else
                %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                }
              end

            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP", %{"cargo" => cargo})})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => [active_contract_body("CONTRACT-1")]})

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "traits" => [%{"symbol" => "MARKETPLACE"}]
                }
              ],
              "meta" => %{"page" => 1, "total" => 1}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 10,
                    "sellPrice" => 8,
                    "tradeVolume" => 10
                  }
                ]
              }
            })

          {"/v2/my/ships/FLEET-SHIP/purchase", "POST"} ->
            intent = Repo.one!(from i in ManualIntent, where: i.ship_id == ^ship.id)

            send(test_pid, {:job_buy_intent, intent.parameters, Repo.get!(Job, job.id).status})

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 50},
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                },
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "IRON_ORE",
                  "type" => "PURCHASE",
                  "units" => 5,
                  "pricePerUnit" => 10,
                  "totalPrice" => 50,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })

          {"/v2/my/contracts/CONTRACT-1/deliver", "POST"} ->
            intent =
              Repo.one!(
                from i in ManualIntent,
                  where: i.ship_id == ^ship.id and i.type == "deliver"
              )

            send(
              test_pid,
              {:job_delivery_intent, intent.parameters, Repo.get!(Job, job.id).status}
            )

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "contract" =>
                  active_contract_body("CONTRACT-1", [
                    contract_delivery_entry(%{"unitsFulfilled" => 5})
                  ])
              }
            })
        end
      end)

      assert {:ok, %Job{status: "completed"}} = Fleet.start_procurement_job(agent, ship.symbol)

      assert_receive {:job_buy_intent,
                      %{
                        "max_price" => nil,
                        "recipient" => %{
                          "contract_id" => "CONTRACT-1",
                          "type" => "contract",
                          "waypoint" => "X1-UX81-A1"
                        },
                        "reserve_credits" => 0,
                        "trade_symbol" => "IRON_ORE",
                        "units" => 5
                      }, "active"}

      assert_receive {:job_delivery_intent,
                      %{
                        "contract_id" => "CONTRACT-1",
                        "recipient" => %{
                          "contract_id" => "CONTRACT-1",
                          "type" => "contract",
                          "waypoint" => "X1-UX81-A1"
                        },
                        "trade_symbol" => "IRON_ORE",
                        "units" => 5
                      }, "active"}
    end
  end

  describe "Construction Supply Job" do
    test "captures one fixed Construction project and its multi-material constraints" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"GET", "/v2/my/ships/FLEET-SHIP"} = {conn.method, conn.request_path}
        Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})
      end)

      assert {:ok, %Job{type: "construction_supply", status: "paused", progress: progress}} =
               Fleet.configure_construction_supply_job(agent, "FLEET-SHIP", %{
                 construction_system: "X1-UX81",
                 construction_waypoint: "X1-UX81-A1",
                 source_systems: ["X1-UX81"],
                 reserve_credits: 500,
                 maximum_total_cost: 2_000,
                 compatible_existing_cargo?: true
               })

      assert progress == %{
               "construction_system" => "X1-UX81",
               "construction_waypoint" => "X1-UX81-A1",
               "target_system" => "X1-UX81",
               "source_systems" => ["X1-UX81"],
               "reserve_credits" => 500,
               "maximum_total_cost" => 2_000,
               "compatible_existing_cargo" => true,
               "accepted" => %{},
               "acquired" => %{},
               "committed_cargo" => %{},
               "spent" => 0,
               "trips" => 0,
               "external_progress" => %{}
             }
    end
  end

  describe "System Exploration Job" do
    test "captures the authoritative current System and completes remote baseline coverage" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          "/v2/systems/X1-UX81/waypoints" ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "x" => 1,
                  "y" => 2,
                  "traits" => [%{"symbol" => "MARKETPLACE"}]
                }
              ],
              "meta" => %{"page" => 1, "total" => 1}
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "ORBITAL_STATION",
                "x" => 1,
                "y" => 2,
                "orbits" => "X1-UX81-A0",
                "orbitals" => [],
                "traits" => [%{"symbol" => "MARKETPLACE"}],
                "modifiers" => [],
                "isUnderConstruction" => false
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "exports" => [],
                "imports" => [],
                "exchange" => []
              }
            })

          "/v2/my/ships/FLEET-SHIP/chart" ->
            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{},
                "chart" => %{"waypointSymbol" => "X1-UX81-A1", "submittedBy" => "FLEET-SHIP"},
                "waypoint" => %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "x" => 1,
                  "y" => 2,
                  "orbits" => "X1-UX81-A0",
                  "orbitals" => [],
                  "traits" => [%{"symbol" => "MARKETPLACE"}],
                  "modifiers" => [],
                  "isUnderConstruction" => false,
                  "chart" => %{"waypointSymbol" => "X1-UX81-A1", "submittedBy" => "FLEET-SHIP"}
                }
              }
            })

          path ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok,
              %Job{type: "explorer", status: "paused", progress: %{"target_system" => "X1-UX81"}}} =
               Fleet.configure_explorer_job(agent, "FLEET-SHIP")

      assert {:ok, %Job{status: "completed", progress: %{"coverage" => coverage}}} =
               Fleet.start_explorer_job(agent, "FLEET-SHIP")

      assert coverage["X1-UX81-A1"] == []
    end
  end

  describe "command_snapshot/1" do
    test "adds Ship command decisions with stable block reasons" do
      agent = agent_fixture()

      ship =
        ship_body("FLEET-SHIP", %{
          "nav" => %{
            "systemSymbol" => "X1-UX81",
            "waypointSymbol" => "X1-UX81-A1",
            "status" => "DOCKED",
            "flightMode" => "CRUISE"
          },
          "cooldown" => %{"remainingSeconds" => 12}
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship]})

          "/v2/systems/X1-UX81/waypoints" ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)

      assert {:ok, [%{actions: actions}]} = snapshot.ships

      # Outcome-level Navigate is always dispatchable: its Intent reconciles
      # cooldown and transit instead of refusing while the Ship is busy.
      assert actions.navigate == %{allowed?: true, reason: nil}
      assert actions.dock == %{allowed?: false, reason: :cooldown_active}
      assert actions.orbit == %{allowed?: false, reason: :cooldown_active}
      assert actions.extract == %{allowed?: false, reason: :cooldown_active}
      assert actions.siphon == %{allowed?: false, reason: :cooldown_active}
      assert actions.refuel == %{allowed?: false, reason: :cooldown_active}
    end

    test "reuses fresh headquarters waypoints for the browser and listings" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.query_params["traits"]} do
          {"/v2/my/agent", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          {"/v2/my/contracts", _} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", _} ->
            Req.Test.json(conn, %{"data" => [ship_body("FLEET-SHIP")]})

          {"/v2/systems/X1-UX81/waypoints", nil} ->
            case conn.query_params["page"] do
              "1" ->
                Req.Test.json(conn, %{
                  "data" => [
                    %{
                      "symbol" => "X1-UX81-A1",
                      "systemSymbol" => "X1-UX81",
                      "type" => "ORBITAL_STATION",
                      "traits" => [
                        %{"symbol" => "MARKETPLACE"},
                        %{"symbol" => "SHIPYARD"}
                      ]
                    }
                  ]
                })

              _ ->
                Req.Test.json(conn, %{"data" => []})
            end

          {"/v2/systems/X1-UX81/waypoints", trait} when trait in ["MARKETPLACE", "SHIPYARD"] ->
            flunk(
              "expected command snapshot to reuse the full headquarters read, not rediscover #{trait}"
            )

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", _} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "type" => "EXPORT",
                    "purchasePrice" => 10,
                    "sellPrice" => 8,
                    "tradeVolume" => 10
                  }
                ]
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)

      assert {:ok, [%{symbol: "X1-UX81-A1"}]} = snapshot.waypoints

      assert {:ok, [%{actions: actions}]} = snapshot.ships
      assert actions.navigate == %{allowed?: true, reason: nil}
      assert actions.dock == %{allowed?: false, reason: :ship_not_in_orbit}
      assert actions.orbit == %{allowed?: true, reason: nil}
      assert actions.extract == %{allowed?: false, reason: :ship_not_in_orbit}
      assert actions.siphon == %{allowed?: false, reason: :ship_not_in_orbit}
      assert actions.refuel == %{allowed?: true, reason: nil}

      assert {:ok,
              [
                %{
                  waypoint: "X1-UX81-A1",
                  market: %{symbol: "X1-UX81-A1"},
                  ships: [%{trade_actions: trade_actions}]
                }
              ]} = snapshot.markets

      assert trade_actions["IRON_ORE"].sell == %{allowed?: true, reason: nil}
      assert trade_actions["IRON_ORE"].buy == %{allowed?: true, reason: nil}

      assert {:ok, [%{waypoint: "X1-UX81-A1", shipyard: %{symbol: "X1-UX81-A1"}}]} =
               snapshot.shipyards
    end

    test "falls back to independent listing discovery when headquarters waypoints are unavailable" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.query_params["traits"]} do
          {"/v2/my/agent", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          {"/v2/my/contracts", _} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", _} ->
            Req.Test.json(conn, %{"data" => [ship_body("FLEET-SHIP")]})

          {"/v2/systems/X1-UX81/waypoints", nil} ->
            conn
            |> Map.put(:status, 400)
            |> Req.Test.json(%{"error" => %{"message" => "unavailable"}})

          {"/v2/systems/X1-UX81/waypoints", trait} when trait in ["MARKETPLACE", "SHIPYARD"] ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "traits" => [%{"symbol" => trait}]
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)

      assert {:error, _reason} = snapshot.waypoints
      assert {:ok, [%{waypoint: "X1-UX81-A1"}]} = snapshot.markets
      assert {:ok, [%{waypoint: "X1-UX81-A1"}]} = snapshot.shipyards
    end

    test "uses trait-filtered discovery for listings outside headquarters" do
      agent = agent_fixture()

      ship =
        ship_body("FLEET-SHIP", %{
          "nav" => %{
            "systemSymbol" => "X1-UX82",
            "waypointSymbol" => "X1-UX82-A1",
            "status" => "DOCKED",
            "flightMode" => "CRUISE"
          }
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.query_params["traits"]} do
          {"/v2/my/agent", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          {"/v2/my/contracts", _} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", _} ->
            Req.Test.json(conn, %{"data" => [ship]})

          {"/v2/systems/X1-UX81/waypoints", nil} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/systems/X1-UX82/waypoints", trait} when trait in ["MARKETPLACE", "SHIPYARD"] ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX82-A1",
                  "systemSymbol" => "X1-UX82",
                  "type" => "ORBITAL_STATION",
                  "traits" => [%{"symbol" => trait}]
                }
              ]
            })

          {"/v2/systems/X1-UX82/waypoints/X1-UX82-A1/market", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX82-A1", "tradeGoods" => []}})

          {"/v2/systems/X1-UX82/waypoints/X1-UX82-A1/shipyard", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX82-A1", "ships" => []}})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)

      assert {:ok, []} = snapshot.waypoints
      assert {:ok, [%{waypoint: "X1-UX82-A1"}]} = snapshot.markets
      assert {:ok, [%{waypoint: "X1-UX82-A1"}]} = snapshot.shipyards
    end

    test "keeps the shipyard result when a market listing is partially unavailable" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.query_params["traits"]} do
          {"/v2/my/agent", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          {"/v2/my/contracts", _} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", _} ->
            Req.Test.json(conn, %{"data" => [ship_body("FLEET-SHIP")]})

          {"/v2/systems/X1-UX81/waypoints", nil} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "traits" => [%{"symbol" => "MARKETPLACE"}, %{"symbol" => "SHIPYARD"}]
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", _} ->
            conn
            |> Map.put(:status, 400)
            |> Req.Test.json(%{"error" => %{"message" => "unavailable"}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", _} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)

      assert {:partial, []} = snapshot.markets
      assert {:ok, [%{waypoint: "X1-UX81-A1"}]} = snapshot.shipyards
    end

    test "assembles the agent overview, live fleet and on-site shipyard listings" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship_body("FLEET-SHIP")]})

          "/v2/systems/X1-UX81/waypoints" ->
            case conn.query_params["page"] do
              page when page in [nil, "1"] ->
                Req.Test.json(conn, %{
                  "data" => [
                    %{
                      "symbol" => "X1-UX81-A1",
                      "systemSymbol" => "X1-UX81",
                      "type" => "ORBITAL_STATION",
                      "x" => 1,
                      "y" => 2,
                      "traits" => [
                        %{"symbol" => "SHIPYARD", "name" => "Shipyard", "description" => ""}
                      ]
                    }
                  ]
                })

              _ ->
                Req.Test.json(conn, %{"data" => []})
            end

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "modificationsFee" => 100,
                "shipTypes" => [%{"type" => "SHIP_MINING_DRONE"}],
                "ships" => [
                  %{
                    "type" => "SHIP_MINING_DRONE",
                    "name" => "Mining Drone",
                    "purchasePrice" => 50
                  }
                ]
              }
            })
        end
      end)

      snapshot = Fleet.command_snapshot(agent)
      assert snapshot.agent == agent
      assert {:ok, %{symbol: symbol, credits: 42_000}} = snapshot.overview
      assert symbol == agent.symbol
      assert {:ok, [%{symbol: "FLEET-SHIP"}]} = snapshot.ships

      assert {:ok, [%{waypoint: "X1-UX81-A1", shipyard: %{symbol: "X1-UX81-A1"}}]} =
               snapshot.shipyards
    end

    test "keeps the agent overview when the live fleet is unavailable" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships" ->
            conn
            |> Map.put(:status, 500)
            |> Req.Test.json(%{})

          "/v2/systems/X1-UX81/waypoints" ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)
      assert {:ok, %{symbol: symbol, credits: 42_000}} = snapshot.overview
      assert symbol == agent.symbol
      assert {:error, _reason} = snapshot.ships
      assert snapshot.shipyards == {:ok, []}
    end
  end

  describe "waypoint_market/2" do
    test "reads a selected Marketplace Waypoint through Fleet" do
      agent = agent_fixture()

      waypoint = %{
        symbol: "X1-UX81-A1",
        system_symbol: "X1-UX81",
        traits: [%{symbol: "MARKETPLACE"}]
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"
        Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})
      end)

      assert {:ok, %{symbol: "X1-UX81-A1"}} = Fleet.waypoint_market(agent, waypoint)
    end

    test "does not read a selected non-Marketplace Waypoint" do
      agent = agent_fixture()
      waypoint = %{symbol: "X1-UX81-A1", system_symbol: "X1-UX81", traits: []}

      assert :not_a_marketplace = Fleet.waypoint_market(agent, waypoint)
    end
  end

  describe "purchase_ship/3" do
    test "purchases a listed ship and records it for restart recovery" do
      agent = agent_fixture()

      snapshot = %{
        agent: agent,
        shipyards:
          {:ok,
           [
             %{
               waypoint: "X1-UX81-A1",
               shipyard: %{ships: [%{type: "SHIP_MINING_DRONE"}]}
             }
           ]}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships"

        Req.Test.json(conn, %{
          "data" => %{
            "agent" => %{},
            "ship" => ship_body("FLEET-2"),
            "transaction" => %{}
          }
        })
      end)

      assert {:ok, %{ship: %{symbol: "FLEET-2"}, warning: nil}} =
               Fleet.purchase_ship(snapshot, "SHIP_MINING_DRONE", "X1-UX81-A1")

      assert %Ship{agent_id: agent_id, ship_type: "SHIP_MINING_DRONE"} =
               Repo.get_by(Ship, symbol: "FLEET-2")

      assert agent_id == agent.id
    end

    test "refuses a ship that is not in the snapshot listing" do
      agent = agent_fixture()

      snapshot = %{
        agent: agent,
        shipyards: {:ok, [%{waypoint: "X1-UX81-A1", shipyard: %{ships: []}}]}
      }

      assert {:error, :shipyard_unavailable} =
               Fleet.purchase_ship(snapshot, "SHIP_MINING_DRONE", "X1-UX81-A1")
    end

    test "reports a local record warning after a successful game purchase" do
      agent = agent_fixture()

      snapshot = %{
        agent: agent,
        shipyards:
          {:ok,
           [
             %{
               waypoint: "X1-UX81-A1",
               shipyard: %{ships: [%{type: "SHIP_MINING_DRONE"}]}
             }
           ]}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{"agent" => %{}, "ship" => %{}, "transaction" => %{}}
        })
      end)

      assert {:ok, %{warning: {:ship_record_failed, _reason}}} =
               Fleet.purchase_ship(snapshot, "SHIP_MINING_DRONE", "X1-UX81-A1")
    end
  end

  describe "navigate_ship/3" do
    test "navigates a ship to a waypoint and returns the nav" do
      agent = agent_fixture()
      arrival = future_iso()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/navigate"
        Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT", arrival)})
      end)

      assert {:ok, %{nav: nav, fuel: fuel}} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert nav.status == "IN_TRANSIT"
      assert nav.route.arrival == arrival
      assert fuel.current == 80
    end

    test "persists an arrival event and arms the ship's server" do
      agent = agent_fixture()
      arrival = future_iso()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT", arrival)})
      end)

      assert {:ok, _} = Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert [%Event{} = event] = Timeline.pending_events(:ship, "FLEET-SHIP")
      assert event.event_type == "arrival"
      assert event.payload == %{"destination" => "X1-UX81-A2"}
      assert {:ok, expected, _offset} = DateTime.from_iso8601(arrival)
      assert event.due_at == expected

      assert ShipServer.ensure_ready("FLEET-SHIP") == {:error, :ship_in_transit}
    end

    test "does not schedule an arrival when the ship is not in transit" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => navigate_response("DOCKED")})
      end)

      assert {:ok, %{nav: %{status: "DOCKED"}}} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A1")

      assert Timeline.pending_events(:ship, "FLEET-SHIP") == []
    end

    test "refuses while a local arrival is pending" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, _event} =
        Timeline.schedule_event(
          :ship,
          "FLEET-SHIP",
          :arrival,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      {:ok, _pid} = ShipServer.ensure_started(agent, "FLEET-SHIP")

      assert {:error, :ship_in_transit} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")
    end

    test "refuses while a cooldown is pending" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, _event} =
        Timeline.schedule_event(
          :ship,
          "FLEET-SHIP",
          :cooldown,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      {:ok, _pid} = ShipServer.ensure_started(agent, "FLEET-SHIP")

      assert {:error, :cooldown_active} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")
    end

    test "returns an error when the agent has no stored token" do
      assert {:error, :agent_token_missing} =
               Fleet.navigate_ship(%AgentRecord{agent_token: nil}, "FLEET-SHIP", "X1-UX81-A2")
    end

    test "propagates gameplay errors from the API" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 409)
        |> Req.Test.json(%{
          "error" => %{"code" => 4000, "message" => "Ship is in transit to its destination"}
        })
      end)

      assert {:error, %SpaceTraders.API.GameplayError{}} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")
    end

    test "persists five recent distinct successful destinations in recency order" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      destinations = ~w(A1 A2 A3 A4 A5 A6)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        destination = List.last(String.split(conn.body_params["waypointSymbol"] || "A1", "-"))

        Req.Test.json(conn, %{
          "data" => navigate_response("DOCKED", future_iso(), "X1-UX81-#{destination}")
        })
      end)

      Enum.each(destinations, fn suffix ->
        assert {:ok, _} = Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-#{suffix}")
      end)

      assert Fleet.destination_history(agent, "FLEET-SHIP") ==
               ~w(X1-UX81-A6 X1-UX81-A5 X1-UX81-A4 X1-UX81-A3 X1-UX81-A2)

      assert Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A3") |> elem(0) == :ok

      assert Fleet.destination_history(agent, "FLEET-SHIP") ==
               ~w(X1-UX81-A3 X1-UX81-A6 X1-UX81-A5 X1-UX81-A4 X1-UX81-A2)
    end

    test "does not mutate destination history when navigation fails" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => navigate_response("DOCKED", future_iso(), "X1-UX81-A2")})
      end)

      assert {:ok, _} = Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 409)
        |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "Unavailable"}})
      end)

      assert {:error, %SpaceTraders.API.GameplayError{}} =
               Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A3")

      assert Fleet.destination_history(agent, "FLEET-SHIP") == ["X1-UX81-A2"]
    end
  end

  describe "navigate_intent/3" do
    test "jumps through connected complete gates and completes from a fresh Ship read" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()
      {:ok, state} = Agent.start_link(fn -> %{jumped?: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.request_path, conn.method})

        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            destination = if Agent.get(state, & &1.jumped?), do: "X2-UX81-G1", else: "X1-UX81-G1"
            system = if destination == "X2-UX81-G1", do: "X2-UX81", else: "X1-UX81"

            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: destination, systemSymbol: system)
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "isComplete" => true, "materials" => []}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X2-UX81-G1", "isComplete" => true, "materials" => []}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X2-UX81-G1", "connections" => ["X1-UX81-G1"]}
            })

          {"/v2/my/ships/FLEET-SHIP/jump", "POST"} ->
            assert conn.body_params == %{"waypointSymbol" => "X2-UX81-G1"}
            Agent.update(state, &%{&1 | jumped?: true})

            Req.Test.json(conn, %{
              "data" => %{
                "nav" => nav_body("IN_ORBIT", destination: "X2-UX81-G1", systemSymbol: "X2-UX81"),
                "cooldown" => %{"shipSymbol" => "FLEET-SHIP", "remainingSeconds" => 60},
                "transaction" => %{"pricePerUnit" => 1_000, "totalPrice" => 1_000},
                "agent" => %{"symbol" => agent.symbol, "credits" => 41_000}
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{status: "completed", last_action_result: evidence}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert evidence["kind"] == "jump"
      assert evidence["transaction"]["total_price"] == 1_000
      assert_receive {:request, "/v2/my/ships/FLEET-SHIP/jump", "POST"}
    end

    test "blocks an incomplete jump-gate endpoint without dispatching a jump" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.request_path, conn.method})

        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-G1")
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "isComplete" => false, "materials" => []}
            })
        end
      end)

      assert {:ok, %ManualIntent{status: "blocked", blocker: blocker}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert blocker.reason == "jump_gate_incomplete"

      assert blocker.corrective_actions == [
               "inspect_construction",
               "supply_construction",
               "resume"
             ]

      refute_received {:request, "/v2/my/ships/FLEET-SHIP/jump", "POST"}
    end

    test "persists the active Job pause before Navigate dispatches a mutating request" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(config, status: "active"))
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, {:job_status_at_dispatch, Repo.get!(Job, config.id).status})

            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting", target_waypoint: "X1-UX81-A2"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert_receive {:job_status_at_dispatch, "paused"}
      assert %{status: "paused"} = Fleet.ship_job(agent, "FLEET-SHIP")
    end

    test "completes immediately when the Ship is already at the requested Waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
        })
      end)

      assert {:ok, %ManualIntent{status: "completed"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert Timeline.pending_events(:ship, "FLEET-SHIP") == []
    end

    test "keeps the preempted Job paused after completion" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(config, status: "active"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
        })
      end)

      assert {:ok, %ManualIntent{status: "completed"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert %{status: "paused", blocked_reason: "Paused by direct navigation"} =
               Fleet.ship_job(agent, "FLEET-SHIP")
    end

    test "orbits a docked Ship before navigating and persists the Intent's arrival" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      arrival = future_iso()
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            send(test_pid, :orbit)
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)

            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", arrival, "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert_received :orbit
      assert_received :navigate

      assert [%Event{} = event] = Timeline.pending_events(:ship, "FLEET-SHIP")
      assert event.event_type == "arrival"
      assert event.payload["destination"] == "X1-UX81-A2"
      assert event.payload["intent_id"]
      refute event.payload["job_id"]
    end

    test "waits when an in-transit Ship is already heading to the target" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert [%Event{event_type: "arrival", payload: %{"intent_id" => _}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "waits through a live cooldown before navigating" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "cooldown" => %{
                    "shipSymbol" => "FLEET-SHIP",
                    "totalSeconds" => 60,
                    "remainingSeconds" => 60,
                    "expiration" => future_iso(60)
                  }
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert [%Event{event_type: "cooldown", payload: %{"intent_id" => _}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "blocks a fuel-empty Ship without dispatching navigation" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "fuel" => %{"capacity" => 200, "current" => 0}
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "blocked"} = intent} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert intent.blocker.reason == "insufficient_fuel"
      assert "refuel" in intent.blocker.corrective_actions
    end

    test "blocks on an authoritative insufficient-fuel rejection without retrying" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "fuel" => %{"capacity" => 200, "current" => 5}
                })
            })

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)

            conn
            |> Map.put(:status, 422)
            |> Req.Test.json(%{
              "error" => %{
                "code" => 4203,
                "message" => "Ship does not have enough fuel to travel to destination."
              }
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "blocked"} = intent} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert_received :navigate
      refute_receive :navigate
      assert intent.blocker.reason == "insufficient_fuel"
    end

    test "replaces a pending manual outcome explicitly without cancelling accepted transit" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, first} = Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert {:ok, second} = Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A3")

      intents = Repo.all(from intent in ManualIntent, where: intent.ship_id == ^first.ship_id)
      assert length(intents) == 2

      predecessor = Enum.find(intents, &(&1.id == first.id))
      successor = Enum.find(intents, &(&1.id == second.id))

      assert %{status: "stopped", target_waypoint: "X1-UX81-A2"} = predecessor
      assert %{status: "waiting", target_waypoint: "X1-UX81-A3"} = successor
      refute_received :navigate
    end

    test "refuses Job resume while a manual Navigate is active" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert {:error, :manual_intent_active} = Fleet.resume_miner_job(agent, "FLEET-SHIP")
    end

    test "stops an active manual Navigate and keeps the Ship in Manual Control" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(config, status: "active"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")

      assert :ok = Fleet.stop_manual_intent(agent, "FLEET-SHIP")
      assert Fleet.ship_manual_intent(agent, "FLEET-SHIP") == nil

      assert %{status: "paused"} = Fleet.ship_job(agent, "FLEET-SHIP")

      intent = Repo.one!(from i in ManualIntent, select: i.status)
      assert intent == "stopped"
    end

    test "returns an error when the agent has no stored token" do
      assert {:error, :agent_token_missing} =
               Fleet.navigate_intent(%AgentRecord{agent_token: nil}, "FLEET-SHIP", "X1-UX81-A2")
    end
  end

  describe "manual intent revalidation" do
    test "arrival revalidation completes the Intent at the requested Waypoint" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      intent =
        Repo.insert!(%ManualIntent{
          ship_id: ship.id,
          type: "navigate",
          target_waypoint: "X1-UX81-A2",
          status: "waiting"
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "IN_ORBIT",
          waypoint_symbol: "X1-UX81-A2",
          system_symbol: "X1-UX81"
        }
      }

      assert {:ok, %ManualIntent{status: "completed"}} =
               Fleet.revalidate_manual_intent_arrival(
                 agent.id,
                 "FLEET-SHIP",
                 live_ship,
                 intent.id
               )
    end

    test "arrival revalidation navigates on from game truth after arriving elsewhere" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      intent =
        Repo.insert!(%ManualIntent{
          ship_id: ship.id,
          type: "navigate",
          target_waypoint: "X1-UX81-A2",
          status: "waiting"
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A3",
          system_symbol: "X1-UX81"
        },
        fuel: %Model.ShipFuel{capacity: 200, current: 100}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A3")}
            })

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)
            assert conn.body_params["waypointSymbol"] == "X1-UX81-A2"

            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.revalidate_manual_intent_arrival(
                 agent.id,
                 "FLEET-SHIP",
                 live_ship,
                 intent.id
               )

      assert_received :navigate
    end

    test "ignores events that do not belong to the active Intent" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting"
      })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A3",
          system_symbol: "X1-UX81"
        }
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        flunk("unexpected request #{conn.request_path}")
      end)

      assert :ok = Fleet.revalidate_manual_intent_arrival(agent.id, "FLEET-SHIP", live_ship, nil)
    end

    test "cooldown revalidation dispatches the pending navigation" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      intent =
        Repo.insert!(%ManualIntent{
          ship_id: ship.id,
          type: "navigate",
          target_waypoint: "X1-UX81-A2",
          status: "waiting"
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "IN_ORBIT",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cooldown: %Model.Cooldown{remaining_seconds: 0},
        fuel: %Model.ShipFuel{capacity: 200, current: 100}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)

            Req.Test.json(conn, %{
              "data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.revalidate_manual_intent_cooldown(
                 agent.id,
                 "FLEET-SHIP",
                 live_ship,
                 intent.id
               )

      assert_received :navigate
    end
  end

  describe "manual intent restart recovery" do
    test "boot recovery confirms an in-flight navigation and re-arms its arrival" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{
          "kind" => "navigate",
          "waypoint" => "X1-UX81-A2",
          "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A2"}
        }
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "waiting"}} =
               Fleet.recover_manual_intent_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      assert [%Event{event_type: "arrival", payload: %{"intent_id" => _}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "boot recovery completes an Intent whose Ship already sits at the target" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "active",
        in_flight_action: %{"kind" => "orbit", "waypoint" => "X1-UX81-A2"}
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{status: "completed"}} =
               Fleet.recover_manual_intent_on_boot("FLEET-SHIP", agent.id, agent.agent_token)
    end

    test "boot recovery blocks after repeated authoritative read failures" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "active"
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn |> Map.put(:status, 500) |> Req.Test.json(%{})
      end)

      assert {:error, :manual_intent_recovery_blocked} =
               Fleet.recover_manual_intent_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      intent = Repo.one!(from i in ManualIntent, where: i.ship_id == ^ship.id)
      assert intent.status == "blocked"
      assert intent.blocker.reason == "retry_exhausted"
    end
  end

  describe "ship actions" do
    test "Outfitting Job completes from fresh authoritative installed readiness" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, job} =
               Fleet.configure_outfitting_job(agent, "FLEET-SHIP", %{
                 requested_capability: "cargo capacity",
                 acceptable_modules: ["MODULE_CARGO_HOLD_I"],
                 authorized_removals: %{}
               })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}]
            })
        })
      end)

      assert {:ok, %Job{status: "completed", progress: progress}} =
               Fleet.start_outfitting_job(agent, "FLEET-SHIP")

      assert progress["requested_capability"] == "cargo capacity"
      assert progress["acceptable_modules"] == ["MODULE_CARGO_HOLD_I"]
      assert progress["installed_modules"] == ["MODULE_CARGO_HOLD_I"]

      assert progress["evidence"] == [
               %{"installed_modules" => ["MODULE_CARGO_HOLD_I"], "outcome" => "ready"}
             ]

      assert Repo.get!(Job, job.id).status == "completed"
    end

    test "Outfitting Job installs an acceptable Cargo module through the durable operation" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, _job} =
               Fleet.configure_outfitting_job(agent, "FLEET-SHIP", %{
                 requested_capability: "gas processing",
                 acceptable_modules: ["MODULE_GAS_PROCESSOR_I"],
                 authorized_removals: %{}
               })

      {:ok, response_state} = Elixir.Agent.start_link(fn -> :cargo end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            installed? = Elixir.Agent.get(response_state, &(&1 == :installed))

            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" =>
                    if(installed?,
                      do: [%{"symbol" => "MODULE_GAS_PROCESSOR_I", "name" => "Gas Processor I"}],
                      else: []
                    ),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => if(installed?, do: 0, else: 1),
                    "inventory" =>
                      if(installed?,
                        do: [],
                        else: [%{"symbol" => "MODULE_GAS_PROCESSOR_I", "units" => 1}]
                      )
                  }
                })
            })

          {"/v2/my/ships/FLEET-SHIP/modules/install", "POST"} ->
            assert conn.body_params == %{"symbol" => "MODULE_GAS_PROCESSOR_I"}
            Elixir.Agent.update(response_state, fn _ -> :installed end)

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 99},
                "modules" => [
                  %{"symbol" => "MODULE_GAS_PROCESSOR_I", "name" => "Gas Processor I"}
                ],
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "MODULE_GAS_PROCESSOR_I",
                  "totalPrice" => 1,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %Job{status: "completed", progress: progress}} =
               Fleet.start_outfitting_job(agent, "FLEET-SHIP")

      assert progress["cargo_candidate"] == "MODULE_GAS_PROCESSOR_I"
      assert [%{"operation" => %{"kind" => "install_module"}} | _] = progress["evidence"]
    end

    test "Outfitting Job never removes a module before an acceptable replacement is in Cargo" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, _job} =
               Fleet.configure_outfitting_job(agent, "FLEET-SHIP", %{
                 requested_capability: "gas processing",
                 acceptable_modules: ["MODULE_GAS_PROCESSOR_I"],
                 authorized_removals: %{"MODULE_CARGO_HOLD_I" => 1}
               })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "modules" => [
                %{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"},
                %{"symbol" => "MODULE_CREW_QUARTERS_I", "name" => "Crew Quarters I"}
              ]
            })
        })
      end)

      assert {:error, %Job{status: "blocked", blocker: blocker}} =
               Fleet.start_outfitting_job(agent, "FLEET-SHIP")

      assert blocker.reason == "acceptable_module_missing_from_cargo"
    end

    test "Outfitting Job buys an acceptable module from its fixed source Listing" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      {:ok, response_state} = Elixir.Agent.start_link(fn -> :before_purchase end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            installed? = Elixir.Agent.get(response_state, &(&1 == :installed))
            purchased? = Elixir.Agent.get(response_state, &(&1 == :purchased))

            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" =>
                    if(installed?,
                      do: [%{"symbol" => "MODULE_GAS_PROCESSOR_I", "name" => "Gas Processor I"}],
                      else: []
                    ),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => if(purchased?, do: 1, else: 0),
                    "inventory" =>
                      if(purchased?,
                        do: [%{"symbol" => "MODULE_GAS_PROCESSOR_I", "units" => 1}],
                        else: []
                      )
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 500}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            send(self(), :fresh_outfitting_listing)

            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "MODULE_GAS_PROCESSOR_I",
                    "purchasePrice" => 100,
                    "sellPrice" => 75,
                    "tradeVolume" => 1
                  }
                ]
              }
            })

          {"/v2/my/ships/FLEET-SHIP/purchase", "POST"} ->
            assert conn.body_params == %{"symbol" => "MODULE_GAS_PROCESSOR_I", "units" => 1}
            Elixir.Agent.update(response_state, fn _ -> :purchased end)

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 400},
                "cargo" => %{"capacity" => 40, "units" => 1, "inventory" => []},
                "transaction" => %{
                  "type" => "PURCHASE",
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "MODULE_GAS_PROCESSOR_I",
                  "waypointSymbol" => "X1-UX81-A1",
                  "units" => 1,
                  "pricePerUnit" => 100,
                  "totalPrice" => 100
                }
              }
            })

          {"/v2/my/ships/FLEET-SHIP/modules/install", "POST"} ->
            assert conn.body_params == %{"symbol" => "MODULE_GAS_PROCESSOR_I"}
            Elixir.Agent.update(response_state, fn _ -> :installed end)

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 400},
                "modules" => [
                  %{"symbol" => "MODULE_GAS_PROCESSOR_I", "name" => "Gas Processor I"}
                ],
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "MODULE_GAS_PROCESSOR_I",
                  "totalPrice" => 1,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %Job{progress: progress}} =
               Fleet.configure_outfitting_job(agent, "FLEET-SHIP", %{
                 requested_capability: "gas processing",
                 acceptable_modules: ["MODULE_GAS_PROCESSOR_I"],
                 authorized_removals: %{},
                 source_waypoints: ["X1-UX81-A1"],
                 reserve_credits: 250,
                 maximum_total_cost: 100
               })

      assert progress["source_system"] == "X1-UX81"

      assert {:ok, %Job{status: "completed", progress: progress}} =
               Fleet.start_outfitting_job(agent, "FLEET-SHIP")

      assert_receive :fresh_outfitting_listing
      assert_receive :fresh_outfitting_listing
      assert progress["spent"] == 100
      assert progress["cargo_candidate"] == "MODULE_GAS_PROCESSOR_I"
    end

    test "manual module installation persists evidence and leaves a preempted Job paused" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, job} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(job, status: "active"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 1,
                    "inventory" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "units" => 1}]
                  }
                })
            })

          {"/v2/my/ships/FLEET-SHIP/modules/install", "POST"} ->
            assert conn.body_params == %{"symbol" => "MODULE_CARGO_HOLD_I"}

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 99},
                "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "MODULE_CARGO_HOLD_I",
                  "totalPrice" => 1,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{type: "install_module", status: "completed"} = intent} =
               Fleet.install_module_intent(agent, "FLEET-SHIP", "MODULE_CARGO_HOLD_I")

      assert intent.parameters == %{
               "authorized_removals" => %{},
               "caller" => "manual",
               "module_symbol" => "MODULE_CARGO_HOLD_I",
               "quantity" => 1
             }

      assert intent.last_action_result["transaction"]["total_price"] == 1
      assert Fleet.ship_job(agent, "FLEET-SHIP").status == "paused"
    end

    test "manual module removal requires exact authorization" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:error, :invalid_module_intent} =
               Fleet.remove_module_intent(agent, "FLEET-SHIP", "MODULE_CARGO_HOLD_I", %{})

      assert {:error, :invalid_module_intent} =
               Fleet.remove_module_intent(agent, "FLEET-SHIP", "MODULE_CARGO_HOLD_I", %{
                 "MODULE_CARGO_HOLD_I" => 2
               })
    end

    test "manual module removal returns only the removed module to Cargo" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 3,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 3}]
                  }
                })
            })

          {"/v2/my/ships/FLEET-SHIP/modules/remove", "POST"} ->
            assert conn.body_params == %{"symbol" => "MODULE_CARGO_HOLD_I"}

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 99},
                "modules" => [],
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 4,
                  "inventory" => [
                    %{"symbol" => "IRON_ORE", "units" => 3},
                    %{"symbol" => "MODULE_CARGO_HOLD_I", "units" => 1}
                  ]
                },
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "MODULE_CARGO_HOLD_I",
                  "totalPrice" => 1,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{type: "remove_module", status: "completed"}} =
               Fleet.remove_module_intent(agent, "FLEET-SHIP", "MODULE_CARGO_HOLD_I", %{
                 "MODULE_CARGO_HOLD_I" => 1
               })
    end

    test "reconciles an ambiguous module installation before accepting another mutation" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "install_module",
        target_waypoint: "MODULE_CARGO_HOLD_I",
        parameters: %{
          "caller" => "manual",
          "module_symbol" => "MODULE_CARGO_HOLD_I",
          "quantity" => 1,
          "authorized_removals" => %{}
        },
        status: "blocked",
        in_flight_action: %{
          "kind" => "install_module",
          "module_symbol" => "MODULE_CARGO_HOLD_I",
          "quantity" => 1,
          "installed_before" => 0,
          "cargo_before" => 1
        }
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "cargo" => %{
                "capacity" => 40,
                "units" => 1,
                "inventory" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "units" => 1}]
              }
            })
        })
      end)

      assert {:error, :manual_intent_reconciliation_required} =
               Fleet.install_module_intent(agent, "FLEET-SHIP", "MODULE_CARGO_HOLD_I")

      assert %ManualIntent{status: "blocked", in_flight_action: action} =
               Fleet.ship_manual_intent(agent, "FLEET-SHIP")

      assert action["kind"] == "install_module"
    end

    test "returns a confirmed ambiguous installation without posting it again" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "install_module",
        target_waypoint: "MODULE_CARGO_HOLD_I",
        parameters: %{
          "caller" => "manual",
          "module_symbol" => "MODULE_CARGO_HOLD_I",
          "quantity" => 1,
          "authorized_removals" => %{}
        },
        status: "blocked",
        in_flight_action: %{
          "kind" => "install_module",
          "module_symbol" => "MODULE_CARGO_HOLD_I",
          "quantity" => 1,
          "installed_before" => 0,
          "cargo_before" => 1
        }
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
            })
        })
      end)

      assert {:ok, %ManualIntent{status: "completed", last_action_result: result}} =
               Fleet.install_module_intent(agent, "FLEET-SHIP", "MODULE_CARGO_HOLD_I")

      assert result["modules"] == [
               %{
                 "symbol" => "MODULE_CARGO_HOLD_I",
                 "name" => "Cargo Hold I",
                 "capacity" => nil,
                 "range" => nil
               }
             ]
    end

    test "does not replace unresolved module evidence with navigation" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "install_module",
        target_waypoint: "MODULE_CARGO_HOLD_I",
        parameters: %{"module_symbol" => "MODULE_CARGO_HOLD_I", "quantity" => 1},
        status: "blocked",
        in_flight_action: %{
          "kind" => "install_module",
          "module_symbol" => "MODULE_CARGO_HOLD_I",
          "quantity" => 1,
          "installed_before" => 0,
          "cargo_before" => 1
        }
      })

      assert {:error, :manual_intent_reconciliation_required} =
               Fleet.navigate_intent(agent, "FLEET-SHIP", "X1-UX81-A2")
    end

    test "does not stop and discard unresolved module evidence" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      intent =
        Repo.insert!(%ManualIntent{
          ship_id: ship.id,
          type: "remove_module",
          target_waypoint: "MODULE_CARGO_HOLD_I",
          parameters: %{"module_symbol" => "MODULE_CARGO_HOLD_I", "quantity" => 1},
          status: "blocked",
          in_flight_action: %{"kind" => "remove_module", "module_symbol" => "MODULE_CARGO_HOLD_I"}
        })

      assert {:error, :manual_intent_reconciliation_required} =
               Fleet.stop_manual_intent(agent, "FLEET-SHIP")

      assert Repo.get!(ManualIntent, intent.id).in_flight_action["kind"] == "remove_module"
    end

    test "Buy Goods Intent pauses the active Job and buys from a fresh on-site Listing" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, job} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(job, status: "active"))
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 10,
                    "sellPrice" => 8,
                    "tradeVolume" => 10
                  }
                ]
              }
            })

          {"/v2/my/ships/FLEET-SHIP/purchase", "POST"} ->
            send(test_pid, {:job_status_at_purchase, Repo.get!(Job, job.id).status})
            assert conn.body_params == %{"symbol" => "IRON_ORE", "units" => 5}

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 50},
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                },
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "IRON_ORE",
                  "type" => "PURCHASE",
                  "units" => 5,
                  "pricePerUnit" => 10,
                  "totalPrice" => 50,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{type: "buy", status: "completed"} = intent} =
               Fleet.buy_goods_intent(agent, "FLEET-SHIP", "X1-UX81-A1", "IRON_ORE", 5,
                 max_price: 10
               )

      assert_receive {:job_status_at_purchase, "paused"}

      assert %{
               "kind" => "buy",
               "units" => 5,
               "price" => 10,
               "transaction" => %{"type" => "PURCHASE", "units" => 5}
             } = intent.last_action_result

      assert Fleet.ship_job(agent, "FLEET-SHIP").status == "paused"
    end

    test "Buy Goods Intent rejects an unverified Job caller" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:error, :invalid_cargo_intent_owner} =
               Fleet.buy_goods_intent(agent, "FLEET-SHIP", "X1-UX81-A1", "IRON_ORE", 1,
                 caller: "job",
                 job_id: -1
               )
    end

    test "Buy Goods Intent permits a zero-price listing within cargo capacity" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 0}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 0,
                    "sellPrice" => 0,
                    "tradeVolume" => 10
                  }
                ]
              }
            })

          {"/v2/my/ships/FLEET-SHIP/purchase", "POST"} ->
            assert conn.body_params == %{"symbol" => "IRON_ORE", "units" => 5}

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 0},
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                },
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "IRON_ORE",
                  "type" => "PURCHASE",
                  "units" => 5,
                  "pricePerUnit" => 0,
                  "totalPrice" => 0,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{status: "completed", last_action_result: result}} =
               Fleet.buy_goods_intent(agent, "FLEET-SHIP", "X1-UX81-A1", "IRON_ORE", 5)

      assert %{"kind" => "buy", "units" => 5, "price" => 0} = result
    end

    test "manual Buy preserves a preempted Job's in-flight recovery evidence" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      {:ok, job} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      evidence = %{"kind" => "extract", "expected" => %{"cargo_units_at_least" => 1}}
      Repo.update!(Ecto.Changeset.change(job, status: "active", in_flight_action: evidence))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})
        end
      end)

      assert {:ok, %ManualIntent{status: "blocked"}} =
               Fleet.buy_goods_intent(agent, ship.symbol, "X1-UX81-A1", "IRON_ORE", 1)

      assert Fleet.ship_job(agent, ship.symbol).in_flight_action == evidence
    end

    test "Sell Goods Intent records an observed demand blocker without posting a sale" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                  }
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 10,
                    "sellPrice" => 8,
                    "tradeVolume" => 0
                  }
                ]
              }
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %ManualIntent{type: "sell", status: "blocked", blocker: blocker}} =
               Fleet.sell_goods_intent(agent, "FLEET-SHIP", "X1-UX81-A1", "IRON_ORE", 5,
                 min_price: 8
               )

      assert blocker.reason == "market_demand_unavailable"
      assert blocker.evidence =~ "IRON_ORE"
    end

    test "Deliver Goods Intent confirms accepted quantity from the refreshed Contract" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                  }
                })
            })

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => [active_contract_body("CONTRACT-1")]})

          {"/v2/my/contracts/CONTRACT-1/deliver", "POST"} ->
            assert conn.body_params == %{
                     "shipSymbol" => "FLEET-SHIP",
                     "tradeSymbol" => "IRON_ORE",
                     "units" => 5
                   }

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "contract" =>
                  active_contract_body("CONTRACT-1", [
                    contract_delivery_entry(%{"unitsFulfilled" => 5})
                  ])
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{type: "deliver", status: "completed"} = intent} =
               Fleet.deliver_goods_intent(
                 agent,
                 "FLEET-SHIP",
                 "X1-UX81-A1",
                 "CONTRACT-1",
                 "IRON_ORE",
                 5
               )

      assert %{
               "kind" => "deliver",
               "units" => 5,
               "recipient" => %{"units_fulfilled" => 5}
             } = intent.last_action_result
    end

    test "Deliver Goods Intent supplies Construction from fresh project evidence" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                  }
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "isComplete" => false,
                "materials" => [
                  %{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 7}
                ]
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply", "POST"} ->
            assert conn.body_params == %{
                     "shipSymbol" => "FLEET-SHIP",
                     "tradeSymbol" => "IRON_ORE",
                     "units" => 5
                   }

            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "construction" => %{
                  "symbol" => "X1-UX81-A1",
                  "isComplete" => false,
                  "materials" => [
                    %{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 12}
                  ]
                }
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{type: "deliver", status: "completed"} = intent} =
               Fleet.deliver_construction_goods_intent(
                 agent,
                 "FLEET-SHIP",
                 "X1-UX81",
                 "X1-UX81-A1",
                 "IRON_ORE",
                 5
               )

      assert %{
               "kind" => "deliver",
               "units" => 5,
               "recipient" => %{"units_fulfilled" => 12}
             } = intent.last_action_result
    end

    test "restart recovery confirms an in-flight delivery from Contract and Cargo evidence" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%ManualIntent{
        ship_id: ship.id,
        type: "deliver",
        target_waypoint: "X1-UX81-A1",
        parameters: %{
          "caller" => "manual",
          "contract_id" => "CONTRACT-1",
          "trade_symbol" => "IRON_ORE",
          "units" => 5
        },
        status: "blocked",
        in_flight_action: %{
          "kind" => "deliver",
          "trade_symbol" => "IRON_ORE",
          "units" => 5,
          "recipient" => "CONTRACT-1",
          "fulfilled_before" => 0,
          "cargo_before" => 5
        }
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 2,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 2}]
                  }
                })
            })

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                active_contract_body("CONTRACT-1", [
                  contract_delivery_entry(%{"unitsFulfilled" => 3})
                ])
              ]
            })
        end
      end)

      assert {:ok, %ManualIntent{status: "completed", last_action_result: result}} =
               Fleet.recover_manual_intent_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      assert %{"kind" => "deliver", "units" => 3} = result
    end

    test "restart recovery does not infer a completed sale from a cargo delta" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      intent =
        Repo.insert!(%ManualIntent{
          ship_id: ship.id,
          type: "sell",
          target_waypoint: "X1-UX81-A1",
          parameters: %{"trade_symbol" => "IRON_ORE", "units" => 5, "min_price" => 8},
          status: "active",
          in_flight_action: %{
            "kind" => "sell",
            "trade_symbol" => "IRON_ORE",
            "units" => 5,
            "listing_price" => 8
          }
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
            })
        })
      end)

      assert {:ok, %ManualIntent{status: "blocked", blocker: blocker}} =
               Fleet.recover_manual_intent_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      assert blocker.reason == "ambiguous_operation_evidence"
      assert Repo.get!(ManualIntent, intent.id).last_action_result["error"] =~ "ambiguous"
    end

    test "preserves an ambiguous sale request as in-flight evidence" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                  }
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 10,
                    "sellPrice" => 8,
                    "tradeVolume" => 5
                  }
                ]
              }
            })

          {"/v2/my/ships/FLEET-SHIP/sell", "POST"} ->
            conn |> Map.put(:status, 500) |> Req.Test.json(%{})
        end
      end)

      assert {:ok, %ManualIntent{status: "blocked", in_flight_action: action}} =
               Fleet.sell_goods_intent(agent, "FLEET-SHIP", "X1-UX81-A1", "IRON_ORE", 5,
                 min_price: 8
               )

      assert action == %{
               "kind" => "sell",
               "trade_symbol" => "IRON_ORE",
               "units" => 5,
               "listing_price" => 8
             }

      assert {:error, :cargo_operation_reconciliation_required} =
               Fleet.stop_manual_intent(agent, "FLEET-SHIP")
    end

    test "preserves an in-flight sale when the successful response transaction is uncorrelated" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 5,
                    "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                  }
                })
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 10,
                    "sellPrice" => 8,
                    "tradeVolume" => 5
                  }
                ]
              }
            })

          {"/v2/my/ships/FLEET-SHIP/sell", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 100},
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "transaction" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "tradeSymbol" => "COPPER_ORE",
                  "type" => "SELL",
                  "units" => 5,
                  "pricePerUnit" => 8,
                  "totalPrice" => 40,
                  "waypointSymbol" => "X1-UX81-A1",
                  "timestamp" => "2026-01-01T00:00:00.000Z"
                }
              }
            })
        end
      end)

      assert {:ok, %ManualIntent{status: "blocked", in_flight_action: action}} =
               Fleet.sell_goods_intent(agent, "FLEET-SHIP", "X1-UX81-A1", "IRON_ORE", 5,
                 min_price: 8
               )

      assert action["kind"] == "sell"
    end

    test "refuels a ship through the game API" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/refuel"

        Req.Test.json(conn, %{
          "data" => %{
            "agent" => %{"symbol" => agent.symbol, "credits" => 41_800},
            "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
            "fuel" => %{
              "capacity" => 200,
              "current" => 200,
              "consumed" => %{"amount" => 100, "timestamp" => "2026-01-01T00:00:00.000Z"}
            },
            "transaction" => %{
              "waypointSymbol" => "X1-UX81-A1",
              "shipSymbol" => "FLEET-SHIP",
              "tradeSymbol" => "FUEL",
              "type" => "PURCHASE",
              "totalPrice" => 200,
              "units" => 100,
              "pricePerUnit" => 2,
              "timestamp" => "2026-01-01T00:00:00.000Z"
            }
          }
        })
      end)

      assert {:ok, %{fuel: %{current: 200}}} = Fleet.refuel_ship(agent, "FLEET-SHIP")
    end

    test "jettisons cargo through the game API" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/jettison"
        assert conn.body_params == %{"symbol" => "COPPER_ORE", "units" => 5}

        Req.Test.json(conn, %{
          "data" => %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
        })
      end)

      assert {:ok, %{cargo: %{units: 0}}} =
               Fleet.jettison_cargo(agent, "FLEET-SHIP", "COPPER_ORE", 5)

      assert {:error, :invalid_units} =
               Fleet.jettison_cargo(agent, "FLEET-SHIP", "COPPER_ORE", 0)
    end

    test "docks and orbits a ship" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP/dock" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("DOCKED")}})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
        end
      end)

      assert {:ok, %{nav: %{status: "DOCKED"}}} = Fleet.dock_ship(agent, "FLEET-SHIP")
      assert {:ok, %{nav: %{status: "IN_ORBIT"}}} = Fleet.orbit_ship(agent, "FLEET-SHIP")
    end

    test "sets a ship flight mode through the game API" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/nav"
        assert conn.body_params == %{"flightMode" => "DRIFT"}

        Req.Test.json(conn, %{
          "data" => %{
            "fuel" => %{"capacity" => 200, "current" => 81},
            "nav" => nav_body("IN_ORBIT") |> Map.put("flightMode", "DRIFT"),
            "events" => []
          }
        })
      end)

      assert {:ok, %{fuel: %{current: 81}, nav: %{flight_mode: "DRIFT"}}} =
               Fleet.set_ship_flight_mode(agent, "FLEET-SHIP", "DRIFT")

      assert {:error, :invalid_flight_mode} =
               Fleet.set_ship_flight_mode(agent, "FLEET-SHIP", "IMPOSSIBLE")
    end

    test "extracts resources and persists the cooldown" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      expiration = future_iso(60)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/extract"

        Req.Test.json(conn, %{
          "data" => %{
            "cooldown" => %{
              "shipSymbol" => "FLEET-SHIP",
              "totalSeconds" => 60,
              "remainingSeconds" => 60,
              "expiration" => expiration
            },
            "extraction" => %{
              "shipSymbol" => "FLEET-SHIP",
              "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
            },
            "cargo" => %{
              "capacity" => 40,
              "units" => 17,
              "inventory" => [%{"symbol" => "IRON_ORE", "units" => 17}]
            }
          }
        })
      end)

      assert {:ok, %{cargo: %{units: 17}}} = Fleet.extract_resources(agent, "FLEET-SHIP")

      assert [%Event{event_type: "cooldown", payload: %{}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")

      assert ShipServer.ensure_ready("FLEET-SHIP") == {:error, :cooldown_active}
    end

    test "siphons resources and persists the cooldown" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      expiration = future_iso(60)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_GAS_PROCESSOR_I"}],
                  "mounts" => [%{"symbol" => "MOUNT_GAS_SIPHON_I"}]
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "GAS_GIANT",
                "x" => 1,
                "y" => 2
              }
            })

          "/v2/my/ships/FLEET-SHIP/siphon" ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => expiration
                },
                "siphon" => %{
                  "shipSymbol" => "FLEET-SHIP",
                  "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 17,
                  "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 17}]
                },
                "events" => []
              }
            })
        end
      end)

      assert {:ok, %{cargo: %{units: 17}, siphon: %{yield: %{units: 5}}}} =
               Fleet.siphon_resources(agent, "FLEET-SHIP")

      assert [%Event{event_type: "cooldown", payload: %{}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "rejects siphoning away from a gas giant before posting the action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT")
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "PLANET",
                "x" => 1,
                "y" => 2
              }
            })

          path ->
            flunk("unexpected siphon request: #{path}")
        end
      end)

      assert {:error, :invalid_siphon_waypoint} = Fleet.siphon_resources(agent, "FLEET-SHIP")
    end

    test "rejects siphoning without the required equipment before posting the action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT")
                })
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "GAS_GIANT",
                "x" => 1,
                "y" => 2
              }
            })

          path ->
            flunk("unexpected siphon request: #{path}")
        end
      end)

      assert {:error, :siphon_capability_missing} = Fleet.siphon_resources(agent, "FLEET-SHIP")
    end

    test "refuses actions while a cooldown is pending" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, _event} =
        Timeline.schedule_event(
          :ship,
          "FLEET-SHIP",
          :cooldown,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      {:ok, _pid} = ShipServer.ensure_started(agent, "FLEET-SHIP")

      assert {:error, :cooldown_active} = Fleet.dock_ship(agent, "FLEET-SHIP")
      assert {:error, :cooldown_active} = Fleet.orbit_ship(agent, "FLEET-SHIP")
      assert {:error, :cooldown_active} = Fleet.extract_resources(agent, "FLEET-SHIP")
      assert {:error, :cooldown_active} = Fleet.siphon_resources(agent, "FLEET-SHIP")
    end
  end

  describe "list_waypoints/1" do
    test "collects every page of the agent's headquarters system" do
      agent = agent_fixture()

      waypoint = %{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "ORBITAL_STATION",
        "traits" => [%{"symbol" => "SHIPYARD"}]
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/systems/X1-UX81/waypoints"

        case conn.query_params["page"] do
          "1" -> Req.Test.json(conn, %{"data" => List.duplicate(waypoint, 20)})
          "2" -> Req.Test.json(conn, %{"data" => [waypoint]})
          _ -> Req.Test.json(conn, %{"data" => []})
        end
      end)

      assert {:ok, waypoints} = Fleet.list_waypoints(agent)
      assert length(waypoints) == 21
    end

    test "returns a page failure instead of partial headquarters data" do
      agent = agent_fixture()

      waypoint = %{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "ORBITAL_STATION",
        "traits" => []
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.query_params["page"] do
          "1" ->
            Req.Test.json(conn, %{"data" => List.duplicate(waypoint, 20)})

          "2" ->
            conn
            |> Map.put(:status, 503)
            |> Req.Test.json(%{"error" => %{"message" => "unavailable"}})
        end
      end)

      assert {:error, %SpaceTraders.API.Error{status: 503}} = Fleet.list_waypoints(agent)
    end

    test "returns a readable error for an agent without stored credentials" do
      assert {:error, :agent_token_missing} = Fleet.list_waypoints(agent_fixture(nil))
    end
  end

  describe "rearm_ships_on_boot/0" do
    test "starts ship servers for ships with pending events" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, _event} =
        Timeline.schedule_event(
          :ship,
          "FLEET-SHIP",
          :arrival,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      assert :ok = Fleet.rearm_ships_on_boot()

      assert ShipServer.ensure_ready("FLEET-SHIP") == {:error, :ship_in_transit}
    end

    test "catches up events that came due while the app was down" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, event} =
        Timeline.schedule_event(
          :ship,
          "FLEET-SHIP",
          :arrival,
          DateTime.add(DateTime.utc_now(), -60, :second)
        )

      agent_id = agent.id
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet:#{agent_id}")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})
      end)

      # The re-armed server is a separate process; allow it to use the stub once
      # it is running (resolved lazily at request time).
      Req.Test.allow(SpaceTraders.API, self(), fn ->
        case Registry.lookup(SpaceTraders.Fleet.ShipRegistry, "FLEET-SHIP") do
          [{pid, _}] -> pid
          [] -> self()
        end
      end)

      assert :ok = Fleet.rearm_ships_on_boot()

      assert_receive {:ship_updated, ^agent_id, "FLEET-SHIP"}, 1_000
      assert Repo.get(Event, event.id).status == "done"
      assert ShipServer.ensure_ready("FLEET-SHIP") == :ok
    end

    test "skips ships without stored credentials" do
      {:ok, _event} =
        Timeline.schedule_event(
          :ship,
          "GHOST-SHIP",
          :arrival,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      assert :ok = Fleet.rearm_ships_on_boot()

      assert ShipServer.ensure_ready("GHOST-SHIP") == :ok
    end
  end

  describe "stale Agent execution" do
    test "stops manual commands immediately after a reset mismatch" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{
          "error" => %{
            "code" => 4113,
            "message" =>
              "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-08-16, Actual: 2026-08-09"
          }
        })
      end)

      assert {:error, :stale_agent} = Fleet.dock_ship(agent, "FLEET-SHIP")
      assert %{stale_at: %DateTime{}} = Repo.get!(AgentRecord, agent.id)

      Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("stale Agent made a game request") end)

      assert {:error, :stale_agent} = Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A2")
    end
  end
end
