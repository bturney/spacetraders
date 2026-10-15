defmodule SpaceTraders.FleetAcquisition do
  @moduledoc """
  Executes published Ship acquisition and reconciles its recorded mutation.

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
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.CreditSpending
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @doc "Purchases one selected Ship Offer, then registers it from authoritative readiness evidence."
  def reconcile(%Scope{} = scope, %Agent{} = agent, %Revision{}, system)
      when is_binary(system) do
    with {:ok, _} <- SpaceTraders.OperatorAuthority.authorize(scope),
         %Generation{} <- FleetAllocation.active_generation(agent) do
      case open_purchase(agent) do
        {commitment, attempt} ->
          resume(scope, agent, commitment, attempt)

        nil ->
          {:error, :no_purchase_attempt}
      end
    else
      _ -> {:error, :current_fleet_unavailable}
    end
  end

  def reconcile(_scope, _agent, _revision, _system), do: {:error, :ship_acquisition_unavailable}

  @doc "Executes an already published acquisition; does not plan, select or publish."
  def execute(agent, portfolio, %Commitment{} = commitment, candidate) do
    with :ok <- unsent_authority(agent, portfolio),
         :ok <- purchase_precondition(agent, candidate.source_waypoint),
         {:ok, spending} <- CreditSpending.acquire_ship_purchase(agent, candidate) do
      dispatch(agent, portfolio, commitment, candidate, spending)
    else
      {:error, reason}
      when reason in [
             :purchase_precondition_unmet,
             :ship_offer_evidence_unavailable,
             :strategy_revision_superseded,
             :strategy_revision_absent,
             :emergency_stopped
           ] ->
        # Only definitive, pre-Attempt refusals end the published investment.
        # Transient/capacity read failures retain it; a dispatched Attempt always
        # keeps sole authority over whether its purchase happened.
        case open_purchase(agent) do
          {%Commitment{id: id}, nil} when id == commitment.id ->
            withdraw(scope_of(agent), commitment, reason)

          _ ->
            {:error, reason}
        end

      error ->
        error
    end
  end

  defp unsent_authority(agent, portfolio) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- FleetAllocation.admit_current_agent(agent.id, portfolio.fleet_generation_id),
         {:ok, _} <-
           current_purchase_authority(%Attempt{
             agent_id: agent.id,
             strategy_revision_id: portfolio.fleet_strategy_revision_id
           }) do
      :ok
    end
  end

  defp purchase_precondition(agent, waypoint) do
    with {:ok, ships} <- Fleet.list_ships(agent) do
      if Enum.any?(
           ships,
           &((&1.nav && &1.nav.status in ["DOCKED", "IN_ORBIT"]) and
               &1.nav.waypoint_symbol == waypoint)
         ),
         do: :ok,
         else: {:error, :purchase_precondition_unmet}
    end
  end

  defp dispatch(agent, portfolio, commitment, candidate, spending) do
    observe(portfolio, commitment, agent, fn ->
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
          commitment,
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
      CreditSpending.lock_agent(attempt)
      current = Repo.one!(from a in Attempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

      with "prepared" <- current.state,
           :ok <-
             FleetAllocation.admit_current_agent(current.agent_id, current.fleet_generation_id),
           {:ok, revision} <- current_purchase_authority(current),
           :ok <- CreditSpending.admit(current, nil, revision),
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
      operator_id &&
        Repo.one(from s in Strategy, where: s.operator_id == ^operator_id, lock: "FOR SHARE")

    case strategy do
      %Strategy{emergency_stopped_at: stopped} when not is_nil(stopped) ->
        {:error, :emergency_stopped}

      %Strategy{active_revision_id: id} when not is_nil(id) ->
        if attempt.strategy_revision_id in [nil, id],
          do: {:ok, Repo.get!(Revision, id)},
          else: {:error, :strategy_revision_superseded}

      # No active Strategy: only a purchase that never claimed one may proceed,
      # still bounded by its offer evidence and Fleet-wide exposure.
      _ ->
        if is_nil(attempt.strategy_revision_id),
          do: {:ok, nil},
          else: {:error, :strategy_revision_absent}
    end
  end

  defp resume(scope, agent, commitment, nil) do
    portfolio = commitment.fleet_commitment_portfolio

    case unsent_authority(agent, portfolio) do
      :ok ->
        expectations = decision_episode(commitment).expectations

        candidate = %{
          source_waypoint:
            expectations["source_waypoint"] ||
              get_in(expectations, ["candidate", "source_waypoint"]),
          dependencies: get_in(expectations, ["candidate", "dependencies"]) || [],
          ship: %{
            type: expectations["ship_type"],
            readiness: expectations["readiness"],
            purchase_price: expectations["purchase_price"]
          }
        }

        execute(agent, portfolio, commitment, candidate)

      {:error, reason} ->
        withdraw(scope, commitment, reason)
    end
  end

  defp resume(scope, _agent, commitment, %Attempt{state: "prepared"} = attempt) do
    with {:ok, _} <-
           MutationAttempts.record_not_sent(attempt, "Interrupted before send; withdrawn locally") do
      withdraw(scope, commitment, :ship_purchase_not_completed)
    end
  end

  defp resume(scope, _agent, commitment, %Attempt{state: state})
       when state in ["not_sent", "rejected"],
       do: withdraw(scope, commitment, :ship_purchase_not_completed)

  defp resume(scope, agent, commitment, attempt) do
    with {:ok, purchase} <- settled_purchase(scope, agent, commitment, attempt) do
      settle(scope, agent, commitment, purchase)
    end
  end

  defp withdraw(scope, commitment, reason) do
    with {:ok, _} <-
           FleetAllocation.conclude_commitment(scope, commitment, :superseded, %{reason: reason}) do
      {:error, reason}
    end
  end

  # ADR 0011: the attempt decides whether the purchase happened. A `succeeded`
  # attempt records only the response status, so the purchased Ship is still
  # identified from the authoritative owned Fleet rather than from a local record.
  defp settled_purchase(scope, agent, commitment, attempt) do
    expectations = decision_episode(commitment).expectations

    case attempt do
      %Attempt{state: "absent"} ->
        conclude_absent(scope, commitment)

      %Attempt{state: state} when state in ["succeeded", "accepted"] ->
        identify(agent, expectations)

      %Attempt{state: state} = attempt
      when state in ["sent_or_unknown", "ambiguous", "bounded_unknown"] ->
        reconcile_purchase(scope, agent, commitment, attempt, expectations)
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

  defp reconcile_purchase(scope, agent, commitment, attempt, expectations) do
    with {:ok, fleet} <-
           AgentContext.handle_game_result(agent, Evidence.recovery_fleet_binding(agent, attempt)),
         {:ok, credits} <-
           AgentContext.handle_game_result(
             agent,
             Evidence.recovery_agent_binding(agent, attempt, owner: "fleet_reconciliation")
           ) do
      settle_attempt(scope, agent, commitment, attempt, expectations, fleet, credits)
    end
  end

  defp settle_attempt(scope, agent, commitment, attempt, expectations, fleet, credits) do
    case purchased(agent, fleet.value) do
      {:ok, symbol} ->
        with {:ok, _attempt} <- reconcile_attempt(attempt, fleet, credits, :accepted) do
          {:ok, purchase(symbol, expectations)}
        end

      :absent ->
        with {:ok, _attempt} <- reconcile_attempt(attempt, fleet, credits, :absent) do
          conclude_absent(scope, commitment)
        end

      :unattributable ->
        {:error, :ship_purchase_unattributable}
    end
  end

  defp conclude_absent(scope, commitment) do
    with {:ok, _commitment} <-
           FleetAllocation.conclude_commitment(scope, commitment, :superseded, %{
             reason: :ship_purchase_not_completed
           }) do
      {:error, :ship_purchase_not_completed}
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

  @doc "Open published purchase and its latest Attempt, including publication before dispatch."
  def open_purchase(agent) do
    case FleetAllocation.active_generation(agent) do
      %Generation{} = generation -> find_open_purchase(agent, generation)
      _ -> nil
    end
  end

  defp find_open_purchase(agent, generation) do
    commitments =
      Repo.all(
        from c in Commitment,
          join: p in assoc(c, :fleet_commitment_portfolio),
          where: p.fleet_generation_id == ^generation.id and c.unwind_state != :released,
          preload: [
            :replan_decision_episode,
            fleet_commitment_portfolio: :strategy_decision_episode
          ]
      )

    attempts = MutationAttempts.list_for_agent(agent)

    Enum.find_value(commitments, fn commitment ->
      if decision_episode(commitment).expectations["ship_type"] do
        attempt =
          Enum.find(attempts, fn attempt ->
            attempt.operation_id == "purchase-ship" and
              attempt.provenance["commitment_id"] == commitment.id and
              attempt.provenance["decision_episode_id"] == decision_episode(commitment).id
          end)

        {commitment, attempt}
      end
    end)
  end

  defp decision_episode(commitment),
    do:
      commitment.replan_decision_episode ||
        commitment.fleet_commitment_portfolio.strategy_decision_episode

  defp fleet_basis(:accepted),
    do: "Authoritative owned Fleet contains exactly one Ship the registry has not recorded"

  defp fleet_basis(:absent),
    do: "Authoritative owned Fleet contains no Ship the registry has not recorded"

  # Registers the Ship, then records the terminal Decision Episode outcome and
  # releases only the acquisition Commitment so other work keeps its authority.
  defp settle(scope, agent, commitment, purchase) do
    with {:ok, ready} <- read_readiness(agent, purchase.ship_symbol) do
      if ready.symbol == purchase.ship_symbol and readiness_matches?(ready, purchase.readiness) do
        with {:ok, ship} <- Fleet.register_ship(agent, ready, purchase.ship_type),
             :ok <- conclude(scope, commitment, purchase, :realized) do
          {:ok, %{ship: ship, readiness: ready, portfolio: commitment.fleet_commitment_portfolio}}
        end
      else
        with :ok <- conclude(scope, commitment, purchase, :partially_realized) do
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

  defp conclude(scope, commitment, purchase, classification) do
    with {:ok, _commitment} <-
           FleetAllocation.conclude_commitment(
             scope,
             commitment,
             classification,
             purchase_outcome(purchase, classification)
           ) do
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
    requirements = SpaceTraders.FleetAllocation.JsonEvidence.dump(requirements)
    configuration = SpaceTraders.FleetPlanning.ShipInvestment.configuration(ready)
    profile = SpaceTraders.FleetAllocation.MarketWorkRate.ship_profile(ready)

    with %{} = promised <- requirements["configuration"],
         %{} = benchmark <- requirements["work_profile"],
         %{} <- profile do
      matches_fields?(configuration, promised) and
        profile["cargo"] == benchmark["cargo"] and
        profile["navigation"]["waypoint_symbol"] == benchmark["navigation"]["waypoint_symbol"] and
        profile["navigation"]["flight_mode"] == benchmark["navigation"]["flight_mode"] and
        profile["navigation"]["status"] in ["DOCKED", "IN_ORBIT"] and
        profile["cooldown"]["remaining_seconds"] == 0 and
        profile["fuel"]["capacity"] == benchmark["fuel"]["capacity"] and
        profile["fuel"]["current"] >= 0 and
        is_integer(ready.crew.current) and is_integer(ready.crew.required) and
        ready.crew.current >= ready.crew.required
    else
      _ -> false
    end
  end

  defp readiness_matches?(_ready, _requirements), do: false

  defp matches_fields?(actual, expected) when is_map(actual) and is_map(expected),
    do:
      Enum.all?(expected, fn {key, value} ->
        is_nil(value) or matches_fields?(actual[key], value)
      end)

  defp matches_fields?(actual, expected), do: actual == expected

  defp observe(portfolio, commitment, agent, callback) do
    SpaceTraders.Observability.with_context(
      [
        operator_id: agent.operator_id,
        agent_id: agent.id,
        fleet_generation_id: portfolio.fleet_generation_id,
        strategy_revision_id: portfolio.fleet_strategy_revision_id,
        decision_episode_id:
          decision_episode(
            Repo.preload(commitment, [
              :replan_decision_episode,
              fleet_commitment_portfolio: :strategy_decision_episode
            ])
          ).id,
        commitment_id: commitment.id
      ],
      callback
    )
  end

  defp scope_of(agent),
    do: Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
end
