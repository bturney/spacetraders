defmodule SpaceTraders.Timeline do
  @moduledoc """
  A shared timeline of pending async events (arrivals, cooldowns, deadlines).

  This is a library, not a scheduler process (ADR 0005): every pending event is
  persisted to the `timeline_events` table, and each event's owner — a Ship
  GenServer for arrivals/cooldowns, later the Contracts context for deadlines —
  owns its own `Process.send_after` timer. On boot the app re-arms owners from
  the table and catches up events that came due while it was down.

  Event types are atoms (`:arrival`, `:cooldown`, `:deadline`) and are stored
  as their string form. An owner has at most one pending event per type:
  scheduling a new event for the same owner+type cancels the outstanding one.
  """

  import Ecto.Query, warn: false

  require Logger

  alias SpaceTraders.Repo
  alias SpaceTraders.API.Model.{ShipNav, ShipNavRoute}
  alias SpaceTraders.Timeline.Event
  @event_types [:arrival, :cooldown, :deadline]

  @typedoc "The pending-event statuses stored in `timeline_events.status`."
  @type status :: :pending | :done | :cancelled

  @doc """
  Persists a pending event for `owner` due at `due_at`.

  Any outstanding pending event for the same `owner_type`/`owner_id`/
  `event_type` is cancelled first, so an owner has at most one pending event
  per type. Returns `{:ok, %Event{}}`.
  """
  @spec schedule_event(atom(), String.t(), atom(), DateTime.t(), map()) ::
          {:ok, Event.t()}
  def schedule_event(owner_type, owner_id, event_type, due_at, payload \\ %{})
      when event_type in @event_types and is_map(payload) do
    cancel_events(owner_type, owner_id, event_type)

    {:ok, event} =
      Repo.insert(%Event{
        owner_type: Atom.to_string(owner_type),
        owner_id: owner_id,
        event_type: Atom.to_string(event_type),
        due_at: microsecond_precision(due_at),
        status: "pending",
        payload: payload
      })

    {:ok, event}
  end

  @doc """
  Marks all pending events for `owner` as cancelled.

  When `event_type` is given, only events of that type are cancelled.
  """
  @spec cancel_events(atom(), String.t(), atom() | nil) :: :ok
  def cancel_events(owner_type, owner_id, event_type \\ nil) do
    Event
    |> where([e], e.owner_type == ^Atom.to_string(owner_type))
    |> where([e], e.owner_id == ^owner_id)
    |> where([e], e.status == "pending")
    |> maybe_filter_type(event_type)
    |> Repo.update_all(set: [status: "cancelled"])

    :ok
  end

  @doc "Lists the pending events for `owner`, soonest first."
  @spec pending_events(atom(), String.t()) :: [Event.t()]
  def pending_events(owner_type, owner_id) do
    Event
    |> where([e], e.owner_type == ^Atom.to_string(owner_type))
    |> where([e], e.owner_id == ^owner_id)
    |> where([e], e.status == "pending")
    |> order_by([e], asc: e.due_at)
    |> Repo.all()
  end

  @doc "Returns whether a persisted event is still pending."
  def pending?(%Event{id: id}) do
    Repo.exists?(from e in Event, where: e.id == ^id and e.status == "pending")
  end

  @doc """
  Lists the distinct owners that have at least one pending event.

  Used on boot to re-arm owners. Returns `[%{owner_type: type, owner_id: id}]`.
  """
  @spec pending_owners(atom() | nil) :: [%{owner_type: String.t(), owner_id: String.t()}]
  def pending_owners(owner_type \\ nil) do
    Event
    |> where([e], e.status == "pending")
    |> maybe_filter_owner_type(owner_type)
    |> select([e], %{owner_type: e.owner_type, owner_id: e.owner_id})
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Marks an event as fired (`done`). Idempotent.
  """
  @spec fire_event(Event.t()) :: :ok
  def fire_event(%Event{id: id}) do
    Event
    |> where([e], e.id == ^id and e.status == "pending")
    |> Repo.update_all(set: [status: "done"])

    :ok
  end

  @doc """
  Returns whether `event` is already due at `now`.
  """
  @spec due?(Event.t(), DateTime.t()) :: boolean()
  def due?(%Event{due_at: due_at}, now \\ DateTime.utc_now()) do
    DateTime.compare(due_at, now) != :gt
  end

  defp maybe_filter_type(query, nil), do: query

  defp maybe_filter_type(query, event_type),
    do: where(query, [e], e.event_type == ^Atom.to_string(event_type))

  defp maybe_filter_owner_type(query, nil), do: query

  defp maybe_filter_owner_type(query, owner_type),
    do: where(query, [e], e.owner_type == ^Atom.to_string(owner_type))

  # `:utc_datetime_usec` requires full microsecond precision; game timestamps
  # arrive at millisecond precision, so pad the field out (without changing the
  # instant).
  defp microsecond_precision(%DateTime{} = dt) do
    {usec, _precision} = dt.microsecond
    %{dt | microsecond: {usec, 6}}
  end

  @doc false
  def parse_expiration(expiration, seconds) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, due_at, _offset} -> due_at
      _ -> DateTime.add(DateTime.utc_now(), seconds, :second)
    end
  end

  @doc false
  def parse_expiration(_expiration, seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  @doc false
  def parse_arrival(%ShipNavRoute{arrival: arrival}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} ->
        {:ok, due_at}

      _ ->
        Logger.warning("ship arrival #{arrival} is not a parseable timestamp")
        :error
    end
  end

  @doc false
  def parse_arrival(_route), do: :error

  @doc false
  def arrival_payload(%ShipNav{route: %{destination: %{symbol: destination}}})
      when is_binary(destination),
      do: %{destination: destination}

  @doc false
  def arrival_payload(_nav), do: %{}
end
