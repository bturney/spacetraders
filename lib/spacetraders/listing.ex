defmodule SpaceTraders.Listing do
  @moduledoc false

  alias SpaceTraders.Agent.Agent, as: AgentRecord

  @market_trait "MARKETPLACE"
  @shipyard_trait "SHIPYARD"

  @doc "Builds market and shipyard listings, reusing fresh headquarters waypoints when available."
  def for_ships(
        %AgentRecord{agent_token: token, headquarters: headquarters},
        ships,
        headquarters_waypoints
      )
      when is_binary(token) and token != "" and is_list(ships) do
    ships_by_system = on_site_by_system(ships)
    headquarters_system = system_from_headquarters(headquarters)

    %{
      markets:
        market_listings(token, ships_by_system, headquarters_system, headquarters_waypoints),
      shipyards:
        shipyard_listings(token, ships_by_system, headquarters_system, headquarters_waypoints)
    }
  end

  def for_ships(%AgentRecord{}, _ships, _headquarters_waypoints) do
    %{markets: {:error, :agent_token_missing}, shipyards: {:error, :agent_token_missing}}
  end

  defp on_site_by_system(ships) do
    ships
    |> Enum.filter(&on_site?/1)
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

  defp market_listings(token, ships_by_system, headquarters_system, headquarters_waypoints) do
    {waypoints, unavailable?} =
      discover_for_snapshot(
        token,
        Map.keys(ships_by_system),
        headquarters_system,
        headquarters_waypoints,
        @market_trait
      )

    {listings, unavailable?} =
      Enum.reduce(on_site_waypoints(waypoints, ships_by_system), {[], unavailable?}, fn
        {waypoint, ships}, {listings, unavailable?} ->
          case SpaceTraders.API.get_market(token, waypoint.system_symbol, waypoint.symbol) do
            {:ok, market} ->
              {[%{waypoint: waypoint.symbol, market: market, ships: ships} | listings],
               unavailable?}

            {:error, _reason} ->
              {listings, true}
          end
      end)

    result(Enum.reverse(listings), unavailable?)
  end

  defp shipyard_listings(token, ships_by_system, headquarters_system, headquarters_waypoints) do
    {waypoints, unavailable?} =
      discover_for_snapshot(
        token,
        Map.keys(ships_by_system),
        headquarters_system,
        headquarters_waypoints,
        @shipyard_trait
      )

    {listings, unavailable?} =
      Enum.reduce(on_site_waypoints(waypoints, ships_by_system), {[], unavailable?}, fn
        {waypoint, _ships}, {listings, unavailable?} ->
          case SpaceTraders.API.get_shipyard(token, waypoint.system_symbol, waypoint.symbol) do
            {:ok, shipyard} ->
              {[%{waypoint: waypoint.symbol, shipyard: shipyard} | listings], unavailable?}

            {:error, _reason} ->
              {listings, true}
          end
      end)

    result(Enum.reverse(listings), unavailable?)
  end

  defp discover_for_snapshot(
         token,
         systems,
         headquarters_system,
         {:ok, headquarters_waypoints},
         trait
       ) do
    headquarters =
      if headquarters_system in systems,
        do: Enum.filter(headquarters_waypoints, &has_trait?(&1, trait)),
        else: []

    {other_waypoints, unavailable?} =
      discover_waypoints(token, Enum.reject(systems, &(&1 == headquarters_system)), trait)

    {headquarters ++ other_waypoints, unavailable?}
  end

  defp discover_for_snapshot(token, systems, _headquarters_system, _headquarters_waypoints, trait) do
    discover_waypoints(token, systems, trait)
  end

  defp on_site_waypoints(waypoints, ships_by_system) do
    waypoints
    |> Enum.sort_by(& &1.symbol)
    |> Enum.map(fn waypoint ->
      ships =
        Enum.filter(
          Map.get(ships_by_system, waypoint.system_symbol, []),
          &at?(&1, waypoint.symbol)
        )

      {waypoint, ships}
    end)
    |> Enum.reject(fn {_waypoint, ships} -> ships == [] end)
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

  defp on_site?(%{nav: %{status: "DOCKED", system_symbol: system}})
       when is_binary(system),
       do: true

  defp on_site?(_), do: false

  defp has_trait?(%{traits: traits}, trait) when is_list(traits) do
    Enum.any?(traits, &(&1.symbol == trait))
  end

  defp has_trait?(_, _), do: false

  defp at?(%{nav: %{waypoint_symbol: waypoint}}, waypoint), do: true
  defp at?(_, _), do: false

  defp system_from_headquarters(headquarters) when is_binary(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> system
      _ -> nil
    end
  end

  defp system_from_headquarters(_), do: nil
end
