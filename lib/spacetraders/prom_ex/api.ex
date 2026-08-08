defmodule SpaceTraders.PromEx.API do
  use PromEx.Plugin

  @event [:spacetraders, :api, :request]

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(
      :spacetraders_api_request_metrics,
      [
        counter(
          [:spacetraders, :api, :requests, :total],
          event_name: @event,
          measurement: :count,
          tags: [:endpoint, :status],
          description: "SpaceTraders API requests by endpoint and status."
        )
      ]
    )
  end
end
