defmodule SpaceTraders.FleetTest do
  # navigate_ship and boot re-arm start ship GenServers, which read and write the
  # timeline as separate processes, so the sandbox must be shared (not async).
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.AutopilotConfig
  alias SpaceTraders.Fleet.ShipServer
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
      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

    Repo.update!(
      Ecto.Changeset.change(config,
        desired_mode: "autopilot",
        status: "revalidating",
        in_flight_action: action
      )
    )

    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:api_request, conn.request_path})

      case conn.request_path do
        "/v2/my/ships/FLEET-SHIP" ->
          Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP", ship_overrides)})

        "/v2/my/ships/FLEET-SHIP/orbit" ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        "/v2/my/ships/FLEET-SHIP/navigate" ->
          Req.Test.json(conn, %{"data" => navigate_response("IN_TRANSIT")})
      end
    end)

    assert {:ok, _} = Fleet.recover_autopilot_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

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

  describe "autopilot configuration" do
    test "pauses and resumes without losing the configured loop" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, _} =
               Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert {:ok, %{status: "paused", desired_mode: "manual"}} =
               Fleet.pause_autopilot(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{"error" => %{"code" => 4011, "message" => "Invalid token"}})
      end)

      assert {:error, {:autopilot_blocked, _reason}} = Fleet.resume_autopilot(agent, "FLEET-SHIP")
      assert Fleet.autopilot_config(agent, "FLEET-SHIP").extraction_waypoint == "X1-UX81-A2"
    end

    test "stops and clears the saved loop" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      assert :ok = Fleet.stop_autopilot(agent, "FLEET-SHIP")
      assert Fleet.autopilot_config(agent, "FLEET-SHIP") == nil
      assert [%{kind: "stop"} | _] = Fleet.recent_activity(agent)
    end

    test "manual navigation pauses active Autopilot before dispatch" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      config = Fleet.autopilot_config(agent, "FLEET-SHIP")
      Repo.update!(Ecto.Changeset.change(config, desired_mode: "autopilot", status: "waiting"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => navigate_response("DOCKED")})
      end)

      assert {:ok, _} = Fleet.navigate_ship(agent, "FLEET-SHIP", "X1-UX81-A1")

      assert %{
               desired_mode: "manual",
               status: "paused",
               blocked_reason: "Paused by direct navigation"
             } =
               Fleet.autopilot_config(agent, "FLEET-SHIP")

      assert [%{kind: "manual_override"} | _] = Fleet.recent_activity(agent)
    end

    test "persists a loop without starting it" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      assert {:ok, %AutopilotConfig{} = config} =
               Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
                 extraction_waypoint: "X1-UX81-A2",
                 market_waypoint: "X1-UX81-A1",
                 cargo_threshold: 30
               })

      assert config.desired_mode == "manual"
      assert config.status == "ready"
      assert Fleet.autopilot_config(agent, "FLEET-SHIP").cargo_threshold == 30
    end

    test "starts only after validating authoritative ship, waypoints and market" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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
              %AutopilotConfig{
                desired_mode: "autopilot",
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"},
                last_action_result: %{"status" => "IN_TRANSIT"},
                last_validated_at: %DateTime{}
              }} =
               Fleet.start_autopilot(agent, "FLEET-SHIP")

      assert [%Event{event_type: "arrival"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "arrival revalidation completes the attempt without replaying navigation" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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

      assert {:ok, %AutopilotConfig{status: "waiting"} = config} =
               Fleet.start_autopilot(agent, "FLEET-SHIP")

      arrived = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{status: "IN_ORBIT", waypoint_symbol: "X1-UX81-A2"},
        cargo: %Model.ShipCargo{capacity: 40, units: 30, inventory: []}
      }

      assert {:ok,
              %AutopilotConfig{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} =
               Fleet.revalidate_autopilot_arrival(agent.id, "FLEET-SHIP", arrived)

      assert {:ok, %AutopilotConfig{status: "waiting"}} =
               Fleet.advance_autopilot(agent, Repo.get!(AutopilotConfig, config.id), arrived)

      assert {:ok, %AutopilotConfig{status: "waiting"}} =
               Fleet.advance_autopilot(agent, Repo.get!(AutopilotConfig, config.id), arrived)
    end

    test "extracts once below the cargo threshold at the configured waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      expiration = future_iso(60)

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
              %AutopilotConfig{
                status: "waiting",
                in_flight_action: %{"kind" => "extract"},
                last_action_result: %{
                  "kind" => "extract",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                }
              }} = Fleet.start_autopilot(agent, "FLEET-SHIP")

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "navigates to the configured market when cargo reaches the threshold" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
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
              %AutopilotConfig{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"}
              }} =
               Fleet.advance_autopilot(agent, %{config | desired_mode: "autopilot"}, live_ship)

      assert [%Event{event_type: "arrival"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "sells accepted cargo, jettisons rejected cargo, and returns to extraction" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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
        | desired_mode: "autopilot",
          progress: %{"waypoint" => "X1-UX81-A1"}
      }

      assert {:ok, %AutopilotConfig{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_autopilot(agent, config, live_ship)
    end

    test "blocks at the configured market when it cannot refill the Ship" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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

      config = %{config | desired_mode: "autopilot", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:error, {:market_fuel_unavailable, "X1-UX81-A1"}} =
               Fleet.advance_autopilot(agent, config, live_ship)

      assert %AutopilotConfig{status: "blocked", blocked_reason: reason} =
               Repo.get!(AutopilotConfig, config.id)

      assert reason =~ "market_fuel_unavailable"
    end

    test "blocks when configured market refueling remains below return-leg fuel" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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

      config = %{config | desired_mode: "autopilot", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:error, {:market_fuel_insufficient, "X1-UX81-A1", 198, 200}} =
               Fleet.advance_autopilot(agent, config, live_ship)
    end

    test "does not require market fuel when a Ship is already full" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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

      config = %{config | desired_mode: "autopilot", progress: %{"waypoint" => "X1-UX81-A1"}}

      assert {:ok, %AutopilotConfig{status: "waiting", in_flight_action: %{"kind" => "navigate"}}} =
               Fleet.advance_autopilot(agent, config, live_ship)
    end

    test "waits for an authoritative cooldown before extracting" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
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

      assert {:ok, %AutopilotConfig{status: "waiting", in_flight_action: %{"kind" => "cooldown"}}} =
               Fleet.advance_autopilot(agent, %{config | desired_mode: "autopilot"}, live_ship)

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "cooldown wakeup records extraction completion before another action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "autopilot",
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
              %AutopilotConfig{
                status: "waiting",
                in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A1"},
                progress: progress
              }} =
               Fleet.revalidate_autopilot_cooldown(
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
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "autopilot",
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
               current = Repo.get_by!(AutopilotConfig, ship_id: config.ship_id)

               current.status == "waiting" and
                 current.in_flight_action["kind"] == "extract"
             end)
    end

    test "blocks an invalid extraction waypoint without a game action" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
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

      assert {:error, {:autopilot_blocked, :invalid_extraction_waypoint}} =
               Fleet.start_autopilot(agent, "FLEET-SHIP")

      assert Fleet.autopilot_config(agent, "FLEET-SHIP").status == "blocked"
    end

    test "boot recovery confirms an in-flight navigation without replaying it" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "autopilot",
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

      assert {:ok, _} = Fleet.recover_autopilot_on_boot("FLEET-SHIP", agent.id, agent.agent_token)
      recovered = Fleet.autopilot_config(agent, "FLEET-SHIP")
      assert recovered.last_action_result == %{"kind" => "recovery", "outcome" => "confirmed"}
      assert recovered.recovery_attempts == 0

      assert [%{kind: "autopilot_recovery", metadata: %{"outcome" => "confirmed"}} | _] =
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
        Fleet.configure_autopilot(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(
        Ecto.Changeset.change(config,
          desired_mode: "autopilot",
          status: "revalidating",
          in_flight_action: %{"kind" => "unknown_action"}
        )
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP"
        Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})
      end)

      assert {:error, :autopilot_recovery_blocked} =
               Fleet.recover_autopilot_on_boot("FLEET-SHIP", agent.id, agent.agent_token)

      recovered = Fleet.autopilot_config(agent, "FLEET-SHIP")
      assert recovered.status == "blocked"
      assert recovered.last_action_result["outcome"] == "ambiguous"

      assert [%{kind: "autopilot_recovery", metadata: %{"outcome" => "ambiguous"}} | _] =
               Fleet.recent_activity(agent)
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
      assert actions.navigate == %{allowed?: false, reason: :cooldown_active}
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

  describe "ship actions" do
    test "sells cargo through the game API" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/sell"
        assert conn.body_params == %{"symbol" => "IRON_ORE", "units" => 5}

        Req.Test.json(conn, %{
          "data" => %{
            "agent" => %{"symbol" => agent.symbol, "credits" => 42_400},
            "cargo" => %{"capacity" => 40, "units" => 7, "inventory" => []},
            "transaction" => %{
              "shipSymbol" => "FLEET-SHIP",
              "tradeSymbol" => "IRON_ORE",
              "type" => "SELL",
              "units" => 5,
              "pricePerUnit" => 80,
              "totalPrice" => 400,
              "waypointSymbol" => "X1-UX81-A1",
              "timestamp" => "2026-01-01T00:00:00.000Z"
            }
          }
        })
      end)

      assert {:ok, %{cargo: %{units: 7}, transaction: %{total_price: 400}}} =
               Fleet.sell_cargo(agent, "FLEET-SHIP", "IRON_ORE", 5)
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

    test "purchases cargo through the game API" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP/purchase"
        assert conn.body_params == %{"symbol" => "SHIP_PLATING", "units" => 5}

        Req.Test.json(conn, %{
          "data" => %{
            "agent" => %{"symbol" => agent.symbol, "credits" => 121_819},
            "cargo" => %{
              "capacity" => 40,
              "units" => 5,
              "inventory" => [%{"symbol" => "SHIP_PLATING", "units" => 5}]
            },
            "transaction" => %{
              "shipSymbol" => "FLEET-SHIP",
              "tradeSymbol" => "SHIP_PLATING",
              "type" => "PURCHASE",
              "units" => 5,
              "pricePerUnit" => 14_384,
              "totalPrice" => 71_920,
              "waypointSymbol" => "X1-UX81-C42",
              "timestamp" => "2026-01-01T00:00:00.000Z"
            }
          }
        })
      end)

      assert {:ok, %{cargo: %{units: 5}, transaction: %{total_price: 71_920}}} =
               Fleet.purchase_cargo(agent, "FLEET-SHIP", "SHIP_PLATING", 5)

      assert {:error, :invalid_units} =
               Fleet.purchase_cargo(agent, "FLEET-SHIP", "SHIP_PLATING", 0)
    end

    test "docks and orbits a ship" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP/dock" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("DOCKED")}})

          "/v2/my/ships/FLEET-SHIP/orbit" ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
        end
      end)

      assert {:ok, %{nav: %{status: "DOCKED"}}} = Fleet.dock_ship(agent, "FLEET-SHIP")
      assert {:ok, %{nav: %{status: "IN_ORBIT"}}} = Fleet.orbit_ship(agent, "FLEET-SHIP")
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
end
