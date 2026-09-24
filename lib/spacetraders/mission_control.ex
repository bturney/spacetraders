defmodule SpaceTraders.MissionControl do
  @moduledoc """
  Read projections for the authenticated Operator's Mission Control adapter.

  The caller supplies an authenticated `SpaceTraders.Agent.Scope`. This module
  owns the Operator-to-Agent scoping boundary and exposes no gameplay commands.
  Read failures remain in each Fleet snapshot so adapters can render unknown or
  stale state without substituting cached values.
  """

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.Activity
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo
  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.{
    Agent,
    Fleet,
    FleetAllocation,
    FleetExecution,
    FleetGeneration,
    FleetPlanning,
    FleetStrategy,
    Intelligence,
    OperatorConditions
  }

  @evaluation_fact_keys %{
    "change" => :change,
    "current" => :current,
    "elapsed_seconds" => :elapsed_seconds,
    "expected_seconds_to_target" => :expected_seconds_to_target,
    "feasible?" => :feasible?,
    "horizon_seconds" => :horizon_seconds,
    "required_margin" => :required_margin,
    "target" => :target
  }

  @doc "Returns the signed-in Operator's Agents for adapter subscriptions."
  def agents(%Scope{operator: operator}) do
    operator
    |> Agent.list_agents()
    |> Enum.map(&without_agent_credentials/1)
  end

  @doc "Returns the dashboard projections for the signed-in Operator's Agents."
  def dashboard(%Scope{} = scope), do: dashboard(scope, agents(scope))

  @doc "Projects a previously scoped Agent list after adapter subscriptions are established."
  def dashboard(%Scope{} = scope, agents) do
    agents
    |> Enum.filter(&owned_by?(&1, scope))
    |> Enum.map(&Agent.get_agent(scope, &1.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Fleet.command_snapshot/1)
    |> Enum.map(&without_credentials/1)
  end

  @doc "Returns the authenticated Operator's Fleet Strategy review projection."
  def strategy(%Scope{} = scope) do
    FleetStrategy.get(scope)
    |> Map.put(:presets, FleetStrategy.presets())
  end

  @doc "Returns visible Market Candidate Contributions from retained Operational Intelligence."
  def market_planning(%Scope{} = scope, as_of \\ DateTime.utc_now()) do
    case strategy(scope).active_revision do
      nil ->
        []

      revision ->
        scope
        |> agents()
        |> Enum.flat_map(&agent_market_planning(revision, &1, as_of))
    end
  end

  @doc "Returns the concise Fleet Strategy and Fleet Generation read projection."
  def overview(%Scope{} = scope) do
    strategy = strategy(scope)
    generations = FleetGeneration.list_generations(scope)
    snapshots = dashboard(scope)

    %{
      strategy: strategy,
      generations: generations,
      fleets: Enum.map(snapshots, &fleet_overview(&1, generations)),
      objectives: objective_overviews(strategy.active_revision, generations),
      market_execution: market_execution(scope),
      conditions: OperatorConditions.unresolved(scope),
      notable_activity: activity(scope) |> Enum.filter(&notable_activity?/1) |> Enum.take(5)
    }
  end

  @doc "Chronological consequential decisions and conditions for the signed-in Operator."
  def activity(%Scope{operator: %{id: operator_id}} = scope) do
    decisions =
      Repo.all(
        from episode in StrategyDecisionEpisode,
          where: episode.operator_id == ^operator_id,
          order_by: [desc: episode.inserted_at, desc: episode.id],
          limit: 100
      )
      |> Enum.map(fn episode ->
        %{
          id: "decision-#{episode.id}",
          type: :decision,
          at: episode.inserted_at,
          summary: decision_summary(episode),
          detail: decision_detail(episode)
        }
      end)

    conditions =
      OperatorConditions.history(scope)
      |> Enum.map(fn condition ->
        %{
          id: "condition-#{condition.id}",
          type: condition.kind,
          at: condition.inserted_at,
          summary: condition.summary,
          detail: if(condition.resolved_at, do: "Resolved", else: "Still unresolved")
        }
      end)

    generations =
      scope
      |> FleetGeneration.list_generations()
      |> Enum.flat_map(fn generation ->
        started = %{
          id: "generation-#{generation.id}",
          type: :milestone,
          at: generation.inserted_at,
          summary: "Fleet Generation #{generation.number} began with #{generation.symbol}",
          detail:
            "Strategy resumed: #{if generation.strategy_capable_at, do: "yes", else: "not yet confirmed"}."
        }

        reset =
          if generation.fenced_at do
            [
              %{
                id: "reset-#{generation.id}",
                type: :milestone,
                at: generation.fenced_at,
                summary: "Server Reset interrupted Fleet Generation #{generation.number}",
                detail:
                  "Old-generation gameplay mutations were fenced. Replacement status is in Generations."
              }
            ]
          else
            []
          end

        [started | reset]
      end)

    purchases =
      Repo.all(
        from attempt in Attempt,
          join: outcome in Outcome,
          on: outcome.mutation_attempt_id == attempt.id,
          where:
            attempt.operator_id == ^operator_id and attempt.operation_id == "purchase-ship" and
              outcome.classification == "succeeded",
          order_by: [desc: outcome.recorded_at],
          select: %{id: attempt.id, at: outcome.recorded_at}
      )
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn purchase ->
        %{
          id: "purchase-#{purchase.id}",
          type: :milestone,
          at: purchase.at,
          summary: "Fleet acquired a Ship",
          detail: "The game confirmed the purchase."
        }
      end)

    operator_events =
      Repo.all(
        from event in Activity,
          join: agent in AgentRecord,
          on: agent.id == event.agent_id,
          where:
            agent.operator_id == ^operator_id and
              event.kind in ["manual_intervention_stopped", "manual_intent_completed"],
          order_by: [desc: event.inserted_at, desc: event.id],
          limit: 100
      )
      |> Enum.map(fn event ->
        %{
          id: "ship-#{event.id}",
          type: :event,
          at: event.inserted_at,
          summary: event.message,
          detail: "Recorded Operator-directed Ship outcome."
        }
      end)

    (decisions ++ conditions ++ generations ++ purchases ++ operator_events)
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
  end

  def notable_activity?(%{type: type})
      when type in [:decision, :milestone, :attention, :intervention],
      do: true

  def notable_activity?(_), do: false

  defp decision_summary(%{
         classification: :realized,
         actual_outcomes: %{"net_credit_change" => change}
       })
       when is_number(change),
       do: "Fleet decision realized #{change} credits net change"

  defp decision_summary(%{classification: :partially_realized}),
    do: "Fleet decision partially realized"

  defp decision_summary(%{classification: :reset_censored}),
    do: "Fleet decision interrupted by Server Reset"

  defp decision_summary(%{classification: :superseded}), do: "Fleet decision superseded"
  defp decision_summary(_), do: "Fleet selected a new commitment portfolio"

  defp decision_detail(episode) do
    [
      "Decision Episode #{episode.id} · #{episode.classification |> Atom.to_string() |> String.replace("_", " ")}",
      if(episode.binding_constraints != [],
        do: "#{length(episode.binding_constraints)} binding constraints"
      ),
      if(episode.alternatives != [],
        do: "#{length(episode.alternatives)} alternatives considered"
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "Comparable Fleet Generation chapters using only retained outcome evidence."
  def generation_recaps(%Scope{operator: %{id: operator_id}} = scope) do
    generations = FleetGeneration.list_generations(scope)

    episodes =
      Repo.all(
        from episode in StrategyDecisionEpisode,
          where: episode.operator_id == ^operator_id,
          select: episode
      )
      |> Enum.group_by(& &1.fleet_generation_id)

    revision_ids =
      generations
      |> Enum.map(& &1.fleet_strategy_revision_id)
      |> Kernel.++(
        for {_id, entries} <- episodes, entry <- entries, do: entry.fleet_strategy_revision_id
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    revisions =
      Repo.all(from revision in Revision, where: revision.id in ^revision_ids)
      |> Map.new(&{&1.id, &1})

    Enum.map(generations, fn generation ->
      decisions = Map.get(episodes, generation.id, [])

      credit_changes =
        for %{classification: :realized, actual_outcomes: %{"net_credit_change" => change}} <-
              decisions,
            is_number(change),
            do: change

      next_generation = Enum.find(generations, &(&1.number == generation.number + 1))

      %{
        generation: generation,
        revisions:
          [
            generation.fleet_strategy_revision_id
            | Enum.map(decisions, & &1.fleet_strategy_revision_id)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.map(&Map.get(revisions, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(& &1.number)
          |> Enum.sort(),
        objective_outcomes:
          generation_objective_outcomes(
            generation,
            Map.get(revisions, generation.fleet_strategy_revision_id)
          ),
        realized_credit_change: if(credit_changes == [], do: nil, else: Enum.sum(credit_changes)),
        realized_decisions: Enum.count(decisions, &(&1.classification == :realized)),
        limitations:
          Enum.count(decisions, &(&1.classification in [:partially_realized, :reset_censored])),
        resumed?: next_generation && not is_nil(next_generation.strategy_capable_at)
      }
    end)
  end

  defp generation_objective_outcomes(_generation, nil), do: []

  defp generation_objective_outcomes(generation, revision) do
    revision.document
    |> Map.get("objectives", [])
    |> Enum.with_index()
    |> Enum.map(fn {objective, index} ->
      facts = generation.objective_progress[Integer.to_string(index)]

      evaluation =
        if is_map(facts),
          do: FleetStrategy.evaluate_objective(revision, index, atomize_keys(facts)),
          else: {:error, :unknown}

      %{name: objective["objective"], evaluation: evaluation}
    end)
  end

  @doc """
  Returns the current Market execution report for the active Fleet Generation.

  The report carries the shadow-published expectations, the realized economics
  from the last completed round trip, the Fleet contribution, and any limitation
  or Attention worth surfacing to the Operator.
  """
  def market_execution(%Scope{} = scope) do
    case FleetAllocation.current_portfolio(scope) do
      nil ->
        %{
          family: nil,
          expected: nil,
          realized: %{
            completed_round_trips: 0,
            realized_net_credit_change: nil,
            realized_sale_value: nil
          },
          contribution: %{commitment_count: 0, expected_value: 0},
          limitation: nil,
          attention: []
        }

      portfolio ->
        family = portfolio_family(portfolio.strategy_decision_episode)

        %{
          family: family,
          expected: if(family == :market, do: expected_economics(portfolio)),
          realized:
            if(family == :market,
              do: realized_economics(portfolio),
              else: %{
                completed_round_trips: 0,
                realized_net_credit_change: nil,
                realized_sale_value: nil
              }
            ),
          contribution: contribution(portfolio),
          limitation: limitation(portfolio),
          attention: []
        }
    end
  end

  defp portfolio_family(%{calibration_version: "market" <> _}), do: :market
  defp portfolio_family(%{calibration_version: "resources" <> _}), do: :resources
  defp portfolio_family(_), do: :other

  @doc """
  Refreshes one Operator-owned Agent in an existing dashboard projection.

  An Agent outside the supplied scope cannot be read and leaves the projection
  unchanged. A failed refresh replaces prior values with the new explicit error.
  """
  def refresh_agent(%Scope{operator: operator}, projections, agent_id) do
    case Agent.get_agent(operator, agent_id) do
      nil ->
        projections

      agent ->
        Enum.map(projections, fn projection ->
          if projection.agent.id == agent.id do
            agent |> Fleet.command_snapshot() |> without_credentials()
          else
            projection
          end
        end)
    end
  end

  @doc "Reads one Waypoint's Market projection for an Operator-owned Agent."
  def waypoint_market(%Scope{} = scope, %AgentRecord{} = agent, waypoint) do
    if owned_by?(agent, scope) do
      Fleet.waypoint_market(agent, waypoint)
    else
      {:error, :waypoint_unavailable}
    end
  end

  @doc "Reads current and stale Waypoint readiness facts for an Operator-owned Agent."
  def waypoint_readiness(%Scope{} = scope, %AgentRecord{} = agent, waypoint) do
    if owned_by?(agent, scope) do
      waypoint_facts =
        Intelligence.subject(agent, :waypoint, waypoint.system_symbol, waypoint.symbol)

      if waypoint.is_under_construction == true do
        _ = Fleet.waypoint_construction(agent, waypoint)
      end

      construction =
        Intelligence.subject_with_stale(
          agent,
          :construction,
          waypoint.system_symbol,
          waypoint.symbol
        )

      if waypoint.type == "JUMP_GATE" do
        _ = Fleet.waypoint_jump_gate(agent, waypoint)
      end

      gate =
        Intelligence.subject_with_stale(
          agent,
          :jump_gate,
          waypoint.system_symbol,
          waypoint.symbol
        )

      market =
        Intelligence.subject_with_stale(
          agent,
          :market,
          waypoint.system_symbol,
          waypoint.symbol
        )

      waypoint_facts
      |> Map.merge(namespace_facts(construction.current, "construction"))
      |> Map.merge(namespace_facts(construction.stale, "construction_stale"))
      |> Map.merge(namespace_facts(gate.current, "jump_gate"))
      |> Map.merge(namespace_facts(gate.stale, "jump_gate_stale"))
      |> Map.merge(namespace_facts(market.stale, "market_stale"))
    else
      %{}
    end
  end

  @doc "Returns current and stale Market Intelligence for an Operator-owned Waypoint."
  def market_intelligence(%Scope{} = scope, %AgentRecord{} = agent, waypoint) do
    if owned_by?(agent, scope) do
      Intelligence.subject_with_stale(agent, :market, waypoint.system_symbol, waypoint.symbol)
    else
      %{current: %{}, stale: %{}}
    end
  end

  @doc "Returns observed Marketplace Waypoints for an Operator-owned Agent."
  def marketplace_waypoints(%Scope{} = scope, %AgentRecord{} = agent, system_symbol) do
    if owned_by?(agent, scope) do
      Intelligence.marketplace_waypoints(agent, system_symbol)
    else
      []
    end
  end

  @doc "Returns a usable Survey for an Operator-owned Agent, when one exists."
  def usable_survey(%Scope{} = scope, %AgentRecord{} = agent, waypoint_symbol) do
    if owned_by?(agent, scope) do
      Intelligence.usable_survey(agent, waypoint_symbol)
    end
  end

  defp owned_by?(%AgentRecord{operator_id: operator_id}, %Scope{operator: %{id: operator_id}}),
    do: true

  defp owned_by?(_agent, _scope), do: false

  defp without_credentials(%{agent: %AgentRecord{} = agent} = projection) do
    %{projection | agent: without_agent_credentials(agent)}
  end

  defp without_agent_credentials(%AgentRecord{} = agent), do: %{agent | agent_token: nil}

  defp agent_market_planning(revision, agent, as_of) do
    with {:ok, system_symbol} <- Fleet.system_from_headquarters(agent.headquarters) do
      markets =
        agent
        |> Intelligence.marketplace_waypoints(system_symbol)
        |> Enum.map(&market_evidence(agent, system_symbol, &1, as_of))

      snapshot = FleetPlanning.market_snapshot(as_of, system_symbol, agent.id, markets)

      revision.document
      |> Map.get("objectives", [])
      |> Enum.with_index()
      |> Enum.map(fn {objective, objective_index} ->
        {:ok, planning} = FleetPlanning.plan_market(revision, objective_index, snapshot)

        %{
          agent: agent,
          objective: objective,
          objective_index: objective_index,
          planning: planning
        }
      end)
    else
      _ -> []
    end
  end

  defp market_evidence(agent, system_symbol, waypoint_symbol, as_of) do
    facts = Intelligence.subject_with_stale(agent, :market, system_symbol, waypoint_symbol)
    current = facts.current["trade_goods"]
    stale = facts.stale["trade_goods"]
    fact = current || stale || latest_fact(facts)

    %{
      subject: "market:#{system_symbol}:#{waypoint_symbol}",
      observed_at: (fact && fact.observation.observed_at) || as_of,
      evidence_id: fact && "intelligence-observation:#{fact.observation.id}",
      source: fact && fact.observation.source,
      state: if(is_nil(current) and not is_nil(stale), do: :stale, else: :current),
      trade_goods: if(current, do: current.value, else: stale && stale.value)
    }
  end

  defp latest_fact(%{current: current, stale: stale}) do
    (Map.values(current) ++ Map.values(stale))
    |> Enum.max_by(& &1.observation.observed_at, DateTime, fn -> nil end)
  end

  defp fleet_overview(snapshot, generations) do
    generation =
      Enum.find(generations, &(&1.agent_id == snapshot.agent.id and is_nil(&1.retired_at)))

    Map.take(snapshot, [:agent, :stale?, :overview, :ships, :activity, :control])
    |> Map.put(:generation, generation)
  end

  defp objective_overviews(nil, _generations), do: []

  defp objective_overviews(revision, generations) do
    generation =
      Enum.find(generations, fn generation ->
        generation.fleet_strategy_revision_id == revision.id and is_nil(generation.retired_at)
      end)

    revision.document
    |> Map.get("objectives", [])
    |> Enum.with_index()
    |> Enum.map(fn {objective, index} ->
      facts = generation && Map.get(generation.objective_progress, Integer.to_string(index))

      %{
        priority: index + 1,
        objective: objective,
        evaluation:
          if(is_map(facts),
            do: FleetStrategy.evaluate_objective(revision, index, atomize_keys(facts)),
            else: {:error, :unknown}
          )
      }
    end)
  end

  defp atomize_keys(facts),
    do: Map.new(facts, fn {key, value} -> {@evaluation_fact_keys[key], value} end)

  defp namespace_facts(facts, namespace) do
    Map.new(facts, fn {field, fact} -> {"#{namespace}.#{field}", fact} end)
  end

  defp expected_economics(%FleetAllocation.Portfolio{} = portfolio) do
    episode = portfolio.strategy_decision_episode
    expectations = if episode, do: episode.expectations, else: %{}

    %{
      expected_value: Enum.sum_by(portfolio.commitments, & &1.expected_value),
      decision_episode_id: if(episode, do: episode.id),
      expectations: expectations
    }
  end

  defp realized_economics(%FleetAllocation.Portfolio{} = portfolio) do
    trips =
      portfolio.commitments
      |> Enum.flat_map(fn commitment ->
        case realized_trip(commitment) do
          nil -> []
          trip -> [trip]
        end
      end)

    %{
      completed_round_trips: length(trips),
      realized_net_credit_change:
        if(trips == [], do: nil, else: Enum.sum_by(trips, & &1.net_credit_change)),
      realized_sale_value: if(trips == [], do: nil, else: Enum.sum_by(trips, & &1.sale_value))
    }
  end

  defp realized_trip(%FleetAllocation.Commitment{} = commitment) do
    with %{last_action_result: sell_result} <- FleetExecution.last_realized_sell(commitment),
         %{last_action_result: buy_result} <- FleetExecution.last_realized_buy(commitment),
         sale_value when is_integer(sale_value) <- transaction_total(sell_result),
         purchase_value when is_integer(purchase_value) <- transaction_total(buy_result) do
      %{net_credit_change: sale_value - purchase_value, sale_value: sale_value}
    else
      _ -> nil
    end
  end

  defp transaction_total(%{"transaction" => %{"total_price" => total}})
       when is_integer(total),
       do: total

  defp transaction_total(_result), do: nil

  defp contribution(%FleetAllocation.Portfolio{} = portfolio) do
    %{
      commitment_count: length(portfolio.commitments),
      expected_value: Enum.sum_by(portfolio.commitments, & &1.expected_value),
      claims: portfolio.commitments |> Enum.flat_map(& &1.claims) |> Enum.uniq()
    }
  end

  defp limitation(%FleetAllocation.Portfolio{} = portfolio) do
    cond do
      portfolio.commitments == [] ->
        "No eligible Fleet Commitment is active for this Fleet Generation."

      Enum.any?(portfolio.commitments, &(&1.unwind_state == :released)) ->
        "A Fleet Commitment was released without a confirmed outcome; allocation may select a replacement."

      true ->
        nil
    end
  end
end
