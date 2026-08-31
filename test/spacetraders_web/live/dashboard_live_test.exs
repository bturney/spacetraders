defmodule SpaceTradersWeb.DashboardLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.{Fleet, Timeline}
  alias SpaceTraders.Timeline.Event
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Fleet.ShipDestination
  alias SpaceTraders.Fleet.Job
  alias SpaceTraders.Fleet.JobBlocker
  alias SpaceTraders.Fleet.Activity
  alias SpaceTraders.Repo

  defp stub_live_game(agent_overview, ships) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => agent_overview})

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => ships})

        "/v2/my/ships/" <> symbol ->
          Req.Test.json(conn, %{"data" => Enum.find(ships, &(&1["symbol"] == symbol))})

        "/v2/my/contracts" ->
          Req.Test.json(conn, %{"data" => []})

        "/v2/systems/X1-UX81/waypoints" ->
          Req.Test.json(conn, %{"data" => []})
      end
    end)
  end

  defp stub_contract_game(agent, contracts) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" -> Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})
        "/v2/my/ships" -> Req.Test.json(conn, %{"data" => []})
        "/v2/my/contracts" -> Req.Test.json(conn, %{"data" => contracts})
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

  defp input_value(lv, form_id, field) do
    lv
    |> element(~s(form##{form_id} input[name="#{field}"]))
    |> render()
  end

  defp ship_offer_body(overrides \\ %{}) do
    Map.merge(
      %{
        "type" => "SHIP_LIGHT_FREIGHTER",
        "name" => "Light Freighter",
        "description" => "A small freighter for light trading runs.",
        "supply" => "SCARCE",
        "activity" => "STRONG",
        "purchasePrice" => 70_000,
        "frame" => %{
          "symbol" => "FRAME_FREIGHTER",
          "name" => "Freighter",
          "description" => "A freighter frame",
          "moduleSlots" => 4,
          "mountingPoints" => 2,
          "fuelCapacity" => 300,
          "condition" => 100,
          "integrity" => 100,
          "requirements" => %{"power" => 1, "crew" => 1}
        },
        "reactor" => %{
          "symbol" => "REACTOR_FISSION_I",
          "name" => "Fission I",
          "description" => "A fission reactor",
          "condition" => 100,
          "integrity" => 100,
          "powerOutput" => 5,
          "requirements" => %{"crew" => 1}
        },
        "engine" => %{
          "symbol" => "ENGINE_ION_DRIVE_I",
          "name" => "Ion Drive I",
          "description" => "An ion engine",
          "condition" => 100,
          "integrity" => 100,
          "speed" => 2,
          "requirements" => %{"power" => 1, "crew" => 1}
        },
        "modules" => [
          %{
            "symbol" => "MODULE_CARGO_HOLD_I",
            "name" => "Cargo Hold I",
            "description" => "A cargo hold",
            "capacity" => 20,
            "requirements" => %{"crew" => 1}
          }
        ],
        "mounts" => [
          %{
            "symbol" => "MOUNT_MINING_LASER_I",
            "name" => "Mining Laser I",
            "description" => "A mining laser",
            "strength" => 10,
            "deposits" => ["QUARTZ_SAND"],
            "requirements" => %{"power" => 1, "crew" => 1}
          }
        ],
        "crew" => %{"required" => 4, "capacity" => 8}
      },
      overrides
    )
  end

  defp stub_shipyard_offers(agent, ships) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/agent", "GET"} ->
          Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

        {"/v2/my/contracts", "GET"} ->
          Req.Test.json(conn, %{"data" => []})

        {"/v2/my/ships", "GET"} ->
          Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1")]})

        {"/v2/systems/X1-UX81/waypoints", "GET"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "ORBITAL_STATION",
                "x" => 1,
                "y" => 2,
                "traits" => [%{"symbol" => "SHIPYARD", "name" => "Shipyard", "description" => ""}]
              }
            ]
          })

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", "GET"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => ships}})
      end
    end)
  end

  defp past_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(-seconds, :second) |> DateTime.to_iso8601()
  end

  defp deadline_label_for(deadline) do
    {:ok, date_time, _offset} = DateTime.from_iso8601(deadline)
    Calendar.strftime(date_time, "%m-%d %H:%M UTC")
  end

  defp pending_contract_body(deadline_to_accept) do
    %{
      "id" => "ctr-pending",
      "accepted" => false,
      "fulfilled" => false,
      "factionSymbol" => "COSMIC",
      "type" => "PROCUREMENT",
      "deadlineToAccept" => deadline_to_accept,
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
  end

  defp contract_body(overrides) do
    Map.merge(
      %{
        "id" => "ctr-1",
        "accepted" => false,
        "fulfilled" => false,
        "factionSymbol" => "COSMIC",
        "type" => "PROCUREMENT",
        "deadlineToAccept" => future_iso(),
        "terms" => %{
          "deadline" => future_iso(),
          "deliver" => [],
          "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
        }
      },
      overrides
    )
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

  defp assert_before(html, first, second) do
    [first_index, second_index] =
      Enum.map([first, second], fn text ->
        case :binary.match(html, text) do
          {index, _} -> index
          :nomatch -> flunk("expected #{inspect(text)} in rendered html")
        end
      end)

    assert first_index < second_index
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
        Agent.start_link(fn -> %{credits: 42_000, cargo_units: 15, sale_attempts: 0} end)

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
                        "units" => Agent.get(state, &(&1.cargo_units - 3))
                      },
                      %{
                        "symbol" => "COPPER_ORE",
                        "name" => "Copper Ore",
                        "units" => 3
                      }
                    ]
                  }
                })
              ]
            })

          "/v2/my/ships/ORBITALIST-1" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-1", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => Agent.get(state, & &1.cargo_units),
                    "inventory" => [
                      %{
                        "symbol" => "IRON_ORE",
                        "name" => "Iron Ore",
                        "units" => Agent.get(state, &(&1.cargo_units - 3))
                      },
                      %{"symbol" => "COPPER_ORE", "name" => "Copper Ore", "units" => 3}
                    ]
                  }
                })
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
              Agent.update(state, &%{&1 | credits: 42_400, cargo_units: 10, sale_attempts: 1})

              Req.Test.json(conn, %{
                "data" => %{
                  "agent" => %{},
                  "cargo" => %{"capacity" => 40, "units" => 10, "inventory" => []},
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
      assert html =~ "A ship can sell only cargo listed at its current market."

      refute has_element?(
               lv,
               "form[phx-submit=\"sell_cargo\"] input[name=\"trade_symbol\"][value=\"COPPER_ORE\"]"
             )

      html =
        lv
        |> element("form[phx-submit=\"sell_cargo\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", trade_symbol: "IRON_ORE", units: "5"})

      assert html =~ "Sold 5 IRON_ORE for 400 credits."
      assert html =~ "42,400"

      lv
      |> element(
        "form[phx-change=\"track_draft\"][id=\"sell-form-X1-UX81-A1-ORBITALIST-1-IRON_ORE\"]"
      )
      |> render_change(%{
        draft_key: "sell:ORBITALIST-1:IRON_ORE",
        symbol: "ORBITALIST-1",
        trade_symbol: "IRON_ORE",
        units: "3"
      })

      assert input_value(lv, "sell-form-X1-UX81-A1-ORBITALIST-1-IRON_ORE", "units") =~
               ~s(value="3")

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "sell-form-X1-UX81-A1-ORBITALIST-1-IRON_ORE", "units") =~
               ~s(value="3")

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

          "/v2/my/ships/ORBITALIST-1" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-1", %{
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => Agent.get(state, & &1.cargo_units),
                    "inventory" =>
                      if(Agent.get(state, &(&1.cargo_units == 0)),
                        do: [],
                        else: [
                          %{"symbol" => "SHIP_PLATING", "name" => "Ship Plating", "units" => 5}
                        ]
                      )
                  }
                })
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

    test "shows Market Signals on trade rows from a complete market response", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1")]})

          "/v2/systems/X1-UX81/waypoints" ->
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

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "exports" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "name" => "Iron Ore",
                    "description" => "Iron ore mined from asteroids and rocky planets."
                  }
                ],
                "imports" => [
                  %{
                    "symbol" => "SHIP_PLATING",
                    "name" => "Ship Plating",
                    "description" => "A collection of ship plating for hull repairs."
                  }
                ],
                "exchange" => [
                  %{
                    "symbol" => "FUEL",
                    "name" => "Fuel",
                    "description" => "Fuel for ship engines."
                  }
                ],
                "transactions" => [
                  %{
                    "shipSymbol" => "ORBITALIST-1",
                    "tradeSymbol" => "IRON_ORE",
                    "type" => "SELL",
                    "units" => 5,
                    "pricePerUnit" => 80,
                    "totalPrice" => 400,
                    "waypointSymbol" => "X1-UX81-A1",
                    "timestamp" => "2026-01-01T00:00:00.000Z"
                  }
                ],
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "type" => "EXPORT",
                    "sellPrice" => 80,
                    "purchasePrice" => 100,
                    "supply" => "LIMITED",
                    "activity" => "STRONG",
                    "tradeVolume" => 20
                  },
                  %{
                    "symbol" => "SHIP_PLATING",
                    "type" => "IMPORT",
                    "sellPrice" => 7920,
                    "purchasePrice" => 14384,
                    "supply" => "SCARCE",
                    "activity" => "RESTRICTED",
                    "tradeVolume" => 5
                  },
                  %{
                    "symbol" => "FUEL",
                    "type" => "EXCHANGE",
                    "sellPrice" => 50,
                    "purchasePrice" => 70,
                    "supply" => "ABUNDANT",
                    "tradeVolume" => 100
                  }
                ]
              }
            })
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Market"

      assert html =~ "IRON_ORE"
      assert html =~ "Iron Ore"
      assert html =~ "Export"
      assert html =~ "LIMITED"
      assert html =~ "STRONG"
      assert html =~ "Vol 20"

      assert html =~ "SHIP_PLATING"
      assert html =~ "Ship Plating"
      assert html =~ "Import"
      assert html =~ "SCARCE"
      assert html =~ "RESTRICTED"
      assert html =~ "Vol 5"

      assert html =~ "FUEL"
      assert html =~ "Exchange"
      assert html =~ "ABUNDANT"
      assert html =~ "Vol 100"

      assert html =~ ~s(class="badge badge-warning badge-xs">LIMITED</span>)
      assert html =~ ~s(class="badge badge-warning badge-xs">SCARCE</span>)
      assert html =~ ~s(class="badge badge-warning badge-xs">RESTRICTED</span>)
      refute html =~ ~s(class="badge badge-warning badge-xs">ABUNDANT</span>)
      refute html =~ ~s(class="badge badge-warning badge-xs">STRONG</span>)

      refute html =~ "Transactions"
      refute html =~ "totalPrice"

      refute html =~ "Iron ore mined from asteroids and rocky planets."
      refute html =~ "Hide description"
      assert html =~ ~s(aria-expanded="false")

      html =
        lv
        |> element(~s{button[phx-click="toggle_market_description"][phx-value-symbol="IRON_ORE"]})
        |> render_click()

      assert html =~ "Iron ore mined from asteroids and rocky planets."
      assert html =~ "Hide description"
      assert html =~ ~s(aria-expanded="true")
      assert html =~ ~s(id="market-description-X1-UX81-A1-IRON_ORE")

      html =
        lv
        |> element(~s{button[phx-click="toggle_market_description"][phx-value-symbol="IRON_ORE"]})
        |> render_click()

      refute html =~ "Iron ore mined from asteroids and rocky planets."
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

    test "keeps the map before compact Fleet rows and opens a grouped Ship console", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, html} = live(conn, ~p"/")

      assert_before(html, "System map", "Ship status")
      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"]", "ORBITALIST-1")
      assert has_element?(lv, "button[data-select-ship=ORBITALIST-1]", "Open operations")

      lv |> element("button[data-select-ship=ORBITALIST-1]") |> render_click()
      html = render(lv)

      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"][data-selected=\"true\"]")
      assert html =~ "Selected Ship operations"
      assert html =~ "Navigation"
      assert html =~ "Cargo &amp; Trade"
      assert has_element?(lv, "[data-console-section=\"ship\"] summary", "Ship Readiness")
      assert html =~ "Sensors"
    end

    test "shows transfer controls only for ships at the same waypoint and state", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-1"),
        ship_body("ORBITALIST-2", %{
          "nav" => nav_body("DOCKED"),
          "cargo" => %{"capacity" => 40, "units" => 2, "inventory" => []}
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("button[data-select-ship=ORBITALIST-1]")
        |> render_click()

      assert html =~ ~s(id="transfer-form-ORBITALIST-1")
      assert html =~ ~s(<option value="ORBITALIST-2")
      assert html =~ "Transfer cargo"
    end

    test "keeps the fleet card compact and reveals Ship Readiness on demand", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-1", %{
          "crew" => %{"current" => 2, "required" => 1, "capacity" => 6, "morale" => 70},
          "engine" => %{"name" => "Impulse Drive II", "speed" => 3}
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "ORBITALIST-1"
      assert html =~ "DOCKED"
      assert html =~ "X1-UX81-A1"
      assert html =~ "150 / 200"
      assert html =~ "12 / 40"

      assert has_element?(
               lv,
               "details#ship-readiness-ORBITALIST-1[data-ship-readiness] summary",
               "Ship Readiness"
             )

      refute has_element?(lv, "details[data-ship-readiness][open]")

      assert html =~ "CRUISE"
      assert html =~ "2 / 1 / 6"
      assert html =~ "speed 3"
      assert html =~ "Morale 70"
      assert html =~ "current / required / capacity"
      assert html =~ "No modules installed."
      assert html =~ "No mounts installed."
    end

    test "reveals component condition before integrity and equipment capabilities on demand", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-1", %{
          "frame" => %{
            "symbol" => "FRAME_FRIGATE",
            "name" => "Frigate",
            "moduleSlots" => 2,
            "condition" => 55,
            "integrity" => 100,
            "quality" => 75,
            "description" => "A medium frigate."
          },
          "reactor" => %{
            "symbol" => "REACTOR_SOLAR_I",
            "name" => "Solar I",
            "condition" => 60,
            "integrity" => 95,
            "description" => "A reactor"
          },
          "engine" => %{
            "symbol" => "ENGINE_IMPULSE_DRIVE_I",
            "name" => "Impulse Drive I",
            "condition" => 70,
            "integrity" => 90,
            "speed" => 1,
            "description" => "An engine"
          },
          "modules" => [
            %{
              "symbol" => "MODULE_CARGO_HOLD_I",
              "name" => "Cargo Hold I",
              "capacity" => 10,
              "description" => "Expands the ship's cargo capacity."
            },
            %{
              "symbol" => "MODULE_CREW_QUARTERS_I",
              "name" => "Crew Quarters I",
              "capacity" => 6
            }
          ],
          "mounts" => [
            %{
              "symbol" => "MOUNT_MINING_LASER_I",
              "name" => "Mining Laser I",
              "strength" => 5,
              "deposits" => ["QUARTZ_SAND", "IRON_ORE"],
              "description" => "A mining laser."
            }
          ]
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Condition 55"
      assert html =~ "Condition 60"
      assert html =~ "Condition 70"
      assert has_element?(lv, "[data-component=\"frame\"]", "Condition 55")

      assert has_element?(lv, "details[data-component-detail=\"frame\"]", "Integrity 100")
      assert has_element?(lv, "details[data-component-detail=\"frame\"]", "Quality 75")
      assert has_element?(lv, "details[data-component-detail=\"frame\"]", "A medium frigate.")
      refute has_element?(lv, "details[data-component-detail=\"frame\"][open]")
      assert has_element?(lv, "details[data-component-detail=\"engine\"]", "Integrity 90")

      assert has_element?(lv, "[data-module=\"MODULE_CARGO_HOLD_I\"]", "Cargo Hold I capacity 10")

      assert has_element?(
               lv,
               "[data-module=\"MODULE_CREW_QUARTERS_I\"]",
               "Crew Quarters I capacity 6"
             )

      assert has_element?(lv, "[data-module-capacity]", "2 / 2 module slots")

      assert has_element?(
               lv,
               "[data-mount=\"MOUNT_MINING_LASER_I\"]",
               "Mining Laser I strength 5"
             )

      assert has_element?(lv, "[data-mount=\"MOUNT_MINING_LASER_I\"]", "QUARTZ_SAND, IRON_ORE")

      assert has_element?(lv, "details[data-equipment-description]", "A mining laser.")

      assert has_element?(
               lv,
               "details[data-equipment-description]",
               "Expands the ship's cargo capacity."
             )
    end

    test "offers explicit module installation and one-module removal controls", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      stub_live_game(agent_overview_body(agent.symbol), [
        ship_body("ORBITALIST-1", %{
          "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
          "cargo" => %{
            "capacity" => 40,
            "units" => 1,
            "inventory" => [%{"symbol" => "MODULE_GAS_PROCESSOR_I", "units" => 1}]
          }
        })
      ])

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button[data-select-ship=ORBITALIST-1]") |> render_click()

      assert has_element?(
               lv,
               "button[data-install-module=MODULE_GAS_PROCESSOR_I]",
               "Install module"
             )

      assert has_element?(lv, "button[data-remove-module=MODULE_CARGO_HOLD_I]", "Remove module")
    end

    test "offers Ship Outfitting Job assignment from Ship Readiness", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")
      lv |> element("button[data-select-ship=ORBITALIST-1]") |> render_click()

      assert has_element?(lv, "form[id=outfitting-job-form-ORBITALIST-1]")
      assert has_element?(lv, "input[name=source_waypoints]")
      assert has_element?(lv, "input[name=reserve_credits]")
      assert has_element?(lv, "input[name=maximum_total_cost][required]")

      assert has_element?(
               lv,
               "button[type=submit]",
               "Assign Ship Outfitting Job"
             )
    end

    test "shows an in-transit ship's origin and destination with departure in Route details", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      arrival = future_iso()

      ships = [
        ship_body("ORBITALIST-1", %{
          "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "In transit"
      assert has_element?(lv, "[data-transit-arrival]", arrival_label_for(arrival))
      assert has_element?(lv, "[data-transit-route-summary]", "X1-UX81-A1")
      assert has_element?(lv, "[data-transit-route-summary]", "X1-UX81-A2")

      assert has_element?(lv, "details[data-route-details] summary", "Route details")
      refute has_element?(lv, "details[data-route-details][open]")
      assert has_element?(lv, "details[data-route-details] dd", "01-01 00:00 UTC")
      refute has_element?(lv, "details[data-route-details]", arrival_label_for(arrival))
    end

    test "shows cargo symbol-first with name and description on demand", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-1", %{
          "cargo" => %{
            "capacity" => 40,
            "units" => 15,
            "inventory" => [
              %{
                "symbol" => "IRON_ORE",
                "name" => "Iron Ore",
                "description" => "Iron ore used in smelting.",
                "units" => 12
              },
              %{"symbol" => "COPPER_ORE", "units" => 3}
            ]
          }
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "15 / 40"
      assert has_element?(lv, "[data-cargo-item=\"IRON_ORE\"]", "IRON_ORE")
      assert has_element?(lv, "[data-cargo-item=\"IRON_ORE\"]", "Iron Ore")
      assert has_element?(lv, "[data-cargo-item=\"IRON_ORE\"]", "12 units")

      assert has_element?(
               lv,
               "details[data-cargo-description=\"IRON_ORE\"]",
               "Iron ore used in smelting."
             )

      refute has_element?(lv, "details[data-cargo-description=\"IRON_ORE\"][open]")

      assert has_element?(lv, "[data-cargo-item=\"COPPER_ORE\"]", "COPPER_ORE")
      assert has_element?(lv, "[data-cargo-item=\"COPPER_ORE\"]", "3 units")
      refute has_element?(lv, "[data-cargo-item=\"COPPER_ORE\"]", "Copper Ore")
      refute has_element?(lv, "details[data-cargo-description=\"COPPER_ORE\"]")
    end

    test "fills cargo meter from cargo units", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      ships = [
        ship_body("ORBITALIST-1", %{
          "cargo" => %{"capacity" => 15, "units" => 7, "inventory" => []}
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "7 / 15"
      assert has_element?(lv, "progress.progress-secondary[value='7'][max='15']")
    end

    test "shows an active cooldown on a ship card", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          symbol: "ORBITALIST-2",
          ship_type: "SHIP_COMMAND_FRIGATE",
          agent_id: agent.id
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "active",
        status: "waiting",
        in_flight_action: %{"kind" => "extract"}
      })

      ships = [
        ship_body("ORBITALIST-2", %{
          "cooldown" => %{
            "shipSymbol" => "ORBITALIST-2",
            "totalSeconds" => 60,
            "remainingSeconds" => 42
          }
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Cooldown 42s"
      assert html =~ "Waiting for cooldown"
      assert html =~ "Wait through Cooldown 42s"
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
      assert html =~ "Waypoint symbol"
      assert html =~ "This ship is in transit; actions resume on arrival."
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
      assert html =~ "This action requires the Ship to be in orbit."
      assert html =~ ~s(phx-click="orbit")
      assert html =~ ~s(phx-click="dock")
      assert html =~ ~s(phx-click="extract")
    end

    test "assigns a loop as a paused Miner Job", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Assign Miner Job"
      refute html =~ "Start Miner Job"

      html =
        lv
        |> element("form[phx-submit=\"configure_miner_job\"]")
        |> render_submit(%{
          ship_symbol: "ORBITALIST-1",
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: "30"
        })

      assert html =~ "Miner Job assigned and paused."
      assert has_element?(lv, "[data-job-status]", "Paused")
      assert has_element?(lv, "button[phx-click=\"resume_miner_job\"]")
    end

    test "assigns a Procurement Job from the ship operations panel", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "form#procurement-job-form-ORBITALIST-1")
      assert has_element?(lv, "form#procurement-job-form-ORBITALIST-1", "Assign Procurement Job")

      html =
        lv
        |> element("form#procurement-job-form-ORBITALIST-1")
        |> render_submit(%{
          ship_symbol: "ORBITALIST-1",
          recipient_type: "market",
          trade_symbol: "IRON_ORE",
          quantity: "30",
          destination_waypoint: "X1-UX81-A1"
        })

      assert html =~ "Procurement Job assigned and paused."
      assert has_element?(lv, "[data-job-panel=procurement]", "Procurement Job")
      assert has_element?(lv, "[data-procurement-job-status]", "Paused")
      assert has_element?(lv, "button[phx-click=\"resume_procurement_job\"]")
    end

    test "explains when a Procurement Job cannot find a source market", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      Repo.insert!(%Ship{
        agent_id: agent.id,
        symbol: "ORBITALIST-1",
        ship_type: "SHIP_COMMAND_FRIGATE"
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1")]})

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("ORBITALIST-1")})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                contract_body(%{
                  "accepted" => true,
                  "terms" => %{
                    "deadline" => future_iso(),
                    "deliver" => [
                      %{
                        "tradeSymbol" => "DIAMONDS",
                        "destinationSymbol" => "X1-UX81-A1",
                        "unitsRequired" => 10,
                        "unitsFulfilled" => 0
                      }
                    ],
                    "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
                  }
                })
              ]
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE"
                }
              ]
            })
        end
      end)

      assert {:ok, _job} =
               Fleet.configure_procurement_job(agent, "ORBITALIST-1", %{
                 contract_id: "ctr-1",
                 trade_symbol: "DIAMONDS",
                 quantity: 10,
                 destination_waypoint: "X1-UX81-A1"
               })

      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("button[phx-click=\"resume_procurement_job\"]")
        |> render_click()

      assert html =~
               "Procurement Job blocked: no source market is available in the current system."

      refute html =~ "The game API could not be reached."
    end

    test "assigns a Construction Supply Job from the ship operations panel", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "form#construction-supply-job-form-ORBITALIST-1")

      html =
        lv
        |> element("form#construction-supply-job-form-ORBITALIST-1")
        |> render_submit(%{
          ship_symbol: "ORBITALIST-1",
          construction_system: "X1-UX81",
          construction_waypoint: "X1-UX81-A1",
          reserve_credits: "500",
          maximum_total_cost: "2000"
        })

      assert html =~ "Construction Supply Job assigned and paused."
      assert has_element?(lv, "[data-job-panel=construction-supply]", "Construction Supply Job")
      assert has_element?(lv, "[data-construction-supply-job-status]", "Paused")
      assert has_element?(lv, "button[phx-click=\"resume_construction_supply_job\"]")
    end

    test "keeps Procurement Job drafts across dashboard patches", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form#procurement-job-form-ORBITALIST-1")
      |> render_change(%{
        draft_key: "procurement_job:ORBITALIST-1",
        ship_symbol: "ORBITALIST-1",
        recipient_type: "contract",
        contract_id: "CONTRACT-1",
        construction_system: "X1-UX81",
        trade_symbol: "IRON_ORE",
        quantity: "30",
        destination_waypoint: "X1-UX81-A1",
        source_systems: "X1-UX81",
        reserve_credits: "500",
        price_ceiling: "10",
        minimum_sale_price: "25",
        minimum_sale_value: "750",
        compatible_existing_cargo: "on"
      })

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "procurement-job-form-ORBITALIST-1", "trade_symbol") =~
               ~s(value="IRON_ORE")

      assert input_value(lv, "procurement-job-form-ORBITALIST-1", "quantity") =~
               ~s(value="30")

      assert input_value(lv, "procurement-job-form-ORBITALIST-1", "destination_waypoint") =~
               ~s(value="X1-UX81-A1")

      assert has_element?(
               lv,
               "form#procurement-job-form-ORBITALIST-1 option[value=\"contract\"][selected]"
             )

      assert has_element?(
               lv,
               "form#procurement-job-form-ORBITALIST-1 input[name=\"compatible_existing_cargo\"][checked]"
             )
    end

    test "presents the configured loop as a Miner Job", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "[data-job-panel=miner]", "Miner Job")

      assert has_element?(
               lv,
               "form#miner-job-form-ORBITALIST-1[phx-submit=\"configure_miner_job\"]"
             )

      assert has_element?(lv, "[data-job-status]", "Manual")
      assert has_element?(lv, "[data-job-next-transition]", "Assign Miner Job")
    end

    test "renders System Exploration Job coverage and recovery controls", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "explorer",
        extraction_waypoint: "EXPLORER-NONE",
        market_waypoint: "EXPLORER-NONE",
        cargo_threshold: 1,
        status: "blocked",
        progress: %{
          "target_system" => "X1-UX81",
          "coverage" => %{"X1-UX81-A1" => [], "X1-UX81-A2" => ["modifiers"]}
        }
      })

      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "[data-explorer-job-panel]", "System Exploration Job")
      assert has_element?(lv, "[data-explorer-target-system]", "X1-UX81")
      assert has_element?(lv, "[data-explorer-coverage]", "1 / 2")
      assert has_element?(lv, "[data-explorer-unresolved]", "X1-UX81-A2: modifiers")
      assert has_element?(lv, "button[phx-click=\"reconcile_explorer_job\"]")
    end

    test "shows the gather mode and surfaces siphon results as active work", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      extract_ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      siphon_ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-2",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(
        struct(
          Job,
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          desired_mode: "active",
          status: "waiting",
          gather_mode: "siphon",
          ship_id: siphon_ship.id,
          in_flight_action: %{"kind" => "siphon"},
          last_action_result: %{
            "kind" => "siphon",
            "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 5}
          }
        )
      )

      Repo.insert!(
        struct(
          Job,
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          desired_mode: "manual",
          ship_id: extract_ship.id
        )
      )

      stub_live_game(agent_overview_body(agent.symbol), [
        ship_body("ORBITALIST-1"),
        ship_body("ORBITALIST-2")
      ])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-2\"] [data-job-gather-mode]",
               "Siphon"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-2\"] [data-job-active-work]",
               "Waiting for cooldown"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-gather-mode]",
               "Extract"
             )
    end

    test "saves a siphon gather mode through the configured form", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> element("form[phx-submit=\"configure_miner_job\"]")
        |> render_submit(%{
          ship_symbol: "ORBITALIST-1",
          gather_mode: "siphon",
          extraction_waypoint: "X1-UX81-A3",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: "30"
        })

      assert html =~ "Miner Job assigned and paused."

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-gather-mode]",
               "Siphon"
             )

      job = Repo.get_by!(Job, ship_id: Repo.get_by!(Ship, symbol: "ORBITALIST-1").id)
      assert job.gather_mode == "siphon"
      assert job.extraction_waypoint == "X1-UX81-A3"
    end

    test "shows Operator recovery controls and Activity", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Assign Miner Job"
      assert html =~ "Activity"
      assert html =~ "No local recovery events yet."
    end

    test "marks blocked Ships for attention without flagging healthy Ships", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "active",
        status: "blocked",
        blocked_reason: "ambiguous outcome"
      })

      stub_live_game(agent_overview_body(agent.symbol), [
        ship_body("ORBITALIST-1"),
        ship_body("ORBITALIST-2", %{"nav" => nav_body("IN_TRANSIT", arrival: future_iso())})
      ])

      {:ok, lv, html} = live(conn, ~p"/")

      assert has_element?(lv, "[data-needs-attention-count]", "1 needs attention")
      refute has_element?(lv, "[data-fleet-healthy]")

      assert has_element?(
               lv,
               "[data-fleet-attention]",
               "Resolve blocked work before reviewing history"
             )

      assert has_element?(lv, "[data-open-attention=\"ORBITALIST-1\"]", "Resolve")
      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"]", "Blocked")

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-ship-row-status]",
               "Blocked"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] button[phx-click=\"row_resume_miner_job\"]",
               "Resolve"
             )

      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-2\"]", "IN_TRANSIT")
      assert html =~ "ambiguous outcome"
    end

    test "a blocked Job with a structured blocker shows its correction, not Assign", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        status: "blocked",
        blocker: %JobBlocker{
          reason: "invalid_extraction_waypoint",
          resolver: "operator",
          retry_condition: "configuration_changed",
          corrective_actions: ["replace_job", "resume"]
        }
      })

      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-next-transition]",
               "Choose an asteroid extraction waypoint, then Resume"
             )

      refute has_element?(lv, "[data-job-next-transition]", "Assign Miner Job")
    end

    test "keeps Miner Job mode, action, and recovery aligned", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      paused_ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      waiting_ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-2",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      blocked_ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-3",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      config_attrs = [
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "manual"
      ]

      Repo.insert!(
        struct(
          Job,
          Keyword.put(config_attrs, :ship_id, paused_ship.id) ++
            [status: "paused", blocked_reason: "Paused by a direct Ship action"]
        )
      )

      Repo.insert!(
        struct(
          Job,
          Keyword.put(config_attrs, :ship_id, waiting_ship.id) ++
            [
              desired_mode: "active",
              status: "active",
              in_flight_action: %{"kind" => "navigate"}
            ]
        )
      )

      Repo.insert!(
        struct(
          Job,
          Keyword.put(config_attrs, :ship_id, blocked_ship.id) ++
            [
              desired_mode: "active",
              status: "blocked",
              blocked_reason: ":invalid_extraction_waypoint"
            ]
        )
      )

      stub_live_game(agent_overview_body(agent.symbol), [
        ship_body("ORBITALIST-1"),
        ship_body("ORBITALIST-2"),
        ship_body("ORBITALIST-3")
      ])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-status]",
               "Paused"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-next-transition]",
               "Resume after revalidation"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-2\"] [data-job-status]",
               "Active Miner Job"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-2\"] [data-job-active-work]",
               "Revalidating navigation"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-2\"] [data-job-next-transition]",
               "Continue navigation recovery"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-3\"] [data-job-status]",
               "Blocked"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-3\"] [data-job-next-transition]",
               "Choose an asteroid extraction waypoint, then Resume"
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-3\"] [data-job-reason]",
               "Choose an ASTEROID_FIELD or ENGINEERED_ASTEROID extraction waypoint."
             )

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-3\"] button[phx-click=\"resume_miner_job\"]"
             )

      refute has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-3\"] button[phx-click=\"pause_miner_job\"]"
             )
    end

    test "starts, pauses, resumes, and stops the Miner Job through the selected Ship panel", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "manual",
        status: "paused",
        blocked_reason: "Awaiting Operator resume"
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1")]})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-1", %{
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          {"/v2/my/ships/ORBITALIST-3", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-3", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A2"),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 9,
                    "inventory" => [
                      %{
                        "symbol" => "COPPER_ORE",
                        "name" => "Copper Ore",
                        "description" => "Ore",
                        "units" => 9
                      }
                    ]
                  }
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

          {"/v2/my/ships/ORBITALIST-1/orbit", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A1")}
            })

          {"/v2/my/ships/ORBITALIST-1/navigate", "POST"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-1", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")
      assert has_element?(lv, "[data-job-status]", "Paused")
      assert has_element?(lv, "button[phx-click=\"resume_miner_job\"]")
      assert has_element?(lv, "form[phx-submit=\"replace_miner_job\"]", "Replace Miner Job")
      refute has_element?(lv, "button[phx-click=\"pause_miner_job\"]")

      lv |> element("button[phx-click=\"resume_miner_job\"]") |> render_click()
      assert has_element?(lv, "button[phx-click=\"pause_miner_job\"]")

      lv |> element("button[phx-click=\"pause_miner_job\"]") |> render_click()
      assert has_element?(lv, "[data-job-status]", "Paused")
      assert has_element?(lv, "button[phx-click=\"resume_miner_job\"]")

      lv |> element("button[phx-click=\"resume_miner_job\"]") |> render_click()
      refute has_element?(lv, "[data-job-status]", "Paused")

      lv |> element("button[phx-click=\"stop_miner_job\"]") |> render_click()
      assert has_element?(lv, "[data-job-status]", "Manual")
      assert has_element?(lv, "[data-job-history]", "Stopped")
      refute has_element?(lv, "button[phx-click=\"stop_miner_job\"]")
      refute has_element?(lv, "button[phx-click=\"resume_miner_job\"]")
    end

    test "explicitly replaces the assigned Miner Job and displays terminal history", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      predecessor =
        Repo.insert!(%Job{
          ship_id: ship.id,
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30,
          status: "paused"
        })

      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      html =
        lv
        |> form("form[phx-submit=\"replace_miner_job\"]", %{
          "ship_symbol" => "ORBITALIST-1",
          "gather_mode" => "extract",
          "extraction_waypoint" => "X1-UX81-A3",
          "market_waypoint" => "X1-UX81-A1",
          "cargo_threshold" => "20"
        })
        |> render_submit()

      assert html =~ "Miner Job replaced."
      assert has_element?(lv, "[data-job-history]", "Replaced")
      assert has_element?(lv, "[data-job-history-entry=\"#{predecessor.id}\"]", "X1-UX81-A2")
      assert has_element?(lv, "[data-job-history-entry=\"#{predecessor.id}\"]", "30")
      assert has_element?(lv, "[data-job-history-entry=\"#{predecessor.id}\"]", "Successor")
      assert Repo.get!(Job, predecessor.id).status == "replaced"
      successor = Fleet.ship_job(agent, "ORBITALIST-1")
      assert successor.extraction_waypoint == "X1-UX81-A3"
      assert successor.predecessor_job_id == predecessor.id
    end

    test "selects a Ship operation panel and returns to the Fleet roster on mobile", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "[data-select-ship=\"ORBITALIST-1\"]", "Open operations")
      assert has_element?(lv, "[data-ship-operations=\"ORBITALIST-1\"].hidden")
      assert has_element?(lv, "[data-ship-readiness=\"\"].hidden")

      html =
        lv
        |> element("[data-select-ship=\"ORBITALIST-1\"]")
        |> render_click()

      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"][data-selected=\"true\"]")
      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"]")
      assert has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"]:not(.hidden)")
      refute has_element?(lv, "[data-ship-operations=\"ORBITALIST-1\"].hidden")
      refute has_element?(lv, "[data-ship-readiness=\"\"].hidden")
      assert html =~ "Selected Ship operations"
      assert has_element?(lv, "[data-back-to-fleet]", "Back to Fleet")

      html = lv |> element("[data-back-to-fleet]") |> render_click()

      refute has_element?(lv, "[data-ship-card=\"ORBITALIST-1\"][data-selected=\"true\"]")
      refute html =~ "Selected Ship operations"
    end

    test "renders consequential activity chronologically without retry noise", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      older = DateTime.add(DateTime.utc_now(), -20, :second) |> DateTime.truncate(:second)
      newer = DateTime.add(DateTime.utc_now(), -10, :second) |> DateTime.truncate(:second)

      Repo.insert!(%Activity{
        agent_id: agent.id,
        ship_id: ship.id,
        kind: "configuration",
        message: "Miner Job configuration changed",
        metadata: %{},
        inserted_at: older,
        updated_at: older
      })

      Repo.insert!(%Activity{
        agent_id: agent.id,
        ship_id: ship.id,
        kind: "miner_job_recovery",
        message: "Retrying recovery",
        metadata: %{"outcome" => "transport_error", "retry" => 2}
      })

      Repo.insert!(%Activity{
        agent_id: agent.id,
        ship_id: ship.id,
        kind: "recovery",
        message: "Recovery confirmed",
        metadata: %{"outcome" => "confirmed", "delta" => "cargo +5"},
        inserted_at: newer,
        updated_at: newer
      })

      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")
      html = render(lv)

      assert html =~ "Miner Job configuration changed"
      assert html =~ "Recovery confirmed"
      assert html =~ "outcome: confirmed"
      assert html =~ "delta: cargo +5"
      refute html =~ "Retrying recovery"

      assert :binary.match(html, "Miner Job configuration changed") <
               :binary.match(html, "Recovery confirmed")
    end

    test "shows the effective sellable payload and jettison activity while drafts stay patch-safe",
         %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "active",
        status: "active",
        sellable_goods: ["IRON_ORE"]
      })

      Repo.insert!(%Activity{
        agent_id: agent.id,
        ship_id: ship.id,
        kind: "miner_job_jettison",
        message: "Jettisoned 6 COPPER_ORE at X1-UX81-A2 (X1-UX81-A1 will not buy it)",
        metadata: %{"jettison" => "COPPER_ORE 6"}
      })

      stub_live_game(
        agent_overview_body(agent.symbol),
        [
          ship_body("ORBITALIST-1", %{
            "cargo" => %{
              "capacity" => 40,
              "units" => 16,
              "inventory" => [
                %{"symbol" => "IRON_ORE", "units" => 10},
                %{"symbol" => "COPPER_ORE", "units" => 6}
              ]
            }
          })
        ]
      )

      {:ok, lv, _html} = live(conn, ~p"/")
      html = render(lv)

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-sellable]",
               "10 / 30 sellable units"
             )

      assert html =~ "Jettisoned 6 COPPER_ORE at X1-UX81-A2"
      assert html =~ "jettison: COPPER_ORE 6"

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"miner-job-form-ORBITALIST-1\"]")
      |> render_change(%{
        draft_key: "miner_job:ORBITALIST-1",
        ship_symbol: "ORBITALIST-1",
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: "55"
      })

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")
      assert has_element?(lv, "[data-job-sellable]", "10 / 30 sellable units")
    end

    test "surfaces pending contract delivery in the panel and lets drafts survive live patches",
         %{
           conn: conn,
           operator: operator
         } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

      Repo.insert!(%Job{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "active",
        status: "active",
        sellable_goods: ["IRON_ORE"],
        contract_deliverables: [
          %{
            "contract_id" => "ctr-1",
            "destination_symbol" => "X1-UX81-A1",
            "trade_symbol" => "IRON_ORE",
            "units_required" => 100,
            "units_fulfilled" => 60,
            "units_remaining" => 40
          }
        ]
      })

      Repo.insert!(%Activity{
        agent_id: agent.id,
        ship_id: ship.id,
        kind: "miner_job_deliver",
        message: "Delivered 40 IRON_ORE to contract ctr-1 at X1-UX81-A1; 60 remain",
        metadata: %{"deliver" => "IRON_ORE 40", "remaining" => "60 remain"}
      })

      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "[data-ship-card=\"ORBITALIST-1\"] [data-job-pending-delivery]",
               "IRON_ORE 40 due here"
             )

      assert html =~ "Delivered 40 IRON_ORE to contract ctr-1"
      assert html =~ "deliver: IRON_ORE 40"
      assert html =~ "remaining: 60 remain"

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"miner-job-form-ORBITALIST-1\"]")
      |> render_change(%{
        draft_key: "miner_job:ORBITALIST-1",
        ship_symbol: "ORBITALIST-1",
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: "55"
      })

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")
      assert has_element?(lv, "[data-job-pending-delivery]", "IRON_ORE 40 due here")

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")
      assert has_element?(lv, "[data-job-pending-delivery]", "IRON_ORE 40 due here")
    end

    test "keeps an in-progress Miner Job draft across live patches", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"miner-job-form-ORBITALIST-1\"]")
      |> render_change(%{
        draft_key: "miner_job:ORBITALIST-1",
        ship_symbol: "ORBITALIST-1",
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: "55"
      })

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "extraction_waypoint") =~
               ~s(value="X1-UX81-A2")

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "market_waypoint") =~
               ~s(value="X1-UX81-A1")

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "extraction_waypoint") =~
               ~s(value="X1-UX81-A2")

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "market_waypoint") =~
               ~s(value="X1-UX81-A1")

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "extraction_waypoint") =~
               ~s(value="X1-UX81-A2")

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "market_waypoint") =~
               ~s(value="X1-UX81-A1")

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "cargo_threshold") =~ ~s(value="55")
    end

    test "keeps a siphon gather-mode draft across cooldown ticks and fleet pushes", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"miner-job-form-ORBITALIST-1\"]")
      |> render_change(%{
        draft_key: "miner_job:ORBITALIST-1",
        ship_symbol: "ORBITALIST-1",
        gather_mode: "siphon",
        extraction_waypoint: "X1-UX81-A3",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: "55"
      })

      assert has_element?(
               lv,
               "form#miner-job-form-ORBITALIST-1 option[value=\"siphon\"][selected]"
             )

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert has_element?(
               lv,
               "form#miner-job-form-ORBITALIST-1 option[value=\"siphon\"][selected]"
             )

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      assert has_element?(
               lv,
               "form#miner-job-form-ORBITALIST-1 option[value=\"siphon\"][selected]"
             )

      refute has_element?(
               lv,
               "form#miner-job-form-ORBITALIST-1 option[value=\"extract\"][selected]"
             )
    end

    test "clears the Miner Job draft once the configuration is saved", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"miner-job-form-ORBITALIST-1\"]")
      |> render_change(%{
        draft_key: "miner_job:ORBITALIST-1",
        ship_symbol: "ORBITALIST-1",
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: "55"
      })

      lv
      |> element("form[phx-submit=\"configure_miner_job\"]")
      |> render_submit(%{
        ship_symbol: "ORBITALIST-1",
        extraction_waypoint: "X1-UX81-A9",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: "55"
      })

      assert input_value(lv, "miner-job-form-ORBITALIST-1", "extraction_waypoint") =~
               ~s(value="X1-UX81-A9")

      refute input_value(lv, "miner-job-form-ORBITALIST-1", "extraction_waypoint") =~
               ~s(value="X1-UX81-A2")
    end

    test "keeps a navigation draft across live patches", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"navigate-form-ORBITALIST-1\"]")
      |> render_change(%{
        draft_key: "navigate:ORBITALIST-1",
        waypoint_symbol: "X1-UX81-A3"
      })

      assert input_value(lv, "navigate-form-ORBITALIST-1", "waypoint_symbol") =~
               ~s(value="X1-UX81-A3")

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "navigate-form-ORBITALIST-1", "waypoint_symbol") =~
               ~s(value="X1-UX81-A3")

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      assert input_value(lv, "navigate-form-ORBITALIST-1", "waypoint_symbol") =~
               ~s(value="X1-UX81-A3")
    end

    test "keeps a jettison draft across live patches", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      ship =
        ship_body("ORBITALIST-1", %{
          "cargo" => %{
            "capacity" => 40,
            "units" => 12,
            "inventory" => [
              %{"symbol" => "PRECIOUS_STONES", "name" => "Precious Stones", "units" => 12}
            ]
          }
        })

      stub_live_game(agent_overview_body(agent.symbol), [ship])

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element(
        "form[phx-change=\"track_draft\"][id=\"jettison-form-ORBITALIST-1-PRECIOUS_STONES\"]"
      )
      |> render_change(%{
        draft_key: "jettison:ORBITALIST-1:PRECIOUS_STONES",
        symbol: "ORBITALIST-1",
        trade_symbol: "PRECIOUS_STONES",
        units: "4"
      })

      assert input_value(lv, "jettison-form-ORBITALIST-1-PRECIOUS_STONES", "units") =~
               ~s(value="4")

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert input_value(lv, "jettison-form-ORBITALIST-1-PRECIOUS_STONES", "units") =~
               ~s(value="4")

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      assert input_value(lv, "jettison-form-ORBITALIST-1-PRECIOUS_STONES", "units") =~
               ~s(value="4")
    end

    test "announces the extraction yield and refreshes cargo and cooldown", %{
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
                  "nav" => nav_body("IN_ORBIT"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
                })
              ]
            })

          {"/v2/my/ships/ORBITALIST-1/extract", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "ORBITALIST-1",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60
                },
                "extraction" => %{
                  "shipSymbol" => "ORBITALIST-1",
                  "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 5,
                  "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
                }
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "0 / 40"
      refute html =~ "Extracted 5 IRON_ORE."

      html = lv |> element("button[phx-click=\"extract\"]") |> render_click()

      assert html =~ "Extracted 5 IRON_ORE."
      assert html =~ "5 / 40"
      assert html =~ "IRON_ORE"
      assert html =~ "Cooldown 60s"
    end

    test "announces the siphon yield and explains gas giant readiness", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        ship_body("ORBITALIST-1", %{
          "nav" => nav_body("IN_ORBIT"),
          "modules" => [%{"symbol" => "MODULE_GAS_PROCESSOR_I", "name" => "Gas Processor I"}],
          "mounts" => [%{"symbol" => "MOUNT_GAS_SIPHON_I", "name" => "Gas Siphon I"}],
          "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => [ship]})

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(conn, %{"data" => ship})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "GAS_GIANT",
                "x" => 1,
                "y" => 2
              }
            })

          {"/v2/my/ships/ORBITALIST-1/siphon", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "ORBITALIST-1",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60
                },
                "siphon" => %{
                  "shipSymbol" => "ORBITALIST-1",
                  "yield" => %{"symbol" => "LIQUID_HYDROGEN", "units" => 7}
                },
                "cargo" => %{
                  "capacity" => 40,
                  "units" => 7,
                  "inventory" => [%{"symbol" => "LIQUID_HYDROGEN", "units" => 7}]
                }
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "GAS_GIANT",
                  "x" => 1,
                  "y" => 2
                }
              ]
            })
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Gas Processor I"
      assert html =~ "Gas Siphon I"
      assert html =~ "The dashboard does not currently purchase or outfit"
      refute html =~ "Siphoned 7 LIQUID_HYDROGEN."

      html = lv |> element("button[phx-click=\"siphon\"]") |> render_click()

      assert html =~ "Siphoned 7 LIQUID_HYDROGEN."
      assert html =~ "7 / 40"
      assert html =~ "LIQUID_HYDROGEN"
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

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            nav =
              case Agent.get(state, & &1.arrival) do
                nil -> nav_body("DOCKED")
                arrival -> nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
              end

            Req.Test.json(conn, %{"data" => ship_body("ORBITALIST-1", %{"nav" => nav})})

          {"/v2/my/ships/ORBITALIST-1/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

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
      assert html =~ "Waypoint symbol"
      assert html =~ "This ship is in transit; actions resume on arrival."
      assert has_element?(lv, ~s([data-manual-intent="waiting"]))
    end

    test "previews a remote jump before it dispatches", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.request_path, conn.method})

        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-1", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-G1")
                })
              ]
            })

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-1", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-G1")
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

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE"
                }
              ]
            })
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form[phx-submit=\"navigate\"]")
      |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X2-UX81-G1"})

      assert has_element?(lv, "[data-jump-preview]", "Jump route ready for review")
      assert has_element?(lv, "[data-jump-preview]", "X1-UX81-G1 to X2-UX81-G1")
      assert has_element?(lv, "[data-jump-preview]", "1000 credits for one antimatter charge.")
      assert has_element?(lv, "[data-jump-candidates]", "X1-UX81-G1")
      assert has_element?(lv, "[data-jump-candidates]", "viable")
      refute_received {:request, "/v2/my/ships/ORBITALIST-1/jump", "POST"}
    end

    test "keeps outcome-level Navigate available during a live cooldown and waits it out", %{
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
                    "remainingSeconds" => 42
                  }
                })
              ]
            })

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-1", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "cooldown" => %{
                    "shipSymbol" => "ORBITALIST-1",
                    "totalSeconds" => 60,
                    "remainingSeconds" => 42,
                    "expiration" => future_iso(42)
                  }
                })
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Cooldown 42s"

      # The outcome-level Navigate control is not gated by the cooldown: its
      # Intent waits for the authoritative cooldown instead of refusing.
      assert has_element?(
               lv,
               "form[phx-submit=\"navigate\"] button[type=\"submit\"]:not([disabled])"
             )

      html =
        lv
        |> element("form[phx-submit=\"navigate\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X1-UX81-A2"})

      assert html =~ "ORBITALIST-1 will navigate to X1-UX81-A2 once its cooldown ends."
      assert has_element?(lv, ~s([data-manual-intent="waiting"]))

      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "ORBITALIST-1")
      Timeline.cancel_events(:ship, "ORBITALIST-1", :cooldown)
      ShipServer.cancel_pending("ORBITALIST-1")
    end

    test "exposes the active Navigate Intent with Stop and keeps posture actions disclosed", %{
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
            Req.Test.json(
              conn,
              %{"data" => [ship_body("ORBITALIST-1", %{"nav" => nav_body("IN_ORBIT")})]}
            )

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(
              conn,
              %{"data" => ship_body("ORBITALIST-1", %{"nav" => nav_body("IN_ORBIT")})}
            )

          {"/v2/my/ships/ORBITALIST-1/navigate", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 200, "current" => 80},
                "nav" => nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")

      # Posture-level actions stay available through progressive disclosure.
      assert has_element?(lv, "[data-posture-actions] button[phx-click=\"dock\"]")
      assert has_element?(lv, "[data-posture-actions] button[phx-click=\"refuel\"]")

      lv
      |> element("form[phx-submit=\"navigate\"]")
      |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X1-UX81-A2"})

      assert has_element?(lv, ~s([data-manual-intent="waiting"]))
      assert has_element?(lv, "[data-manual-intent]", "X1-UX81-A2")

      html = lv |> element("[data-manual-intent] button", "Stop") |> render_click()

      assert html =~ "ORBITALIST-1 manual Navigate stopped"
      refute has_element?(lv, "[data-manual-intent]")
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

    test "compares ship offers by price, availability, engine speed, fuel and crew", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_shipyard_offers(agent, [ship_offer_body()])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Light Freighter"
      assert html =~ "70,000 cr"
      assert html =~ "Supply SCARCE"
      assert html =~ "Speed 2"
      assert html =~ "Fuel 300"
      assert html =~ "Crew 4"
    end

    test "discloses a ship offer's Specifications with description, components, modules and mounts",
         %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      stub_shipyard_offers(agent, [ship_offer_body()])

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "A small freighter for light trading runs."
      assert html =~ "Freighter"
      assert html =~ "300 fuel, 4 slots, 2 mounts"
      assert html =~ "Fission I"
      assert html =~ "5 power"
      assert html =~ "Ion Drive I"
      assert html =~ "speed 2"
      assert html =~ "Modules"
      assert html =~ "Cargo Hold I"
      assert html =~ "capacity 20"
      assert html =~ "Mounts"
      assert html =~ "Mining Laser I"
      assert html =~ "strength 10"
      assert has_element?(lv, "details[data-ship-offer-specs] summary", "Specifications")
    end

    test "disables Buy for a known unaffordable ship offer and keeps an affordable one available",
         %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> %{bought: false} end)

      ships = [
        ship_offer_body(),
        ship_offer_body(%{
          "type" => "SHIP_MINING_DRONE",
          "name" => "Mining Drone",
          "purchasePrice" => 50
        })
      ]

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
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => ships}})

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

      assert html =~ "42,000"
      assert html =~ "Light Freighter"
      assert html =~ "Mining Drone"

      assert has_element?(
               lv,
               "[data-ship-offer=\"SHIP_LIGHT_FREIGHTER\"] button[type=\"submit\"][disabled]"
             )

      refute has_element?(
               lv,
               "[data-ship-offer=\"SHIP_MINING_DRONE\"] button[type=\"submit\"][disabled]"
             )

      html =
        lv
        |> element("[data-ship-offer=\"SHIP_MINING_DRONE\"] form[phx-submit=\"buy_ship\"]")
        |> render_submit()

      assert html =~ "SHIP_MINING_DRONE purchased"
      assert html =~ "ORBITALIST-2"
    end

    test "keeps Buy available when the agent credits are unknown", %{
      conn: conn,
      operator: operator
    } do
      _agent = agent_fixture(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            conn
            |> Map.put(:status, 400)
            |> Req.Test.json(%{
              "error" => %{"code" => 4000, "message" => "Agent overview unavailable"}
            })

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1")]})

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
              "data" => %{"symbol" => "X1-UX81-A1", "ships" => [ship_offer_body()]}
            })
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Agent overview unavailable"
      assert html =~ "Light Freighter"
      refute has_element?(lv, "[data-ship-offer=\"SHIP_LIGHT_FREIGHTER\"] button[disabled]")
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

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"negotiate-form-#{agent.id}\"]")
      |> render_change(%{
        draft_key: "negotiate:#{agent.id}",
        agent_id: agent.id,
        ship_symbol: "ORBITALIST-1"
      })

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert has_element?(
               lv,
               "form[phx-submit=\"negotiate_contract\"] option[value=\"ORBITALIST-1\"][selected]"
             )

      html =
        lv
        |> element("form[phx-submit=\"negotiate_contract\"]")
        |> render_submit(%{agent_id: agent.id, ship_symbol: "ORBITALIST-1"})

      assert html =~ "New contract negotiated."
      assert html =~ "Accept contract"
      refute html =~ "Negotiate a new contract"
    end

    test "shows reward, faction and acceptance deadline on a pending contract", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      accept_by = future_iso()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                pending_contract_body(accept_by)
              ]
            })

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Reward: 1,000 cr on acceptance, 5,000 cr on fulfillment"
      assert html =~ ~s(Issued by <span class="font-mono">COSMIC</span>)
      assert html =~ "Accept by #{deadline_label_for(accept_by)}"
      refute html =~ "Complete by"

      assert has_element?(
               lv,
               "form[phx-submit=\"accept_contract\"] button:not([disabled])",
               "Accept contract"
             )
    end

    test "collapses an unaccepted contract when the acceptance deadline has elapsed", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      accept_by = past_iso()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                pending_contract_body(accept_by)
              ]
            })

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "button#toggle-historical-contracts-#{agent.id}",
               "Show historical (1)"
             )

      refute has_element?(lv, "details[data-contract-id=\"ctr-pending\"]")
      refute has_element?(lv, "form[phx-submit=\"accept_contract\"]")

      lv
      |> element("button#toggle-historical-contracts-#{agent.id}")
      |> render_click()

      assert has_element?(lv, "details[data-contract-id=\"ctr-pending\"]")
      refute has_element?(lv, "details[data-contract-id=\"ctr-pending\"][open]")
      assert render(lv) =~ "Accept by #{deadline_label_for(accept_by)}"
      assert render(lv) =~ "EXPIRED"
    end

    test "shows the completion deadline on an accepted contract and hides expiration", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      complete_by = future_iso()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => "ctr-accepted",
                  "accepted" => true,
                  "fulfilled" => false,
                  "factionSymbol" => "COSMIC",
                  "type" => "PROCUREMENT",
                  "expiration" => "2025-01-01T00:00:00.000Z",
                  "terms" => %{
                    "deadline" => complete_by,
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
            })

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Reward: 1,000 cr on acceptance, 5,000 cr on fulfillment"
      assert html =~ ~s(Issued by <span class="font-mono">COSMIC</span>)
      assert html =~ "Complete by #{deadline_label_for(complete_by)}"
      refute html =~ "Accept by"
      refute html =~ "expiration"
      refute html =~ "2025-01-01"
      refute has_element?(lv, "form[phx-submit=\"accept_contract\"]")
    end

    test "hides historical contracts behind a filter while keeping active contracts visible", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      contracts = [
        contract_body(%{"id" => "ctr-fulfilled", "fulfilled" => true}),
        contract_body(%{"id" => "ctr-pending-expired", "deadlineToAccept" => past_iso()}),
        contract_body(%{
          "id" => "ctr-accepted-expired",
          "accepted" => true,
          "deadlineToAccept" => past_iso(),
          "terms" => %{
            "deadline" => past_iso(),
            "deliver" => [],
            "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
          }
        }),
        contract_body(%{"id" => "ctr-active", "accepted" => true}),
        contract_body(%{"id" => "ctr-unknown", "deadlineToAccept" => nil})
      ]

      stub_contract_game(agent, contracts)

      {:ok, lv, html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "button#toggle-historical-contracts-#{agent.id}",
               "Show historical (3)"
             )

      for contract_id <- ["ctr-fulfilled", "ctr-pending-expired", "ctr-accepted-expired"] do
        refute has_element?(lv, "details[data-contract-id=\"#{contract_id}\"]")
      end

      assert has_element?(lv, "details[data-contract-id=\"ctr-active\"][open]")
      assert has_element?(lv, "details[data-contract-id=\"ctr-unknown\"][open]")
      assert html =~ "ctr-active"
      assert html =~ "ctr-unknown"

      lv
      |> element("button#toggle-historical-contracts-#{agent.id}")
      |> render_click()

      for contract_id <- ["ctr-fulfilled", "ctr-pending-expired", "ctr-accepted-expired"] do
        assert has_element?(lv, "details[data-contract-id=\"#{contract_id}\"]")
        refute has_element?(lv, "details[data-contract-id=\"#{contract_id}\"][open]")
      end

      assert has_element?(
               lv,
               "button#toggle-historical-contracts-#{agent.id}",
               "Hide historical (3)"
             )

      assert render(lv) =~ "FULFILLED"
      assert render(lv) =~ "EXPIRED"
    end

    test "treats only historical contracts as non-actionable", %{conn: conn, operator: operator} do
      agent = agent_fixture(operator)

      stub_contract_game(agent, [
        contract_body(%{"id" => "ctr-expired", "deadlineToAccept" => past_iso()})
      ])

      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Negotiate a new contract"
      refute has_element?(lv, "form[phx-submit=\"accept_contract\"]")
      refute has_element?(lv, "form[phx-submit=\"deliver_contract\"]")
      refute has_element?(lv, "form[phx-submit=\"fulfill_contract\"]")
    end

    test "prefills a partial contract delivery from an eligible ship", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "id" => "ctr-partial-delivery",
                  "accepted" => true,
                  "fulfilled" => false,
                  "factionSymbol" => "COSMIC",
                  "type" => "PROCUREMENT",
                  "terms" => %{
                    "deadline" => future_iso(),
                    "deliver" => [
                      %{
                        "tradeSymbol" => "COPPER_ORE",
                        "destinationSymbol" => "X1-UX81-A2",
                        "unitsRequired" => 53,
                        "unitsFulfilled" => 0
                      }
                    ],
                    "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
                  }
                }
              ]
            })

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-3", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A2"),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 9,
                    "inventory" => [
                      %{
                        "symbol" => "COPPER_ORE",
                        "name" => "Copper Ore",
                        "description" => "Ore",
                        "units" => 9
                      }
                    ]
                  }
                }),
                ship_body("ORBITALIST-4", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A1"),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 9,
                    "inventory" => [
                      %{
                        "symbol" => "COPPER_ORE",
                        "name" => "Copper Ore",
                        "description" => "Ore",
                        "units" => 9
                      }
                    ]
                  }
                }),
                ship_body("ORBITALIST-5", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A2")
                }),
                ship_body("ORBITALIST-6", %{
                  "nav" => nav_body("IN_TRANSIT", destination: "X1-UX81-A2"),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 9,
                    "inventory" => [
                      %{
                        "symbol" => "COPPER_ORE",
                        "name" => "Copper Ore",
                        "description" => "Ore",
                        "units" => 9
                      }
                    ]
                  }
                })
              ]
            })

          {"/v2/my/ships/ORBITALIST-3", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("ORBITALIST-3", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A2"),
                  "cargo" => %{
                    "capacity" => 40,
                    "units" => 9,
                    "inventory" => [
                      %{
                        "symbol" => "COPPER_ORE",
                        "name" => "Copper Ore",
                        "description" => "Ore",
                        "units" => 9
                      }
                    ]
                  }
                })
            })

          {"/v2/my/contracts/ctr-partial-delivery/deliver", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "contract" => %{
                  "id" => "ctr-partial-delivery",
                  "accepted" => true,
                  "fulfilled" => false,
                  "factionSymbol" => "COSMIC",
                  "type" => "PROCUREMENT",
                  "terms" => %{
                    "deadline" => future_iso(),
                    "deliver" => [
                      %{
                        "tradeSymbol" => "COPPER_ORE",
                        "destinationSymbol" => "X1-UX81-A2",
                        "unitsRequired" => 53,
                        "unitsFulfilled" => 9
                      }
                    ],
                    "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
                  }
                }
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(
               lv,
               "form[phx-submit=\"deliver_contract\"] input[type=\"hidden\"][name=\"ship_symbol\"][value=\"ORBITALIST-3\"]"
             )

      assert has_element?(lv, "form[phx-submit=\"deliver_contract\"]", "ORBITALIST-3")
      refute has_element?(lv, "form[phx-submit=\"deliver_contract\"]", "ORBITALIST-4")
      refute has_element?(lv, "form[phx-submit=\"deliver_contract\"]", "ORBITALIST-5")
      refute has_element?(lv, "form[phx-submit=\"deliver_contract\"]", "ORBITALIST-6")

      assert has_element?(
               lv,
               "form[phx-submit=\"deliver_contract\"] input[name=\"units\"][value=\"9\"][max=\"9\"][required]"
             )

      html =
        lv
        |> element("form[phx-submit=\"deliver_contract\"]")
        |> render_submit(%{
          agent_id: agent.id,
          contract_id: "ctr-partial-delivery",
          ship_symbol: "ORBITALIST-3",
          trade_symbol: "COPPER_ORE",
          units: "9"
        })

      assert html =~ "Delivered 9 COPPER_ORE."
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

    test "recovers a fuel-starved ship through orbit, DRIFT, navigation, refueling, and CRUISE",
         %{
           conn: conn,
           operator: operator
         } do
      agent = agent_fixture(operator)

      {:ok, state} =
        Agent.start_link(fn ->
          %{
            status: "DOCKED",
            mode: "CRUISE",
            fuel: 81,
            destination: "X1-UX81-B21",
            arrival: nil,
            consumed: nil
          }
        end)

      ship_from_state = fn ->
        %{status: status, mode: mode, fuel: fuel, destination: destination} =
          Agent.get(state, & &1)

        arrival = Agent.get(state, & &1.arrival)
        consumed = Agent.get(state, & &1.consumed)

        nav_overrides = if arrival, do: [arrival: arrival], else: []

        nav =
          nav_body(status, [destination: destination] ++ nav_overrides)
          |> Map.put("flightMode", mode)

        fuel_body =
          if consumed,
            do: %{"capacity" => 400, "current" => fuel, "consumed" => %{"amount" => consumed}},
            else: %{"capacity" => 400, "current" => fuel}

        ship_body("ORBITALIST-1", %{"nav" => nav, "fuel" => fuel_body})
      end

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{"data" => [ship_from_state.()]})

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_from_state.()})

          {"/v2/my/ships/ORBITALIST-1/orbit", "POST"} ->
            Agent.update(state, &%{&1 | status: "IN_ORBIT"})
            destination = Agent.get(state, & &1.destination)

            Req.Test.json(
              conn,
              %{"data" => %{"nav" => nav_body("IN_ORBIT", destination: destination)}}
            )

          {"/v2/my/ships/ORBITALIST-1/nav", "PATCH"} ->
            %{"flightMode" => mode} = conn.body_params
            Agent.update(state, &%{&1 | mode: mode})

            %{status: status, fuel: fuel} = Agent.get(state, & &1)

            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 400, "current" => fuel},
                "nav" => nav_body(status) |> Map.put("flightMode", mode),
                "events" => []
              }
            })

          {"/v2/my/ships/ORBITALIST-1/navigate", "POST"} ->
            assert conn.body_params == %{"waypointSymbol" => "X1-UX81-C43"}

            Agent.update(
              state,
              &%{
                &1
                | status: "IN_TRANSIT",
                  fuel: 80,
                  destination: "X1-UX81-C43",
                  arrival: future_iso(),
                  consumed: 1
              }
            )

            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 400, "current" => 80, "consumed" => %{"amount" => 1}},
                "nav" =>
                  nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-C43")
                  |> Map.put("flightMode", "DRIFT")
              }
            })

          {"/v2/my/ships/ORBITALIST-1/dock", "POST"} ->
            Agent.update(state, &%{&1 | status: "DOCKED"})
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("DOCKED")}})

          {"/v2/my/ships/ORBITALIST-1/refuel", "POST"} ->
            Agent.update(state, &%{&1 | fuel: 400})

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{},
                "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                "fuel" => %{"capacity" => 400, "current" => 400},
                "transaction" => %{}
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "81 / 400"

      lv |> element("button[phx-click=\"orbit\"]") |> render_click()

      html =
        lv
        |> element("form[phx-submit=\"set_flight_mode\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", flight_mode: "DRIFT"})

      assert html =~ "ORBITALIST-1 flight mode set to DRIFT."
      assert html =~ "DRIFT"

      lv
      |> element("form[phx-submit=\"navigate\"]")
      |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X1-UX81-C43"})

      assert has_element?(lv, "[data-route-details]", "X1-UX81-C43")
      assert has_element?(lv, "[data-route-details]", "1 fuel")

      Timeline.cancel_events(:ship, "ORBITALIST-1", :arrival)
      ShipServer.cancel_pending("ORBITALIST-1")

      # Simulate the authoritative post-arrival game state before the wakeup.
      Agent.update(state, &%{&1 | status: "IN_ORBIT", arrival: nil})

      send(lv.pid, {:ship_updated, agent.id, "ORBITALIST-1"})
      render(lv)

      lv |> element("button[phx-click=\"dock\"]") |> render_click()
      html = lv |> element("button[phx-click=\"refuel\"]") |> render_click()
      assert html =~ "400 / 400"

      html =
        lv
        |> element("form[phx-submit=\"set_flight_mode\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", flight_mode: "CRUISE"})

      assert html =~ "ORBITALIST-1 flight mode set to CRUISE."
    end

    test "keeps a flight-mode draft when the game rejects the change", %{
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
            Req.Test.json(conn, %{"data" => [ship_body("ORBITALIST-1")]})

          {"/v2/my/ships/ORBITALIST-1/nav", "PATCH"} ->
            conn
            |> Map.put(:status, 400)
            |> Req.Test.json(%{"error" => %{"code" => 4214, "message" => "Ship is in transit"}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"flight-mode-form-ORBITALIST-1\"]")
      |> render_change(%{draft_key: "flight_mode:ORBITALIST-1", flight_mode: "DRIFT"})

      html =
        lv
        |> element("form[phx-submit=\"set_flight_mode\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", flight_mode: "DRIFT"})

      assert html =~ "Ship is in transit"

      assert has_element?(
               lv,
               "form#flight-mode-form-ORBITALIST-1 option[value=\"DRIFT\"][selected]"
             )
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

    test "renders a system map and reveals a selected waypoint's identity", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      ship =
        Repo.insert!(%Ship{
          symbol: "ORBITALIST-1",
          ship_type: "SHIP_COMMAND_FRIGATE",
          agent_id: agent.id
        })

      Repo.insert!(%ShipDestination{
        ship_id: ship.id,
        waypoint_symbol: "X1-UX81-A99",
        position: 0
      })

      {:ok, state} = Agent.start_link(fn -> %{transit: false} end)

      waypoints = [
        %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "ORBITAL_STATION",
          "x" => -12,
          "y" => 8,
          "traits" => [%{"symbol" => "MARKETPLACE"}, %{"symbol" => "SHIPYARD"}]
        },
        %{
          "symbol" => "X1-UX81-A3",
          "systemSymbol" => "X1-UX81",
          "type" => "ENGINEERED_ASTEROID",
          "x" => 14,
          "y" => -6,
          "traits" => [%{"symbol" => "MINERAL_DEPOSITS"}, %{"symbol" => "MARKETPLACE"}]
        },
        %{
          "symbol" => "X1-UX81-B1",
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => 4,
          "y" => 19,
          "traits" => [%{"symbol" => "MARKETPLACE"}],
          "orbitals" => [%{"symbol" => "X1-UX81-B2"}]
        },
        %{
          "symbol" => "X1-UX81-B2",
          "systemSymbol" => "X1-UX81",
          "type" => "MOON",
          "x" => 4,
          "y" => 19,
          "orbits" => "X1-UX81-B1",
          "traits" => []
        },
        %{
          "symbol" => "X1-UX81-C1",
          "systemSymbol" => "X1-UX81",
          "type" => "JUMP_GATE",
          "traits" => []
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
                nav_body("IN_ORBIT")
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
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "exports" => [%{"symbol" => "FERTILIZERS", "name" => "Fertilizers"}],
                "imports" => [%{"symbol" => "IRON_ORE", "name" => "Iron Ore"}],
                "tradeGoods" => []
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-C1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-C1", "connections" => []}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A3/market", "GET"} ->
            conn
            |> Map.put(:status, 400)
            |> Req.Test.json(%{"error" => %{"message" => "Market data unavailable"}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-B1/market", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-B1", "tradeGoods" => []}})
        end
      end)

      {:ok, lv, html} = live(conn, ~p"/")
      assert has_element?(lv, "svg[data-system-map]")

      assert has_element?(
               lv,
               "[data-waypoint-symbol=\"X1-UX81-A1\"][data-x=\"-12\"][data-y=\"8\"]"
             )

      assert has_element?(
               lv,
               "[data-waypoint-symbol=\"X1-UX81-A3\"][data-x=\"14\"][data-y=\"-6\"]"
             )

      assert has_element?(
               lv,
               "[data-waypoint-symbol=\"X1-UX81-B2\"][data-orbital-offset-x=\"0.0\"][data-orbital-offset-y=\"-1.0\"][data-orbital-distance=\"32\"]"
             )

      assert html =~ "Type markers"

      assert has_element?(
               lv,
               "datalist#destination-history-ORBITALIST-1 option[value=\"X1-UX81-A99\"]"
             )

      assert has_element?(lv, "[data-map-control=\"zoom-in\"]")
      refute has_element?(lv, "[data-map-inspector]")

      html =
        lv
        |> element("[data-waypoint-symbol=\"X1-UX81-A3\"]")
        |> render_click()

      assert html =~ "X1-UX81-A3"
      assert html =~ "ENGINEERED_ASTEROID"
      assert html =~ "MINERAL_DEPOSITS"
      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A3\"].selected")
      assert has_element?(lv, "form[phx-submit=\"browser_navigate\"]")

      assert has_element?(
               lv,
               "form[phx-submit=\"browser_navigate\"] option[value=\"X1-UX81-A99\"]"
             )

      assert has_element?(lv, "[data-map-inspector]")

      html =
        lv
        |> element("[data-waypoint-symbol=\"X1-UX81-B1\"]")
        |> render_click()

      assert html =~ "Orbital relationship"
      assert html =~ "X1-UX81-B2"

      html =
        lv
        |> element("[data-waypoint-row=\"X1-UX81-C1\"]")
        |> render_click()

      assert html =~ "X1-UX81-C1"
      assert has_element?(lv, "[data-map-inspector]")

      lv
      |> element("button[aria-label=\"Close waypoint inspector\"]")
      |> render_click()

      refute has_element?(lv, "[data-map-inspector]")
    end

    test "exposes Waypoint Intelligence and Chart Provenance in the waypoint inspector", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      submitted_on = "2026-08-10T12:34:56Z"
      {:ok, charted_at, _offset} = DateTime.from_iso8601(submitted_on)
      charted_label = Calendar.strftime(charted_at, "%m-%d %H:%M UTC")

      waypoints = [
        %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "JUMP_GATE",
          "x" => -12,
          "y" => 8,
          "isUnderConstruction" => true,
          "modifiers" => [
            %{
              "symbol" => "STRIPPED",
              "name" => "Stripped",
              "description" => "The waypoint's resources have been stripped."
            },
            %{
              "symbol" => "UNSTABLE",
              "name" => "Unstable",
              "description" => "The waypoint's structure is unstable."
            }
          ],
          "faction" => %{"symbol" => "COSMIC"},
          "chart" => %{"submittedBy" => "ORBITALIST", "submittedOn" => submitted_on},
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        },
        %{
          "symbol" => "X1-UX81-A3",
          "systemSymbol" => "X1-UX81",
          "type" => "ENGINEERED_ASTEROID",
          "x" => 14,
          "y" => -6,
          "traits" => [%{"symbol" => "MINERAL_DEPOSITS"}, %{"symbol" => "MARKETPLACE"}]
        },
        %{
          "symbol" => "X1-UX81-B1",
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => 4,
          "y" => 19,
          "chart" => %{"submittedOn" => submitted_on},
          "traits" => []
        }
      ]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [ship_body("ORBITALIST-1", %{"nav" => nav_body("IN_ORBIT")})]
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            case conn.query_params["page"] do
              "1" -> Req.Test.json(conn, %{"data" => waypoints})
              _ -> Req.Test.json(conn, %{"data" => []})
            end

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "exports" => [%{"symbol" => "FERTILIZERS", "name" => "Fertilizers"}],
                "imports" => [%{"symbol" => "IRON_ORE", "name" => "Iron Ore"}],
                "tradeGoods" => []
              }
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

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-A1", "connections" => ["X1-TEST-A1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A3/market", "GET"} ->
            conn
            |> Map.put(:status, 400)
            |> Req.Test.json(%{"error" => %{"message" => "Market data unavailable"}})
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("[data-waypoint-symbol=\"X1-UX81-A1\"]")
      |> render_click()

      inspector_html = lv |> element("[data-map-inspector]") |> render()

      assert inspector_html =~ "Waypoint Intelligence"
      assert has_element?(lv, "[data-waypoint-market]", "Market Signals")
      assert has_element?(lv, "[data-waypoint-market]", "FERTILIZERS")
      assert has_element?(lv, "[data-waypoint-market]", "IRON_ORE")
      assert inspector_html =~ "Under construction"
      assert inspector_html =~ "STRIPPED"
      assert inspector_html =~ "UNSTABLE"
      assert has_element?(lv, "[data-waypoint-intelligence]")
      assert has_element?(lv, "[data-construction-status]", "Under construction")
      assert has_element?(lv, "[data-readiness=\"construction\"]", "material:IRON_ORE:remaining")
      assert has_element?(lv, "[data-readiness=\"construction\"]", "13")
      assert has_element?(lv, "[data-readiness=\"jump_gate\"]", "X1-TEST-A1")
      assert has_element?(lv, "details[data-modifier=\"STRIPPED\"] summary", "Stripped")

      assert has_element?(
               lv,
               "details[data-modifier=\"STRIPPED\"]",
               "The waypoint's resources have been stripped."
             )

      assert has_element?(
               lv,
               "details[data-modifier=\"UNSTABLE\"]",
               "The waypoint's structure is unstable."
             )

      assert has_element?(lv, "[data-waypoint-context]")
      assert has_element?(lv, "[data-waypoint-context]", "COSMIC")
      assert has_element?(lv, "[data-waypoint-context]", "ORBITALIST")
      assert has_element?(lv, "[data-waypoint-context]", charted_label)

      assert_before(inspector_html, "Waypoint Intelligence", "Traits")
      assert_before(inspector_html, "Under construction", "STRIPPED")
      assert_before(inspector_html, "Traits", "Context")

      lv
      |> element("[data-waypoint-symbol=\"X1-UX81-A3\"]")
      |> render_click()

      refute has_element?(lv, "[data-waypoint-intelligence]")
      refute has_element?(lv, "[data-waypoint-context]")
      refute render(lv) =~ "Waypoint Intelligence"
      assert has_element?(lv, "[data-map-inspector]", "Market data unavailable")

      lv
      |> element("[data-waypoint-symbol=\"X1-UX81-B1\"]")
      |> render_click()

      assert has_element?(lv, "[data-waypoint-context]")
      assert has_element?(lv, "[data-waypoint-context]", charted_label)
      refute has_element?(lv, "[data-waypoint-context]", "Controlling faction")
      refute has_element?(lv, "[data-waypoint-context]", "Chart submitter")
      refute has_element?(lv, "[data-waypoint-context]", "Unknown")
    end

    test "links the waypoint grid and system map, including filters and ship counts", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      waypoints = [
        %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "ORBITAL_STATION",
          "x" => -12,
          "y" => 8,
          "traits" => [%{"symbol" => "MARKETPLACE"}, %{"symbol" => "SHIPYARD"}]
        },
        %{
          "symbol" => "X1-UX81-A3",
          "systemSymbol" => "X1-UX81",
          "type" => "ENGINEERED_ASTEROID",
          "x" => 14,
          "y" => -6,
          "traits" => [%{"symbol" => "MINERAL_DEPOSITS"}]
        }
      ]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-1"),
                ship_body("ORBITALIST-2", %{
                  "nav" => nav_body("DOCKED", destination: "X1-UX81-A3")
                })
              ]
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

      assert html =~ "Waypoint grid"
      assert html =~ "Waypoint"
      assert html =~ "Traits"
      assert html =~ "Ships"
      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A1\"]", "1")
      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A3\"]", "1")

      _html =
        lv
        |> element("[data-waypoint-row=\"X1-UX81-A1\"]")
        |> render_keydown(%{"key" => "Enter"})

      assert has_element?(lv, "[data-waypoint-symbol=\"X1-UX81-A1\"].selected")

      html = lv |> element("[data-waypoint-row=\"X1-UX81-A3\"]") |> render_click()
      assert html =~ "MINERAL_DEPOSITS"
      assert has_element?(lv, "[data-waypoint-symbol=\"X1-UX81-A3\"].selected")
      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A3\"].selected")

      html = lv |> element("button[phx-value-filter=\"marketplace\"]") |> render_click()
      assert html =~ "X1-UX81-A1"
      refute has_element?(lv, "[data-waypoint-row=\"X1-UX81-A3\"]")
      assert has_element?(lv, "[data-waypoint-symbol=\"X1-UX81-A3\"].muted")
    end

    test "shows local fleet state without plotting off-system ships", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      waypoints = [
        %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "ORBITAL_STATION",
          "x" => -12,
          "y" => 8,
          "traits" => []
        },
        %{
          "symbol" => "X1-UX81-A3",
          "systemSymbol" => "X1-UX81",
          "type" => "ENGINEERED_ASTEROID",
          "x" => 14,
          "y" => -6,
          "traits" => []
        },
        %{
          "symbol" => "X1-UX81-B1",
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => 4,
          "y" => 19,
          "traits" => []
        },
        %{
          "symbol" => "X1-UX81-B2",
          "systemSymbol" => "X1-UX81",
          "type" => "MOON",
          "x" => 4,
          "y" => 19,
          "orbits" => "X1-UX81-B1",
          "traits" => []
        }
      ]

      transit_nav =
        nav_body("IN_TRANSIT", destination: "X1-UX81-B2")
        |> Map.put("route", %{
          "origin" => %{
            "symbol" => "X1-UX81-A1",
            "systemSymbol" => "X1-UX81",
            "type" => "ORBITAL_STATION",
            "x" => -12,
            "y" => 8
          },
          "destination" => %{
            "symbol" => "X1-UX81-B2",
            "systemSymbol" => "X1-UX81",
            "type" => "MOON",
            "x" => 4,
            "y" => 19
          },
          "departureTime" => "2026-01-01T00:00:00.000Z",
          "arrival" => future_iso(300)
        })

      inter_system_nav =
        nav_body("IN_TRANSIT", destination: "X1-OTHER-A2")
        |> Map.put("systemSymbol", "X1-OTHER")
        |> Map.put("route", %{
          "origin" => %{"symbol" => "X1-OTHER-A1", "systemSymbol" => "X1-OTHER"},
          "destination" => %{"symbol" => "X1-UX81-A1", "systemSymbol" => "X1-UX81"},
          "departureTime" => "2026-01-01T00:00:00.000Z",
          "arrival" => future_iso(300)
        })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                ship_body("ORBITALIST-1"),
                ship_body("ORBITALIST-2", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A1")
                }),
                ship_body("ORBITALIST-3", %{"nav" => transit_nav}),
                ship_body("ORBITALIST-6", %{
                  "nav" =>
                    Map.put(nav_body("IN_TRANSIT", destination: "X1-UX81-MISSING"), "route", %{
                      "origin" => %{"symbol" => "X1-UX81-A1", "systemSymbol" => "X1-UX81"},
                      "destination" => %{
                        "symbol" => "X1-UX81-MISSING",
                        "systemSymbol" => "X1-UX81"
                      },
                      "departureTime" => "2026-01-01T00:00:00.000Z",
                      "arrival" => future_iso(300)
                    })
                }),
                ship_body("ORBITALIST-4", %{
                  "nav" => Map.put(nav_body("DOCKED"), "systemSymbol", "X1-OTHER")
                }),
                ship_body("ORBITALIST-5", %{"nav" => inter_system_nav})
              ]
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            case conn.query_params["page"] do
              "1" -> Req.Test.json(conn, %{"data" => waypoints})
              _ -> Req.Test.json(conn, %{"data" => []})
            end

          {"/v2/systems/X1-OTHER/waypoints", "GET"} ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A1\"]", "2")
      assert has_element?(lv, "[data-ship-count=\"X1-UX81-A1\"]", "2")
      assert has_element?(lv, "[data-ship-count-badge=\"X1-UX81-A1\"]")
      assert has_element?(lv, "[data-transit-route=\"ORBITALIST-3\"]")

      assert has_element?(
               lv,
               "[data-transit-route=\"ORBITALIST-3\"][data-transit-destination=\"X1-UX81-B2\"]"
             )

      refute has_element?(lv, "[data-transit-route=\"ORBITALIST-6\"]")

      assert has_element?(
               lv,
               "[data-fleet-summary=\"off-system\"]",
               "1 off-system ship at another system"
             )

      assert has_element?(
               lv,
               "[data-fleet-summary=\"inter-system-transit\"]",
               "1 ship in inter-system transit"
             )

      _html = lv |> element("[data-waypoint-row=\"X1-UX81-A1\"]") |> render_click()

      assert has_element?(lv, "[data-waypoint-ships]", "ORBITALIST-1")
      assert has_element?(lv, "[data-waypoint-ships]", "DOCKED")
      assert has_element?(lv, "[data-waypoint-ships]", "ORBITALIST-2")
      assert has_element?(lv, "[data-waypoint-ships]", "IN_ORBIT")
    end

    test "keeps fleet counts unavailable when the fleet refresh fails", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          "/v2/my/ships" ->
            conn
            |> Map.put(:status, 503)
            |> Req.Test.json(%{"error" => %{"message" => "Fleet unavailable"}})

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints" ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "x" => -12,
                  "y" => 8,
                  "traits" => []
                }
              ]
            })
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A1\"]", "Unavailable")
      refute has_element?(lv, "[data-ship-count=\"X1-UX81-A1\"]")
    end

    test "does not mark local ships off-system when waypoint data is empty", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "[data-fleet-summary=\"off-system\"]")
    end

    test "navigates an orbiting local ship from shared waypoint details and preserves selection",
         %{
           conn: conn,
           operator: operator
         } do
      agent = agent_fixture(operator)
      arrival = future_iso(300)
      {:ok, state} = Agent.start_link(fn -> %{navigated: false} end)

      waypoints = [
        %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "ORBITAL_STATION",
          "x" => -12,
          "y" => 8,
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        },
        %{
          "symbol" => "X1-UX81-A3",
          "systemSymbol" => "X1-UX81",
          "type" => "ENGINEERED_ASTEROID",
          "x" => 14,
          "y" => -6,
          "traits" => [%{"symbol" => "MINERAL_DEPOSITS"}]
        }
      ]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          {"/v2/my/contracts", "GET"} ->
            Req.Test.json(conn, %{"data" => []})

          {"/v2/my/ships", "GET"} ->
            local_ship =
              if Agent.get(state, & &1.navigated) do
                ship_body("ORBITALIST-1", %{
                  "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A3")
                })
              else
                ship_body("ORBITALIST-1", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A1")
                })
              end

            off_system_ship =
              ship_body("ORBITALIST-3", %{
                "nav" => Map.put(nav_body("IN_ORBIT"), "systemSymbol", "X1-OTHER")
              })

            Req.Test.json(conn, %{
              "data" => [
                local_ship,
                ship_body("ORBITALIST-2", %{"nav" => nav_body("DOCKED")}),
                off_system_ship
              ]
            })

          {"/v2/my/ships/ORBITALIST-1", "GET"} ->
            nav =
              if Agent.get(state, & &1.navigated),
                do: nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A3"),
                else: nav_body("IN_ORBIT", destination: "X1-UX81-A1")

            Req.Test.json(conn, %{"data" => ship_body("ORBITALIST-1", %{"nav" => nav})})

          {"/v2/my/ships/ORBITALIST-1/navigate", "POST"} ->
            Agent.update(state, &%{&1 | navigated: true})

            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 200, "current" => 150},
                "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A3")
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            case conn.query_params["page"] do
              "1" -> Req.Test.json(conn, %{"data" => waypoints})
              _ -> Req.Test.json(conn, %{"data" => []})
            end

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/")

      _html = lv |> element("[data-waypoint-row=\"X1-UX81-A3\"]") |> render_click()

      assert has_element?(
               lv,
               "form[phx-submit=\"browser_navigate\"] option[value=\"ORBITALIST-1\"]"
             )

      refute has_element?(
               lv,
               "form[phx-submit=\"browser_navigate\"] option[value=\"ORBITALIST-2\"]"
             )

      refute has_element?(
               lv,
               "form[phx-submit=\"browser_navigate\"] option[value=\"ORBITALIST-3\"]"
             )

      lv
      |> element("form[phx-change=\"track_draft\"][id=\"browser-navigate-X1-UX81-A3\"]")
      |> render_change(%{
        draft_key: "browser_navigate:X1-UX81-A3",
        symbol: "ORBITALIST-1",
        waypoint_symbol: "X1-UX81-A3"
      })

      send(lv.pid, :cooldown_tick)
      render(lv)

      assert has_element?(
               lv,
               "form[phx-submit=\"browser_navigate\"] option[value=\"ORBITALIST-1\"][selected]"
             )

      html =
        lv
        |> element("form[phx-submit=\"browser_navigate\"]")
        |> render_submit(%{symbol: "ORBITALIST-1", waypoint_symbol: "X1-UX81-A3"})

      assert html =~ "ORBITALIST-1 is in transit to X1-UX81-A3."
      assert has_element?(lv, "[data-waypoint-symbol=\"X1-UX81-A3\"].selected")
      assert has_element?(lv, "[data-waypoint-row=\"X1-UX81-A3\"].selected")
      assert has_element?(lv, "[data-transit-route=\"ORBITALIST-1\"]")
      refute has_element?(lv, "form[phx-submit=\"browser_navigate\"]")
    end

    test "keeps the dashboard usable when a system map is unavailable", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [])

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => agent_overview_body(agent.symbol)})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/my/contracts" ->
            Req.Test.json(conn, %{"data" => []})

          "/v2/systems/X1-UX81/waypoints" ->
            conn
            |> Map.put(:status, 401)
            |> Req.Test.json(%{"error" => %{"message" => "System scan unavailable"}})
        end
      end)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "System map unavailable"
      assert html =~ agent.symbol
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

    test "shows one recovery card when a server reset invalidates an agent", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)

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

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Your stale Agents are no longer available"
      assert html =~ agent.symbol
      assert html =~ "Mint a replacement"
      refute html =~ "Contracts unavailable"
      assert %{stale_at: %DateTime{}} = Repo.get!(SpaceTraders.Agent.Agent, agent.id)
    end

    test "groups multiple stale agents in one recovery card", %{conn: conn, operator: operator} do
      first = agent_fixture(operator, %{symbol: "ORBITALIST"})
      second = agent_fixture(operator, %{symbol: "TURNEY"})

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

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ first.symbol
      assert html =~ second.symbol
      assert length(String.split(html, "Server reset recovery")) == 2
    end

    test "retires stale Agents from the recovery card without affecting healthy Agents", %{
      conn: conn,
      operator: operator
    } do
      agent_fixture(operator, %{
        symbol: "ORBITALIST",
        stale_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      healthy_agent = agent_fixture(operator, %{symbol: "TURNEY"})
      stub_live_game(agent_overview_body(healthy_agent.symbol), [])

      {:ok, lv, html} = live(conn, ~p"/")
      assert html =~ "Your stale Agents are no longer available"
      assert html =~ "Retire stale Agents"
      assert html =~ healthy_agent.symbol

      html = lv |> element("#retire-stale-agents") |> render_click()

      refute html =~ "Your stale Agents are no longer available"
      assert html =~ healthy_agent.symbol
      assert html =~ "Retired stale Agents: ORBITALIST."
    end

    test "explains when stale Agents were already retired", %{conn: conn, operator: operator} do
      healthy_agent = agent_fixture(operator, %{symbol: "TURNEY"})
      stub_live_game(agent_overview_body(healthy_agent.symbol), [])

      {:ok, lv, _html} = live(conn, ~p"/")

      html = render_click(lv, "retire_stale_agents")

      assert html =~ "There are no stale Agents to retire."
    end

    test "prompts to mint a first agent when the operator has none", %{conn: conn} do
      stub_live_game(agent_overview_body("UNUSED"), [])

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "minted any agents yet"
      assert html =~ "Mint an agent"
    end
  end
end
