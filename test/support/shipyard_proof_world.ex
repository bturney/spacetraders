defmodule SpaceTraders.ShipyardProofWorld do
  @moduledoc """
  Bounded #821 transport world. Owns authoritative game facts, never application
  choices, Claims, offers-as-evidence or Earnings. Not a general simulator.

  Fixed two-route finite stock/depth, one-stock Shipyard and signed effect
  account. Fixture mechanics only; never a live-game fidelity qualification.
  """
  use Agent

  import SpaceTraders.ShipBody
  alias SpaceTraders.Clock

  @t0 ~U[2026-10-22 00:00:00Z]
  @system "X1-UX81"
  @source "X1-UX81-A1"
  @coordinates %{"X1-UX81-A1" => {0, 0}, "X1-UX81-A2" => {62, 0}, "X1-UX81-A3" => {0, 62}}

  def start_link(opts) do
    scenario = Keyword.get(opts, :scenario, :positive)

    maximum =
      case scenario do
        :positive -> 40
        :payment_safety -> 20
      end

    credits = Keyword.get(opts, :credits, 400_000)
    reset_at = Keyword.get(opts, :reset_at, DateTime.add(@t0, 120, :hour))
    destination_sell = Map.new(~w(IRON COPPER), &{&1, Keyword.get(opts, :destination_sell, 1500)})
    rivals = Keyword.get(opts, :rivals, [])

    Agent.start_link(fn ->
      initial = %{
        credits: credits,
        ships: %{
          "PROOF824-1" => ship("PROOF824-1", :trader),
          "PROOF824-2" => ship("PROOF824-2", :probe)
        },
        routes:
          Map.new(
            ~w(IRON COPPER),
            &{&1, %{source_units: 1600, demand_units: if(&1 in rivals, do: 0, else: 1600)}}
          ),
        replenished_at: @t0,
        cargo_basis: %{},
        offer_stock: 1
      }

      Map.merge(initial, %{
        initial: initial,
        scenario: scenario,
        transaction_maximum: maximum,
        low_credits: credits,
        initial_credits: credits,
        destination_sell: destination_sell,
        rivals: rivals,
        reset_at: reset_at,
        effects: [],
        requests: []
      })
    end)
  end

  def snapshot(world) do
    Agent.get_and_update(world, fn state ->
      next = advance(state)
      {next, next}
    end)
  end

  def market(world, symbol), do: market_from(snapshot(world), symbol)

  @doc "Named S4 variation: advertise another obtainable hull after the first effect."
  def advertise_second_offer(world) do
    Agent.update(world, fn %{offer_stock: 0, ships: ships} = state when map_size(ships) == 3 ->
      state
      |> Map.put(:offer_stock, 1)
      |> Map.put(:second_offer_advertised_at, Clock.utc_now())
    end)
  end

  @doc "Named R1 variation: announce only thirty minutes remaining, without moving time."
  def shorten_horizon(world) do
    Agent.update(world, fn state ->
      state
      |> Map.put(:reset_at, DateTime.add(Clock.utc_now(), 30, :minute))
      |> Map.put(:short_horizon_announced_at, Clock.utc_now())
    end)
  end

  @doc """
  Named S3 variation: lower one route's destination sell quote to 1,000 from
  now on. Only a later legitimate on-site Market read can reveal it.
  """
  def deteriorate_destination(world, trade) when trade in ~w(IRON COPPER) do
    Agent.update(world, fn state ->
      state
      |> Map.update(:destination_sell, %{trade => 1000}, &Map.put(&1, trade, 1000))
      |> Map.update(:deteriorations, [deterioration(trade)], &(&1 ++ [deterioration(trade)]))
    end)
  end

  defp deterioration(trade),
    do: %{
      at: Clock.utc_now(),
      trade: trade,
      waypoint: if(trade == "IRON", do: "X1-UX81-A2", else: "X1-UX81-A3"),
      sell: 1000
    }

  def account(world, cutoff) do
    state = snapshot(world)

    effects =
      state.effects
      |> Enum.filter(&(DateTime.compare(&1.at, cutoff) != :gt))
      |> Enum.sort_by(& &1.at, DateTime)

    cash = Enum.sum_by(effects, & &1.signed_cash)

    last =
      state.requests
      |> Enum.filter(&(DateTime.compare(&1.completed_at, cutoff) != :gt))
      |> List.last()

    ships = if last, do: last.after.ships, else: state.initial.ships
    ships = arrive(%{state | ships: ships}, cutoff).ships
    cargo_basis = if last, do: last.after.cargo_basis, else: %{}

    outlays = fn suffix ->
      effects
      |> Enum.filter(&String.ends_with?(&1.path, suffix))
      |> Enum.sum_by(&max(-&1.signed_cash, 0))
    end

    observed_credits = if last, do: last.after.credits, else: state.initial_credits

    cutoff_state = Map.merge(state, if(last, do: last.after, else: state.initial))
    cutoff_state = advance(cutoff_state, cutoff)

    %{
      credits: observed_credits,
      net_cash: cash,
      receipts: Enum.sum_by(effects, &max(&1.signed_cash, 0)),
      all_outlays: Enum.sum_by(effects, &max(-&1.signed_cash, 0)),
      goods_outlays: outlays.("/purchase"),
      fuel_outlays: outlays.("/refuel"),
      acquisition_outlays: outlays.("/my/ships"),
      unknown_monetary_effects: [],
      unexplained_cash: observed_credits - state.initial_credits - cash,
      low_credits:
        effects
        |> Enum.map_reduce(state.initial_credits, fn e, credits ->
          {credits + e.signed_cash, credits + e.signed_cash}
        end)
        |> elem(0)
        |> Enum.min(fn -> state.initial_credits end),
      ships: ships,
      cargo_basis: cargo_basis,
      stock: cutoff_state.routes,
      fuel: Map.new(ships, fn {symbol, ship} -> {symbol, ship["fuel"]} end),
      open_travel:
        for(
          {symbol, ship} <- ships,
          ship["nav"]["status"] == "IN_TRANSIT",
          do: %{ship: symbol, route: ship["nav"]["route"]}
        ),
      effects: effects,
      closure_tail: Enum.filter(state.effects, &(DateTime.compare(&1.at, cutoff) == :gt))
    }
  end

  defp market_from(state, symbol) do
    listing = fn trade, type, buy, sell, side ->
      units = state.routes[trade][side]
      # Canonical 40-unit (and e.g. 20-unit partial) effects are exact. The
      # frozen 10/40 pro-rata rule can produce quarter credits, whereas the
      # pinned API requires integers. Do not invent a rounding convention.
      if rem(1600 - units, 4) != 0,
        do: raise("frozen pro-rata quote is not an integer API credit amount")

      movement = div(1600 - units, 4)
      buy = if type == "EXPORT", do: buy + movement, else: buy
      sell = if type == "IMPORT", do: sell - movement, else: sell
      Map.put(good(trade, type, buy, sell), "tradeVolume", min(state.transaction_maximum, units))
    end

    goods =
      case symbol do
        @source ->
          [
            listing.("IRON", "EXPORT", 1000, 900, :source_units),
            listing.("COPPER", "EXPORT", 1000, 900, :source_units)
          ]

        "X1-UX81-A2" ->
          [listing.("IRON", "IMPORT", 1600, destination_sell(state, "IRON"), :demand_units)]

        "X1-UX81-A3" ->
          [listing.("COPPER", "IMPORT", 1600, destination_sell(state, "COPPER"), :demand_units)]
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

  defp destination_sell(state, trade),
    do: state |> Map.get(:destination_sell, %{}) |> Map.get(trade, 1500)

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

  def reply(world, conn, controller, delivery \\ :delivered)
      when delivery in [:delivered, :lost_response] do
    started_at = Clock.utc_now()
    SpaceTraders.ShipyardProofRuntime.wait(controller, :service, 1000)

    result =
      Agent.get_and_update(world, fn state ->
        state = advance(state)

        receipt = %{
          method: conn.method,
          path: conn.request_path,
          body: conn.body_params,
          delivery: delivery,
          started_at: started_at,
          completed_at: Clock.utc_now(),
          before:
            Map.take(state, [
              :credits,
              :ships,
              :routes,
              :cargo_basis,
              :offer_stock,
              :replenished_at
            ])
        }

        try do
          {response, meta, next} =
            respond(state, conn.method, conn.request_path, conn.body_params)

          receipt =
            Map.merge(receipt, %{
              response: response,
              signed_cash: next.credits - state.credits,
              after:
                Map.take(next, [
                  :credits,
                  :ships,
                  :routes,
                  :cargo_basis,
                  :offer_stock,
                  :replenished_at
                ])
            })

          effect = %{
            at: Clock.utc_now(),
            path: conn.request_path,
            body: conn.body_params,
            signed_cash: next.credits - state.credits
          }

          next = %{next | effects: state.effects ++ [effect]}

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

    case delivery do
      :delivered -> Req.Test.json(conn, body)
      :lost_response -> Req.Test.transport_error(conn, :timeout)
    end
  end

  defp respond(state, "GET", "/v2/", _) do
    {%{
       "status" => "online",
       "version" => "2.3.0",
       "resetDate" => "2026-10-22",
       "description" => "Bounded #821 controlled world",
       "stats" => %{
         "agents" => 1,
         "ships" => map_size(state.ships),
         "systems" => 1,
         "waypoints" => 3
       },
       "leaderboards" => %{"mostCredits" => [], "mostSubmittedCharts" => []},
       "announcements" => [],
       "links" => [],
       "serverResets" => %{
         "next" => stamp(state.reset_at),
         "frequency" => "120 game hours (controlled fixture)"
       }
     }, nil, state}
  end

  defp respond(state, "GET", "/v2/my/agent", _), do: {agent_json(state), nil, state}
  defp respond(state, "GET", "/v2/my/contracts", _), do: {[], meta(0), state}

  defp respond(state, "GET", "/v2/my/ships", _) do
    {state.ships |> Map.values() |> Enum.sort_by(& &1["symbol"]), meta(map_size(state.ships)),
     state}
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
        market = market_from(state, symbol)

        market =
          if present?(state, symbol),
            do: market,
            else: Map.drop(market, ~w(tradeGoods transactions))

        {market, nil, state}

      [@source, "shipyard"] ->
        yard = %{
          "symbol" => @source,
          "shipTypes" => [%{"type" => "SHIP_LIGHT_HAULER"}],
          "modificationsFee" => 2000
        }

        yard = if present?(state, @source), do: Map.put(yard, "ships", offers(state)), else: yard
        {yard, nil, state}

      _ ->
        raise "unsupported proof observation #{rest}"
    end
  end

  defp respond(
         state,
         "POST",
         "/v2/my/ships",
         %{"shipType" => "SHIP_LIGHT_HAULER", "waypointSymbol" => @source} = body
       )
       when map_size(body) == 2 do
    unless present?(state, @source), do: raise("proof Ship purchase requires presence")
    if state.offer_stock == 0, do: raise("proof Ship Offer exhausted")
    if state.credits < 100_000, do: raise("proof Ship purchase exceeds credits")
    acquired = ship("PROOF824-#{map_size(state.ships) + 1}", :trader)

    state =
      put_ship(
        %{state | credits: state.credits - 100_000, offer_stock: state.offer_stock - 1},
        acquired
      )

    {%{
       "ship" => acquired,
       "agent" => agent_json(state),
       "transaction" => %{
         "agentSymbol" => "PROOF824",
         "shipSymbol" => acquired["symbol"],
         "shipType" => "SHIP_LIGHT_HAULER",
         "waypointSymbol" => @source,
         "price" => 100_000,
         "timestamp" => stamp(Clock.utc_now())
       }
     }, nil, state}
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
        market_from(state, ship["nav"]["waypointSymbol"])["tradeGoods"],
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
    side = if action == "purchase", do: :source_units, else: :demand_units
    state = update_in(state, [:routes, trade, side], &(&1 - units))
    basis = get_in(state.cargo_basis, [ship["symbol"], trade]) || 0

    remaining_basis =
      if action == "purchase", do: basis + units * price, else: div(basis * (held - units), held)

    state = %{
      state
      | cargo_basis:
          Map.update(
            state.cargo_basis,
            ship["symbol"],
            %{trade => remaining_basis},
            &Map.put(&1, trade, remaining_basis)
          )
    }

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

  defp offers(%{offer_stock: 0}), do: []

  defp offers(_state) do
    [
      Map.merge(
        Map.take(ship("PROOF824-3", :trader), ~w(frame reactor engine modules mounts crew)),
        %{
          "type" => "SHIP_LIGHT_HAULER",
          "symbol" => "SHIP_LIGHT_HAULER",
          "supply" => "LIMITED",
          "name" => "Proof light hauler",
          "description" => "Controlled ready trader",
          "purchasePrice" => 100_000
        }
      )
    ]
  end

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

  defp arrive(state, now) do
    ships =
      Map.new(state.ships, fn {symbol, ship} ->
        {:ok, arrival, 0} = DateTime.from_iso8601(ship["nav"]["route"]["arrival"])

        if ship["nav"]["status"] == "IN_TRANSIT" and
             DateTime.compare(now, arrival) != :lt,
           do: {symbol, put_in(ship, ["nav", "status"], "IN_ORBIT")},
           else: {symbol, ship}
      end)

    %{state | ships: ships}
  end

  defp advance(state, now \\ Clock.utc_now()) do
    periods = div(DateTime.diff(now, state.replenished_at), 1800)

    routes =
      Map.new(state.routes, fn {trade, route} ->
        # Rival Players consume replenished destination demand before the bot
        # can observe or admit it: a named input, not a bot-side rule.
        rival? = trade in state.rivals

        {trade,
         Map.new(route, fn
           {:demand_units, _} when rival? -> {:demand_units, 0}
           {side, units} -> {side, min(1600, units + periods * 40)}
         end)}
      end)

    %{state | routes: routes, replenished_at: DateTime.add(state.replenished_at, periods * 1800)}
    |> arrive(now)
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
