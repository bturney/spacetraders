defmodule SpaceTraders.Outcomes.PostCommit do
  @moduledoc """
  Cheap writer-side bridge from Repo query telemetry to the single Outcomes worker.

  Ecto emits transaction telemetry in the writer process. Buffer bounded dirty
  families, additive scan counts and retained owned observations there until the
  outer COMMIT; ROLLBACK discards them. Nested Repo transactions share that outer
  boundary. No writer SQL, worker wait, or second process is introduced.
  """
  require Logger

  alias SpaceTraders.{Evidence.Observation, Repo}

  @fleet_families [:claim, :intent_state, :nav_status]
  @families @fleet_families ++ [:chart]
  @handler {__MODULE__, :durable_changes}
  @pending {__MODULE__, :pending}

  def attach(worker) do
    :telemetry.detach(@handler)

    :telemetry.attach(
      @handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      &__MODULE__.durable_change/4,
      worker
    )
  end

  def detach, do: :telemetry.detach(@handler)

  # Called inside the observation's retention transaction, before its COMMIT.
  def observe(%Observation{operation_id: operation} = observation)
      when operation in ["get-my-agent", "get-contracts"] do
    case Process.get(@pending) do
      nil ->
        # A missing BEGIN (for example, the bridge started during this
        # transaction) cannot prove commit. Drop rather than publish early.
        drop()

      pending ->
        Process.put(@pending, %{pending | observations: [observation | pending.observations]})
    end

    :ok
  rescue
    _ -> drop()
  catch
    _, _ -> drop()
  end

  def observe(_observation), do: :ok

  # Retain only the bounded nav fact in the existing mutation ledger. Its
  # recorded_at supplies ordering against subsequent owned reads.
  def nav_evidence(%{nav: %{status: status}}) when status in ~w(DOCKED IN_ORBIT IN_TRANSIT),
    do: %{nav_status: status}

  def nav_evidence(_), do: %{}

  @doc false
  def durable_change(_event, _measurements, metadata, worker) do
    case metadata do
      %{query: "begin", result: {:ok, _}} ->
        Process.put(@pending, %{families: MapSet.new(), scans: 0, observations: []})

      %{query: "commit", result: {:ok, _}} ->
        if pending = Process.delete(@pending) do
          notify(worker, pending)
          Enum.each(Enum.reverse(pending.observations), &GenServer.cast(worker, {:observe, &1}))
        end

      %{query: "rollback"} ->
        Process.delete(@pending)

      %{result: {:ok, %{command: command, num_rows: rows}}}
      when command in [:insert, :update, :delete] and rows > 0 ->
        change = %{
          families: MapSet.new(changed_families(metadata, command)),
          scans: scan_events(metadata, command, rows)
        }

        case Process.get(@pending) do
          nil ->
            notify(worker, change)

          pending ->
            Process.put(@pending, %{
              pending
              | families: MapSet.union(pending.families, change.families),
                scans: pending.scans + change.scans
            })
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> drop()
  catch
    _, _ -> drop()
  end

  defp drop do
    Logger.error("Outcome post-commit notification failed; dropping change")
    :ok
  end

  defp changed_families(%{source: "ships"}, _), do: @fleet_families

  defp changed_families(%{source: source}, command)
       when source in ["agents", "fleet_generations"] and command in [:insert, :delete],
       do: @families

  defp changed_families(%{source: source, query: query}, :update)
       when source in ["agents", "fleet_generations"] do
    if String.contains?(query, ["\"stale_at\"", "\"fenced_at\"", "\"retired_at\"", "\"agent_id\""]),
       do: @families,
       else: []
  end

  defp changed_families(%{source: source}, _)
       when source in [
              "fleet_commitment_claims",
              "fleet_commitments",
              "fleet_commitment_portfolios"
            ],
       do: [:claim]

  defp changed_families(%{source: "intents"}, _), do: [:intent_state]

  defp changed_families(%{source: "intelligence_observations"} = metadata, :insert) do
    if scan_events(metadata, :insert, 1) > 0, do: [:chart], else: []
  end

  defp changed_families(%{source: "intelligence_facts"} = metadata, :update) do
    if "waypoint" in (metadata.cast_params || metadata.params), do: [:chart], else: []
  end

  defp changed_families(%{source: source}, command)
       when source in ["intelligence_facts", "intelligence_observations"] and
              command in [:update, :delete],
       do: [:chart]

  defp changed_families(%{source: source}, :delete)
       when source in ["authoritative_observations", "mutation_attempt_outcomes"],
       do: [:nav_status]

  defp changed_families(%{source: "authoritative_observations"} = metadata, _) do
    if Enum.any?(
         metadata.cast_params || metadata.params,
         &(&1 in ["get-my-ship", "get-my-ships"])
       ),
       do: [:nav_status],
       else: []
  end

  defp changed_families(%{source: "mutation_attempt_outcomes"} = metadata, _) do
    if Enum.any?(metadata.cast_params || metadata.params, fn
         %{"nav_status" => status} -> status in ~w(DOCKED IN_ORBIT IN_TRANSIT)
         _ -> false
       end),
       do: [:nav_status],
       else: []
  end

  defp changed_families(_, _), do: []

  defp scan_events(%{source: "intelligence_observations"} = metadata, :insert, rows) do
    params = metadata.cast_params || metadata.params
    if "scan_waypoints" in params and "waypoint" in params, do: rows, else: 0
  end

  defp scan_events(_, _, _), do: 0

  defp notify(worker, %{families: families, scans: scans}) do
    if MapSet.size(families) > 0 or scans > 0,
      do: send(worker, {:dirty, %{families: families, scans: scans}})
  end
end
