defmodule SpaceTraders.FleetShipStateTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RecordedDispatchFixtures

  alias SpaceTraders.{API, Fleet}
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.RuntimeFleetGame, as: FleetGame

  defp start_game(opts) do
    game = start_supervised!({FleetGame, opts})
    Req.Test.stub(API, fn conn -> FleetGame.reply(conn, FleetGame.call(game, conn)) end)
    game
  end

  defp ship_spec(symbol, attrs \\ %{}) do
    Map.merge(
      %{
        symbol: symbol,
        frame: "FRAME_FRIGATE",
        role: "COMMAND",
        fuel_capacity: 200,
        fuel: 120,
        cargo_capacity: 40,
        waypoint: "X1-UX81-A1"
      },
      attrs
    )
  end

  defp register(agent, symbols) do
    Enum.each(symbols, fn symbol ->
      Repo.insert!(%Ship{agent_id: agent.id, symbol: symbol, ship_type: "SHIP_COMMAND_FRIGATE"})
    end)
  end

  defp stored(agent, symbol) do
    Repo.get_by!(Ship, agent_id: agent.id, symbol: symbol) |> Repo.preload(:cargo)
  end

  defp cargo(ship), do: Map.new(ship.cargo, &{&1.trade_symbol, &1.units})

  test "list_ships pages through more Ships than the game's default page" do
    symbols = for n <- 1..25, do: "BASELINE-#{String.pad_leading("#{n}", 2, "0")}"
    game = start_game(ships: Enum.map(symbols, &ship_spec/1))
    agent = operator_fixture() |> agent_fixture()

    assert {:ok, ships} = Fleet.list_ships(agent)
    assert Enum.map(ships, & &1.symbol) == symbols
    assert length(FleetGame.snapshot(game).requests) > 1
  end

  test "an owned Fleet read stores every registered Ship's current state and broadcasts per Ship" do
    start_game(
      ships: [
        ship_spec("BASELINE-1"),
        ship_spec("BASELINE-2", %{fuel_capacity: 0, fuel: 0, cargo_capacity: 0})
      ]
    )

    agent = operator_fixture() |> agent_fixture()
    register(agent, ["BASELINE-1", "BASELINE-2"])
    Fleet.subscribe_ship_state(agent.id)

    assert {:ok, _ships} = Fleet.list_ships(agent)

    assert_receive {:ship_state, %Ship{symbol: "BASELINE-1"}}
    assert_receive {:ship_state, %Ship{symbol: "BASELINE-2"}}

    ship = stored(agent, "BASELINE-1")
    assert ship.nav_status == "DOCKED"
    assert ship.waypoint_symbol == "X1-UX81-A1"
    assert {ship.fuel_current, ship.fuel_capacity, ship.cargo_capacity} == {120, 200, 40}
    assert ship.engine_speed == 1
    assert ship.engine_condition == 1.0
    assert %DateTime{} = ship.state_observed_at
    assert stored(agent, "BASELINE-2").fuel_capacity == 0
  end

  test "a Ship read for an unregistered Ship stores nothing" do
    start_game(ships: [ship_spec("BASELINE-1")])
    agent = operator_fixture() |> agent_fixture()

    assert {:ok, _ships} = Fleet.list_ships(agent)
    assert Repo.get_by(Ship, agent_id: agent.id, symbol: "BASELINE-1") == nil
  end

  test "recorded Ship actions update stored state through the same upsert" do
    game = start_game(ships: [ship_spec("BASELINE-1")])
    agent = operator_fixture() |> agent_fixture()
    register(agent, ["BASELINE-1"])
    Fleet.subscribe_ship_state(agent.id)

    dispatch = fn action ->
      %{attempt: attempt, intent: intent} = prepare_action(agent, "BASELINE-1", action)
      assert {:ok, _} = API.dispatch_recorded(attempt)
      # The next action belongs to a new Intent; this one is done.
      Repo.update_all(from(i in Intent, where: i.id == ^intent.id), set: [status: "completed"])
    end

    dispatch.(%{"kind" => "buy", "trade_symbol" => "IRON_ORE", "units" => 10})
    assert_receive {:ship_state, %Ship{symbol: "BASELINE-1"}}
    assert cargo(stored(agent, "BASELINE-1")) == %{"IRON_ORE" => 10}

    dispatch.(%{"kind" => "orbit"})
    assert stored(agent, "BASELINE-1").nav_status == "IN_ORBIT"

    dispatch.(%{"kind" => "navigate", "waypoint" => "X1-UX81-A2"})
    ship = stored(agent, "BASELINE-1")
    arrival = FleetGame.snapshot(game).ships["BASELINE-1"].arrival

    assert ship.nav_status == "IN_TRANSIT"
    assert {ship.route_origin, ship.route_destination} == {"X1-UX81-A1", "X1-UX81-A2"}
    assert ship.waypoint_symbol == "X1-UX81-A2"
    assert DateTime.compare(ship.route_arrives_at, DateTime.truncate(arrival, :second)) == :eq
    assert DateTime.diff(ship.route_arrives_at, ship.route_departed_at) == 60
    assert ship.fuel_current == 60
    # Cargo the navigate response does not carry stays as last observed.
    assert cargo(ship) == %{"IRON_ORE" => 10}
  end

  test "current Ships read in natural name order: AGENT-2 before AGENT-10" do
    agent = operator_fixture() |> agent_fixture()
    register(agent, ["AGENT-10", "AGENT-A", "AGENT-2", "AGENT-1", "BGENT-3"])
    ids = Enum.map(Repo.all(Ship), & &1.id)

    expected = ["AGENT-1", "AGENT-2", "AGENT-A", "AGENT-10", "BGENT-3"]
    assert Enum.map(Fleet.current_ships(agent.id), & &1.symbol) == expected
    assert Enum.map(Fleet.current_ships(agent.id, ids), & &1.symbol) == expected
  end

  test "a running cooldown is stored with its end; an ended one clears it" do
    agent = operator_fixture() |> agent_fixture()
    register(agent, ["AGENT-1"])

    cooldown = fn remaining, expiration ->
      %SpaceTraders.API.Model.Cooldown{
        ship_symbol: "AGENT-1",
        total_seconds: 70,
        remaining_seconds: remaining,
        expiration: expiration
      }
    end

    Fleet.record_ship_state(agent.id, "AGENT-1", %{
      cooldown: cooldown.(65, "2026-10-19T12:01:05.123Z")
    })

    assert stored(agent, "AGENT-1").cooldown_expires_at == ~U[2026-10-19 12:01:05Z]

    Fleet.record_ship_state(agent.id, "AGENT-1", %{cooldown: cooldown.(0, nil)})
    assert stored(agent, "AGENT-1").cooldown_expires_at == nil
  end
end
