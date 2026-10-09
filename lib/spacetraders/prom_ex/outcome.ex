defmodule SpaceTraders.PromEx.Outcome do
  use PromEx.Plugin

  @impl PromEx.Plugin
  def event_metrics(_opts) do
    Event.build(:spacetraders_outcome_metrics, [
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
      )
    ])
  end
end
