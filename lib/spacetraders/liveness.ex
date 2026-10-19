defmodule SpaceTraders.Liveness do
  @moduledoc """
  In-memory liveness facts Plan Health reads: the engine's runtime heartbeat
  and whether the game is answering. Nothing is stored in the database; a
  restart starts both from the boot moment.

    * Engine - `RuntimeAuthority` beats once a second while it holds mutation
      authority. Without runtime authority (dev, test) no heartbeat is expected.
    * Game - every game response (2xx-4xx: the game answered) records the last
      answer and clears the failing state; a 5xx or transport failure marks it
      failing. A failing game is silent since its last answer (or boot).
  """

  alias SpaceTraders.{Clock, RuntimeAuthority}

  @key {__MODULE__, :atomics}
  @engine 1
  @game_answered 2
  @game_failing 3

  @doc "Creates the counters; the engine's last beat and the game's last answer start at boot."
  def init do
    ref = :atomics.new(3, signed: true)
    :persistent_term.put(@key, ref)
    reset()
    :ok
  end

  @doc "Records one engine heartbeat."
  def beat, do: :atomics.put(ref(), @engine, now_ms())

  @doc "Records one game request outcome by HTTP status (or a transport failure)."
  def game_request(status) when is_integer(status) and status in 200..499 do
    ref = ref()
    :atomics.put(ref, @game_answered, now_ms())
    :atomics.put(ref, @game_failing, 0)
  end

  def game_request(_status) do
    :atomics.put(ref(), @game_failing, 1)
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

  @doc "While the game is failing, its last answer (or boot); otherwise nil."
  def game_failing_since do
    ref = ref()

    case :atomics.get(ref, @game_failing) do
      0 -> nil
      _ -> ref |> :atomics.get(@game_answered) |> to_datetime()
    end
  end

  @doc false
  def reset do
    ref = ref()
    now = now_ms()
    :atomics.put(ref, @engine, now)
    :atomics.put(ref, @game_answered, now)
    :atomics.put(ref, @game_failing, 0)
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
