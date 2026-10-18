defmodule SpaceTradersWeb.EntityReference do
  @moduledoc false

  def system_from_waypoint(waypoint) when is_binary(waypoint) do
    waypoint |> String.split("-") |> Enum.drop(-1) |> Enum.join("-")
  end
end
