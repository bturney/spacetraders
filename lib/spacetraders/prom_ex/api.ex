defmodule SpaceTraders.PromEx.API do
  use PromEx.Plugin

  @event [:spacetraders, :api, :request]
  @capacity_admission_event [:spacetraders, :api, :capacity, :admission]
  @capacity_actual_event [:spacetraders, :api, :capacity, :actual]
  @governor_admission_event [:spacetraders, :api, :capacity, :governor]
  @capacity_reject_event [:spacetraders, :api, :capacity, :reject]
  @capacity_recovered_event [:spacetraders, :api, :capacity, :recovered]
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
          [:spacetraders, :api, :capacity, :governor, :admissions, :total],
          event_name: @governor_admission_event,
          measurement: :count,
          tags: [:lane, :backpressure],
          description:
            "API Capacity Governor production admissions by lane and backpressure state."
        ),
        distribution(
          [:spacetraders, :api, :capacity, :governor, :admission, :queue_time, :milliseconds],
          event_name: @governor_admission_event,
          measurement: :queue_time,
          reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 5000]],
          description: "Queue wait before governor production admissions."
        ),
        counter(
          [:spacetraders, :api, :capacity, :rejections, :total],
          event_name: @capacity_reject_event,
          measurement: :count,
          tags: [:ordinary_delayed],
          description: "Protocol-limit rejections and Retry-After ordinary admission delays."
        ),
        last_value(
          [:spacetraders, :api, :capacity, :rejections, :window],
          event_name: @capacity_reject_event,
          measurement: :protocol_rejections,
          description: "Protocol-limit rejections inside the governor calibration window."
        ),
        distribution(
          [:spacetraders, :api, :capacity, :rejections, :retry_after, :seconds],
          event_name: @capacity_reject_event,
          measurement: :retry_after_seconds,
          reporter_options: [buckets: [1, 2, 5, 10, 30, 60]],
          description: "Retry-After delays the game granted on protocol rejections."
        ),
        counter(
          [:spacetraders, :api, :capacity, :recoveries, :total],
          event_name: @capacity_recovered_event,
          measurement: :count,
          description: "Recoveries from protocol backpressure after clean responses."
        ),
        counter(
          [:spacetraders, :fleet, :activity, :total],
          event_name: @fleet_activity_event,
          measurement: :count,
          tags: [:kind],
          description: "Durable Fleet activity by kind."
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
