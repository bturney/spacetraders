defmodule SpaceTraders.Timeline.Event do
  @moduledoc """
  A persisted pending event (arrival, cooldown, deadline) in the shared timeline.

  `owner_type`/`owner_id` name the entity that owns the event (a ship by
  symbol, later a contract by id); `event_type` is one of `arrival`,
  `cooldown` or `deadline`; `due_at` is when the event comes due. Rows move
  from `pending` to `done` (fired) or `cancelled`.
  """

  use Ecto.Schema

  schema "timeline_events" do
    field :owner_type, :string
    field :owner_id, :string
    field :event_type, :string
    field :due_at, :utc_datetime_usec
    field :status, :string, default: "pending"
    field :payload, :map, default: %{}

    timestamps(type: :utc_datetime)
  end
end
