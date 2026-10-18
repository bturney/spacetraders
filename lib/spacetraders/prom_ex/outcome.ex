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
        description: "Committed Earnings records, by whether Net Earnings beat the expected value."
      ),
      sum(
        [:earnings, :ship_seconds, :total],
        event_name: [:earnings, :ship_seconds],
        measurement: :seconds,
        tags: [:source, :ship_type, :good, :price_age],
        description: "Ship-seconds from taking the work until its last disposal."
      ),
      last_value(
        [:spacetraders, :outcome, :agent, :credits],
        event_name: [:spacetraders, :outcome, :agent],
        measurement: :credits,
        description: "Current credits from the latest authoritative owned Agent read."
      ),
      last_value(
        [:spacetraders, :outcome, :contracts],
        event_name: [:spacetraders, :outcome, :contracts],
        measurement: :count,
        tags: [:status],
        description: "Current Contract counts by bounded status from the latest owned read."
      ),
      sum(
        [:spacetraders, :outcome, :credits, :transactions, :total],
        event_name: [:spacetraders, :outcome, :transaction],
        measurement: :credits,
        tags: [:intent_type, :operation],
        description:
          "Gross confirmed transaction credits by bounded root Intent type and operation."
      ),
      last_value(
        [:spacetraders, :outcome, :systems, :charted],
        event_name: [:spacetraders, :outcome, :chart],
        measurement: :count,
        description:
          "Distinct Systems with a known durable scanned-Waypoint identity for non-stale Agents."
      ),
      sum(
        [:spacetraders, :outcome, :waypoints, :scanned, :total],
        event_name: [:spacetraders, :outcome, :scan],
        measurement: :count,
        description:
          "Committed waypoint scan observations since instrumentation; repeated waypoints count again."
      ),
      last_value(
        [:spacetraders, :outcome, :observed_at, :seconds],
        event_name: [:spacetraders, :outcome, :observed],
        measurement: :observed_at_seconds,
        tags: [:family],
        description: "Epoch time of the latest real observation for each outcome family."
      ),
      last_value(
        [:spacetraders, :outcome, :agent, :credits, :previous],
        event_name: [:spacetraders, :outcome, :credit_pair],
        measurement: &Map.get(&1, :previous_credits),
        description:
          "Previous genuine authoritative credits; valid only with a positive previous observation time."
      ),
      last_value(
        [:spacetraders, :outcome, :agent, :credits, :previous_observed_at, :seconds],
        event_name: [:spacetraders, :outcome, :credit_pair],
        measurement: :previous_observed_at_seconds,
        description:
          "Previous authoritative credit observation epoch; zero means the interval is unknown."
      )
    ])
  end
end
