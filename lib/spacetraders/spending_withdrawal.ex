defmodule SpaceTraders.SpendingWithdrawal do
  @moduledoc """
  Returns a Market purchase refused at its pre-marker spending checkpoint to
  Allocation for fresh planning (ADR 0013, #579).

  The prepared request is never resized in the send window: the attempt is
  recorded not sent, its Intent is superseded, and the never-sent
  Commitment's Reservation and Claims are released unless another unfinished
  owner still depends on them. A `market_purchase_withdrawn` notification
  wakes Allocation to replan from fresh evidence. Refuel and jump spending is
  not replanned here; it stays paused for the Operator.

  Runs inside the caller's per-Agent admission transaction.
  """

  import Ecto.Query

  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @replan_reasons [
    :market_quote_stale_or_missing,
    :insufficient_unreserved_headroom,
    :authoritative_credit_facts_required,
    :unbounded_purchase_exposure,
    :credit_calibration_superseded,
    :credit_spending_paused
  ]

  @doc "Whether a spending refusal returns the work to Allocation for replanning."
  def replan_reason?(reason), do: reason in @replan_reasons

  @doc "Whether this refused attempt is withdrawn for replanning rather than suppressed."
  def replannable?(%Attempt{operation_id: "purchase-cargo"}, reason), do: replan_reason?(reason)
  def replannable?(_attempt, _reason), do: false

  @doc "Withdraws the still-prepared purchase and returns its work to Allocation."
  def withdraw(%Intent{} = intent, %Attempt{} = attempt, reason) do
    with {:ok, _} <- MutationAttempts.record_not_sent(attempt, reason_text(reason)) do
      intent
      |> Ecto.Changeset.change(
        status: "superseded",
        in_flight_action: nil,
        mutation_attempt_id: nil,
        finished_at: DateTime.utc_now(:second),
        blocker: nil,
        last_action_result: %{
          "outcome" => "spending_replan_required",
          "reason" => reason_text(reason),
          "mutation_attempt_id" => attempt.id
        }
      )
      |> Repo.update!()

      release_unsent_commitment(intent)
      notify(intent, attempt, reason)
      {:error, reason}
    end
  end

  # Nothing was sent, so no protection is owed to the withdrawn work; another
  # unfinished owner of the same Commitment keeps its protections.
  defp release_unsent_commitment(%Intent{fleet_commitment_id: nil}), do: :ok

  defp release_unsent_commitment(%Intent{fleet_commitment_id: id} = intent) do
    unless Repo.exists?(
             from i in Intent,
               where:
                 i.fleet_commitment_id == ^id and i.id != ^intent.id and
                   i.status in ^Intent.unfinished_states()
           ) do
      Repo.update_all(from(c in Commitment, where: c.id == ^id), set: [unwind_state: :released])
      Repo.delete_all(from c in "fleet_commitment_claims", where: c.fleet_commitment_id == ^id)
    end

    :ok
  end

  defp notify(intent, attempt, reason) do
    Repo.insert!(%SpaceTraders.Outbox.Notification{
      topic: "fleet_market_evidence",
      event: "market_purchase_withdrawn",
      payload: %{
        "agent_id" => attempt.agent_id,
        "waypoint" => intent.target_waypoint,
        "intent_id" => intent.id,
        "mutation_attempt_id" => attempt.id,
        "reason" => to_string(reason)
      }
    })
  end

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
