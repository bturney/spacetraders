defmodule SpaceTraders.Evidence.Demand do
  @moduledoc "Typed input describing the evidence needed for one governed read."

  @enforce_keys [:subject, :required_facts, :owner]
  defstruct [
    :subject,
    :required_facts,
    :owner,
    :deadline_at,
    :freshness_seconds,
    :agent_id,
    :strategy_revision_id,
    lane: :standard,
    strategic_priority: nil,
    expected_value: nil,
    discovery: false
  ]

  @type t :: %__MODULE__{
          subject: String.t(),
          required_facts: [String.t()],
          owner: String.t(),
          deadline_at: DateTime.t() | nil,
          freshness_seconds: non_neg_integer() | nil,
          agent_id: pos_integer() | nil,
          strategy_revision_id: pos_integer() | nil,
          lane: :safety | :reconciliation | :standard,
          strategic_priority: integer() | nil,
          expected_value: number() | nil,
          discovery: boolean()
        }
end
