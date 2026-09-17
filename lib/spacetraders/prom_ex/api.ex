defmodule SpaceTraders.PromEx.API do
  use PromEx.Plugin

  @event [:spacetraders, :api, :request]
  @capacity_admission_event [:spacetraders, :api, :capacity, :admission]
  @capacity_actual_event [:spacetraders, :api, :capacity, :actual]
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
          [:spacetraders, :api, :capacity, :admissions, :total],
          event_name: @capacity_admission_event,
          measurement: :count,
          tags: [:classification, :owner, :lane, :disposition, :reason, :backpressure],
          description: "Shadow API capacity decisions without production enforcement."
        ),
        counter(
          [:spacetraders, :api, :capacity, :actual, :total],
          event_name: @capacity_actual_event,
          measurement: :count,
          tags: [:status, :outcome, :shadow_disposition],
          description: "Production API outcomes correlated to shadow capacity decisions."
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
