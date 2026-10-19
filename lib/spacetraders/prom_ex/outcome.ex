defmodule SpaceTraders.PromEx.Outcome do
  use PromEx.Plugin

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(:spacetraders_outcome_metrics, [
      # Earnings records (#766): the domain area is the prefix; `job` names the app.
      sum(
        [:earnings, :credits, :total],
        event_name: [:earnings, :credits],
        measurement: :credits,
        tags: [:flow, :source, :ship_type, :good, :price_age],
        description: "Credits of committed Earnings records by flow (revenue or cost type)."
      ),
      counter(
        [:earnings, :trips, :total],
        event_name: [:earnings, :trips],
        tags: [:result, :source, :ship_type, :good, :price_age],
        description:
          "Committed Earnings records, by whether Net Earnings beat the expected value."
      ),
      sum(
        [:earnings, :ship_seconds, :total],
        event_name: [:earnings, :ship_seconds],
        measurement: :seconds,
        tags: [:source, :ship_type, :good, :price_age],
        description: "Ship-seconds from taking the work until its last disposal."
      ),
      last_value(
        [:agent, :credits],
        event_name: [:agent, :credits],
        measurement: :credits,
        description: "Current credits from the latest authoritative owned Agent read."
      )
    ])
  end
end
