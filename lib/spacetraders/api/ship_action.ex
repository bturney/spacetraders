defmodule SpaceTraders.API.ShipAction do
  @moduledoc """
  Operation adapters for recorded Ship actions. Request parameters and response
  decoding live here; Ship Execution selects outcomes, not HTTP requests.

  Jettison retains its existing low-level adapter, but has no selectable root
  Intent. Ship/System scans, mount changes and repair have no implemented adapter.
  """

  alias SpaceTraders.API.{Model, OperationInventory, Request}

  @flight_modes Model.ShipNavFlightMode.values()

  @responses %{
    "orbit-ship" => %{nav: {:model, Model.ShipNav}},
    "dock-ship" => %{nav: {:model, Model.ShipNav}},
    "navigate-ship" => %{fuel: {:model, Model.ShipFuel}, nav: {:model, Model.ShipNav}},
    "warp-ship" => %{fuel: {:model, Model.ShipFuel}, nav: {:model, Model.ShipNav}},
    "jump-ship" => %{
      agent: {:model, Model.Agent},
      cooldown: {:model, Model.Cooldown},
      nav: {:model, Model.ShipNav},
      transaction: {:model, Model.MarketTransaction}
    },
    "patch-ship-nav" => %{
      fuel: {:model, Model.ShipFuel},
      nav: {:model, Model.ShipNav},
      events: {:list, Model.ShipConditionEvent}
    },
    "refuel-ship" => %{
      agent: {:model, Model.Agent},
      cargo: {:model, Model.ShipCargo},
      fuel: {:model, Model.ShipFuel},
      transaction: {:model, Model.MarketTransaction}
    },
    "purchase-cargo" => %{
      agent: {:model, Model.Agent},
      cargo: {:model, Model.ShipCargo},
      transaction: {:model, Model.MarketTransaction}
    },
    "sell-cargo" => %{
      agent: {:model, Model.Agent},
      cargo: {:model, Model.ShipCargo},
      transaction: {:model, Model.MarketTransaction}
    },
    "deliver-contract" => %{contract: {:model, Model.Contract}, cargo: {:model, Model.ShipCargo}},
    "supply-construction" => %{
      construction: {:model, Model.Construction},
      cargo: {:model, Model.ShipCargo}
    },
    "transfer-cargo" => %{cargo: {:model, Model.ShipCargo}},
    "jettison" => %{cargo: {:model, Model.ShipCargo}},
    "create-chart" => %{
      chart: {:model, Model.Chart},
      waypoint: {:model, Model.Waypoint},
      agent: {:model, Model.Agent}
    },
    "create-ship-waypoint-scan" => %{
      cooldown: {:model, Model.Cooldown},
      waypoints: {:list, Model.ScannedWaypoint}
    },
    "create-survey" => %{cooldown: {:model, Model.Cooldown}, surveys: {:list, Model.Survey}},
    "extract-resources" => %{
      cooldown: {:model, Model.Cooldown},
      extraction: {:model, Model.Extraction},
      cargo: {:model, Model.ShipCargo}
    },
    "extract-resources-with-survey" => %{
      cooldown: {:model, Model.Cooldown},
      extraction: {:model, Model.Extraction},
      cargo: {:model, Model.ShipCargo},
      events: {:list, Model.ShipConditionEvent}
    },
    "siphon-resources" => %{
      cooldown: {:model, Model.Cooldown},
      siphon: {:model, Model.Siphon},
      cargo: {:model, Model.ShipCargo},
      events: {:list, Model.ShipConditionEvent}
    },
    "ship-refine" => %{
      cargo: {:model, Model.ShipCargo},
      cooldown: {:model, Model.Cooldown},
      produced: :raw,
      consumed: :raw
    },
    "install-ship-module" => %{
      agent: {:model, Model.Agent},
      modules: {:list, Model.ShipModule},
      cargo: {:model, Model.ShipCargo},
      transaction: {:model, Model.ShipModificationTransaction}
    },
    "remove-ship-module" => %{
      agent: {:model, Model.Agent},
      modules: {:list, Model.ShipModule},
      cargo: {:model, Model.ShipCargo},
      transaction: {:model, Model.ShipModificationTransaction}
    }
  }

  @unsupported %{
    "create-ship-ship-scan" => "No Ship scan outcome or adapter is implemented",
    "create-ship-system-scan" => "No System scan outcome or adapter is implemented",
    "install-mount" => "No mount installation outcome or adapter is implemented",
    "remove-mount" => "No mount removal outcome or adapter is implemented",
    "repair-ship" => "No repair outcome or adapter is implemented"
  }

  def implemented_operations, do: Map.keys(@responses)
  def unsupported_operations, do: @unsupported

  def response_schema(operation_id) do
    case Map.fetch(@responses, operation_id) do
      {:ok, fields} -> {:ok, {:map, fields}}
      :error -> {:error, :recorded_operation_not_activated}
    end
  end

  @doc "Builds the operation request from one selected outcome; never sends."
  def request(ship_symbol, action) when is_binary(ship_symbol) and is_map(action) do
    with {:ok, id, body, parameters} <- parameters(ship_symbol, action),
         {:ok, schema} <- response_schema(id) do
      operation = OperationInventory.fetch!(id)

      path =
        Enum.reduce(Map.put(parameters, "shipSymbol", ship_symbol), operation.path, fn
          {name, value}, path -> String.replace(path, "{#{name}}", value)
        end)

      opts = [as: schema]
      opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

      opts =
        if id == "create-chart",
          do: Keyword.put(opts, :dependency_context, %{waypoint_symbol: action["waypoint"]}),
          else: opts

      {:ok, %{operation: operation, path: path, opts: opts}}
    end
  end

  def request(_, _), do: {:error, :invalid_recorded_action}

  # Refuel always names the fuel it authorizes; the game's fill-to-capacity default
  # would be an unbounded spend.
  defp parameters(_ship, %{"kind" => "refuel", "units" => units})
       when is_integer(units) and units > 0,
       do: {:ok, "refuel-ship", %{"units" => units}, %{}}

  # A unit-less refuel only identifies historical work for recovery. Preparation
  # refuses it (`CreditSpending.acquire/3`), so it can never be dispatched.
  defp parameters(_ship, %{"kind" => kind})
       when kind in ["orbit", "dock", "refuel", "scan_waypoints", "survey", "siphon"] do
    id =
      %{
        "orbit" => "orbit-ship",
        "dock" => "dock-ship",
        "refuel" => "refuel-ship",
        "scan_waypoints" => "create-ship-waypoint-scan",
        "survey" => "create-survey",
        "siphon" => "siphon-resources"
      }[kind]

    {:ok, id, nil, %{}}
  end

  defp parameters(_ship, %{"kind" => "chart", "waypoint" => waypoint})
       when is_binary(waypoint) and waypoint != "",
       do: {:ok, "create-chart", nil, %{}}

  defp parameters(_ship, %{"kind" => kind, "waypoint" => waypoint})
       when kind in ["navigate", "warp", "jump"] and is_binary(waypoint) and waypoint != "" do
    body =
      Request.NavigateRequest.new(%{waypoint_symbol: waypoint})
      |> Request.NavigateRequest.to_json()

    {:ok, kind <> "-ship", body, %{}}
  end

  defp parameters(_ship, %{"kind" => "set_flight_mode", "flight_mode" => mode})
       when mode in @flight_modes do
    body = Request.ShipNavRequest.new(%{flight_mode: mode}) |> Request.ShipNavRequest.to_json()
    {:ok, "patch-ship-nav", body, %{}}
  end

  defp parameters(_ship, %{"kind" => kind, "trade_symbol" => symbol, "units" => units})
       when kind in ["buy", "sell", "jettison"] and is_binary(symbol) and
              is_integer(units) and units > 0 do
    {id, module} =
      %{
        "buy" => {"purchase-cargo", Request.PurchaseCargoRequest},
        "sell" => {"sell-cargo", Request.SellCargoRequest},
        "jettison" => {"jettison", Request.JettisonCargoRequest}
      }[kind]

    {:ok, id, module.new(%{symbol: symbol, units: units}) |> module.to_json(), %{}}
  end

  defp parameters(ship, %{
         "kind" => "deliver",
         "trade_symbol" => symbol,
         "units" => units,
         "recipient" => %{"type" => "contract", "contract_id" => id}
       })
       when is_binary(id) and is_binary(symbol) and is_integer(units) and units > 0 do
    body =
      Request.DeliverContractRequest.new(%{ship_symbol: ship, trade_symbol: symbol, units: units})
      |> Request.DeliverContractRequest.to_json()

    {:ok, "deliver-contract", body, %{"contractId" => id}}
  end

  defp parameters(ship, %{
         "kind" => "deliver",
         "trade_symbol" => symbol,
         "units" => units,
         "recipient" => %{"type" => "construction", "system" => system, "waypoint" => waypoint}
       })
       when is_binary(system) and is_binary(waypoint) and is_binary(symbol) and
              is_integer(units) and units > 0 do
    body =
      Request.SupplyConstructionRequest.new(%{
        ship_symbol: ship,
        trade_symbol: symbol,
        units: units
      })
      |> Request.SupplyConstructionRequest.to_json()

    {:ok, "supply-construction", body, %{"systemSymbol" => system, "waypointSymbol" => waypoint}}
  end

  defp parameters(_ship, %{
         "kind" => "transfer",
         "trade_symbol" => symbol,
         "units" => units,
         "target_ship" => target
       })
       when is_binary(symbol) and is_binary(target) and is_integer(units) and units > 0 do
    body =
      Request.TransferCargoRequest.new(%{trade_symbol: symbol, units: units, ship_symbol: target})
      |> Request.TransferCargoRequest.to_json()

    {:ok, "transfer-cargo", body, %{}}
  end

  defp parameters(_ship, %{"kind" => "extract", "survey" => survey}) when is_map(survey),
    do: {:ok, "extract-resources-with-survey", survey, %{}}

  defp parameters(_ship, %{"kind" => "extract"}), do: {:ok, "extract-resources", nil, %{}}

  defp parameters(_ship, %{"kind" => "refine", "produce" => produce})
       when produce in ~w(IRON COPPER SILVER GOLD ALUMINUM PLATINUM URANITE MERITIUM FUEL),
       do: {:ok, "ship-refine", %{"produce" => produce}, %{}}

  defp parameters(_ship, %{"kind" => kind, "module_symbol" => symbol})
       when kind in ["install_module", "remove_module"] and is_binary(symbol) do
    {id, module} =
      %{
        "install_module" => {"install-ship-module", Request.InstallShipModuleRequest},
        "remove_module" => {"remove-ship-module", Request.RemoveShipModuleRequest}
      }[kind]

    {:ok, id, module.new(%{symbol: symbol}) |> module.to_json(), %{}}
  end

  defp parameters(_, _), do: {:error, :invalid_recorded_action}
end
