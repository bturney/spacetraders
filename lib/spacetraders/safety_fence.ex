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

  import Ecto.Query

  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @active_states ["sent_or_unknown", "ambiguous", "bounded_unknown"]

  @doc "Returns whether an attempt currently suppresses dependent mutations."
  @spec active?(Attempt.t()) :: boolean()
  def active?(%Attempt{state: state}), do: state in @active_states

  @doc "Returns active attempts whose dependency keys overlap the candidate action."
  @spec blocking_attempts([String.t()], Ecto.UUID.t() | nil) :: [Attempt.t()]
  def blocking_attempts(dependency_keys, excluded_attempt_id \\ nil)

  def blocking_attempts([], _excluded_attempt_id), do: []

  def blocking_attempts(dependency_keys, excluded_attempt_id) do
    Attempt
    |> where([attempt], attempt.state in ^@active_states)
    |> where(
      [attempt],
      fragment("? && ?", attempt.dependency_keys, type(^dependency_keys, {:array, :string}))
    )
    |> maybe_exclude(excluded_attempt_id)
    |> order_by([attempt], asc: attempt.prepared_at, asc: attempt.id)
    |> Repo.all()
  end

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

  defp maybe_exclude(query, nil), do: query
  defp maybe_exclude(query, id), do: where(query, [attempt], attempt.id != ^id)
end
