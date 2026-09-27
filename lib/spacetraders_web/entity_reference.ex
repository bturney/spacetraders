defmodule SpaceTradersWeb.EntityReference do
  @moduledoc false

  def path("system:" <> system), do: "/world/systems/#{system}"

  def path("waypoint:" <> rest), do: world_path(rest, "")
  def path("market:" <> rest), do: world_path(rest, "/market")
  def path("shipyard:" <> rest), do: world_path(rest, "/shipyard")
  def path("construction:" <> rest), do: world_path(rest, "/construction")
  def path("ship:" <> ship), do: "/ships/#{ship}"
  def path("contract:" <> contract), do: "/contracts/#{contract}"
  def path(_reference), do: nil

  def label("system:" <> _), do: "System"
  def label("waypoint:" <> _), do: "Waypoint"
  def label("market:" <> _), do: "Market"
  def label("shipyard:" <> _), do: "Shipyard"
  def label("construction:" <> _), do: "Construction"
  def label("ship:" <> _), do: "Ship"
  def label("contract:" <> _), do: "Contract"

  def system_from_waypoint(waypoint) when is_binary(waypoint) do
    waypoint |> String.split("-") |> Enum.drop(-1) |> Enum.join("-")
  end

  defp world_path(rest, suffix) do
    case String.split(rest, ":") do
      [system, waypoint] ->
        "/world/systems/#{system}/waypoints/#{waypoint}#{suffix}"

      [agent_id, system, waypoint] ->
        "/world/systems/#{system}/waypoints/#{waypoint}#{suffix}?agent=#{agent_id}"

      _ ->
        nil
    end
  end
end
