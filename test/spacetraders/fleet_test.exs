defmodule SpaceTraders.FleetTest do
  # navigate_ship and boot re-arm start ship GenServers, which read and write the
  # timeline as separate processes, so the sandbox must be shared (not async).
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

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

  defp navigate_response(status), do: navigate_response(status, future_iso())

  defp navigate_response(status, arrival) do
    %{
      "fuel" => %{"capacity" => 200, "current" => 80},
      "nav" => nav_body(status, arrival: arrival, destination: "X1-UX81-A2")
    }
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

  describe "command_snapshot/1" do
    test "assembles the agent overview, live fleet and on-site shipyard listings" do
      agent = agent_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship_body("FLEET-SHIP")]})

          "/v2/systems/X1-UX81/waypoints" ->
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

          "/v2/my/ships" ->
            conn
            |> Map.put(:status, 500)
            |> Req.Test.json(%{})
        end
      end)

      snapshot = Fleet.command_snapshot(agent)
      assert {:ok, %{symbol: symbol, credits: 42_000}} = snapshot.overview
      assert symbol == agent.symbol
      assert {:error, _reason} = snapshot.ships
      assert snapshot.shipyards == {:ok, []}
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
  end

  describe "ship actions" do
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
