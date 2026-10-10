defmodule SpaceTraders.RuntimeFleetGame do
  @moduledoc """
  Stateful multi-Ship transport fixture for the Gate 2A runtime qualification.

  Like `SpaceTraders.RuntimeBaselineGame`, this owns only game state and
  transport receipts, never application work. Every Ship is physically located,
  travel burns fuel (a Ship with no fuel tank travels free, as a solar probe
  does), Market Listings are served only while a Ship of the Agent is present
  at the Marketplace, trades are bounded by the Listing's `tradeVolume`, the
  Ship's free Cargo and the Agent's credits, and every outbound request is kept
  as a transport receipt. Unknown requests fail loudly.

  `new_game/1` options override the production-mirroring defaults:
  `:credits`, `:ships` (list of Ship specs) and `:markets` (waypoint symbol to
  list of Listing maps). `update/2` lets a scenario change the world itself
  (a price move), never application state.
  """

  use Agent

  import SpaceTraders.ShipBody

  alias SpaceTraders.Clock

  @symbol "BASELINE"
  @system "X1-UX81"
  @travel_seconds 60

  @waypoints %{
    "X1-UX81-A1" => 0,
    "X1-UX81-A2" => 60,
    "X1-UX81-A3" => 120,
    "X1-UX81-A4" => 180
  }

  def system, do: @system

  @doc """
  Mirrors the 6043e38 production failure: a FRAME_FRIGATE with a 40-unit hold
  and a low tank at the observed source Marketplace, a FRAME_PROBE with no hold
  and no tank, route depth of 60 on both Listings, and two further Marketplaces
  nobody has observed.
  """
  def default_ships do
    [
      %{
        symbol: "BASELINE-1",
        frame: "FRAME_FRIGATE",
        role: "COMMAND",
        fuel_capacity: 200,
        fuel: 30,
        cargo_capacity: 40,
        waypoint: "X1-UX81-A1"
      },
      %{
        symbol: "BASELINE-2",
        frame: "FRAME_PROBE",
        role: "SATELLITE",
        fuel_capacity: 0,
        fuel: 0,
        cargo_capacity: 0,
        waypoint: "X1-UX81-A1"
      }
    ]
  end

  def default_markets do
    %{
      "X1-UX81-A1" => [
        good("IRON_ORE", "EXPORT", 60, 10, 9),
        good("FUEL", "EXCHANGE", 100, 72, 70)
      ],
      "X1-UX81-A2" => [good("IRON_ORE", "IMPORT", 60, 35, 30)],
      "X1-UX81-A3" => [good("COPPER_ORE", "EXPORT", 60, 40, 38)],
      "X1-UX81-A4" => [good("COPPER_ORE", "IMPORT", 60, 80, 70)]
    }
  end

  def good(symbol, type, trade_volume, purchase_price, sell_price) do
    %{
      symbol: symbol,
      type: type,
      trade_volume: trade_volume,
      supply: "ABUNDANT",
      activity: "STRONG",
      purchase_price: purchase_price,
      sell_price: sell_price
    }
  end

  def start_link(opts) do
    ships = Keyword.get(opts, :ships, default_ships())

    Agent.start_link(fn ->
      %{
        credits: Keyword.get(opts, :credits, 175_000),
        low_credits: Keyword.get(opts, :credits, 175_000),
        markets: Keyword.get(opts, :markets, default_markets()),
        ships: Map.new(ships, &{&1.symbol, ship_state(&1)}),
        requests: [],
        throttled_market_reads: Keyword.get(opts, :throttled_market_reads, 0)
      }
    end)
  end

  defp ship_state(spec) do
    spec
    |> Map.merge(%{
      origin: spec.waypoint,
      status: Map.get(spec, :status, "DOCKED"),
      arrival: nil,
      cargo: %{}
    })
  end

  def snapshot(game), do: Agent.get(game, & &1)

  @doc "A change of the world itself, such as a price move at a Marketplace."
  def update(game, fun), do: Agent.update(game, fun)

  def set_good(game, waypoint, symbol, fields) do
    update(game, fn state ->
      goods =
        Enum.map(state.markets[waypoint], fn
          %{symbol: ^symbol} = good -> Map.merge(good, Map.new(fields))
          other -> other
        end)

      put_in(state.markets[waypoint], goods)
    end)
  end

  def call(game, conn) do
    Agent.get_and_update(game, fn state ->
      state = arrive(state)

      {reply, next} =
        respond(state, conn.method, conn.request_path, conn.body_params, conn.params)

      receipt = %{
        method: conn.method,
        path: conn.request_path,
        body: conn.body_params,
        at: Clock.utc_now(),
        reply: elem(reply, 0),
        transaction: transaction_of(reply)
      }

      next = %{next | low_credits: min(next.low_credits, next.credits)}
      {reply, %{next | requests: next.requests ++ [receipt]}}
    end)
  end

  defp transaction_of({:ok, %{"transaction" => transaction}}), do: transaction
  defp transaction_of(_reply), do: nil

  def reply(conn, {:ok, data, meta}), do: Req.Test.json(conn, %{"data" => data, "meta" => meta})
  def reply(conn, {:ok, data}), do: Req.Test.json(conn, %{"data" => data})

  def reply(conn, {:throttled, error}) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "1")
    |> Plug.Conn.put_status(429)
    |> Req.Test.json(%{"error" => error})
  end

  defp respond(state, "POST", "/v2/register", %{"symbol" => @symbol}, _) do
    ships = state.ships |> Map.values() |> Enum.sort_by(& &1.symbol) |> Enum.map(&ship_json/1)

    {{:ok,
      %{
        "token" => "BASELINE_AGENT_TOKEN",
        "agent" => agent_json(state),
        "contract" => %{"id" => "baseline-contract", "type" => "PROCUREMENT"},
        "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
        "ships" => ships
      }}, state}
  end

  defp respond(state, "GET", "/v2/my/agent", _, _), do: {{:ok, agent_json(state)}, state}

  defp respond(state, "GET", "/v2/my/ships", _, _) do
    ships = state.ships |> Map.values() |> Enum.sort_by(& &1.symbol) |> Enum.map(&ship_json/1)
    {{:ok, ships, %{"total" => length(ships), "page" => 1, "limit" => 20}}, state}
  end

  defp respond(state, "GET", "/v2/my/ships/" <> symbol, _, _) do
    {{:ok, ship_json(Map.fetch!(state.ships, symbol))}, state}
  end

  defp respond(state, "GET", "/v2/my/contracts", _, _),
    do: {{:ok, [], %{"total" => 0, "page" => 1, "limit" => 20}}, state}

  defp respond(state, "GET", "/v2/systems/" <> @system <> "/waypoints", _, params) do
    page = params |> Map.get("page", "1") |> to_string() |> String.to_integer()
    limit = params |> Map.get("limit", "20") |> to_string() |> String.to_integer()
    waypoints = @waypoints |> Map.keys() |> Enum.sort() |> Enum.map(&waypoint/1)
    data = Enum.slice(waypoints, (page - 1) * limit, limit)
    {{:ok, data, %{"total" => length(waypoints), "page" => page, "limit" => limit}}, state}
  end

  defp respond(
         %{throttled_market_reads: remaining} = state,
         "GET",
         "/v2/systems/" <> @system <> "/waypoints/" <> suffix,
         _,
         _
       )
       when remaining > 0 do
    if String.ends_with?(suffix, "/market") do
      {{:throttled, %{"code" => 429, "message" => "rate limited"}},
       %{state | throttled_market_reads: remaining - 1}}
    else
      {{:ok, waypoint(suffix)}, state}
    end
  end

  defp respond(state, "GET", "/v2/systems/" <> @system <> "/waypoints/" <> suffix, _, _) do
    case String.split(suffix, "/") do
      [symbol, "market"] -> {{:ok, market(state, symbol)}, state}
      [symbol] -> {{:ok, waypoint(symbol)}, state}
    end
  end

  defp respond(state, "POST", "/v2/my/ships/" <> rest, body, _) do
    [symbol, action] = String.split(rest, "/")
    ship = Map.fetch!(state.ships, symbol)
    ship_action(state, ship, action, body)
  end

  defp respond(_state, method, path, _body, _params),
    do: raise("unexpected game request: #{method} #{path}")

  defp ship_action(state, ship, "orbit", _body) do
    require_stationary!(ship)
    next = %{ship | status: "IN_ORBIT"}
    {{:ok, %{"nav" => ship_json(next)["nav"]}}, put_ship(state, next)}
  end

  defp ship_action(state, ship, "dock", _body) do
    require_stationary!(ship)
    next = %{ship | status: "DOCKED"}
    {{:ok, %{"nav" => ship_json(next)["nav"]}}, put_ship(state, next)}
  end

  defp ship_action(state, ship, "navigate", body) do
    require_stationary!(ship)
    if ship.status != "IN_ORBIT", do: raise("navigation requires orbit")
    destination = Map.fetch!(body, "waypointSymbol")
    cost = if ship.fuel_capacity == 0, do: 0, else: abs(x(destination) - x(ship.waypoint))
    if ship.fuel < cost, do: raise("navigation exceeds fuel for #{ship.symbol}")

    next = %{
      ship
      | origin: ship.waypoint,
        waypoint: destination,
        status: "IN_TRANSIT",
        arrival: DateTime.add(Clock.utc_now(), @travel_seconds),
        fuel: ship.fuel - cost
    }

    {{:ok, Map.take(ship_json(next), ["nav", "fuel"])}, put_ship(state, next)}
  end

  defp ship_action(state, ship, "purchase", body) do
    require_docked_marketplace!(ship, state)
    units = Map.fetch!(body, "units")
    trade = Map.fetch!(body, "symbol")
    listing = listing!(state, ship.waypoint, trade)

    if listing.type == "IMPORT", do: raise("cannot purchase #{trade} at an importing Market")
    if units <= 0 or units > listing.trade_volume, do: raise("purchase exceeds tradeVolume")
    if cargo_units(ship) + units > ship.cargo_capacity, do: raise("purchase exceeds free Cargo")
    cost = units * listing.purchase_price
    if state.credits < cost, do: raise("purchase exceeds credits")

    next = %{ship | cargo: Map.update(ship.cargo, trade, units, &(&1 + units))}
    state = %{state | credits: state.credits - cost} |> put_ship(next)
    {{:ok, trade_result(state, next, trade, "PURCHASE", units, listing.purchase_price)}, state}
  end

  defp ship_action(state, ship, "sell", body) do
    require_docked_marketplace!(ship, state)
    units = Map.fetch!(body, "units")
    trade = Map.fetch!(body, "symbol")
    listing = listing!(state, ship.waypoint, trade)

    if units <= 0 or units > Map.get(ship.cargo, trade, 0), do: raise("sale exceeds Cargo")
    if units > listing.trade_volume, do: raise("sale exceeds tradeVolume")

    left = Map.fetch!(ship.cargo, trade) - units

    cargo =
      if left == 0, do: Map.delete(ship.cargo, trade), else: Map.put(ship.cargo, trade, left)

    next = %{ship | cargo: cargo}
    state = %{state | credits: state.credits + units * listing.sell_price} |> put_ship(next)
    {{:ok, trade_result(state, next, trade, "SELL", units, listing.sell_price)}, state}
  end

  defp ship_action(state, ship, "refuel", body) do
    require_docked_marketplace!(ship, state)
    listing = listing!(state, ship.waypoint, "FUEL")
    units = Map.fetch!(body, "units")
    market_units = div(units + 99, 100)
    cost = market_units * listing.purchase_price

    if units <= 0 or ship.fuel + units > ship.fuel_capacity or state.credits < cost,
      do: raise("refuel exceeds resources")

    next = %{ship | fuel: ship.fuel + units}
    state = %{state | credits: state.credits - cost} |> put_ship(next)

    {{:ok,
      %{
        "agent" => agent_json(state),
        "cargo" => cargo_json(next),
        "fuel" => fuel_json(next),
        "transaction" => %{
          "waypointSymbol" => next.waypoint,
          "shipSymbol" => next.symbol,
          "tradeSymbol" => "FUEL",
          "type" => "PURCHASE",
          "units" => market_units,
          "pricePerUnit" => listing.purchase_price,
          "totalPrice" => cost,
          "timestamp" => DateTime.to_iso8601(Clock.utc_now())
        }
      }}, state}
  end

  defp ship_action(_state, ship, action, _body),
    do: raise("unexpected game action #{action} for #{ship.symbol}")

  defp put_ship(state, ship), do: %{state | ships: Map.put(state.ships, ship.symbol, ship)}

  defp arrive(state) do
    ships =
      Map.new(state.ships, fn
        {symbol, %{status: "IN_TRANSIT", arrival: arrival} = ship} ->
          if DateTime.compare(Clock.utc_now(), arrival) != :lt,
            do: {symbol, %{ship | status: "IN_ORBIT"}},
            else: {symbol, ship}

        other ->
          other
      end)

    %{state | ships: ships}
  end

  defp ship_json(ship) do
    nav = nav_body(ship.status, destination: ship.waypoint)
    arrival = ship.arrival || Clock.utc_now()

    nav = %{
      nav
      | "route" => %{
          "origin" => waypoint(ship.origin),
          "destination" => waypoint(ship.waypoint),
          "departureTime" => DateTime.to_iso8601(DateTime.add(arrival, -@travel_seconds)),
          "arrival" => DateTime.to_iso8601(arrival)
        }
    }

    ship_body(ship.symbol, %{
      "registration" => %{
        "name" => ship.symbol,
        "factionSymbol" => "COSMIC",
        "role" => ship.role
      },
      "frame" => %{
        "symbol" => ship.frame,
        "name" => ship.frame,
        "description" => ship.frame,
        "moduleSlots" => 2,
        "mountingPoints" => 1,
        "fuelCapacity" => ship.fuel_capacity,
        "condition" => 100,
        "integrity" => 100,
        "requirements" => %{"power" => 1, "crew" => 1}
      },
      "nav" => nav,
      "cargo" => cargo_json(ship),
      "fuel" => fuel_json(ship)
    })
  end

  defp fuel_json(ship), do: %{"capacity" => ship.fuel_capacity, "current" => ship.fuel}

  defp cargo_json(ship) do
    inventory =
      for {trade, units} <- Enum.sort(ship.cargo) do
        %{"symbol" => trade, "name" => trade, "description" => trade, "units" => units}
      end

    %{
      "capacity" => ship.cargo_capacity,
      "units" => cargo_units(ship),
      "inventory" => inventory
    }
  end

  defp cargo_units(ship), do: ship.cargo |> Map.values() |> Enum.sum()

  defp x(symbol), do: Map.fetch!(@waypoints, symbol)

  defp waypoint(symbol) do
    %{
      "symbol" => symbol,
      "systemSymbol" => @system,
      "type" => "PLANET",
      "x" => x(symbol),
      "y" => 0,
      "orbitals" => [],
      "traits" => [%{"symbol" => "MARKETPLACE"}],
      "chart" => %{"submittedBy" => "OTHER", "submittedOn" => "2026-01-01T00:00:00Z"}
    }
  end

  defp agent_json(state) do
    %{
      "symbol" => @symbol,
      "credits" => state.credits,
      "headquarters" => "X1-UX81-A1",
      "startingFaction" => "COSMIC",
      "shipCount" => map_size(state.ships)
    }
  end

  defp market(state, symbol) do
    goods = Map.get(state.markets, symbol, [])
    of_type = fn type -> for g <- goods, g.type == type, do: %{"symbol" => g.symbol} end

    composition = %{
      "symbol" => symbol,
      "exports" => of_type.("EXPORT"),
      "imports" => of_type.("IMPORT"),
      "exchange" => of_type.("EXCHANGE")
    }

    if present?(state, symbol) do
      Map.merge(composition, %{
        "transactions" => [],
        "tradeGoods" =>
          for g <- goods do
            %{
              "symbol" => g.symbol,
              "type" => g.type,
              "tradeVolume" => g.trade_volume,
              "supply" => g.supply,
              "activity" => g.activity,
              "purchasePrice" => g.purchase_price,
              "sellPrice" => g.sell_price
            }
          end
      })
    else
      composition
    end
  end

  defp present?(state, symbol) do
    Enum.any?(Map.values(state.ships), &(&1.waypoint == symbol and &1.status != "IN_TRANSIT"))
  end

  defp listing!(state, waypoint, trade) do
    Enum.find(state.markets[waypoint] || [], &(&1.symbol == trade)) ||
      raise("#{waypoint} lists no #{trade}")
  end

  defp trade_result(state, ship, trade, type, units, price) do
    %{
      "agent" => agent_json(state),
      "cargo" => cargo_json(ship),
      "transaction" => %{
        "waypointSymbol" => ship.waypoint,
        "shipSymbol" => ship.symbol,
        "tradeSymbol" => trade,
        "type" => type,
        "units" => units,
        "pricePerUnit" => price,
        "totalPrice" => units * price,
        "timestamp" => DateTime.to_iso8601(Clock.utc_now())
      }
    }
  end

  defp require_stationary!(%{status: "IN_TRANSIT"}), do: raise("Ship is still in transit")
  defp require_stationary!(_ship), do: :ok

  defp require_docked_marketplace!(ship, state) do
    if ship.status != "DOCKED" or not Map.has_key?(state.markets, ship.waypoint),
      do: raise("trade requires docking at a Marketplace (#{ship.symbol})")
  end
end
