defmodule SpaceTraders.Liveness do
  @moduledoc """
  In-memory liveness facts Plan Health reads: the engine's runtime heartbeat
  and whether the game is answering. Nothing is stored in the database; a
  restart starts both from the boot moment.

    * Engine - `RuntimeAuthority` beats once a second while it holds mutation
      authority. Without runtime authority (dev, test) no heartbeat is expected.
    * Game - every game response (2xx-4xx: the game answered) clears the
      failing state; a 5xx or transport failure starts it, once, at the first
      failure after the last answer.
  """

  alias SpaceTraders.{Clock, RuntimeAuthority}

  @key {__MODULE__, :atomics}
  @engine 1
  @game_failing_since 2

  @doc "Creates the counters; the engine's last beat starts at boot."
  def init do
    ref = :atomics.new(2, signed: true)
    :atomics.put(ref, @engine, now_ms())
    :persistent_term.put(@key, ref)
    :ok
  end

  @doc "Records one engine heartbeat."
  def beat, do: :atomics.put(ref(), @engine, now_ms())

  @doc "Records one game request outcome by HTTP status (or a transport failure)."
  def game_request(status) when is_integer(status) and status in 200..499,
    do: :atomics.put(ref(), @game_failing_since, 0)

  def game_request(_status) do
    _ = :atomics.compare_exchange(ref(), @game_failing_since, 0, now_ms())
    :ok
  end

  @doc """
  `%{expected?: boolean, last_beat_at: DateTime}`: whether this runtime runs
  the engine, and its last heartbeat.
  """
  def engine do
    %{
      expected?: RuntimeAuthority.enabled?(),
      last_beat_at: ref() |> :atomics.get(@engine) |> to_datetime()
    }
  end

  @doc "The first failed game request since the last answer, or nil."
  def game_failing_since do
    case :atomics.get(ref(), @game_failing_since) do
      0 -> nil
      ms -> to_datetime(ms)
    end
  end

  @doc false
  def reset do
    :atomics.put(ref(), @engine, now_ms())
    :atomics.put(ref(), @game_failing_since, 0)
  end

  defp ref do
    case :persistent_term.get(@key, nil) do
      nil ->
        init()
        :persistent_term.get(@key)

      ref ->
        ref
    end
  end

  defp now_ms, do: Clock.utc_now() |> DateTime.to_unix(:millisecond)
  defp to_datetime(ms), do: DateTime.from_unix!(ms, :millisecond)
end
