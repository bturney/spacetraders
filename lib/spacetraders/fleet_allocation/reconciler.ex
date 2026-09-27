defmodule SpaceTraders.FleetAllocation.Reconciler do
  @moduledoc "Replans Market Commitments when governed Market evidence changes."

  use GenServer

  import Ecto.Query

  alias SpaceTraders.API.ShadowAdmission
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
    send(self(), :reconcile_intelligence_on_boot)
    Process.send_after(self(), :reconcile_durable_work, @refresh_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:market_evidence_observed, agent_id, "market:" <> system_and_waypoint}, state) do
    system_symbol = system_and_waypoint |> String.split(":", parts: 2) |> hd()
    reconcile(agent_id, system_symbol)
    {:noreply, state}
  end

  def handle_info({:waypoint_intelligence_observed, agent_id, system_symbol}, state) do
    with_context(agent_id, fn scope, agent, revision ->
      FleetIntelligence.reconcile(
        scope,
        agent,
        revision,
        system_symbol,
        ShadowAdmission.snapshot()
      )

      FleetResources.reconcile(scope, agent, revision, system_symbol)
      FleetContracts.reconcile(scope, agent, revision)
      FleetConstruction.reconcile(scope, agent, revision)
      FleetAcquisition.reconcile(scope, agent, revision, system_symbol)
      FleetRefit.reconcile(scope, agent, revision, system_symbol)
    end)

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

  def handle_info(_message, state), do: {:noreply, state}

  @doc """
  Reconciles durable, due work for every active Fleet Generation.

  This is the recurring durable scan. It reads durable state only: whether a
  Market Intelligence refresh is due is derived from the age of retained Market
  evidence, so the process timer that calls it is a disposable wakeup rather
  than a correctness dependency. Contracts and Construction have always been
  reconciled here; Market Intelligence is included so a Generation whose Market
  evidence has aged out schedules a fresh observation and re-evaluates its
  Strategy instead of sitting idle until the process restarts.
  """
  def reconcile_durable_work(capacity \\ ShadowAdmission.snapshot()) do
    Generation
    |> where([generation], is_nil(generation.fenced_at) and is_nil(generation.retired_at))
    |> select([generation], generation.agent_id)
    |> Repo.all()
    |> Enum.each(&reconcile_generation(&1, capacity))
  end

  defp reconcile_generation(agent_id, capacity) do
    with_context(agent_id, fn scope, agent, revision ->
      reconcile_due_market_intelligence(scope, agent, revision, capacity)
      FleetContracts.reconcile(scope, agent, revision)
      FleetConstruction.reconcile(scope, agent, revision)
    end)
  end

  defp reconcile_due_market_intelligence(scope, agent, revision, capacity) do
    with {:ok, system} <- Fleet.system_from_headquarters(agent.headquarters) do
      FleetIntelligence.reconcile(scope, agent, revision, system, capacity)
    end
  end

  defp reconcile(agent_id, system_symbol) do
    with_context(agent_id, fn scope, agent, revision ->
      FleetExecution.reconcile_market_evidence(
        scope,
        agent,
        revision,
        system_symbol,
        ShadowAdmission.snapshot()
      )

      FleetContracts.reconcile(scope, agent, revision)
      FleetConstruction.reconcile(scope, agent, revision)
      FleetAcquisition.reconcile(scope, agent, revision, system_symbol)
      FleetRefit.reconcile(scope, agent, revision, system_symbol)
    end)
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
