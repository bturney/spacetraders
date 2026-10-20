defmodule SpaceTraders.API.Pagination do
  @moduledoc false

  @default_limit 20

  alias SpaceTraders.API.AgentTokenReference

  @doc "Collects every Waypoint page while preserving data collected before a failure."
  @spec waypoints(AgentTokenReference.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term(), list()}
  def waypoints(credential_ref, system, params \\ [], opts \\ []) do
    collect(
      fn page ->
        SpaceTraders.API.get_waypoints(
          credential_ref,
          system,
          Keyword.merge(params, limit: @default_limit, page: page),
          opts
        )
      end,
      @default_limit
    )
  end

  @doc """
  Collects every owned Ship page. A page repeating an already collected Ship
  ends the read, so a source that ignores paging cannot loop forever.
  """
  @spec ships((keyword() -> {:ok, list()} | {:error, term()})) ::
          {:ok, list()} | {:error, term(), list()}
  def ships(fetch_page) when is_function(fetch_page, 1) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn page, {:ok, collected, seen} ->
      case fetch_page.(limit: @default_limit, page: page) do
        {:ok, ships} when is_list(ships) ->
          fresh = Enum.reject(ships, &MapSet.member?(seen, &1.symbol))
          collected = [fresh | collected]

          if length(ships) < @default_limit or length(fresh) < length(ships),
            do: {:halt, {:ok, flatten_pages(collected)}},
            else: {:cont, {:ok, collected, MapSet.union(seen, MapSet.new(fresh, & &1.symbol))}}

        {:error, reason} ->
          {:halt, {:error, reason, flatten_pages(collected)}}
      end
    end)
  end

  @doc "Collects pages until an empty or short page is returned."
  @spec collect((pos_integer() -> {:ok, list()} | {:error, term()}), pos_integer()) ::
          {:ok, list()} | {:error, term(), list()}
  def collect(fetch_page, limit)
      when is_function(fetch_page, 1) and is_integer(limit) and limit > 0 do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, collected} ->
      case fetch_page.(page) do
        {:ok, []} ->
          {:halt, {:ok, flatten_pages(collected)}}

        {:ok, items} when length(items) < limit ->
          {:halt, {:ok, flatten_pages([items | collected])}}

        {:ok, items} ->
          {:cont, {:ok, [items | collected]}}

        {:error, reason} ->
          {:halt, {:error, reason, flatten_pages(collected)}}
      end
    end)
  end

  defp flatten_pages(pages), do: pages |> Enum.reverse() |> List.flatten()
end
