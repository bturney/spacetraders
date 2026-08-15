defmodule SpaceTraders.API.Pagination do
  @moduledoc false

  @default_limit 20

  @doc "Collects every Waypoint page while preserving data collected before a failure."
  @spec waypoints(String.t(), String.t(), keyword()) ::
          {:ok, list()} | {:error, term(), list()}
  def waypoints(token, system, params \\ []) do
    collect(
      fn page ->
        SpaceTraders.API.get_waypoints(
          token,
          system,
          Keyword.merge(params, limit: @default_limit, page: page)
        )
      end,
      @default_limit
    )
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
