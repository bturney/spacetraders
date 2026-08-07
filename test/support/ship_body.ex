defmodule SpaceTraders.ShipBody do
  @moduledoc """
  Builds realistic SpaceTraders ship API payloads for `Req.Test` stubs.

  The canned payloads exercise the real decode path in `SpaceTraders.API.Model`.
  `ship_body/2` returns the full `GET /my/ships` JSON object for one ship; pass
  overrides to shape nav/cooldown/fuel per test.
  """

  @doc "A full ship JSON payload for one ship, deep-mergeable via overrides."
  def ship_body(symbol, overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => symbol,
        "registration" => %{
          "name" => symbol,
          "factionSymbol" => "COSMIC",
          "role" => "COMMAND"
        },
        "nav" => nav_body("DOCKED"),
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

  @doc "A ship nav JSON payload. `status` is DOCKED, IN_ORBIT or IN_TRANSIT."
  def nav_body(status \\ "DOCKED", overrides \\ []) do
    overrides = Map.new(overrides)
    destination = Map.get(overrides, :destination, "X1-UX81-A1")

    Map.merge(
      %{
        "systemSymbol" => "X1-UX81",
        "waypointSymbol" => destination,
        "status" => status,
        "flightMode" => "CRUISE",
        "route" => route_body(destination, overrides)
      },
      Map.drop(overrides, [:destination])
    )
  end

  defp route_body(destination, overrides) do
    arrival = Map.get(overrides, :arrival, "2026-01-01T00:00:00.000Z")

    %{
      "destination" => %{
        "symbol" => destination,
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
      "arrival" => arrival
    }
  end
end
