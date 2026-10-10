defmodule SpaceTraders.FleetAllocation.Reconciler do
  @moduledoc "Routes governed evidence boundaries into Fleet Allocation and capability reconciliation."

  use GenServer

  require Logger

  import Ecto.Query

  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.FleetAcquisition
  alias SpaceTraders.FleetRefit
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetResources
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Repo

  @refresh_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_market_evidence")
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_intelligence_evidence")
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_resource_evidence")
    # Durable Evidence scheduler announcements for due Observation Demands.
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "observation_demands")
    send(self(), :reconcile_intelligence_on_boot)
    Process.send_after(self(), :reconcile_durable_work, @refresh_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:market_evidence_observed, agent_id, "market:" <> system_and_waypoint}, state) do
    system_symbol = system_and_waypoint |> String.split(":", parts: 2) |> hd()
    observe_market_evidence(agent_id, system_symbol)
    {:noreply, state}
  end

  def handle_info(
        {:outbox, _id, "market_purchase_withdrawn",
         %{"agent_id" => agent_id, "waypoint" => waypoint}},
        state
      ) do
    system = waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
    observe_market_evidence(agent_id, system)
    {:noreply, state}
  end

  def handle_info({:waypoint_intelligence_observed, agent_id, system_symbol}, state) do
    observe_waypoint_intelligence(agent_id, system_symbol)
    {:noreply, state}
  end

  def handle_info({:resource_cooldown_recovered, agent_id, system_symbol}, state) do
    with_context(agent_id, fn scope, agent, revision ->
      FleetResources.reconcile(scope, agent, revision, system_symbol)
      FleetContracts.reconcile(scope, agent, revision)
      FleetConstruction.reconcile(scope, agent, revision)
      FleetAcquisition.reconcile(scope, agent, revision, system_symbol)
      FleetRefit.reconcile(scope, agent, revision, system_symbol)
    end)

    {:noreply, state}
  end

  def handle_info(:reconcile_intelligence_on_boot, state) do
    Generation
    |> where([generation], is_nil(generation.fenced_at) and is_nil(generation.retired_at))
    |> select([generation], generation.agent_id)
    |> Repo.all()
    |> Enum.each(fn agent_id ->
      case Repo.get(AgentRecord, agent_id) do
        %AgentRecord{headquarters: headquarters} ->
          case SpaceTraders.Fleet.system_from_headquarters(headquarters) do
            {:ok, system} -> send(self(), {:waypoint_intelligence_observed, agent_id, system})
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)

    {:noreply, state}
  end

  def handle_info(:reconcile_durable_work, state) do
    reconcile_durable_work()
    Process.send_after(self(), :reconcile_durable_work, @refresh_ms)
    {:noreply, state}
  end

  def handle_info({:observation_demand_due, agent_id, _subjects}, state) do
    wake_due_demands(agent_id)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Wakes Strategy reconciliation for a Generation whose Observation Demands came
  due.

  The durable Evidence scheduler announces due demands; this entry point does
  the waking. The wakeup itself never acquires evidence — reconciliation
  decides what is worth acquiring — and demands deferred by API backpressure
  stay open for the next wakeup instead of being dropped or fulfilled.
  """
  def wake_due_demands(agent_id, capacity \\ FleetCapacity.disposition("get-market"))
      when is_integer(agent_id) and is_map(capacity) do
    with_context(agent_id, fn scope, agent, revision ->
      system = system_for(agent)

      if system do
        FleetExecution.reconcile_market_domain(scope, agent, revision, system, capacity)
        FleetResources.reconcile(scope, agent, revision, system)
        FleetAcquisition.reconcile(scope, agent, revision, system)
        FleetRefit.reconcile(scope, agent, revision, system)
      end

      if system do
        # Refresh durable Market demands after the wakeup-driven reconciliation.
        enforce_sync_result!(
          agent.id,
          agent_id,
          FleetIntelligence.sync_market_observation_demands(agent, revision, system)
        )
      end

      FleetContracts.reconcile(scope, agent, revision)
      FleetConstruction.reconcile(scope, agent, revision)
    end)

    :ok
  end

  # A failed synchronization never claims success: nothing logged-and-
  # continued. There is no later scheduler wake for a demand that was never
  # persisted, so the failure terminates this process and its supervisor
  # restart reruns boot reconstruction from durable state.
  defp enforce_sync_result!(_agent, _agent_id, :ok), do: :ok

  defp enforce_sync_result!(agent_id, caller_agent_id, {:error, reason}) do
    Logger.error(
      "Market Observation Demand synchronization failed for agent #{inspect(agent_id)} " <>
        "(caller #{inspect(caller_agent_id)}): #{inspect(reason)}; restarting for boot reconstruction"
    )

    exit({:market_demand_sync_failed, reason})
  end

  defp system_for(%AgentRecord{headquarters: headquarters}) do
    case Fleet.system_from_headquarters(headquarters) do
      {:ok, system} -> system
      _error -> nil
    end
  end

  @doc """
  Reconciles durable Contract and Construction work for every active Fleet
  Generation.

  Market Intelligence is intentionally absent: whether a Market refresh is
  needed is carried by durable Observation Demands, and due demands wake
  reconciliation through the durable Evidence scheduler instead of a recurring
  scan. The fixed recurring Market refresh scan is no longer required for
  progress.
  """
  def reconcile_durable_work do
    # Owning Intents retain withdrawals. A missed notification or restart does
    # not strand the released Commitment while its Portfolio remains current.
    from(i in SpaceTraders.Fleet.Intent,
      join: c in SpaceTraders.FleetAllocation.Commitment,
      on: c.id == i.fleet_commitment_id,
      join: p in SpaceTraders.FleetAllocation.Portfolio,
      on: p.id == c.fleet_commitment_portfolio_id,
      join: s in SpaceTraders.Fleet.Ship,
      on: s.id == i.ship_id,
      where:
        i.status == "superseded" and is_nil(p.superseded_at) and
          fragment("?->>'outcome' = 'spending_replan_required'", i.last_action_result),
      select: {s.agent_id, i.target_waypoint},
      distinct: true
    )
    |> Repo.all()
    |> Enum.each(fn {agent_id, waypoint} ->
      observe_market_evidence(
        agent_id,
        waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
      )
    end)

    Generation
    |> where([generation], is_nil(generation.fenced_at) and is_nil(generation.retired_at))
    |> select([generation], generation.agent_id)
    |> Repo.all()
    |> Enum.each(fn agent_id ->
      with_context(agent_id, fn scope, agent, revision ->
        FleetContracts.reconcile(scope, agent, revision)
        FleetConstruction.reconcile(scope, agent, revision)
      end)
    end)
  end

  @doc """
  Governed Market evidence landed in `system_symbol`.

  The Market pilot domain (trade, coverage, retained work) is decided once
  by Fleet Allocation through `FleetExecution.reconcile_market_domain/5`;
  durable Market demands are then refreshed and the other capability owners
  reconcile beside the published pilot work.
  """
  def observe_market_evidence(
        agent_id,
        system_symbol,
        capacity \\ FleetCapacity.disposition("get-market")
      )
      when is_integer(agent_id) and is_binary(system_symbol) do
    reconcile_market_boundary(agent_id, system_symbol, capacity, false)
  end

  @doc """
  Waypoint intelligence (including a completed coverage observation) landed
  in `system_symbol`.

  It enters the same single Market pilot-domain decision as Market evidence,
  so the order in which the two announcements arrive cannot change the
  selected portfolio. Resource work also reconciles on Waypoint evidence.
  """
  def observe_waypoint_intelligence(
        agent_id,
        system_symbol,
        capacity \\ FleetCapacity.disposition("get-market")
      )
      when is_integer(agent_id) and is_binary(system_symbol) do
    reconcile_market_boundary(agent_id, system_symbol, capacity, true)
  end

  # One Market pilot-domain decision; then durable Market demands are refreshed
  # from retained Listing evidence and the other capability owners reconcile
  # beside the published pilot work.
  defp reconcile_market_boundary(agent_id, system_symbol, capacity, resources?) do
    with_context(agent_id, fn scope, agent, revision ->
      FleetExecution.reconcile_market_domain(scope, agent, revision, system_symbol, capacity)

      enforce_sync_result!(
        agent.id,
        agent_id,
        FleetIntelligence.sync_market_observation_demands(agent, revision, system_symbol)
      )

      if resources?, do: FleetResources.reconcile(scope, agent, revision, system_symbol)
      FleetContracts.reconcile(scope, agent, revision)
      FleetConstruction.reconcile(scope, agent, revision)
      FleetAcquisition.reconcile(scope, agent, revision, system_symbol)
      FleetRefit.reconcile(scope, agent, revision, system_symbol)
    end)

    :ok
  end

  defp with_context(agent_id, callback) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         %Generation{
           fleet_strategy_revision_id: revision_id,
           operator_id: operator_id
         }
         when is_integer(revision_id) <-
           Repo.one(
             from generation in Generation,
               where:
                 generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
                   is_nil(generation.retired_at)
           ),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         %Revision{} = revision <- Repo.get(Revision, revision_id),
         %{} = operator <- Repo.get(SpaceTraders.Agent.Operator, operator_id) do
      _ = callback.(Scope.for_operator(operator), agent, revision)
    end
  end
end
