defmodule SpaceTraders.API.ClientTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API
  alias SpaceTraders.API.Model

  import Plug.Conn, only: [get_req_header: 2]

  describe "get_status/0" do
    test "returns raw server status from the flat root payload" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/"

        Req.Test.json(conn, %{
          "status" => "SpaceTraders is currently online and available to play",
          "version" => "v2.3.0",
          "resetDate" => "2026-08-02"
        })
      end)

      assert {:ok,
              %{
                "status" => "SpaceTraders is currently online and available to play",
                "version" => "v2.3.0",
                "resetDate" => "2026-08-02"
              }} = API.get_status()
    end

    test "emits an API request metric with endpoint and response status" do
      event = [:spacetraders, :api, :request]
      handler_id = "api-metric-#{System.unique_integer()}"
      :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, self())

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => %{}})
      end)

      assert {:ok, %Model.Agent{}} = API.get_agent("TOKEN")
      assert_receive {:telemetry, ^event, %{count: 1}, %{endpoint: "/my/agent", status: 200}}
    end

    test "emits a 429 API request metric after rate-limit retries" do
      event = [:spacetraders, :api, :request]
      handler_id = "api-rate-limit-metric-#{System.unique_integer()}"
      :telemetry.attach(handler_id, event, &__MODULE__.handle_event/4, self())

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(
          429,
          Jason.encode!(%{"error" => %{"code" => 1000, "message" => "slow down"}})
        )
      end)

      assert {:error, %SpaceTraders.API.GameplayError{code: 1000}} = API.get_agent("TOKEN")

      assert_receive {:telemetry, ^event, %{count: 1}, %{endpoint: "/my/agent", status: 429}},
                     5_000
    end
  end

  def handle_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  describe "register/3" do
    test "posts to /register with account token and decodes the full mint result" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/register"
        assert get_req_header(conn, "authorization") == ["Bearer ACCOUNT_TOKEN"]

        assert conn.body_params == %{
                 "symbol" => "ORBITALIST",
                 "faction" => "COSMIC",
                 "email" => "operator@example.com"
               }

        Req.Test.json(conn, %{
          "data" => %{
            "token" => "AGENT_TOKEN",
            "agent" => %{"symbol" => "ORBITALIST", "credits" => 175_000},
            "contract" => %{
              "id" => "c1",
              "type" => "PROCUREMENT",
              "accepted" => false,
              "fulfilled" => false
            },
            "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
            "ships" => [%{"symbol" => "ORBITALIST-1", "registration" => %{"role" => "COMMAND"}}]
          }
        })
      end)

      assert {:ok,
              %{
                token: "AGENT_TOKEN",
                agent: %Model.Agent{symbol: "ORBITALIST"},
                contract: %Model.Contract{type: "PROCUREMENT"},
                faction: %Model.Faction{symbol: "COSMIC"},
                ships: [%Model.Ship{symbol: "ORBITALIST-1"}]
              }} = API.register("ACCOUNT_TOKEN", "ORBITALIST", "COSMIC", "operator@example.com")
    end
  end

  describe "agent and contracts" do
    test "get_agent/1 decodes into an Agent struct" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert get_req_header(conn, "authorization") == ["Bearer TOKEN"]
        Req.Test.json(conn, %{"data" => %{"symbol" => "ORBITALIST", "credits" => 42}})
      end)

      assert {:ok, %Model.Agent{symbol: "ORBITALIST", credits: 42}} = API.get_agent("TOKEN")
    end

    test "get_contracts/1 decodes a list of contracts" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"id" => "c1", "type" => "PROCUREMENT", "accepted" => true, "fulfilled" => false},
            %{"id" => "c2", "type" => "TRANSPORT", "accepted" => false, "fulfilled" => false}
          ]
        })
      end)

      assert {:ok, [%Model.Contract{id: "c1"}, %Model.Contract{id: "c2"}]} =
               API.get_contracts("TOKEN")
    end
  end

  describe "ship actions" do
    test "scan_waypoints/2 posts a scan and decodes the discovered waypoints" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/scan/waypoints"

        Req.Test.json(conn, %{
          "data" => %{
            "cooldown" => %{"shipSymbol" => "ORBITALIST-1", "remainingSeconds" => 30},
            "waypoints" => [
              %{
                "symbol" => "X1-UX81-A2",
                "systemSymbol" => "X1-UX81",
                "type" => "PLANET",
                "x" => 2,
                "y" => 3
              }
            ]
          }
        })
      end)

      assert {:ok,
              %{
                cooldown: %Model.Cooldown{remaining_seconds: 30},
                waypoints: [%{symbol: "X1-UX81-A2"}]
              }} =
               API.scan_waypoints("TOKEN", "ORBITALIST-1")
    end

    test "create_chart/2 posts a chart and decodes the waypoint" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/chart"

        Req.Test.json(conn, %{
          "data" => %{
            "chart" => %{"waypointSymbol" => "X1-UX81-A1", "submittedBy" => "ORBITALIST"},
            "waypoint" => %{
              "symbol" => "X1-UX81-A1",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET"
            },
            "agent" => %{"symbol" => "ORBITALIST", "credits" => 1}
          }
        })
      end)

      assert {:ok, %{waypoint: %Model.Waypoint{symbol: "X1-UX81-A1"}}} =
               API.create_chart("TOKEN", "ORBITALIST-1")
    end

    test "navigate_ship/3 posts the waypoint and decodes fuel + nav" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/navigate"
        assert conn.body_params == %{"waypointSymbol" => "X1-UX81-A3"}

        Req.Test.json(conn, %{
          "data" => %{
            "fuel" => %{
              "capacity" => 200,
              "current" => 150,
              "consumed" => %{"amount" => 50, "timestamp" => "2026-01-01T00:00:00.000Z"}
            },
            "nav" => %{
              "systemSymbol" => "X1-UX81",
              "waypointSymbol" => "X1-UX81-A3",
              "status" => "IN_TRANSIT",
              "flightMode" => "CRUISE",
              "route" => %{
                "destination" => %{
                  "symbol" => "X1-UX81-A3",
                  "type" => "ENGINEERED_ASTEROID",
                  "systemSymbol" => "X1-UX81",
                  "x" => 1,
                  "y" => 2
                },
                "origin" => %{
                  "symbol" => "X1-UX81-A1",
                  "type" => "PLANET",
                  "systemSymbol" => "X1-UX81",
                  "x" => 1,
                  "y" => 2
                },
                "departureTime" => "2026-01-01T00:00:00.000Z",
                "arrival" => "2026-01-01T01:00:00.000Z"
              }
            }
          }
        })
      end)

      assert {:ok,
              %{fuel: %Model.ShipFuel{current: 150}, nav: %Model.ShipNav{status: "IN_TRANSIT"}}} =
               API.navigate_ship("TOKEN", "ORBITALIST-1", "X1-UX81-A3")
    end

    test "jump_ship/3 posts the connected waypoint and decodes execution evidence" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/jump"
        assert conn.body_params == %{"waypointSymbol" => "X2-UX81-A1"}

        Req.Test.json(conn, %{
          "data" => %{
            "nav" => %{
              "systemSymbol" => "X2-UX81",
              "waypointSymbol" => "X2-UX81-A1",
              "status" => "IN_ORBIT",
              "flightMode" => "CRUISE"
            },
            "cooldown" => %{"shipSymbol" => "ORBITALIST-1", "remainingSeconds" => 60},
            "transaction" => %{"waypointSymbol" => "X1-UX81-A1", "pricePerUnit" => 1_000},
            "agent" => %{"symbol" => "ORBITALIST", "credits" => 41_000}
          }
        })
      end)

      assert {:ok,
              %{
                nav: %Model.ShipNav{waypoint_symbol: "X2-UX81-A1", status: "IN_ORBIT"},
                cooldown: %Model.Cooldown{remaining_seconds: 60},
                transaction: %Model.MarketTransaction{price_per_unit: 1_000},
                agent: %Model.Agent{credits: 41_000}
              }} = API.jump_ship("TOKEN", "ORBITALIST-1", "X2-UX81-A1")
    end

    test "set_ship_flight_mode/3 patches the flight mode and decodes fuel + nav" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/nav"
        assert conn.body_params == %{"flightMode" => "DRIFT"}

        Req.Test.json(conn, %{
          "data" => %{
            "fuel" => %{"capacity" => 200, "current" => 81},
            "nav" => %{
              "systemSymbol" => "X1-UX81",
              "waypointSymbol" => "X1-UX81-A1",
              "status" => "IN_ORBIT",
              "flightMode" => "DRIFT"
            },
            "events" => []
          }
        })
      end)

      assert {:ok,
              %{fuel: %Model.ShipFuel{current: 81}, nav: %Model.ShipNav{flight_mode: "DRIFT"}}} =
               API.set_ship_flight_mode("TOKEN", "ORBITALIST-1", "DRIFT")
    end

    test "extract_resources/2 decodes cooldown + extraction + cargo" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "cooldown" => %{
              "shipSymbol" => "ORBITALIST-2",
              "totalSeconds" => 60,
              "remainingSeconds" => 60,
              "expiration" => "2026-01-01T00:01:00.000Z"
            },
            "extraction" => %{
              "shipSymbol" => "ORBITALIST-2",
              "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
            },
            "cargo" => %{
              "capacity" => 40,
              "units" => 5,
              "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
            }
          }
        })
      end)

      assert {:ok,
              %{
                cooldown: %Model.Cooldown{remaining_seconds: 60},
                extraction: %Model.Extraction{yield: %Model.ExtractionYield{units: 5}},
                cargo: %Model.ShipCargo{units: 5}
              }} = API.extract_resources("TOKEN", "ORBITALIST-2")
    end

    test "siphon_resources/2 posts to siphon and decodes cooldown + siphon + cargo" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/my/ships/ORBITALIST-2/siphon"
        assert conn.body_params == %{}

        Req.Test.json(conn, %{
          "data" => %{
            "cooldown" => %{
              "shipSymbol" => "ORBITALIST-2",
              "totalSeconds" => 60,
              "remainingSeconds" => 60,
              "expiration" => "2026-01-01T00:01:00.000Z"
            },
            "siphon" => %{
              "shipSymbol" => "ORBITALIST-2",
              "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 7}
            },
            "cargo" => %{
              "capacity" => 40,
              "units" => 7,
              "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 7}]
            },
            "events" => [
              %{
                "component" => "ENGINE",
                "description" => "Engine wear",
                "name" => "Engine wear",
                "symbol" => "WEAR"
              }
            ]
          }
        })
      end)

      assert {:ok,
              %{
                cooldown: %Model.Cooldown{remaining_seconds: 60},
                siphon: %Model.Siphon{
                  yield: %Model.SiphonYield{symbol: "LIQUID_HYDROGEN", units: 7}
                },
                cargo: %Model.ShipCargo{units: 7},
                events: [%Model.ShipConditionEvent{component: "ENGINE", symbol: "WEAR"}]
              }} = API.siphon_resources("TOKEN", "ORBITALIST-2")
    end

    test "jettison_cargo/4 posts the good and units and decodes cargo" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/jettison"
        assert conn.body_params == %{"symbol" => "IRON_ORE", "units" => 3}

        Req.Test.json(conn, %{
          "data" => %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
        })
      end)

      assert {:ok, %{cargo: %Model.ShipCargo{units: 0}}} =
               API.jettison_cargo("TOKEN", "ORBITALIST-1", "IRON_ORE", 3)
    end

    test "install_ship_module/3 posts the module and decodes the modified readiness" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/modules/install"
        assert conn.body_params == %{"symbol" => "MODULE_CARGO_HOLD_I"}

        Req.Test.json(conn, %{
          "data" => %{
            "agent" => %{"symbol" => "ORBITALIST", "credits" => 42},
            "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
            "cargo" => %{"capacity" => 40, "units" => 12, "inventory" => []},
            "transaction" => %{
              "shipSymbol" => "ORBITALIST-1",
              "tradeSymbol" => "MODULE_CARGO_HOLD_I",
              "totalPrice" => 1_000,
              "waypointSymbol" => "X1-UX81-A1",
              "timestamp" => "2026-01-01T00:00:00.000Z"
            }
          }
        })
      end)

      assert {:ok,
              %{
                modules: [%Model.ShipModule{symbol: "MODULE_CARGO_HOLD_I"}],
                cargo: %Model.ShipCargo{units: 12},
                transaction: %Model.ShipModificationTransaction{total_price: 1_000}
              }} = API.install_ship_module("TOKEN", "ORBITALIST-1", "MODULE_CARGO_HOLD_I")
    end

    test "transfer_cargo/5 posts the good, units, and receiving ship" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/transfer"

        assert conn.body_params == %{
                 "tradeSymbol" => "IRON_ORE",
                 "units" => 3,
                 "shipSymbol" => "ORBITALIST-2"
               }

        Req.Test.json(conn, %{
          "data" => %{"cargo" => %{"capacity" => 40, "units" => 2, "inventory" => []}}
        })
      end)

      assert {:ok, %{cargo: %Model.ShipCargo{units: 2}}} =
               API.transfer_cargo("TOKEN", "ORBITALIST-1", "IRON_ORE", 3, "ORBITALIST-2")
    end

    test "purchase_cargo/4 posts the good and units and decodes the transaction" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/ORBITALIST-1/purchase"
        assert conn.body_params == %{"symbol" => "SHIP_PLATING", "units" => 5}

        Req.Test.json(conn, %{
          "data" => %{
            "agent" => %{"symbol" => "ORBITALIST", "credits" => 121_819},
            "cargo" => %{
              "capacity" => 40,
              "units" => 5,
              "inventory" => [%{"symbol" => "SHIP_PLATING", "units" => 5}]
            },
            "transaction" => %{
              "shipSymbol" => "ORBITALIST-1",
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

      assert {:ok,
              %{
                cargo: %Model.ShipCargo{units: 5},
                transaction: %Model.MarketTransaction{total_price: 71_920}
              }} =
               API.purchase_cargo("TOKEN", "ORBITALIST-1", "SHIP_PLATING", 5)
    end
  end

  describe "construction reads" do
    test "get_construction/3 reads authoritative construction state" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction"

        Req.Test.json(conn, %{
          "data" => %{
            "symbol" => "X1-UX81-A1",
            "isComplete" => false,
            "materials" => []
          }
        })
      end)

      assert {:ok, %{symbol: "X1-UX81-A1", is_complete: false}} =
               API.get_construction("TOKEN", "X1-UX81", "X1-UX81-A1")
    end

    test "get_jump_gate/3 reads connections independently of construction" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/jump-gate"

        Req.Test.json(conn, %{
          "data" => %{"symbol" => "X1-UX81-A1", "connections" => ["X1-TEST-A1"]}
        })
      end)

      assert {:ok, %{symbol: "X1-UX81-A1", connections: ["X1-TEST-A1"]}} =
               API.get_jump_gate("TOKEN", "X1-UX81", "X1-UX81-A1")
    end

    test "supply_construction/6 posts the supplying ship and decodes the fresh project state" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply"

        assert conn.body_params == %{
                 "shipSymbol" => "ORBITALIST-1",
                 "tradeSymbol" => "IRON_ORE",
                 "units" => 5
               }

        Req.Test.json(conn, %{
          "data" => %{
            "construction" => %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => false,
              "materials" => []
            },
            "cargo" => %{"capacity" => 40, "units" => 2, "inventory" => []}
          }
        })
      end)

      assert {:ok, %{construction: %{symbol: "X1-UX81-A1"}, cargo: %{units: 2}}} =
               API.supply_construction(
                 "TOKEN",
                 "X1-UX81",
                 "X1-UX81-A1",
                 "ORBITALIST-1",
                 "IRON_ORE",
                 5
               )
    end
  end

  describe "universe reads" do
    test "get_market/3 decodes a market struct" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

        Req.Test.json(conn, %{
          "data" => %{
            "symbol" => "X1-UX81-A1",
            "exports" => [],
            "imports" => [],
            "exchange" => []
          }
        })
      end)

      assert {:ok, %Model.Market{symbol: "X1-UX81-A1"}} =
               API.get_market("TOKEN", "X1-UX81", "X1-UX81-A1")
    end

    test "get_waypoints/3 forwards query params" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.query_params == %{"limit" => "50", "type" => "ENGINEERED_ASTEROID"}
        Req.Test.json(conn, %{"data" => []})
      end)

      assert {:ok, []} =
               API.get_waypoints("TOKEN", "X1-UX81",
                 type: "ENGINEERED_ASTEROID",
                 limit: 50
               )
    end
  end
end
