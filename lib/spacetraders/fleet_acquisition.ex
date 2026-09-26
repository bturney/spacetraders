defmodule SpaceTraders.FleetAcquisition do
  @moduledoc """
  Selects and reconciles strategic Ship acquisition.

  A purchase needs an owned Ship already co-located at the Shipyard, so the
  planner treats that as admissibility rather than assuming it. `MutationAttempts`
  is the sole authority on whether a dispatched purchase happened (ADR 0011):
  recovery reconciles that attempt against the resources it fenced on and never
  infers the outcome from a second local record.
  """

  import Ecto.Query

  alias SpaceTraders.Agent, as: AgentContext
  alias SpaceTraders.Agent.{Agent, Scope}
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.SafetyFence.DependencyKey
  alias SpaceTraders.{Repo, World}

  @freshness_seconds 300

  @doc "Purchases one selected Ship Offer, then registers it from authoritative readiness evidence."
  def reconcile(%Scope{} = scope, %Agent{} = agent, %Revision{} = revision, system)
      when is_binary(system) do
    case FleetAllocation.current_portfolio(scope, agent) do
      nil -> acquire(scope, agent, revision, system)
      portfolio -> resume(scope, agent, portfolio)
    end
  end

  def reconcile(_scope, _agent, _revision, _system), do: {:error, :ship_acquisition_unavailable}

  defp acquire(scope, agent, revision, system) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         %Generation{} = generation <- active_generation(agent, revision),
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
         {:ok, result} <- dispatch(agent, portfolio, candidate) do
      {:ok, Map.put(result, :portfolio, portfolio)}
    else
      error -> {:error, {:ship_acquisition_unavailable, error}}
    end
  end

  defp dispatch(agent, portfolio, candidate) do
    observe(portfolio, agent, fn ->
      with {:ok, %{ship: purchased, transaction: transaction}} <-
             AgentContext.handle_game_result(
               agent,
               SpaceTraders.API.purchase_ship(
                 AgentTokenReference.new(agent),
                 candidate.ship.type,
                 candidate.source_waypoint
               )
             ) do
        settle(
          scope_of(agent),
          agent,
          portfolio,
          %{
            ship_symbol: purchased.symbol,
            ship_type: candidate.ship.type,
            readiness: candidate.ship.readiness,
            purchase_price: candidate.ship.purchase_price,
            transaction: transaction
          }
        )
      end
    end)
  end

  defp resume(scope, agent, portfolio) do
    with {:ok, purchase} <- settled_purchase(scope, agent, portfolio) do
      settle(scope, agent, portfolio, purchase)
    end
  end

  # ADR 0011: the attempt decides whether the purchase happened. A `succeeded`
  # attempt records only the response status, so the purchased Ship is still
  # identified from the authoritative owned Fleet rather than from a local record.
  defp settled_purchase(scope, agent, portfolio) do
    expectations = portfolio.strategy_decision_episode.expectations
    episode_id = portfolio.strategy_decision_episode_id

    case purchase_attempt(agent, episode_id) do
      nil ->
        {:error, :no_purchase_attempt}

      %Attempt{state: "succeeded"} ->
        identify(agent, expectations)

      %Attempt{state: state} = attempt when state in ["sent_or_unknown", "ambiguous"] ->
        reconcile_purchase(scope, agent, portfolio, attempt, expectations)
    end
  end

  defp identify(agent, expectations) do
    with {:ok, ships} <- Fleet.list_ships(agent) do
      case purchased(agent, ships) do
        {:ok, symbol} -> {:ok, purchase(symbol, expectations)}
        :absent -> {:error, :ship_purchase_unidentified}
        :unattributable -> {:error, :ship_purchase_unattributable}
      end
    end
  end

  defp reconcile_purchase(scope, agent, portfolio, attempt, expectations) do
    with {:ok, ships} <- Fleet.list_ships(agent),
         {:ok, overview} <- AgentContext.agent_overview(agent) do
      settle_attempt(scope, agent, portfolio, attempt, expectations, ships, overview.credits)
    end
  end

  defp settle_attempt(scope, agent, portfolio, attempt, expectations, ships, credits) do
    case purchased(agent, ships) do
      {:ok, symbol} ->
        with {:ok, _attempt} <- reconcile_attempt(agent, attempt, ships, credits, :accepted) do
          {:ok, purchase(symbol, expectations)}
        end

      :absent ->
        with {:ok, _attempt} <- reconcile_attempt(agent, attempt, ships, credits, :absent),
             {:ok, _portfolio} <-
               FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id) do
          {:error, :ship_purchase_not_completed}
        end

      :unattributable ->
        {:error, :ship_purchase_unattributable}
    end
  end

  defp reconcile_attempt(agent, attempt, ships, credits, resolution) do
    MutationAttempts.reconcile(attempt, resolution, [
      owned_fleet_observation(agent, attempt, ships, resolution),
      credit_observation(agent, attempt, credits, resolution)
    ])
  end

  defp purchase(symbol, expectations) do
    %{
      ship_symbol: symbol,
      ship_type: expectations["ship_type"],
      readiness: expectations["readiness"],
      purchase_price: expectations["purchase_price"],
      transaction: nil
    }
  end

  # The API never reports a Ship's type on a fleet read, so the purchase is proven
  # by set difference: the registry records what the app already knew, and within
  # one Fleet Generation only a purchase can add a Ship. More than one unknown
  # Ship is not attributable and must not be guessed at.
  defp purchased(agent, ships) do
    registered = MapSet.new(registered_symbols(agent))

    case Enum.reject(ships, &MapSet.member?(registered, &1.symbol)) do
      [%{symbol: symbol}] -> {:ok, symbol}
      [] -> :absent
      _several -> :unattributable
    end
  end

  defp registered_symbols(agent) do
    Repo.all(from ship in Ship, where: ship.agent_id == ^agent.id, select: ship.symbol)
  end

  defp purchase_attempt(agent, episode_id) do
    MutationAttempts.list_for_agent(agent)
    |> Enum.find(fn attempt ->
      attempt.operation_id == "purchase-ship" and
        attempt.provenance["decision_episode_id"] == episode_id and
        attempt.state in ["sent_or_unknown", "ambiguous", "succeeded"]
    end)
  end

  defp owned_fleet_observation(agent, attempt, ships, resolution) do
    Evidence.authoritative_observation(
      "get-my-ships",
      [DependencyKey.owned_fleet(agent.id)],
      %{
        ships: Enum.map(ships, &%{symbol: &1.symbol}),
        unregistered: length(ships) - length(registered_symbols(agent)),
        reconciliation: conclusion(attempt, resolution, fleet_basis(resolution))
      }
    )
  end

  defp credit_observation(agent, attempt, credits, resolution) do
    Evidence.authoritative_observation(
      "get-my-agent",
      [DependencyKey.agent_credits(agent.id)],
      %{
        credits: credits,
        reconciliation: conclusion(attempt, resolution, credit_basis(resolution))
      }
    )
  end

  defp conclusion(attempt, resolution, basis) do
    %{
      mutation_attempt_id: attempt.id,
      request_fingerprint: attempt.request_fingerprint,
      outcome: Atom.to_string(resolution),
      basis: basis
    }
  end

  defp fleet_basis(:accepted),
    do: "Authoritative owned Fleet contains exactly one Ship the registry has not recorded"

  defp fleet_basis(:absent),
    do: "Authoritative owned Fleet contains no Ship the registry has not recorded"

  defp credit_basis(:accepted),
    do: "Authoritative Agent credits account for the purchase"

  defp credit_basis(:absent),
    do: "Authoritative Agent credits are consistent with no purchase having occurred"

  # Registers the Ship, then records the terminal Decision Episode outcome and
  # releases the portfolio so a later cycle can claim the new Ship.
  defp settle(scope, agent, portfolio, purchase) do
    with {:ok, ready} <- read_readiness(agent, purchase.ship_symbol) do
      if readiness_matches?(ready, purchase.readiness) do
        with {:ok, ship} <- Fleet.register_ship(agent, ready, purchase.ship_type),
             :ok <- conclude(scope, portfolio, purchase, :realized) do
          {:ok, %{ship: ship, readiness: ready, portfolio: portfolio}}
        end
      else
        with :ok <- conclude(scope, portfolio, purchase, :partially_realized) do
          {:error, :ship_readiness_mismatch}
        end
      end
    end
  end

  defp read_readiness(agent, ship_symbol) do
    AgentContext.handle_game_result(
      agent,
      Evidence.get_ship(AgentTokenReference.new(agent), ship_symbol,
        owner: "fleet_reconciliation",
        required_facts: ["readiness"]
      )
    )
  end

  defp conclude(scope, portfolio, purchase, classification) do
    with {:ok, _episode} <-
           FleetAllocation.record_decision_outcome(
             scope,
             portfolio.strategy_decision_episode_id,
             classification,
             purchase_outcome(purchase, classification)
           ),
         {:ok, _portfolio} <-
           FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id) do
      :ok
    end
  end

  defp purchase_outcome(purchase, classification) do
    %{
      ship_symbol: purchase.ship_symbol,
      ship_type: purchase.ship_type,
      purchase_price: purchase.purchase_price,
      transaction: transaction_map(purchase.transaction),
      readiness: if(classification == :realized, do: "ready", else: "mismatch")
    }
  end

  defp transaction_map(nil), do: nil
  defp transaction_map(transaction), do: Map.from_struct(transaction)

  defp readiness_matches?(ready, requirements) when is_map(ready) and is_map(requirements) do
    expected = engine_speed(requirements)

    not is_nil(expected) and engine_speed(ready) == expected
  end

  defp readiness_matches?(_ready, _requirements), do: false

  defp engine_speed(%{engine: %{speed: speed}}) when is_integer(speed), do: speed
  defp engine_speed(%{"engine" => %{"speed" => speed}}) when is_integer(speed), do: speed
  defp engine_speed(%{engine_speed: speed}) when is_integer(speed), do: speed
  defp engine_speed(%{"engine_speed" => speed}) when is_integer(speed), do: speed
  defp engine_speed(_), do: nil

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

  defp observe(portfolio, agent, callback) do
    SpaceTraders.Observability.with_context(
      [
        operator_id: agent.operator_id,
        agent_id: agent.id,
        fleet_generation_id: portfolio.fleet_generation_id,
        strategy_revision_id: portfolio.fleet_strategy_revision_id,
        decision_episode_id: portfolio.strategy_decision_episode_id,
        commitment_id: hd(portfolio.commitments).id
      ],
      callback
    )
  end

  defp scope_of(agent),
    do: Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
end
