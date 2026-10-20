defmodule SpaceTraders.Outcomes.PostCommit do
  @moduledoc """
  Cheap writer-side bridge from Repo query telemetry to the single Outcomes worker.

  Ecto emits transaction telemetry in the writer process. Buffer the bounded dirty
  families and retained owned observations there until the
  outer COMMIT; ROLLBACK discards them. Nested Repo transactions share that outer
  boundary. No writer SQL, worker wait, or second process is introduced.
  """
  require Logger

  alias SpaceTraders.{Evidence.Observation, Repo}

  @families [:status]
  # Tables a Ship status reads (`MissionControl.ShipStatus`).
  @status_sources ~w(
    ships
    intents
    fleet_commitment_claims
    fleet_commitments
    fleet_commitment_portfolios
    allocation_result_pointers
    strategy_decision_episodes
    earnings_records
  )
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
      when operation == "get-my-agent" do
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

  @doc """
  Announces an Intent change of a Ship (`Fleet.broadcast_intent_change/1`)
  once the writer's transaction commits; a rollback drops it. Outside a
  transaction, or without a known BEGIN, it is announced at once.
  """
  def intent_changed(ship_id) do
    case Process.get(@pending) do
      nil -> SpaceTraders.Fleet.broadcast_intent_change(ship_id)
      pending -> Process.put(@pending, %{pending | intents: [ship_id | pending.intents]})
    end

    :ok
  end

  @doc """
  Called inside the Earnings record's own transaction, before its COMMIT: the
  worker emits the record's metrics and Loki line only once it commits.
  """
  def earnings(%SpaceTraders.Outcomes.EarningsRecord{} = record) do
    case Process.get(@pending) do
      nil -> drop()
      pending -> Process.put(@pending, %{pending | earnings: [record | pending.earnings]})
    end

    :ok
  rescue
    _ -> drop()
  catch
    _, _ -> drop()
  end

  # Retain only the bounded nav fact in the existing mutation ledger. Its
  # recorded_at supplies ordering against subsequent owned reads.
  def nav_evidence(%{nav: %{status: status}}) when status in ~w(DOCKED IN_ORBIT IN_TRANSIT),
    do: %{nav_status: status}

  def nav_evidence(_), do: %{}

  @doc false
  def durable_change(_event, _measurements, metadata, worker) do
    case metadata do
      %{query: "begin", result: {:ok, _}} ->
        Process.put(@pending, %{
          families: MapSet.new(),
          observations: [],
          earnings: [],
          intents: []
        })

      %{query: "commit", result: {:ok, _}} ->
        if pending = Process.delete(@pending) do
          notify(worker, pending)
          Enum.each(Enum.reverse(pending.observations), &GenServer.cast(worker, {:observe, &1}))
          Enum.each(Enum.reverse(pending.earnings), &GenServer.cast(worker, {:earnings, &1}))

          pending.intents
          |> Enum.reverse()
          |> Enum.uniq()
          |> Enum.each(&SpaceTraders.Fleet.broadcast_intent_change/1)
        end

      %{query: "rollback"} ->
        Process.delete(@pending)

      %{result: {:ok, %{command: command, num_rows: rows}}}
      when command in [:insert, :update, :delete] and rows > 0 ->
        change = %{families: MapSet.new(changed_families(metadata, command))}

        case Process.get(@pending) do
          nil ->
            notify(worker, change)

          pending ->
            Process.put(@pending, %{
              pending
              | families: MapSet.union(pending.families, change.families)
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

  defp changed_families(%{source: source}, _) when source in @status_sources, do: [:status]

  defp changed_families(%{source: source}, command)
       when source in ["agents", "fleet_generations"] and command in [:insert, :delete],
       do: @families

  defp changed_families(%{source: source, query: query}, :update)
       when source in ["agents", "fleet_generations"] do
    if String.contains?(query, ["\"stale_at\"", "\"fenced_at\"", "\"retired_at\"", "\"agent_id\""]),
       do: @families,
       else: []
  end

  defp changed_families(_, _), do: []

  defp notify(worker, %{families: families}) do
    if MapSet.size(families) > 0,
      do: send(worker, {:dirty, %{families: families}})
  end
end
