defmodule SpaceTraders.GenerationHorizon do
  @moduledoc "Evidence-bound remaining time for a Capacity Investment in this Fleet Generation."

  alias SpaceTraders.{Clock, Evidence, FleetGeneration, ShipAcquisitionCalibration}

  @doc """
  Returns `:known` with `duration_seconds`, or `:unknown` with a refusal `reason`.

  Both results carry the acquisition calibration and `evidence_ref`; only absent
  evidence has a nil reference. The newest `server:status` observation must be
  traceable, from this current Generation, not future-dated, and at most 30
  seconds old (Evidence's standard owned-read freshness budget). Invalid newest
  evidence never falls back to an older schedule.

  This query performs no game requests. Acquire a replacement explicitly through
  `Evidence.get_status_binding/2`. Durations are conservative whole seconds.
  """
  def current(agent, now \\ Clock.utc_now()) do
    case Evidence.latest_observation(agent, "server:status") do
      nil ->
        unknown(nil, :missing_reset_evidence)

      source ->
        horizon(source, now)
    end
  end

  defp horizon(source, now) do
    with {:ok, next_reset, _offset} <- next_reset(source.facts) do
      cond do
        source.operation_id != "get-status" or not Evidence.valid_observation?(source) or
            "server:status" not in source.dependency_keys ->
          unknown(source, :invalid_reset_evidence)

        not current_generation?(source) ->
          unknown(source, :generation_not_current)

        DateTime.compare(source.observed_at, now) == :gt ->
          unknown(source, :future_reset_evidence)

        DateTime.diff(now, source.observed_at, :microsecond) >
            Evidence.owned_read_freshness_seconds() * 1_000_000 ->
          unknown(source, :stale_reset_evidence)

        DateTime.compare(next_reset, now) != :gt ->
          unknown(source, :reset_not_in_future)

        true ->
          calibration = ShipAcquisitionCalibration.current()

          %{
            status: :known,
            duration_seconds:
              min(DateTime.diff(next_reset, now), calibration.horizon_window_seconds),
            evidence_ref: evidence_ref(source),
            calibration: calibration
          }
      end
    else
      _ -> unknown(source, :invalid_reset_evidence)
    end
  end

  defp current_generation?(source) do
    case FleetGeneration.current_fleet() do
      {:ok, %{state: :current, generation: %{id: generation_id, agent_id: agent_id}}} ->
        source.fleet_generation_id == generation_id and source.agent_id == agent_id

      _ ->
        false
    end
  end

  defp next_reset(%{"response" => %{"serverResets" => %{"next" => value}}}) when is_binary(value),
    do: DateTime.from_iso8601(value)

  defp next_reset(_facts), do: :error

  defp unknown(source, reason) do
    %{
      status: :unknown,
      duration_seconds: nil,
      evidence_ref: evidence_ref(source),
      reason: reason,
      calibration: ShipAcquisitionCalibration.current()
    }
  end

  defp evidence_ref(nil), do: nil

  defp evidence_ref(source) do
    %{
      observation_id: source.id,
      operation_id: source.operation_id,
      subject: source.subject,
      fleet_generation_id: source.fleet_generation_id,
      observed_at: source.observed_at,
      response_fingerprint: source.response_fingerprint
    }
  end
end
