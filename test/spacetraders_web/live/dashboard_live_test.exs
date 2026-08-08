defmodule SpaceTradersWeb.DashboardLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Timeline
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Repo

  defp stub_live_game(agent_overview, ships) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" -> Req.Test.json(conn, %{"data" => agent_overview})
        "/v2/my/ships" -> Req.Test.json(conn, %{"data" => ships})
        "/v2/my/contracts" -> Req.Test.json(conn, %{"data" => []})
        "/v2/systems/X1-UX81/waypoints" -> Req.Test.json(conn, %{"data" => []})
      end
    end)
  end

  defp agent_overview_body(symbol) do
    %{
      "accountId" => "ACC",
      "symbol" => symbol,
      "headquarters" => "X1-UX81-A1",
      "credits" => 42_000,
      "startingFaction" => "COSMIC",
      "shipCount" => 2
    }
  end

  defp future_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp arrival_label_for(arrival) do
    {:ok, due_at, _offset} = DateTime.from_iso8601(arrival)
    "arrives #{Calendar.strftime(due_at, "%m-%d %H:%M")} UTC"
  end

  # Polls a LiveView render until the predicate holds (the view re-fetches after
  # a broadcast, which is asynchronous).
  defp eventually(render_fun, predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(render_fun, predicate, deadline)
  end

  defp do_eventually(render_fun, predicate, deadline) do
    cond do
      predicate.(render_fun.()) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition was not met within the deadline")

      true ->
        Process.sleep(20)
        do_eventually(render_fun, predicate, deadline)
    end
  end

  describe "anonymous visitors" do
    test "redirects to first-run setup when no operators exist" do
      conn = build_conn()

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/")
      assert path == ~p"/setup"
    end

    test "shows the landing page when operators exist but the visitor is signed out" do
      operator_fixture()

      {:ok, _lv, html} = live(build_conn(), ~p"/")

      assert html =~ "Log in"
      assert html =~ "Register"
      refute html =~ "Fleet command"
    end
  end

  describe "signed-in operator" do
    setup %{conn: conn} do
      on_exit(fn -> SpaceTraders.Fleet.ShipServer.stop_all() end)
      operator = operator_fixture()
      %{conn: log_in_operator(conn, operator), operator: operator}
    end

    test "shows the agent's live credits, HQ and faction", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Fleet command"
      assert html =~ agent.symbol
      assert html =~ "42,000"
      assert html =~ "X1-UX81-A1"
      assert html =~ "COSMIC"
    end

    test "shows an on-site market and selling cargo refreshes credits", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      {:ok, state} =
        Agent.start_link(fn -> %{credits: 42_000, cargo_units: 12, sale_attempts: 0} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{
              "data" =>
                Map.put(
                  agent_overview_body(agent.symbol),
                  "credits",
                  Agent.get(state, & &1.credits)
                )
            })

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-1", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => Agent.get(state, & &1.cargo_units),
                    "inventory" => [
                      %{
                        "symbol" => "IRON_ORE",
                        "name" => "Iron Ore",
                        "units" => Agent.get(state, & &1.cargo_units)
                      }
                    ]
                  }
                })
              ]
            })

          "/v2/systems/X1-UX81/waypoints" ->
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

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "type" => "EXPORT",
                    "sellPrice" => 80,
                    "purchasePrice" => 100,
                    "supply" => "HIGH",
                    "tradeVolume" => 20
                  }
                ]
              }
            })

          "/v2/my/ships/ORBITALIST-1/sell" ->
            if Agent.get(state, &(&1.sale_attempts == 0)) do
              Agent.update(state, &%{&1 | credits: 42_400, cargo_units: 7, sale_attempts: 1})

              Req.Test.json(conn, %{
                "data" => %{
                  "agent" => %{},
                  "cargo" => %{"capacity" => 40, "units" => 7, "inventory" => []},
                  "transaction" => %{
                    "shipSymbol" => "ORBITALIST-1",
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
            else
              conn
              |> Map.put(:status, 422)
              |> Req.Test.json(%{
                "error" => %{
                  "code" => 4218,
                  "message" => "You do not have enough cargo."
                }
              })
            end
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Market"
      assert html =~ "IRON_ORE"
      assert html =~ "Sell 80 cr"

      html =
        lv
        |> element("form[phx-submit=\"sell_cargo\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", trade_symbol: "IRON_ORE", units: "5"})

      assert html =~ "Sold 5 IRON_ORE for 400 credits."
      assert html =~ "42,400"

      html =
        lv
        |> element("form[phx-submit=\"sell_cargo\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", trade_symbol: "IRON_ORE", units: "5"})

      assert html =~ "You do not have enough cargo."
    end

    test "shows an on-site market and purchasing cargo refreshes credits and cargo", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      {:ok, state} =
        Agent.start_link(fn -> %{credits: 193_739, cargo_units: 0, purchase_attempts: 0} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{
              "data" =>
                Map.put(
                  agent_overview_body(agent.symbol),
                  "credits",
                  Agent.get(state, & &1.credits)
                )
            })

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-1", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => Agent.get(state, & &1.cargo_units),
                    "inventory" =>
                      if Agent.get(state, &(&1.cargo_units == 0)) do
                        []
                      else
                        [%{"symbol" => "SHIP_PLATING", "name" => "Ship Plating", "units" => 5}]
                      end
                  }
                })
              ]
            })

          "/v2/systems/X1-UX81/waypoints" ->
            case conn.query_params["page"] do
              page when page in [nil, "1"] ->
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

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "SHIP_PLATING",
                    "type" => "IMPORT",
                    "sellPrice" => 7920,
                    "purchasePrice" => 14384,
                    "supply" => "LIMITED",
                    "tradeVolume" => 20
                  }
                ]
              }
            })

          "/v2/my/ships/ORBITALIST-1/purchase" ->
            if Agent.get(state, &(&1.purchase_attempts == 0)) do
              Agent.update(state, &%{&1 | credits: 121_819, cargo_units: 5, purchase_attempts: 1})

              Req.Test.json(conn, %{
                "data" => %{
                  "agent" => %{},
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
                    "waypointSymbol" => "X1-UX81-A1",
                    "timestamp" => "2026-01-01T00:00:00.000Z"
                  }
                }
              })
            else
              conn
              |> Map.put(:status, 422)
              |> Req.Test.json(%{
                "error" => %{
                  "code" => 4215,
                  "message" => "You do not have enough credits to purchase this good."
                }
              })
            end
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Market"
      assert html =~ "Buy 14,384 cr"
      assert html =~ "Sell 7,920 cr"

      html =
        lv
        |> element("form[phx-submit=\"purchase_cargo\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", trade_symbol: "SHIP_PLATING", units: "5"})

      assert html =~ "Bought 5 SHIP_PLATING for 71920 credits."
      assert html =~ "121,819"

      html =
        lv
        |> element("form[phx-submit=\"purchase_cargo\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", trade_symbol: "SHIP_PLATING", units: "5"})

      assert html =~ "You do not have enough credits to purchase this good."
    end

    test "renders a fleet card grid with location, fuel, cargo and nav state", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-1"),
        ship_body("ORBITALIST-2", %{
          "registration" => %{
            "name" => "ORBITALIST-2",
            "factionSymbol" => "COSMIC",
            "role" => "SATELLITE"
          },
          "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A3"),
          "fuel" => %{"capacity" => 200, "current" => 80},
          "cargo" => %{"capacity" => 40, "units" => 2, "inventory" => []}
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "ORBITALIST-1"
      assert html =~ "ORBITALIST-2"
      assert html =~ "DOCKED"
      assert html =~ "IN_ORBIT"
      assert html =~ "X1-UX81-A1"
      assert html =~ "X1-UX81-A3"
      assert html =~ "150 / 200"
      assert html =~ "80 / 200"
      assert html =~ "12 / 40"
      assert html =~ "2 / 40"
      assert html =~ "COMMAND"
      assert html =~ "SATELLITE"
    end

    test "shows an active cooldown on a ship card", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-2", %{
          "cooldown" => %{
            "shipSymbol" => "ORBITALIST-2",
            "totalSeconds" => 60,
            "remainingSeconds" => 42,
            "expiration" => future_iso(42)
          }
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Cooldown 42s"
    end

    test "shows an in-transit ship with its arrival time and no actions", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      arrival = future_iso()

      ships = [
        ship_body("ORBITALIST-1", %{
          "nav" => nav_body("IN_TRANSIT", arrival: arrival)
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "In transit"
      assert html =~ arrival_label_for(arrival)
      assert html =~ "Actions resume when the ship arrives."
      refute html =~ "Waypoint symbol"
    end

    test "renders ship action affordances for a docked ship", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Waypoint symbol"
      assert html =~ "Navigate"

      assert html =~ "Dock"
      assert html =~ "Orbit"
      assert html =~ "Extract"
      assert html =~ ~s(phx-click="orbit")
      assert html =~ ~s(phx-click="dock")
      assert html =~ ~s(<button type="button" phx-click="extract")
    end

    test "navigates a ship and the card shows IN_TRANSIT with its arrival time", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      arrival = future_iso()

      {:ok, state} = Agent.start_link(fn -> %{arrival: nil} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            nav =
              case Agent.get(state, & &1.arrival) do
                nil -> nav_body("DOCKED")
                arrival -> nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
              end

            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1", %{"nav" => nav})]})

          {"/v2/my/ships/ORBITALIST-1/navigate", "POST"} ->
            Agent.update(state, &%{&1 | arrival: arrival})

            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 200, "current" => 80},
                "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Waypoint symbol"

      html =
        lv
        |> element("form[phx-submit=\"navigate\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X1-UX81-A2"})

      assert html =~ "ORBITALIST-1 is in transit to X1-UX81-A2."
      assert html =~ "In transit"
      assert html =~ arrival_label_for(arrival)
      refute html =~ "Waypoint symbol"
    end

    test "disables navigate while the ship is on a live cooldown", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-1", %{
                  "cooldown" => %{
                    "shipSymbol" => "ORBITALIST-1",
                    "totalSeconds" => 60,
                    "remainingSeconds" => 42,
                    "expiration" => future_iso(42)
                  }
                })
              ]
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Cooldown 42s"
      assert html =~ ~s(<button type="submit" disabled)
    end

    test "shows an on-site shipyard and buys a mining drone", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> %{bought: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            ships =
              if Agent.get(state, & &1.bought),
                do: [ship_body("ORBITALIST-1"), ship_body("ORBITALIST-2")],
                else: [ship_body("ORBITALIST-1")]

            Req.Test.json(conn, %{"data" => ships})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
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

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", "GET"} ->
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

          {"/v2/my/ships", "POST"} ->
            Agent.update(state, &%{&1 | bought: true})

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{},
                "ship" => ship_body("ORBITALIST-2"),
                "transaction" => %{}
              }
            })
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Mining Drone"

      html = lv |> element("form[phx-submit=\"buy_ship\"]") |> render_submit()
      assert html =~ "SHIP_MINING_DRONE purchased"
      assert html =~ "ORBITALIST-2"

      assert %Ship{ship_type: "SHIP_MINING_DRONE", agent_id: agent_id} =
               Repo.get_by(Ship, symbol: "ORBITALIST-2")

      assert agent_id == agent.id
    end

    test "unblocks the card when the ship arrives", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      agent_id = agent.id
      arrival = future_iso(300)

      {:ok, state} = Agent.start_link(fn -> %{arrived: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            nav =
              if Agent.get(state, & &1.arrived) do
                nav_body("DOCKED")
              else
                nav_body("IN_TRANSIT", arrival: arrival)
              end

            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1", %{"nav" => nav})]})

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Agent.update(state, &%{&1 | arrived: true})

            Req.Test.json(conn, %{
              "data" => ship_body("ORBITALIST-1", %{"nav" => nav_body("DOCKED")})
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, event} =
        Timeline.schedule_event(
          :ship,
          "ORBITALIST-1",
          :arrival,
          DateTime.add(DateTime.utc_now(), 200, :millisecond)
        )

      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet:#{agent_id}")

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "In transit"

      # The ship's server owns the arrival timer; starting it fires the event
      # shortly, re-pulls the real state and broadcasts so the card unblocks.
      start_supervised!(
        {SpaceTraders.Fleet.ShipServer,
         symbol: "ORBITALIST-1", agent_id: agent_id, agent_token: agent.agent_token}
      )

      assert_receive {:ship_updated, ^agent_id, "ORBITALIST-1"}, 1_000
      eventually(fn -> render(lv) end, &(&1 =~ "Waypoint symbol"))

      html = render(lv)

      refute html =~ "In transit"
      refute html =~ "Actions resume when the ship arrives."
      assert html =~ "Waypoint symbol"
      assert SpaceTraders.Repo.get(SpaceTraders.Timeline.Event, event.id).status == "done"
    end

    test "negotiates a new contract with a ship at a faction waypoint", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> %{negotiated: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            contracts =
              if Agent.get(state, & &1.negotiated) do
                [
                  %{
                    "id" => "ctr-2",
                    "accepted" => false,
                    "fulfilled" => false,
                    "factionSymbol" => "COSMIC",
                    "type" => "PROCUREMENT",
                    "terms" => %{
                      "deadline" => future_iso(),
                      "deliver" => [
                        %{
                          "tradeSymbol" => "IRON_ORE",
                          "destinationSymbol" => "X1-UX81-A2",
                          "unitsRequired" => 10,
                          "unitsFulfilled" => 0
                        }
                      ],
                      "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
                    }
                  }
                ]
              else
                []
              end

            Req.Test.json(conn, %{"data" => contracts})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [ship_body("ORBITALIST-1", %{"nav" => nav_body("DOCKED")})]
            })

          {"/v2/my/ships/ORBITALIST-1/negotiate/contract", "POST"} ->
            Agent.update(state, &%{&1 | negotiated: true})
            Req.Test.json(conn, %{"data" => %{"contract" => %{"id" => "ctr-2"}}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Negotiate contract"

      html =
        lv
        |> element("form[phx-submit=\"negotiate_contract\"]")
        |> render_submit(%{agent_id: agent.id, ship_symbol: "ORBITALIST-1"})

      assert html =~ "New contract negotiated."
      assert html =~ "Accept contract"
      refute html =~ "Negotiate a new contract"
    end

    test "refuels a docked ship", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> %{refueled: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            fuel =
              if Agent.get(state, & &1.refueled),
                do: %{"capacity" => 200, "current" => 200},
                else: %{"capacity" => 200, "current" => 100}

            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1", %{"fuel" => fuel})]})

          {"/v2/my/ships/ORBITALIST-1/refuel", "POST"} ->
            Agent.update(state, &%{&1 | refueled: true})

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{},
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "fuel" => %{"capacity" => 200, "current" => 200},
                "transaction" => %{}
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "100 / 200"

      html = lv |> element("button[phx-click=\"refuel\"]") |> render_click()
      assert html =~ "200 / 200"
    end

    test "jettisons cargo from a ship", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> %{jettisoned: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            cargo =
              if Agent.get(state, & &1.jettisoned),
                do: %{"capacity" => 40, "units" => 0, "inventory" => []},
                else: %{
                  "capacity" => 40,
                  "units" => 3,
                  "inventory" => [%{"symbol" => "IRON_ORE", "name" => "Iron Ore", "units" => 3}]
                }

            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1", %{"cargo" => cargo})]})

          {"/v2/my/ships/ORBITALIST-1/jettison", "POST"} ->
            Agent.update(state, &%{&1 | jettisoned: true})

            Req.Test.json(conn, %{
              "data" => %{"cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}}
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "IRON_ORE"

      html =
        lv
        |> element("form[phx-submit=\"jettison_cargo\"]")
        |> render_submit(%{units: 3})

      assert html =~ "Jettisoned 3 IRON_ORE."
      refute html =~ "3 units"
    end

    test "browses system waypoints and navigates from the browser", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> %{transit: false} end)

      waypoints = [
        %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "ORBITAL_STATION",
          "traits" => [%{"symbol" => "MARKETPLACE"}, %{"symbol" => "SHIPYARD"}]
        },
        %{
          "symbol" => "X1-UX81-A3",
          "systemSymbol" => "X1-UX81",
          "type" => "ENGINEERED_ASTEROID",
          "traits" => [%{"symbol" => "MINERAL_DEPOSITS"}]
        },
        %{
          "symbol" => "X1-UX81-B1",
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        }
      ]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            nav =
              if Agent.get(state, & &1.transit) do
                nav_body("IN_TRANSIT", arrival: future_iso(300), destination: "X1-UX81-A3")
              else
                nav_body("DOCKED")
              end

            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1", %{"nav" => nav})]})

          {"/v2/my/ships/ORBITALIST-1/navigate", "POST"} ->
            Agent.update(state, &%{&1 | transit: true})

            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 200, "current" => 150},
                "nav" =>
                  nav_body("IN_TRANSIT", arrival: future_iso(300), destination: "X1-UX81-A3")
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            case conn.query_params["page"] do
              "1" -> Req.Test.json(conn, %{"data" => waypoints})
              _ -> Req.Test.json(conn, %{"data" => []})
            end

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "X1-UX81-A3"
      assert html =~ "ENGINEERED_ASTEROID"

      html =
        lv
        |> element("form[phx-change=\"waypoint_filter\"]")
        |> render_change(%{waypoint_type: "SHIPYARD"})

      refute html =~ "X1-UX81-A3"
      assert html =~ "X1-UX81-A1"

      html =
        lv
        |> element("form[phx-change=\"waypoint_filter\"]")
        |> render_change(%{waypoint_type: "ENGINEERED_ASTEROID"})

      assert html =~ "X1-UX81-A3"

      html =
        lv
        |> element("form[phx-submit=\"browser_navigate\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X1-UX81-A3"})

      assert html =~ "ORBITALIST-1 is in transit to X1-UX81-A3."
    end

    test "shows a readable per-agent error when the game API is unavailable", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{"error" => %{"code" => 4011, "message" => "Invalid token"}})
      end)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ agent.symbol
      assert html =~ "Invalid token"
    end

    test "prompts to mint a first agent when the operator has none", %{conn: conn} do
      stub_live_game(agent_overview_body("UNUSED"), [])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "minted any agents yet"
      assert html =~ "Mint an agent"
    end
  end
end
