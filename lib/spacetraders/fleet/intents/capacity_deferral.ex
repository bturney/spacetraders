defmodule SpaceTraders.Fleet.Intents.CapacityDeferral do
  @moduledoc """
  Root Intent Capacity Deferral: the one place Ship Execution recognizes API
  capacity pressure.

  Capacity Deferral is durable temporary waiting. It is never mutation
  evidence, objective infeasibility, Neutral Wait, or Attention; MutationAttempts
  keeps sole authority over any selected mutation it interrupts.

  The owning Intent stays durable and schedules a bounded Timeline wakeup from
  the governor's `Disposition`; it never reads raw governor timing. Governor
  notifications may only accelerate reconsideration: the bound keeps liveness
  when guidance is far away, a notification is missed, or the governor's
  process-local state is lost on restart.
  """

  alias SpaceTraders.API.CapacityGovernor.Disposition
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.MutationAttempts.Attempt

  @minimum_seconds 1
  @fallback_seconds 60

  @doc """
  Whether a failure means only that the governed request could not be admitted
  or was protocol-throttled: a game 429, missing governor authority, or either
  one met while acquiring recovery evidence.
  """
  defguard capacity_pressure(reason)
           when (is_struct(reason, SpaceTraders.API.GameplayError) and
                   :erlang.map_get(:code, reason) == 429) or
                  reason == :capacity_unavailable or
                  (is_tuple(reason) and tuple_size(reason) == 2 and
                     elem(reason, 0) == :awaiting_reconciliation and
                     ((is_struct(elem(reason, 1), SpaceTraders.API.GameplayError) and
                         :erlang.map_get(:code, elem(reason, 1)) == 429) or
                        elem(reason, 1) == :capacity_unavailable))

  @doc """
  Runtime-clock wakeup for a disposition. Guidance is an offset from the
  governor's own observation time, kept within one second and the fallback bound.
  """
  @spec wake_at(Disposition.t(), DateTime.t()) :: DateTime.t()
  def wake_at(%Disposition{} = disposition, %DateTime{} = now) do
    offset_ms =
      case disposition do
        %Disposition{retry_at: %DateTime{} = retry_at, observed_at: observed_at} ->
          DateTime.diff(retry_at, observed_at, :millisecond)

        _ ->
          0
      end

    offset_ms
    |> max(@minimum_seconds * 1000)
    |> min(@fallback_seconds * 1000)
    |> then(&DateTime.add(now, &1, :millisecond))
  end

  @doc """
  Asks the governor about the governed work an Intent resumes with. An
  unresolved send resumes with a protected recovery read; anything else
  resumes with ordinary work (its prepared mutation, or a Ship read).
  """
  @spec disposition(Attempt.t() | nil) :: Disposition.t()
  def disposition(attempt) do
    {operation_id, attrs} = resumed_work(attempt)
    FleetCapacity.disposition(operation_id, attrs)
  end

  @doc """
  Reports one (re-)deferral with bounded labels only: the governor's reason
  and whether the resumed work is protected recovery or ordinary work.
  `deferred_seconds` is how long the work has been waiting since `since`.
  """
  @spec observe(Disposition.t(), Attempt.t() | nil, DateTime.t()) :: :ok
  def observe(%Disposition{reason: reason}, attempt, %DateTime{} = since) do
    :telemetry.execute(
      [:spacetraders, :intent, :capacity_deferral],
      %{count: 1, deferred_seconds: max(DateTime.diff(DateTime.utc_now(), since), 0)},
      %{reason: reason, work: work(attempt)}
    )
  end

  defp work(attempt) do
    case resumed_work(attempt) do
      {_operation, %{purpose: :recovery}} -> :recovery
      _ -> :ordinary
    end
  end

  defp resumed_work(%Attempt{state: state})
       when state in ["sent_or_unknown", "ambiguous", "bounded_unknown"],
       do: {"get-my-ship", %{purpose: :recovery}}

  defp resumed_work(%Attempt{state: "prepared", operation_id: operation_id}),
    do: {operation_id, %{}}

  defp resumed_work(_attempt), do: {"get-my-ship", %{}}
end
