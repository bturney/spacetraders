defmodule SpaceTraders.Outbox.Notification do
  @moduledoc false

  use Ecto.Schema

  schema "outbox_notifications" do
    field :topic, :string
    field :event, :string
    field :payload, :map, default: %{}
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
