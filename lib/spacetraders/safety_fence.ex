defmodule SpaceTraders.SafetyFence do
  @moduledoc """
  Identifies legacy unresolved mutation evidence that is explicitly fenced.

  Cutover is intentionally conservative: unfamiliar blockers must be reconciled
  instead of being reclassified as safe merely because work is blocked.
  """

  @reconciliation_reasons [
    "ambiguous",
    "ambiguous_jump_evidence",
    "ambiguous_operation_evidence",
    "awaiting_reconciliation",
    "missing_delivery_recipient",
    "missing_market_transaction",
    "mutation_outcome_unknown",
    "retry_exhausted",
    "unexpected_delivery_recipient",
    "unexpected_market_transaction"
  ]

  def explicit?(%{
        status: "blocked",
        in_flight_action: action,
        blocker: %{reason: reason, evidence: evidence, retry_condition: retry_condition}
      })
      when is_map(action) and map_size(action) > 0 and is_binary(reason) and
             is_binary(evidence) and evidence != "" and is_binary(retry_condition) and
             retry_condition != "" do
    reason in @reconciliation_reasons
  end

  def explicit?(_record), do: false
end
