defmodule SpaceTraders.FleetAcquisition do
  @moduledoc "Selects and reconciles strategic Ship acquisition without granting a new Ship a Claim early."

  import Ecto.Query

  alias SpaceTraders.Agent, as: AgentContext
  alias SpaceTraders.Agent.{Agent, Scope}
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.{Repo, World}

  @freshness_seconds 300

  @doc "Purchases one selected Ship Offer, then bootstraps it from authoritative readiness evidence."
  def reconcile(%Scope{} = scope, %Agent{} = agent, %Revision{} = revision, system)
      when is_binary(system) do
    case pending_purchase(scope, agent) do
      {:ok, portfolio, purchase} -> resume_bootstrap(agent, portfolio, purchase)
      {:recover, portfolio} -> recover_purchase(scope, agent, portfolio)
      :none -> reconcile_new(scope, agent, revision, system)
    end
  end

  def reconcile(_scope, _agent, _revision, _system), do: {:error, :ship_acquisition_unavailable}

  defp reconcile_new(scope, agent, revision, system) do
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
                 rejected: rejected_offers(selected.rejected, candidate),
                 source_version: generation.allocation_version
             },
             %{
               evidence_references: candidate.dependencies,
               expectations: acquisition_expectations(candidate),
               calibration_version: "ship-acquisition-v1"
             }
           ),
         {:ok, result} <- purchase_and_bootstrap(agent, portfolio, candidate) do
      {:ok, Map.put(result, :portfolio, portfolio)}
    else
      error -> {:error, {:ship_acquisition_unavailable, error}}
    end
  end

  defp active_generation(agent, revision) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent.id and
            generation.fleet_strategy_revision_id == ^revision.id and
            is_nil(generation.fenced_at) and is_nil(generation.retired_at)
    )
  end

  defp rejected_offers(rejected, candidate) do
    rejected ++
      Enum.map(candidate.alternatives, fn alternative ->
        %{
          candidate_id: alternative.id,
          reasons: [:strategic_opportunity_cost],
          alternative: alternative,
          decisive_reason: %{
            selected_for: "higher_decision_value",
            selected_value: candidate.expected_outcomes.decision_value
          }
        }
      end)
  end

  defp acquisition_expectations(candidate) do
    Map.merge(candidate.expected_outcomes, %{
      alternatives: candidate.alternatives,
      readiness: candidate.ship.readiness,
      opportunity_cost: %{
        foregone_decision_value:
          candidate.alternatives
          |> Enum.map(& &1.decision_value)
          |> Enum.max(fn -> 0 end)
      }
    })
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
             :ok <- record_purchase_progress(agent, portfolio, candidate, purchased, transaction),
             {:ok, ready} <-
               AgentContext.handle_game_result(
                 agent,
                 Evidence.get_ship(AgentTokenReference.new(agent), purchased.symbol,
                   owner: "fleet_reconciliation",
                   required_facts: ["readiness"]
                 )
               ),
             {:ok, ship} <- bootstrap_ready_ship(agent, portfolio, candidate, ready, transaction) do
          {:ok, %{ship: ship, readiness: ready}}
        end
      end
    )
  end

  defp record_bootstrap(agent, portfolio, candidate, ready, transaction) do
    finalize_decision(
      agent,
      portfolio,
      :realized,
      purchase_outcome(candidate, ready.symbol, transaction, "ready")
    )
  end

  defp bootstrap_ready_ship(agent, portfolio, candidate, ready, transaction) do
    if readiness_matches?(ready, candidate.ship.readiness) do
      with {:ok, ship} <- FleetGeneration.bootstrap_ship(agent, ready, candidate.ship.type),
           {:ok, _episode} <- record_bootstrap(agent, portfolio, candidate, ready, transaction) do
        {:ok, ship}
      end
    else
      with {:ok, _episode} <-
             finalize_decision(
               agent,
               portfolio,
               :partially_realized,
               purchase_outcome(candidate, ready.symbol, transaction, "mismatch")
             ) do
        {:error, :ship_readiness_mismatch}
      end
    end
  end

  defp pending_purchase(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{
        strategy_decision_episode: %{classification: :still_evaluating, actual_outcomes: outcomes}
      } =
          portfolio
      when is_map(outcomes) ->
        case outcomes["purchase"] do
          %{"ship_symbol" => symbol, "ship_type" => ship_type} ->
            {:ok, portfolio,
             %{
               ship_symbol: symbol,
               ship_type: ship_type,
               readiness: outcomes["readiness_requirements"]
             }}

          _ ->
            {:recover, portfolio}
        end

      _ ->
        :none
    end
  end

  defp recover_purchase(scope, agent, portfolio) do
    with %{} = _attempt <- purchase_attempt(agent, portfolio.strategy_decision_episode_id),
         {:ok, ships} <- Fleet.list_ships(agent),
         %{symbol: symbol, type: type} <- purchased_ship(agent, ships, portfolio),
         :ok <-
           record_recovered_purchase(
             scope,
             portfolio,
             symbol,
             type,
             portfolio.strategy_decision_episode.expectations
           ) do
      resume_bootstrap(agent, portfolio, %{
        ship_symbol: symbol,
        ship_type: type,
        readiness: portfolio.strategy_decision_episode.expectations["readiness"]
      })
    else
      _ -> {:error, :ship_acquisition_reconciliation_required}
    end
  end

  defp purchase_attempt(agent, episode_id) do
    MutationAttempts.list_for_agent(agent)
    |> Enum.find(fn attempt ->
      attempt.operation_id == "purchase-ship" and
        attempt.state in ["sent_or_unknown", "ambiguous", "succeeded"] and
        attempt.provenance["decision_episode_id"] == episode_id
    end)
  end

  defp purchased_ship(agent, ships, portfolio) do
    registered_symbols =
      Repo.all(from ship in Ship, where: ship.agent_id == ^agent.id, select: ship.symbol)

    expected_type = portfolio.strategy_decision_episode.expectations["ship_type"]

    Enum.find(ships, fn ship ->
      ship.type == expected_type and ship.symbol not in registered_symbols
    end)
  end

  defp record_recovered_purchase(scope, portfolio, symbol, type, expectations) do
    case FleetAllocation.record_decision_progress(
           scope,
           portfolio.strategy_decision_episode_id,
           %{
             purchase: %{
               ship_symbol: symbol,
               ship_type: type,
               purchase_price: expectations["purchase_price"],
               transaction: nil
             },
             readiness: "pending",
             readiness_requirements: expectations["readiness"]
           }
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp resume_bootstrap(agent, portfolio, purchase) do
    with {:ok, ready} <-
           AgentContext.handle_game_result(
             agent,
             Evidence.get_ship(AgentTokenReference.new(agent), purchase.ship_symbol,
               owner: "fleet_reconciliation",
               required_facts: ["readiness"]
             )
           ),
         true <- readiness_matches?(ready, purchase.readiness),
         {:ok, ship} <- FleetGeneration.bootstrap_ship(agent, ready, purchase.ship_type),
         {:ok, _} <-
           finalize_decision(
             agent,
             portfolio,
             :realized,
             portfolio.strategy_decision_episode.actual_outcomes
             |> Map.put_new("purchase", %{
               "ship_symbol" => purchase.ship_symbol,
               "ship_type" => purchase.ship_type,
               "purchase_price" => nil,
               "transaction" => nil
             })
             |> Map.put_new("readiness_requirements", purchase.readiness)
             |> Map.put("readiness", "ready")
           ) do
      {:ok, %{ship: ship, readiness: ready, portfolio: portfolio}}
    else
      _ -> {:error, :ship_acquisition_reconciliation_required}
    end
  end

  defp readiness_matches?(%{engine: %{speed: speed}}, %{engine_speed: speed})
       when is_integer(speed),
       do: true

  defp readiness_matches?(%{engine: %{speed: speed}}, %{"engine_speed" => speed})
       when is_integer(speed),
       do: true

  defp readiness_matches?(_ready, _requirements), do: false

  defp finalize_decision(agent, portfolio, classification, outcomes) do
    scope = Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))

    with {:ok, episode} <-
           FleetAllocation.record_decision_outcome(
             scope,
             portfolio.strategy_decision_episode_id,
             classification,
             outcomes
           ),
         {:ok, _portfolio} <-
           FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id) do
      {:ok, episode}
    end
  end

  defp record_purchase_progress(agent, portfolio, candidate, purchased, transaction) do
    case FleetAllocation.record_decision_progress(
           Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id)),
           portfolio.strategy_decision_episode_id,
           %{
             purchase: %{
               ship_symbol: purchased.symbol,
               ship_type: candidate.ship.type,
               purchase_price: candidate.ship.purchase_price,
               transaction: Map.from_struct(transaction)
             },
             readiness: "pending",
             readiness_requirements: candidate.ship.readiness
           }
         ) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp purchase_outcome(candidate, ship_symbol, transaction, readiness) do
    %{
      ship_symbol: ship_symbol,
      ship_type: candidate.ship.type,
      purchase_price: candidate.ship.purchase_price,
      transaction: Map.from_struct(transaction),
      readiness: readiness
    }
  end
end
