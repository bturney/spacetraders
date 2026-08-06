defmodule SpaceTradersWeb.DashboardLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  defp stub_live_game(agent_overview, ships) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" -> Req.Test.json(conn, %{"data" => agent_overview})
        "/v2/my/ships" -> Req.Test.json(conn, %{"data" => ships})
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

  defp ship_body(symbol, overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => symbol,
        "registration" => %{
          "name" => symbol,
          "factionSymbol" => "COSMIC",
          "role" => "COMMAND"
        },
        "nav" => %{
          "systemSymbol" => "X1-UX81",
          "waypointSymbol" => "X1-UX81-A1",
          "status" => "DOCKED",
          "flightMode" => "CRUISE",
          "route" => %{
            "destination" => %{
              "symbol" => "X1-UX81-A1",
              "type" => "PLANET",
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
            "arrival" => "2026-01-01T00:00:00.000Z"
          }
        },
        "crew" => %{"current" => 1, "required" => 1, "capacity" => 1, "rotation" => "STRICT"},
        "frame" => %{
          "symbol" => "FRAME_FRIGATE",
          "name" => "Frigate",
          "description" => "A frigate",
          "moduleSlots" => 2,
          "mountingPoints" => 1,
          "fuelCapacity" => 200,
          "condition" => 100,
          "integrity" => 100,
          "requirements" => %{"power" => 1, "crew" => 1}
        },
        "reactor" => %{
          "symbol" => "REACTOR_SOLAR_I",
          "name" => "Solar I",
          "description" => "A reactor",
          "condition" => 100,
          "integrity" => 100,
          "powerOutput" => 1,
          "requirements" => %{"crew" => 1}
        },
        "engine" => %{
          "symbol" => "ENGINE_IMPULSE_DRIVE_I",
          "name" => "Impulse Drive I",
          "description" => "An engine",
          "condition" => 100,
          "integrity" => 100,
          "speed" => 1,
          "requirements" => %{"power" => 1, "crew" => 1}
        },
        "modules" => [],
        "mounts" => [],
        "fuel" => %{
          "capacity" => 200,
          "current" => 150,
          "consumed" => %{"amount" => 50, "timestamp" => "2026-01-01T00:00:00.000Z"}
        },
        "cargo" => %{
          "capacity" => 40,
          "units" => 12,
          "inventory" => [
            %{"symbol" => "IRON_ORE", "name" => "Iron Ore", "description" => "Ore", "units" => 12}
          ]
        },
        "cooldown" => %{
          "shipSymbol" => symbol,
          "totalSeconds" => 0,
          "remainingSeconds" => 0,
          "expiration" => "2026-01-01T00:00:00.000Z"
        }
      },
      overrides
    )
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
          "nav" => %{
            "systemSymbol" => "X1-UX81",
            "waypointSymbol" => "X1-UX81-A3",
            "status" => "IN_ORBIT",
            "flightMode" => "CRUISE"
          },
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
            "expiration" => "2026-01-01T00:00:00.000Z"
          }
        })
      ]

      stub_live_game(agent_overview_body(agent.symbol), ships)

      {:ok, _lv, html} = live(conn, ~p"/")

      assert html =~ "Cooldown 42s"
    end

    test "renders ship action affordances, disabled until their tickets land", %{
      conn: conn,
      operator: operator
    } do
      agent = agent_fixture(operator)
      stub_live_game(agent_overview_body(agent.symbol), [ship_body("ORBITALIST-1")])

      {:ok, _lv, html} = live(conn, ~p"/")

      for action <- ["Navigate", "Dock", "Orbit", "Extract"] do
        assert html =~ action
        assert html =~ ~s(<button type="button" disabled)
      end
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
