defmodule SpaceTraders.PromEx.FleetOutcome do
  use PromEx.Plugin

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(:spacetraders_fleet_outcome_metrics, [
      last_value(
        [:spacetraders, :outcome, :ships, :total],
        event_name: [:spacetraders, :outcome, :fleet, :ships],
        measurement: :count,
        tags: [:claim, :intent_state, :nav_status],
        description:
          "Registered current Ships by independent state dimension; unused labels are empty."
      ),
      counter(
        [:spacetraders, :outcome, :fleet, :recomputes, :total],
        event_name: [:spacetraders, :outcome, :fleet, :projection],
        tags: [:family],
        description: "Successful coalesced full-vector Fleet projections by bounded state family."
      ),
      counter(
        [:spacetraders, :outcome, :fleet, :projection, :failures, :total],
        event_name: [:spacetraders, :outcome, :fleet, :projection_failed],
        tags: [:family],
        description: "Dropped Fleet projections by bounded state family."
      )
    ])
  end
end
