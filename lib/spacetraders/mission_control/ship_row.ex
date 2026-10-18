defmodule SpaceTraders.MissionControl.ShipRow do
  @moduledoc """
  One Ships-list row read from stored Ship state; never calls the game.

  A row is overdue when it is 5 minutes past the Ship's next known event. The
  known events today are arrival for a Ship in transit and, for a stationary
  Ship, the observation itself (an action is expected to follow at once).
  """

  alias SpaceTraders.Fleet.Ship

  @overdue_after_seconds 5 * 60

  @doc "Grace after the next known event before a row is overdue."
  def overdue_after_seconds, do: @overdue_after_seconds

  @doc "Builds the row for a Ship (Cargo preloaded) as of `now`."
  def build(%Ship{} = ship, %DateTime{} = now) do
    overdue_at = overdue_at(ship)
    in_transit? = ship.nav_status == "IN_TRANSIT"

    %{
      id: ship.id,
      symbol: ship.symbol,
      ship_type: ship.ship_type,
      location: location(ship),
      in_transit?: in_transit?,
      from: short(ship.route_origin),
      to: short(ship.route_destination),
      at: if(!in_transit?, do: short(ship.waypoint_symbol)),
      depart_at: ship.route_departed_at,
      arrive_at: if(in_transit?, do: ship.route_arrives_at),
      fuel: {ship.fuel_current, ship.fuel_capacity},
      cargo: cargo(ship),
      observed_at: ship.state_observed_at,
      overdue_at: overdue_at,
      overdue?: overdue?(overdue_at, now)
    }
  end

  @doc "The moment a Ship's stored state becomes overdue, or nil when nothing is expected."
  def overdue_at(%Ship{} = ship) do
    case next_event_at(ship) do
      %DateTime{} = at -> DateTime.add(at, @overdue_after_seconds)
      nil -> nil
    end
  end

  defp next_event_at(%Ship{state_observed_at: nil}), do: nil

  defp next_event_at(%Ship{nav_status: "IN_TRANSIT", route_arrives_at: %DateTime{} = arrives}),
    do: arrives

  defp next_event_at(%Ship{state_observed_at: observed}), do: observed

  defp overdue?(nil, _now), do: false
  defp overdue?(overdue_at, now), do: DateTime.compare(now, overdue_at) != :lt

  defp location(%Ship{nav_status: "IN_TRANSIT"} = ship),
    do: "In transit to #{short(ship.route_destination)}"

  defp location(%Ship{nav_status: "DOCKED"} = ship),
    do: "Docked at #{short(ship.waypoint_symbol)}"

  defp location(%Ship{nav_status: "IN_ORBIT"} = ship),
    do: "In orbit at #{short(ship.waypoint_symbol)}"

  defp location(_ship), do: "Not yet observed"

  defp cargo(%Ship{cargo: items}) when is_list(items),
    do: Enum.map(items, &{&1.trade_symbol, &1.units})

  defp cargo(_ship), do: []

  # Waypoints within the headquarters System read by their last segment.
  defp short(nil), do: nil
  defp short(symbol), do: symbol |> String.split("-") |> List.last()
end
