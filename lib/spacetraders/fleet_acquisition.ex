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
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority, Strategy}
  alias SpaceTraders.MarketSpending
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
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
         {:ok, ships} <- Fleet.list_ships(agent),
         as_of = DateTime.utc_now(),
         {:ok, planning} <-
           FleetPlanning.plan_ship_acquisition(revision, acquisition_objective_index(revision), %{
             as_of: as_of,
             credit_margin_percent: SpaceTraders.CreditCalibration.active().margin_percent,
             credits: overview.credits,
             ships: co_locatable_ships(ships),
             shipyards: shipyard_offers(agent, system, as_of)
           }),
         {:ok, selected} <- select_candidate(revision, planning, overview.credits, as_of),
         [commitment | _] <- selected.commitments,
         candidate <-
           Enum.find(planning.candidate_contributions, &(&1.id == commitment.candidate_id)),
         :ok <- authorize_purchase(revision, overview.credits, candidate),
         {:ok, portfolio} <-
           FleetAllocation.publish_portfolio(
             scope,
             generation.id,
             %{
               selected
               | commitments: [commitment],
                 rejected: rejected_offers(selected.rejected, candidate, planning.limitations),
                 source_version: generation.allocation_version
             },
             %{
               evidence_references: candidate.dependencies,
               expectations: acquisition_expectations(candidate),
               calibration_version: "ship-acquisition-v1"
             }
           ),
         {:ok, spending} <- MarketSpending.acquire_ship_purchase(agent, candidate),
         {:ok, result} <- dispatch(agent, portfolio, candidate, spending) do
      {:ok, Map.put(result, :portfolio, portfolio)}
    else
      error -> {:error, {:ship_acquisition_unavailable, error}}
    end
  end

  defp select_candidate(revision, planning, credits, as_of) do
    case planning.candidate_contributions do
      [] ->
        {:no_admissible_ship_offer, planning.limitations}

      candidates ->
        FleetAllocation.select_portfolio(revision, candidates, %{
          as_of: as_of,
          claims: [],
          reservations: %{credits: credits}
        })
    end
  end

  # A purchase needs an owned Ship actually present at the Shipyard's Waypoint.
  # An IN_TRANSIT Ship's waypoint_symbol is its destination rather than a
  # position, so it does not satisfy the precondition yet.
  defp co_locatable_ships(ships) do
    Enum.flat_map(ships, fn ship ->
      nav = ship.nav

      if is_map(nav) and nav.status in ["DOCKED", "IN_ORBIT"] and
           is_binary(nav.waypoint_symbol) do
        [%{symbol: ship.symbol, waypoint: nav.waypoint_symbol}]
      else
        []
      end
    end)
  end

  defp dispatch(agent, portfolio, candidate, spending) do
    observe(portfolio, agent, fn ->
      with {:ok, %{ship: purchased, transaction: transaction}} <-
             AgentContext.handle_game_result(
               agent,
               SpaceTraders.API.purchase_ship(
                 AgentTokenReference.new(agent),
                 candidate.ship.type,
                 candidate.source_waypoint,
                 spending: spending
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

  @doc """
  Spending checkpoint for a prepared Ship purchase, run at the send boundary.

  Takes the Agent credit lock first (Agent -> Attempt, as for recorded Ship
  spending), revalidates offer evidence, credits, other Reservations and
  admitted exposure, then writes the send marker in the same transaction. A
  refusal records `not_sent` on this same Attempt; no second ledger exists.
  """
  def admit_send(%Attempt{} = attempt) do
    Repo.transaction(fn ->
      MarketSpending.lock_agent(attempt)
      current = Repo.one!(from a in Attempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

      with "prepared" <- current.state,
           {:ok, revision} <- current_purchase_authority(current),
           :ok <- MarketSpending.admit(current, nil, revision),
           {:ok, sent} <- MutationAttempts.mark_sent_or_unknown(current) do
        sent
      else
        state when is_binary(state) -> Repo.rollback(:attempt_already_dispatched)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:error, reason} when reason != :attempt_already_dispatched ->
        MutationAttempts.record_not_sent(attempt, inspect(reason))
        {:error, reason}

      result ->
        result
    end
  end

  # Current authority, not the authority the purchase was prepared under: the
  # active, un-stopped Revision supplies the floor, and a purchase prepared
  # under any other Revision is withdrawn rather than sent.
  defp current_purchase_authority(%Attempt{agent_id: agent_id} = attempt) do
    operator_id = Repo.one!(from a in Agent, where: a.id == ^agent_id, select: a.operator_id)

    strategy =
      Repo.one(from s in Strategy, where: s.operator_id == ^operator_id, lock: "FOR SHARE")

    case strategy do
      %Strategy{emergency_stopped_at: stopped} when not is_nil(stopped) ->
        {:error, :emergency_stopped}

      %Strategy{active_revision_id: id} when not is_nil(id) ->
        if attempt.strategy_revision_id in [nil, id],
          do: {:ok, Repo.get!(Revision, id)},
          else: {:error, :strategy_revision_superseded}

      _ ->
        {:error, :strategy_revision_absent}
    end
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

      %Attempt{state: state} when state in ["succeeded", "accepted"] ->
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
    with {:ok, fleet} <-
           AgentContext.handle_game_result(agent, Evidence.recovery_fleet_binding(agent, attempt)),
         {:ok, credits} <-
           AgentContext.handle_game_result(
             agent,
             Evidence.recovery_agent_binding(agent, attempt, owner: "fleet_reconciliation")
           ) do
      settle_attempt(scope, agent, portfolio, attempt, expectations, fleet, credits)
    end
  end

  defp settle_attempt(scope, agent, portfolio, attempt, expectations, fleet, credits) do
    case purchased(agent, fleet.value) do
      {:ok, symbol} ->
        with {:ok, _attempt} <- reconcile_attempt(attempt, fleet, credits, :accepted) do
          {:ok, purchase(symbol, expectations)}
        end

      :absent ->
        with {:ok, _attempt} <- reconcile_attempt(attempt, fleet, credits, :absent),
             {:ok, _portfolio} <-
               FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id) do
          {:error, :ship_purchase_not_completed}
        end

      :unattributable ->
        {:error, :ship_purchase_unattributable}
    end
  end

  defp reconcile_attempt(attempt, fleet, credits, resolution) do
    with {:ok, proof} <-
           Evidence.recovery_proof(attempt, resolution, fleet_basis(resolution), [fleet, credits]) do
      MutationAttempts.reconcile(attempt, resolution, proof)
    end
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
        attempt.state in ["sent_or_unknown", "ambiguous", "succeeded", "accepted"]
    end)
  end

  defp fleet_basis(:accepted),
    do: "Authoritative owned Fleet contains exactly one Ship the registry has not recorded"

  defp fleet_basis(:absent),
    do: "Authoritative owned Fleet contains no Ship the registry has not recorded"

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

  # The episode keeps the alternatives that were not chosen, the unselected
  # offers they lost to, and any Shipyard whose Purchase Precondition or
  # Preparation Exposure evidence was missing, so the decision stays explainable.
  defp rejected_offers(rejected, candidate, limitations) do
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
      end) ++ Enum.map(limitations, &limitation_rejection/1)
  end

  defp limitation_rejection(%{subject: subject, reason: reason} = limitation) do
    %{
      candidate_id: nil,
      reasons: [reason],
      alternative: Map.get(limitation, :prerequisite),
      decisive_reason: %{subject: subject, unmet: reason}
    }
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
            modifications_fee: modification_fee(waypoint.shipyard),
            ships: ships
          }
        ]
      else
        _ -> []
      end
    end)
  end

  # The shipyard's per-modification fee prices the Preparation Exposure. It is
  # only usable while the observed fact is still fresh.
  defp modification_fee(shipyard) do
    with facts when is_map(facts) <- shipyard.facts,
         %{state: "known", freshness: :fresh, value: fee} when is_integer(fee) and fee >= 0 <-
           facts["modifications_fee"] do
      fee
    else
      _ -> nil
    end
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
