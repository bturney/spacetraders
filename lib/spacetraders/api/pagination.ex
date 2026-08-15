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
        {:ok, []} -> {:halt, {:ok, collected}}
        {:ok, items} when length(items) < limit -> {:halt, {:ok, collected ++ items}}
        {:ok, items} -> {:cont, {:ok, collected ++ items}}
        {:error, reason} -> {:halt, {:error, reason, collected}}
      end
    end)
  end
end
