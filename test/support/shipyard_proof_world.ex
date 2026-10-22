defmodule SpaceTraders.ShipyardProofWorld do
  @moduledoc """
  Bounded #821 transport world. Owns authoritative game facts, never application
  choices, Claims, offers-as-evidence or Earnings. Not a general simulator.

  Only the ordinary trader round trip is established here. #834 owns finite
  market depletion/replenishment, offer stock and matched controls; these quotes
  must not be used to extrapolate a long-window or acquisition benefit.
  """
  use Agent

  import SpaceTraders.ShipBody
  alias SpaceTraders.Clock

  @t0 ~U[2026-10-22 00:00:00Z]
  @system "X1-UX81"
  @source "X1-UX81-A1"
  @coordinates %{"X1-UX81-A1" => {0, 0}, "X1-UX81-A2" => {62, 0}, "X1-UX81-A3" => {0, 62}}

  def start_link(_opts) do
    Agent.start_link(fn ->
      %{
        credits: 400_000,
        low_credits: 400_000,
        reset_at: DateTime.add(@t0, 120, :hour),
        ships: %{
          "PROOF824-1" => ship("PROOF824-1", :trader),
          "PROOF824-2" => ship("PROOF824-2", :probe)
        },
        requests: []
      }
    end)
  end

  def snapshot(world), do: Agent.get(world, & &1)

  def market(_world, symbol) do
    goods =
      case symbol do
        @source -> [good("IRON", "EXPORT", 1000, 900), good("COPPER", "EXPORT", 1000, 900)]
        "X1-UX81-A2" -> [good("IRON", "IMPORT", 1600, 1500)]
        "X1-UX81-A3" -> [good("COPPER", "IMPORT", 1600, 1500)]
      end ++ [good("FUEL", "EXCHANGE", 100, 90)]

    of_type = fn type ->
      for g <- goods, g["type"] == type, do: Map.take(g, ~w(symbol name description))
    end

    %{
      "symbol" => symbol,
      "imports" => of_type.("IMPORT"),
      "exports" => of_type.("EXPORT"),
      "exchange" => of_type.("EXCHANGE"),
      "transactions" => [],
      "tradeGoods" => goods
    }
  end

  defp good(symbol, type, buy, sell) do
    %{
      "symbol" => symbol,
      "name" => symbol,
      "description" => symbol,
      "type" => type,
      "tradeVolume" => 40,
      "supply" => "ABUNDANT",
      "activity" => "STATIC",
      "purchasePrice" => buy,
      "sellPrice" => sell
    }
  end

  def reply(world, conn, controller) do
    started_at = Clock.utc_now()
    SpaceTraders.ShipyardProofRuntime.wait(controller, :service, 1000)

    result =
      Agent.get_and_update(world, fn state ->
        state = arrive(state)

        receipt = %{
          method: conn.method,
          path: conn.request_path,
          body: conn.body_params,
          started_at: started_at,
          completed_at: Clock.utc_now(),
          before: Map.take(state, [:credits, :ships])
        }

        try do
          {response, meta, next} =
            respond(state, conn.method, conn.request_path, conn.body_params)

          receipt =
            Map.merge(receipt, %{response: response, after: Map.take(next, [:credits, :ships])})

          {{:ok, response, meta},
           %{
             next
             | requests: state.requests ++ [receipt],
               low_credits: min(next.credits, state.low_credits)
           }}
        rescue
          error ->
            # Preserve the failed request, then re-raise in its caller. A fixture
            # rejection is never a successful response or a swallowed failure.
            receipt =
              Map.merge(receipt, %{failure: Exception.message(error), after: receipt.before})

            {{:error, error, __STACKTRACE__}, %{state | requests: state.requests ++ [receipt]}}
        end
      end)

    {response, meta} =
      case result do
        {:ok, response, meta} -> {response, meta}
        {:error, error, stacktrace} -> reraise error, stacktrace
      end

    body = if conn.request_path == "/v2/", do: response, else: %{"data" => response}
    body = if meta, do: Map.put(body, "meta", meta), else: body
    Req.Test.json(conn, body)
  end

  defp respond(state, "GET", "/v2/", _) do
    {%{"status" => "online", "serverResets" => %{"next" => stamp(state.reset_at)}}, nil, state}
  end

  defp respond(state, "GET", "/v2/my/agent", _), do: {agent_json(state), nil, state}
  defp respond(state, "GET", "/v2/my/contracts", _), do: {[], meta(0), state}

  defp respond(state, "GET", "/v2/my/ships", _) do
    {state.ships |> Map.values() |> Enum.sort_by(& &1["symbol"]), meta(2), state}
  end

  defp respond(state, "GET", "/v2/my/ships/" <> symbol, _),
    do: {Map.fetch!(state.ships, symbol), nil, state}

  defp respond(state, "GET", "/v2/systems/" <> @system <> "/waypoints", _) do
    {Enum.map(Enum.sort(Map.keys(@coordinates)), &waypoint/1), meta(3), state}
  end

  defp respond(state, "GET", "/v2/systems/" <> @system <> "/waypoints/" <> rest, _) do
    case String.split(rest, "/") do
      [symbol] ->
        {waypoint(symbol), nil, state}

      [symbol, "market"] ->
        market = market(nil, symbol)

        market =
          if present?(state, symbol),
            do: market,
            else: Map.drop(market, ~w(tradeGoods transactions))

        {market, nil, state}

      _ ->
        raise "unsupported proof observation #{rest}"
    end
  end

  defp respond(state, "POST", "/v2/my/ships/" <> rest, body) do
    [symbol, action] = String.split(rest, "/")
    ship = Map.fetch!(state.ships, symbol)
    if ship["nav"]["status"] == "IN_TRANSIT", do: raise("proof mutation while in transit")
    {response, next} = action(state, ship, action, body)
    {response, nil, next}
  end

  defp respond(_state, method, path, _), do: raise("unsupported proof request #{method} #{path}")

  defp action(state, ship, posture, body)
       when posture in ["dock", "orbit"] and map_size(body) == 0 do
    next = put_in(ship, ["nav", "status"], if(posture == "dock", do: "DOCKED", else: "IN_ORBIT"))
    {%{"nav" => next["nav"]}, put_ship(state, next)}
  end

  defp action(state, ship, "navigate", %{"waypointSymbol" => destination} = body)
       when map_size(body) == 1 do
    if ship["nav"]["status"] != "IN_ORBIT", do: raise("proof navigation requires orbit")
    origin = ship["nav"]["waypointSymbol"]
    if origin == destination, do: raise("proof navigation must move")
    {x1, y1} = Map.fetch!(@coordinates, origin)
    {x2, y2} = Map.fetch!(@coordinates, destination)
    distance = :math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
    # Independent world implementation of the frozen healthy speed-1 CRUISE
    # rule. The test compares its literal 62-distance result to the estimator.
    if ship["engine"]["speed"] != 1 or ship["engine"]["condition"] != 1.0 or
         ship["nav"]["flightMode"] != "CRUISE",
       do: raise("unsupported proof propulsion")

    seconds = 15 + round(max(1, distance)) * 25
    fuel = if ship["fuel"]["capacity"] == 0, do: 0, else: max(1, round(distance))
    if ship["fuel"]["current"] < fuel, do: raise("proof navigation exceeds fuel")

    nav = %{
      "systemSymbol" => @system,
      "waypointSymbol" => destination,
      "status" => "IN_TRANSIT",
      "flightMode" => "CRUISE",
      "route" => %{
        "origin" => Map.take(waypoint(origin), ~w(symbol type systemSymbol x y)),
        "destination" => Map.take(waypoint(destination), ~w(symbol type systemSymbol x y)),
        "departureTime" => stamp(Clock.utc_now()),
        "arrival" => stamp(DateTime.add(Clock.utc_now(), seconds))
      }
    }

    next =
      ship
      |> Map.put("nav", nav)
      |> put_in(["fuel", "current"], ship["fuel"]["current"] - fuel)
      |> put_in(["fuel", "consumed"], %{"amount" => fuel, "timestamp" => stamp(Clock.utc_now())})

    {Map.take(next, ~w(nav fuel)), put_ship(state, next)}
  end

  defp action(state, ship, "refuel", %{"units" => units} = body)
       when is_integer(units) and map_size(body) == 1 do
    require_docked!(ship)
    missing = ship["fuel"]["capacity"] - ship["fuel"]["current"]
    if units <= 0 or units > missing, do: raise("proof refuel exceeds tank")
    market_units = div(units + 99, 100)
    cost = market_units * 100
    if state.credits < cost, do: raise("proof refuel exceeds credits")
    next = put_in(ship, ["fuel", "current"], ship["fuel"]["current"] + units)
    state = put_ship(%{state | credits: state.credits - cost}, next)

    {%{
       "agent" => agent_json(state),
       "fuel" => next["fuel"],
       "transaction" => transaction(next, "FUEL", "PURCHASE", market_units, 100)
     }, state}
  end

  defp action(state, ship, action, %{"symbol" => trade, "units" => units} = body)
       when action in ["purchase", "sell"] and is_integer(units) and map_size(body) == 2 do
    require_docked!(ship)

    listing =
      Enum.find(
        market(nil, ship["nav"]["waypointSymbol"])["tradeGoods"],
        &(&1["symbol"] == trade)
      ) || raise("proof good not listed")

    if units <= 0 or units > listing["tradeVolume"], do: raise("proof transaction exceeds depth")

    if (action == "purchase" and listing["type"] != "EXPORT") or
         (action == "sell" and listing["type"] != "IMPORT"),
       do: raise("unsupported proof trade direction")

    inventory = ship["cargo"]["inventory"]

    held =
      Enum.find_value(inventory, 0, fn item -> if item["symbol"] == trade, do: item["units"] end)

    price = listing[if(action == "purchase", do: "purchasePrice", else: "sellPrice")]
    delta = if action == "purchase", do: units, else: -units

    if held + delta < 0 or ship["cargo"]["units"] + delta > ship["cargo"]["capacity"],
      do: raise("proof transaction exceeds Cargo")

    credits = state.credits - delta * price
    if credits < 0, do: raise("proof purchase exceeds credits")
    inventory = Enum.reject(inventory, &(&1["symbol"] == trade))

    inventory =
      if held + delta > 0,
        do:
          inventory ++
            [
              %{
                "symbol" => trade,
                "name" => trade,
                "description" => trade,
                "units" => held + delta
              }
            ],
        else: inventory

    cargo = %{ship["cargo"] | "units" => ship["cargo"]["units"] + delta, "inventory" => inventory}
    next = Map.put(ship, "cargo", cargo)
    state = put_ship(%{state | credits: credits}, next)

    {%{
       "agent" => agent_json(state),
       "cargo" => cargo,
       "transaction" =>
         transaction(
           next,
           trade,
           if(action == "purchase", do: "PURCHASE", else: "SELL"),
           units,
           price
         )
     }, state}
  end

  defp action(_state, _ship, action, _), do: raise("unsupported proof action #{action}")

  defp put_ship(state, ship), do: put_in(state, [:ships, ship["symbol"]], ship)
  defp meta(total), do: %{"total" => total, "page" => 1, "limit" => 20}

  defp agent_json(state),
    do: %{
      "accountId" => "PROOF824-ACCOUNT",
      "symbol" => "PROOF824",
      "credits" => state.credits,
      "headquarters" => @source,
      "startingFaction" => "COSMIC",
      "shipCount" => map_size(state.ships)
    }

  defp transaction(ship, trade, type, units, price),
    do: %{
      "waypointSymbol" => ship["nav"]["waypointSymbol"],
      "shipSymbol" => ship["symbol"],
      "tradeSymbol" => trade,
      "type" => type,
      "units" => units,
      "pricePerUnit" => price,
      "totalPrice" => units * price,
      "timestamp" => stamp(Clock.utc_now())
    }

  defp require_docked!(ship) do
    if ship["nav"]["status"] != "DOCKED", do: raise("proof trade requires docking")
  end

  defp present?(state, waypoint),
    do:
      Enum.any?(state.ships, fn {_, ship} ->
        ship["nav"]["waypointSymbol"] == waypoint and ship["nav"]["status"] != "IN_TRANSIT"
      end)

  defp arrive(state) do
    ships =
      Map.new(state.ships, fn {symbol, ship} ->
        {:ok, arrival, 0} = DateTime.from_iso8601(ship["nav"]["route"]["arrival"])

        if ship["nav"]["status"] == "IN_TRANSIT" and
             DateTime.compare(Clock.utc_now(), arrival) != :lt,
           do: {symbol, put_in(ship, ["nav", "status"], "IN_ORBIT")},
           else: {symbol, ship}
      end)

    %{state | ships: ships}
  end

  def waypoint(symbol) do
    {x, y} = Map.fetch!(@coordinates, symbol)
    traits = if symbol == @source, do: ["MARKETPLACE", "SHIPYARD"], else: ["MARKETPLACE"]

    %{
      "symbol" => symbol,
      "systemSymbol" => @system,
      "type" => "PLANET",
      "x" => x,
      "y" => y,
      "orbitals" => [],
      "traits" => Enum.map(traits, &%{"symbol" => &1, "name" => &1, "description" => &1}),
      "modifiers" => [],
      "isUnderConstruction" => false,
      "chart" => %{
        "waypointSymbol" => symbol,
        "submittedBy" => "PROOF824",
        "submittedOn" => stamp(@t0)
      }
    }
  end

  defp ship(symbol, role) do
    trader? = role == :trader
    capacity = if trader?, do: 100, else: 0
    position = Map.take(waypoint(@source), ~w(symbol type systemSymbol x y))

    ship_body(symbol, %{
      "registration" => %{
        "name" => symbol,
        "factionSymbol" => "COSMIC",
        "role" => if(trader?, do: "HAULER", else: "SATELLITE")
      },
      "nav" => %{
        "systemSymbol" => @system,
        "waypointSymbol" => @source,
        "status" => "DOCKED",
        "flightMode" => "CRUISE",
        "route" => %{
          "origin" => position,
          "destination" => position,
          "departureTime" => stamp(@t0),
          "arrival" => stamp(@t0)
        }
      },
      "crew" => %{
        "current" => 3,
        "required" => 3,
        "capacity" => 3,
        "rotation" => "STRICT",
        "morale" => 100,
        "wages" => 0
      },
      "frame" => %{
        "symbol" => if(trader?, do: "FRAME_LIGHT_FREIGHTER", else: "FRAME_PROBE"),
        "name" => "Proof frame",
        "description" => "Controlled proof configuration",
        "moduleSlots" => 4,
        "mountingPoints" => 2,
        "fuelCapacity" => capacity,
        "condition" => 1.0,
        "integrity" => 1.0,
        "quality" => 1,
        "requirements" => %{"power" => 1, "crew" => 1}
      },
      "reactor" => %{
        "symbol" => "REACTOR_SOLAR_I",
        "name" => "Solar I",
        "description" => "Proof reactor",
        "condition" => 1.0,
        "integrity" => 1.0,
        "quality" => 1,
        "powerOutput" => 5,
        "requirements" => %{"crew" => 1}
      },
      "engine" => %{
        "symbol" => "ENGINE_IMPULSE_DRIVE_I",
        "name" => "Impulse Drive I",
        "description" => "Proof engine",
        "condition" => 1.0,
        "integrity" => 1.0,
        "quality" => 1,
        "speed" => 1,
        "requirements" => %{"power" => 1, "crew" => 1}
      },
      "modules" =>
        if(trader?,
          do: [
            %{
              "symbol" => "MODULE_CARGO_HOLD_I",
              "name" => "Cargo Hold I",
              "description" => "Proof hold",
              "capacity" => 40,
              "requirements" => %{"power" => 1, "crew" => 1, "slots" => 1}
            }
          ],
          else: []
        ),
      "mounts" => [],
      "cargo" => %{"capacity" => if(trader?, do: 40, else: 0), "units" => 0, "inventory" => []},
      "fuel" => %{
        "capacity" => capacity,
        "current" => capacity,
        "consumed" => %{"amount" => 0, "timestamp" => stamp(@t0)}
      },
      "cooldown" => %{
        "shipSymbol" => symbol,
        "totalSeconds" => 0,
        "remainingSeconds" => 0,
        "expiration" => stamp(@t0)
      }
    })
  end

  defp stamp(time), do: DateTime.to_iso8601(time)
end
