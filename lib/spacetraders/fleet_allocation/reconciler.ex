defmodule SpaceTraders.FleetAllocation.Reconciler do
  @moduledoc "Replans Market Commitments when governed Market evidence changes."

  use GenServer

  import Ecto.Query

  alias SpaceTraders.API.ShadowAdmission
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Repo

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_market_evidence")
    {:ok, %{}}
  end

  @impl true
  def handle_info({:market_evidence_observed, agent_id, "market:" <> system_and_waypoint}, state) do
    system_symbol = system_and_waypoint |> String.split(":", parts: 2) |> hd()
    reconcile(agent_id, system_symbol)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp reconcile(agent_id, system_symbol) do
    with %Generation{fleet_strategy_revision_id: revision_id, operator_id: operator_id} <-
           Repo.one(
             from generation in Generation,
               where:
                 generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
                   is_nil(generation.retired_at)
           ),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         %Revision{} = revision <- Repo.get(Revision, revision_id),
         %{} = operator <- Repo.get(SpaceTraders.Agent.Operator, operator_id) do
      _ =
        FleetExecution.reconcile_market_evidence(
          Scope.for_operator(operator),
          agent,
          revision,
          system_symbol,
          ShadowAdmission.snapshot()
        )
    end
  end
end
