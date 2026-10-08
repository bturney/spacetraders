defmodule SpaceTraders.RuntimeBaselineGame do
  @moduledoc """
  Stateful transport fixture for the explicit runtime qualification and recorded-dispatch scenarios.

  This owns only game state and transport receipts, never application work.
  Listings require physical presence; navigation costs fuel and takes time;
  purchases and sales change Cargo and credits. Unknown requests fail loudly.

  Gate 1 scenario options: `:credits` and `:fuel` set the opening balance and
  tank; `:purchase_charge` is the per-unit price the game actually charges
  (default: the quoted 10); `:throttled_market_reads` answers that many Market
  reads with 429 and `Retry-After: 1` before serving them; `:fuel_price` lists
  FUEL at the source Market at that per-unit price and accepts refuels there.
  `low_credits` keeps the lowest balance the game ever held.
  """

  use Agent

  import SpaceTraders.ShipBody

  alias SpaceTraders.Clock

  @symbol "BASELINE"
  @ship "BASELINE-1"
  @system "X1-UX81"
  @source "X1-UX81-A1"
  @destination "X1-UX81-A2"

  def start_link(opts) do
    Agent.start_link(fn ->
      %{
        credits: Keyword.get(opts, :credits, 175_000),
        low_credits: Keyword.get(opts, :credits, 175_000),
        purchase_charge: Keyword.get(opts, :purchase_charge, 10),
        throttled_market_reads: Keyword.get(opts, :throttled_market_reads, 0),
        fuel_price: Keyword.get(opts, :fuel_price),
        units: 0,
        fuel: Keyword.get(opts, :fuel, 200),
        waypoint: @source,
        origin: @source,
        status: "DOCKED",
        arrival: nil,
        requests: [],
        orbit_rejection: Keyword.get(opts, :orbit_rejection, false),
        orbit_timeout: Keyword.get(opts, :orbit_timeout, false),
        navigate_timeout: Keyword.get(opts, :navigate_timeout, false)
      }
    end)
  end

  def snapshot(game), do: Agent.get(game, & &1)

  def change_posture(game, status) when status in ["DOCKED", "IN_ORBIT"],
    do: Agent.update(game, &%{&1 | status: status})

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
        reply: elem(reply, 0)
      }

      next = %{next | low_credits: min(next.low_credits, next.credits)}
      {reply, %{next | requests: next.requests ++ [receipt]}}
    end)
  end

  def reply(conn, {:ok, data, meta}), do: Req.Test.json(conn, %{"data" => data, "meta" => meta})
  def reply(conn, {:ok, data}), do: Req.Test.json(conn, %{"data" => data})
  def reply(conn, {:timeout, _}), do: Req.Test.transport_error(conn, :timeout)

  def reply(conn, {:throttled, error}) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "1")
    |> Plug.Conn.put_status(429)
    |> Req.Test.json(%{"error" => error})
  end

  def reply(conn, {:rejected, error}),
    do: conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => error})

  defp respond(state, "POST", "/v2/register", %{"symbol" => @symbol}, _) do
    {{:ok,
      %{
        "token" => "BASELINE_AGENT_TOKEN",
        "agent" => agent_json(state),
        "contract" => %{"id" => "baseline-contract", "type" => "PROCUREMENT"},
        "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
        "ships" => [ship_json(state)]
      }}, state}
  end

  defp respond(state, "GET", "/v2/my/agent", _, _),
    do: {{:ok, agent_json(state)}, state}

  defp respond(state, "GET", "/v2/my/ships", _, _),
    do: {{:ok, [ship_json(state)], %{"total" => 1, "page" => 1, "limit" => 20}}, state}

  defp respond(state, "GET", "/v2/my/ships/" <> @ship, _, _),
    do: {{:ok, ship_json(state)}, state}

  defp respond(state, "GET", "/v2/my/contracts", _, _),
    do: {{:ok, [], %{"total" => 0, "page" => 1, "limit" => 20}}, state}

  defp respond(state, "GET", "/v2/systems/" <> @system <> "/waypoints", _, params) do
    page = params |> Map.get("page", "1") |> to_string() |> String.to_integer()
    limit = params |> Map.get("limit", "20") |> to_string() |> String.to_integer()
    waypoints = Enum.map([@source, @destination, "X1-UX81-A3"], &waypoint/1)
    data = Enum.slice(waypoints, (page - 1) * limit, limit)
    {{:ok, data, %{"total" => 3, "page" => page, "limit" => limit}}, state}
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

  defp respond(
         %{orbit_rejection: true} = state,
         "POST",
         "/v2/my/ships/" <> @ship <> "/orbit",
         _,
         _
       ),
       do:
         {{:rejected, %{"code" => 4204, "message" => "Ship cannot orbit"}},
          %{state | orbit_rejection: false}}

  defp respond(
         %{orbit_timeout: true} = state,
         "POST",
         "/v2/my/ships/" <> @ship <> "/orbit",
         _,
         _
       ),
       do: {{:timeout, :not_applied}, %{state | orbit_timeout: false}}

  defp respond(state, "POST", "/v2/my/ships/" <> @ship <> "/orbit", _, _) do
    require_stationary!(state)
    next = %{state | status: "IN_ORBIT"}
    {{:ok, %{"nav" => ship_json(next)["nav"]}}, next}
  end

  defp respond(state, "POST", "/v2/my/ships/" <> @ship <> "/dock", _, _) do
    require_stationary!(state)
    next = %{state | status: "DOCKED"}
    {{:ok, %{"nav" => ship_json(next)["nav"]}}, next}
  end

  defp respond(
         %{navigate_timeout: true} = state,
         "POST",
         "/v2/my/ships/" <> @ship <> "/navigate",
         _body,
         _
       ) do
    require_stationary!(state)
    if state.status != "IN_ORBIT", do: raise("navigation requires orbit")
    {{:timeout, :not_applied}, %{state | navigate_timeout: false}}
  end

  defp respond(state, "POST", "/v2/my/ships/" <> @ship <> "/navigate", body, _) do
    require_stationary!(state)
    if state.status != "IN_ORBIT", do: raise("navigation requires orbit")
    destination = Map.fetch!(body, "waypointSymbol")
    cost = abs(waypoint(destination)["x"] - waypoint(state.waypoint)["x"])
    if state.fuel < cost, do: raise("navigation exceeds fuel")

    next = %{
      state
      | origin: state.waypoint,
        waypoint: destination,
        status: "IN_TRANSIT",
        arrival: DateTime.add(Clock.utc_now(), 60),
        fuel: state.fuel - cost
    }

    {{:ok, Map.take(ship_json(next), ["nav", "fuel"])}, next}
  end

  defp respond(state, "POST", "/v2/my/ships/" <> @ship <> "/purchase", body, _) do
    require_market!(state, @source)
    units = Map.fetch!(body, "units")
    if body["symbol"] != "IRON_ORE" or units <= 0, do: raise("invalid purchase")

    charge = state.purchase_charge

    if state.units + units > 40 or state.credits < units * charge,
      do: raise("purchase exceeds resources")

    next = %{state | units: state.units + units, credits: state.credits - units * charge}
    {{:ok, trade_result(next, "PURCHASE", units, charge)}, next}
  end

  defp respond(
         %{fuel_price: price} = state,
         "POST",
         "/v2/my/ships/" <> @ship <> "/refuel",
         body,
         _
       )
       when is_integer(price) do
    require_market!(state, @source)
    units = Map.fetch!(body, "units")
    market_units = div(units + 99, 100)
    cost = market_units * price

    if units <= 0 or state.fuel + units > 200 or state.credits < cost,
      do: raise("refuel exceeds resources")

    next = %{state | fuel: state.fuel + units, credits: state.credits - cost}

    {{:ok,
      %{
        "agent" => agent_json(next),
        "cargo" => cargo(next),
        "fuel" => %{"capacity" => 200, "current" => next.fuel},
        "transaction" => %{
          "waypointSymbol" => next.waypoint,
          "shipSymbol" => @ship,
          "tradeSymbol" => "FUEL",
          "type" => "PURCHASE",
          "units" => market_units,
          "pricePerUnit" => price,
          "totalPrice" => cost,
          "timestamp" => DateTime.to_iso8601(Clock.utc_now())
        }
      }}, next}
  end

  defp respond(state, "POST", "/v2/my/ships/" <> @ship <> "/sell", body, _) do
    require_market!(state, @destination)
    units = Map.fetch!(body, "units")

    if body["symbol"] != "IRON_ORE" or units <= 0 or units > state.units,
      do: raise("sale exceeds Cargo")

    next = %{state | units: state.units - units, credits: state.credits + units * 30}
    {{:ok, trade_result(next, "SELL", units, 30)}, next}
  end

  defp respond(_state, method, path, _body, _params),
    do: raise("unexpected game request: #{method} #{path}")

  defp arrive(%{status: "IN_TRANSIT", arrival: arrival} = state) do
    if DateTime.compare(Clock.utc_now(), arrival) != :lt,
      do: %{state | status: "IN_ORBIT"},
      else: state
  end

  defp arrive(state), do: state

  defp ship_json(state) do
    nav = nav_body(state.status, destination: state.waypoint)
    arrival = state.arrival || Clock.utc_now()

    nav = %{
      nav
      | "route" => %{
          "origin" => waypoint(state.origin),
          "destination" => waypoint(state.waypoint),
          "departureTime" => DateTime.to_iso8601(DateTime.add(arrival, -60)),
          "arrival" => DateTime.to_iso8601(arrival)
        }
    }

    ship_body(@ship, %{
      "nav" => nav,
      "cargo" => cargo(state),
      "fuel" => %{"capacity" => 200, "current" => state.fuel}
    })
  end

  defp waypoint(symbol) do
    x = %{@source => 0, @destination => 60, "X1-UX81-A3" => 120} |> Map.fetch!(symbol)

    %{
      "symbol" => symbol,
      "systemSymbol" => @system,
      "type" => "PLANET",
      "x" => x,
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
      "headquarters" => @source,
      "startingFaction" => "COSMIC",
      "shipCount" => 1
    }
  end

  defp market(state, symbol) do
    {purchase, sell, type} = if symbol == @source, do: {10, 9, "EXPORT"}, else: {35, 30, "IMPORT"}

    composition = %{
      "symbol" => symbol,
      "exports" => if(type == "EXPORT", do: [%{"symbol" => "IRON_ORE"}], else: []),
      "imports" => if(type == "IMPORT", do: [%{"symbol" => "IRON_ORE"}], else: []),
      "exchange" => []
    }

    fuel =
      if symbol == @source and is_integer(state.fuel_price),
        do: [
          %{
            "symbol" => "FUEL",
            "type" => "EXCHANGE",
            "tradeVolume" => 100,
            "supply" => "ABUNDANT",
            "activity" => "STRONG",
            "purchasePrice" => state.fuel_price,
            "sellPrice" => state.fuel_price - 2
          }
        ],
        else: []

    composition =
      if fuel == [],
        do: composition,
        else: Map.put(composition, "exchange", [%{"symbol" => "FUEL"}])

    if state.waypoint == symbol and state.status != "IN_TRANSIT" do
      Map.merge(composition, %{
        "transactions" => [],
        "tradeGoods" =>
          [
            %{
              "symbol" => "IRON_ORE",
              "type" => type,
              "tradeVolume" => 40,
              "supply" => "ABUNDANT",
              "activity" => "STRONG",
              "purchasePrice" => purchase,
              "sellPrice" => sell
            }
          ] ++ fuel
      })
    else
      composition
    end
  end

  defp cargo(state) do
    inventory =
      if state.units > 0,
        do: [
          %{
            "symbol" => "IRON_ORE",
            "name" => "Iron Ore",
            "description" => "Ore",
            "units" => state.units
          }
        ],
        else: []

    %{"capacity" => 40, "units" => state.units, "inventory" => inventory}
  end

  defp trade_result(state, type, units, price) do
    %{
      "agent" => agent_json(state),
      "cargo" => cargo(state),
      "transaction" => %{
        "waypointSymbol" => state.waypoint,
        "shipSymbol" => @ship,
        "tradeSymbol" => "IRON_ORE",
        "type" => type,
        "units" => units,
        "pricePerUnit" => price,
        "totalPrice" => units * price,
        "timestamp" => DateTime.to_iso8601(Clock.utc_now())
      }
    }
  end

  defp require_stationary!(%{status: "IN_TRANSIT"}), do: raise("Ship is still in transit")
  defp require_stationary!(_state), do: :ok

  defp require_market!(state, waypoint) do
    if state.status != "DOCKED" or state.waypoint != waypoint,
      do: raise("trade requires docking at the correct Marketplace")
  end
end
