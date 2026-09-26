defmodule SpaceTraders.FleetAcquisition do
  @moduledoc "Selects and reconciles strategic Ship acquisition without granting a new Ship a Claim early."

  import Ecto.Query

  alias SpaceTraders.Agent, as: AgentContext
  alias SpaceTraders.Agent.{Agent, Scope}
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.{Repo, World}

  @freshness_seconds 300

  @doc "Purchases one selected Ship Offer, then bootstraps it from authoritative readiness evidence."
  def reconcile(%Scope{} = scope, %Agent{} = agent, %Revision{} = revision, system)
      when is_binary(system) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         %Generation{} = generation <- active_generation(agent, revision),
         nil <- FleetAllocation.current_portfolio(scope, agent),
         {:ok, overview} <- AgentContext.agent_overview(agent),
         as_of = DateTime.utc_now(),
         {:ok, %{candidate_contributions: [_ | _] = candidates}} <-
           FleetPlanning.plan_ship_acquisition(revision, acquisition_objective_index(revision), %{
             as_of: as_of,
             credits: overview.credits,
             shipyards: shipyard_offers(agent, system, as_of)
           }),
         {:ok, selected} <-
           FleetAllocation.select_portfolio(revision, candidates, %{
             as_of: as_of,
             claims: [],
             reservations: %{credits: overview.credits}
           }),
         [commitment | _] <- selected.commitments,
         candidate <- Enum.find(candidates, &(&1.id == commitment.candidate_id)),
         :ok <- authorize_purchase(revision, overview.credits, candidate),
         {:ok, portfolio} <-
           FleetAllocation.publish_portfolio(
             scope,
             generation.id,
             %{
               selected
               | commitments: [commitment],
                 source_version: generation.allocation_version
             },
             %{
               evidence_references: candidate.dependencies,
               expectations: candidate.expected_outcomes,
               calibration_version: "ship-acquisition-v1"
             }
           ),
         {:ok, result} <- purchase_and_bootstrap(agent, portfolio, candidate) do
      {:ok, Map.put(result, :portfolio, portfolio)}
    else
      error -> {:error, {:ship_acquisition_unavailable, error}}
    end
  end

  def reconcile(_scope, _agent, _revision, _system), do: {:error, :ship_acquisition_unavailable}

  defp active_generation(agent, revision) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent.id and
            generation.fleet_strategy_revision_id == ^revision.id and
            is_nil(generation.fenced_at) and is_nil(generation.retired_at)
    )
  end

  defp acquisition_objective_index(%Revision{document: %{"objectives" => objectives}}) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if FleetPlanning.ship_acquisition_objective?(objective), do: index
    end)
  end

  defp acquisition_objective_index(_revision), do: nil

  defp shipyard_offers(agent, system, as_of) do
    World.waypoints(agent, system, as_of, @freshness_seconds)
    |> Enum.flat_map(fn waypoint ->
      facts = waypoint.shipyard.facts

      with %{
             state: "known",
             freshness: :fresh,
             value: ships,
             observed_at: observed_at,
             observation_id: observation_id
           } <- facts["ships"],
           true <- is_list(ships) do
        [
          %{
            system_symbol: system,
            waypoint: waypoint.symbol,
            observed_at: observed_at,
            evidence_id: "intelligence-observation:#{observation_id}",
            ships: ships
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp authorize_purchase(revision, credits, candidate) do
    StandingAuthority.authorize(revision, %{
      revision_id: revision.id,
      evidence_id: Evidence.fingerprint(candidate.dependencies),
      observed_at: DateTime.utc_now(),
      bounds: %{
        minimum_credits: credits - candidate.required_resources.credits,
        scraps_ship: false
      }
    })
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :hard_constraint_violation}
    end
  end

  defp purchase_and_bootstrap(agent, portfolio, candidate) do
    SpaceTraders.Observability.with_context(
      [
        operator_id: agent.operator_id,
        agent_id: agent.id,
        fleet_generation_id: portfolio.fleet_generation_id,
        strategy_revision_id: portfolio.fleet_strategy_revision_id,
        decision_episode_id: portfolio.strategy_decision_episode_id,
        commitment_id: hd(portfolio.commitments).id
      ],
      fn ->
        with {:ok, %{ship: purchased, transaction: transaction}} <-
               AgentContext.handle_game_result(
                 agent,
                 SpaceTraders.API.purchase_ship(
                   AgentTokenReference.new(agent),
                   candidate.ship.type,
                   candidate.source_waypoint
                 )
               ),
             {:ok, ready} <-
               AgentContext.handle_game_result(
                 agent,
                 Evidence.get_ship(AgentTokenReference.new(agent), purchased.symbol,
                   owner: "fleet_reconciliation",
                   required_facts: ["readiness"]
                 )
               ),
             {:ok, ship} <- Fleet.bootstrap_ship(agent, ready, candidate.ship.type),
             {:ok, _episode} <-
               FleetAllocation.record_decision_outcome(
                 Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id)),
                 portfolio.strategy_decision_episode_id,
                 :realized,
                 %{
                   ship_symbol: ready.symbol,
                   ship_type: candidate.ship.type,
                   purchase_price: candidate.ship.purchase_price,
                   transaction: Map.from_struct(transaction)
                 }
               ) do
          {:ok, %{ship: ship, readiness: ready}}
        end
      end
    )
  end
end
