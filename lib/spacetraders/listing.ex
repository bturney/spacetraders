defmodule SpaceTraders.Listing do
  @moduledoc false

  def docked_by_system(ships) do
    ships
    |> Enum.filter(&docked?/1)
    |> Enum.group_by(& &1.nav.system_symbol)
  end

  def discover_waypoints(token, systems, trait) do
    Enum.reduce(Enum.sort(systems), {[], false}, fn system, {waypoints, unavailable?} ->
      case fetch_waypoint_pages(token, system, trait) do
        {:ok, found} -> {waypoints ++ Enum.filter(found, &has_trait?(&1, trait)), unavailable?}
        {:error, _reason} -> {waypoints, true}
      end
    end)
  end

  def result(listings, unavailable?) do
    if unavailable?, do: {:partial, listings}, else: {:ok, listings}
  end

  defp fetch_waypoint_pages(token, system, trait) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, waypoints} ->
      case SpaceTraders.API.get_waypoints(token, system, traits: trait, limit: 20, page: page) do
        {:ok, []} -> {:halt, {:ok, waypoints}}
        {:ok, found} when length(found) < 20 -> {:halt, {:ok, waypoints ++ found}}
        {:ok, found} -> {:cont, {:ok, waypoints ++ found}}
        error -> {:halt, error}
      end
    end)
  end

  defp docked?(%{nav: %{status: "DOCKED", system_symbol: system}}) when is_binary(system),
    do: true

  defp docked?(_), do: false

  defp has_trait?(%{traits: traits}, trait) when is_list(traits) do
    Enum.any?(traits, &(&1.symbol == trait))
  end

  defp has_trait?(_, _), do: false
end
