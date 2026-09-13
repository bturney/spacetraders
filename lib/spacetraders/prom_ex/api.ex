defmodule SpaceTraders.PromEx.API do
  use PromEx.Plugin

  @event [:spacetraders, :api, :request]
  @fleet_activity_event [:spacetraders, :fleet, :activity]
  @intent_transition_event [:spacetraders, :intent, :transition]

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(
      :spacetraders_api_request_metrics,
      [
        counter(
          [:spacetraders, :api, :requests, :total],
          event_name: @event,
          measurement: :count,
          tags: [:endpoint, :status, :outcome],
          description: "SpaceTraders API requests by bounded endpoint, status, and outcome."
        ),
        counter(
          [:spacetraders, :job, :activity, :total],
          event_name: @fleet_activity_event,
          measurement: :count,
          tags: [:kind, :job_type, :job_state],
          description: "Durable gameplay activity by kind, Job type, and Job State."
        ),
        counter(
          [:spacetraders, :intent, :transitions, :total],
          event_name: @intent_transition_event,
          measurement: :count,
          tags: [:intent_type, :from_state, :to_state],
          description: "Intent State transitions by type and state."
        )
      ]
    )
  end
end
