defmodule SpaceTraders.Fleet.ShipServerTest do
  # Ship servers are separate processes reading/writing the timeline via the
  # shared sandbox, so these tests must not run async.
  use SpaceTraders.DataCase, async: false

  import Phoenix.PubSub
  import SpaceTraders.ShipBody

  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Fleet.{AutopilotConfig, Ship}
  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  @agent_id 900_001

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  defp unique_symbol, do: "SHIP-#{System.unique_integer([:positive])}"

  defp future_iso(seconds \\ 3600) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp subscribe_fleet do
    subscribe(SpaceTraders.PubSub, "fleet:#{@agent_id}")
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

  defp stub_refresh(symbol, status \\ :ok) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case status do
        :ok -> Req.Test.json(conn, %{"data" => ship_body(symbol)})
        :error -> conn |> Map.put(:status, 500) |> Req.Test.json(%{})
      end
    end)
  end

  defp stub_refresh_still_in_transit(symbol, arrival) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "data" => ship_body(symbol, %{"nav" => nav_body("IN_TRANSIT", arrival: arrival)})
      })
    end)
  end

  defp start_server(symbol, token \\ "AGENT_TOKEN") do
    start_supervised!({ShipServer, symbol: symbol, agent_id: @agent_id, agent_token: token})
  end

  defp schedule(symbol, event_type, due_at) do
    {:ok, event} = Timeline.schedule_event(:ship, symbol, event_type, due_at)
    event
  end

  describe "init" do
    test "re-arms a future event and fires it when it comes due" do
      symbol = unique_symbol()
      subscribe_fleet()
      stub_refresh(symbol)

      due_at = DateTime.add(DateTime.utc_now(), 100, :millisecond)
      event = schedule(symbol, :arrival, due_at)

      start_server(symbol)

      assert_receive {:ship_updated, @agent_id, ^symbol}, 1_000
      assert Repo.get(Event, event.id).status == "done"
      assert ShipServer.ensure_ready(symbol) == :ok
    end

    test "catches up a past-due event on boot" do
      symbol = unique_symbol()
      subscribe_fleet()
      stub_refresh(symbol)

      event = schedule(symbol, :arrival, DateTime.add(DateTime.utc_now(), -60, :second))

      start_server(symbol)

      assert_receive {:ship_updated, @agent_id, ^symbol}, 1_000
      assert Repo.get(Event, event.id).status == "done"
    end

    test "keeps a past-due event pending and retries when the refresh fails" do
      symbol = unique_symbol()
      stub_refresh(symbol, :error)

      event = schedule(symbol, :arrival, DateTime.add(DateTime.utc_now(), -60, :second))

      start_server(symbol)

      Process.sleep(50)
      assert Repo.get(Event, event.id).status == "pending"
      assert ShipServer.ensure_ready(symbol) == {:error, :ship_in_transit}
    end

    test "does not unblock while the game still reports the ship in transit" do
      symbol = unique_symbol()
      arrival = future_iso()
      subscribe_fleet()
      stub_refresh_still_in_transit(symbol, arrival)

      event = schedule(symbol, :arrival, DateTime.add(DateTime.utc_now(), -60, :second))

      start_server(symbol)

      # Clock skew between the game and this app: the event is due, but the game
      # still says IN_TRANSIT, so the ship stays busy and no update is broadcast.
      refute_receive {:ship_updated, @agent_id, ^symbol}, 150
      assert Repo.get(Event, event.id).status == "pending"
      assert ShipServer.ensure_ready(symbol) == {:error, :ship_in_transit}
    end

    test "re-arms the cooldown event type alongside an arrival" do
      symbol = unique_symbol()
      subscribe_fleet()
      stub_refresh(symbol)

      arrival = schedule(symbol, :arrival, DateTime.add(DateTime.utc_now(), 2, :second))
      cooldown = schedule(symbol, :cooldown, DateTime.add(DateTime.utc_now(), 100, :millisecond))

      start_server(symbol)

      assert ShipServer.ensure_ready(symbol) == {:error, :ship_in_transit}

      assert_receive {:ship_updated, @agent_id, ^symbol}, 1_000
      assert Repo.get(Event, cooldown.id).status == "done"

      # arrival still pending — ship is still in transit
      assert Repo.get(Event, arrival.id).status == "pending"
      assert ShipServer.ensure_ready(symbol) == {:error, :ship_in_transit}
    end
  end

  describe "ensure_ready/1" do
    test "is :ok when the server has no pending events" do
      symbol = unique_symbol()
      start_server(symbol)
      assert ShipServer.ensure_ready(symbol) == :ok
    end

    test "is :ok when no server is running (the game API backstops)" do
      assert ShipServer.ensure_ready(unique_symbol()) == :ok
    end

    test "is blocked while an arrival is pending" do
      symbol = unique_symbol()
      schedule(symbol, :arrival, DateTime.add(DateTime.utc_now(), 60, :second))
      start_server(symbol)

      assert ShipServer.ensure_ready(symbol) == {:error, :ship_in_transit}
    end

    test "is blocked while a cooldown is pending" do
      symbol = unique_symbol()
      schedule(symbol, :cooldown, DateTime.add(DateTime.utc_now(), 60, :second))
      start_server(symbol)

      assert ShipServer.ensure_ready(symbol) == {:error, :cooldown_active}
    end
  end

  describe "arm/3" do
    test "arms a freshly persisted event on the running server" do
      symbol = unique_symbol()
      start_server(symbol)
      subscribe_fleet()
      stub_refresh(symbol)

      due_at = DateTime.add(DateTime.utc_now(), 100, :millisecond)
      {:ok, event} = Timeline.schedule_event(:ship, symbol, :arrival, due_at)

      assert ShipServer.ensure_ready(symbol) == :ok

      agent = %SpaceTraders.Agent.Agent{id: @agent_id, agent_token: "AGENT_TOKEN"}
      assert :ok = ShipServer.arm(agent, symbol, event)

      assert ShipServer.ensure_ready(symbol) == {:error, :ship_in_transit}
      assert_receive {:ship_updated, @agent_id, ^symbol}, 1_000
      assert Repo.get(Event, event.id).status == "done"
    end
  end

  describe "autopilot continuation" do
    test "continues extraction after a cooldown wakeup without crashing the server" do
      agent =
        Repo.insert!(%Agent{
          id: @agent_id,
          symbol: "SHIP-SERVER-AGENT",
          faction: "COSMIC",
          headquarters: "X1-UX81-A1",
          agent_token: "AGENT_TOKEN"
        })

      ship =
        Repo.insert!(%Ship{
          symbol: "AUTOPILOT-SHIP",
          ship_type: "SHIP_COMMAND_FRIGATE",
          agent_id: agent.id
        })

      Repo.insert!(%AutopilotConfig{
        ship_id: ship.id,
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30,
        desired_mode: "autopilot",
        status: "waiting",
        in_flight_action: %{"kind" => "cooldown"}
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/AUTOPILOT-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("AUTOPILOT-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2"),
                  "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
                  "mounts" => [%{"symbol" => "MOUNT_MINING_LASER_I"}]
                })
            })

          {"/v2/my/ships/AUTOPILOT-SHIP/extract", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "cooldown" => %{
                  "shipSymbol" => "AUTOPILOT-SHIP",
                  "totalSeconds" => 60,
                  "remainingSeconds" => 60,
                  "expiration" => future_iso(60)
                },
                "extraction" => %{
                  "shipSymbol" => "AUTOPILOT-SHIP",
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

      event = schedule("AUTOPILOT-SHIP", :cooldown, DateTime.add(DateTime.utc_now(), -1, :second))
      start_server("AUTOPILOT-SHIP")

      assert eventually(fn -> Repo.get(Event, event.id).status == "done" end)

      assert eventually(fn ->
               config = Repo.get_by!(AutopilotConfig, ship_id: ship.id)
               config.status == "waiting" and config.last_action_result["kind"] == "extract"
             end)

      assert [{pid, _}] = Registry.lookup(SpaceTraders.Fleet.ShipRegistry, "AUTOPILOT-SHIP")
      assert Process.alive?(pid)
      assert [%Event{event_type: "cooldown"}] = Timeline.pending_events(:ship, "AUTOPILOT-SHIP")
    end
  end
end
