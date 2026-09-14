defmodule SpaceTraders.Outbox do
  @moduledoc """
  Atomically commits durable state changes with their external notification.

  Delivery is at-least-once. Consumers must use the notification id when they
  need to deduplicate a redelivery after process failure.
  """

  import Ecto.Query

  alias SpaceTraders.Outbox.Notification
  alias SpaceTraders.Repo

  def publish(%{topic: topic, event: event} = notification, state_change)
      when is_binary(topic) and is_binary(event) and is_function(state_change, 0) do
    Repo.transaction(fn ->
      result = state_change.()

      Repo.insert!(%Notification{
        topic: topic,
        event: event,
        payload: Map.get(notification, :payload, %{})
      })

      result
    end)
  end

  def dispatch_pending(limit \\ 100) do
    Notification
    |> where([notification], is_nil(notification.delivered_at))
    |> order_by([notification], asc: notification.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.each(&dispatch/1)
  end

  defp dispatch(notification) do
    Phoenix.PubSub.broadcast(
      SpaceTraders.PubSub,
      notification.topic,
      {:outbox, notification.id, notification.event, notification.payload}
    )

    notification
    |> Ecto.Changeset.change(delivered_at: DateTime.utc_now())
    |> Repo.update!()
  end
end
