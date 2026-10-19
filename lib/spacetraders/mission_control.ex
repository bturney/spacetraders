defmodule SpaceTraders.MissionControl do
  @moduledoc """
  Read projections for the authenticated Operator's Mission Control adapter.

  The caller supplies an authenticated `SpaceTraders.Agent.Scope`. Strategy,
  condition and history projections belong to the deployment: the scope must
  prove the deployment Operator (`SpaceTraders.OperatorAuthority`) and never
  selects a tenant. Current projections resolve only the published Fleet;
  historical projections retain exact Generation and causal identity.
  This module exposes no gameplay commands.
  Read failures remain in each Fleet snapshot so adapters can render unknown or
  stale state without substituting cached values.
  """

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetShadow
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.OperatorAuthority
  alias SpaceTraders.Repo
  import Ecto.Query, only: [from: 2]

  @decision_episode_comparison_limit 100

  alias SpaceTraders.{
    Clock,
    Fleet,
    FleetAllocation,
    FleetExecution,
    FleetGeneration,
    FleetPlanning,
    FleetStrategy
  }

  defp current_agents(scope) do
    case FleetGeneration.current_fleet(scope) do
      {:ok, %{state: :current, agent: agent}} -> [agent]
      _ -> []
    end
  end

  @doc "A fresh read-only snapshot of the published Fleet, without a resource selector."
  def fleet_snapshot(%Scope{} = scope) do
    case FleetGeneration.current_fleet(scope) do
      {:ok, %{agent: %AgentRecord{id: id}, state: state}} when state in [:current, :transition] ->
        id
        |> then(&Repo.get!(AgentRecord, &1))
        |> Fleet.command_snapshot()
        |> without_credentials()

      _ ->
        nil
    end
  end

  @doc """
  Returns the authenticated Operator's Fleet Strategy review projection.

  Presets and the computed comparison of any draft against the active revision
  are included. Governed consequences for a draft are added by
  `strategy_review/3`, so read paths that do not render the review do not run
  planning.
  """
  def strategy(%Scope{} = scope), do: scope |> FleetStrategy.get() |> review_fields()

  @doc """
  Returns governed availability keyed by Agent id for the authenticated
  Operator's Agents.

  Availability is read from authoritative evidence so a draft's likely Fleet
  Commitments can be shadow-evaluated. An Agent whose Ships or credits cannot
  be established maps to `nil`, and its evaluation must state the limitation
  rather than assume zero capacity.
  """
  def availability(%Scope{} = scope) do
    with {:ok, _} <- OperatorAuthority.authorize(scope),
         %{agent_id: agent_id} <- FleetAllocation.current_generation() do
      agent = Repo.get!(AgentRecord, agent_id)

      case FleetExecution.governed_availability(agent) do
        {:ok, availability} -> %{agent_id => availability}
        {:error, _reason} -> %{agent_id => nil}
      end
    else
      _ -> %{}
    end
  end

  @doc """
  Returns the Strategy review projection for the authenticated Operator's
  current draft, including its governed consequences.
  """
  def strategy_review(%Scope{} = scope), do: strategy_review(scope, FleetStrategy.get(scope), [])

  @doc """
  Returns the Strategy review projection for a given durable Strategy
  projection, including the governed consequences of its draft.

  Accepting an existing projection keeps callers from re-reading after a
  versioned draft mutation, so a concurrent draft cannot be adopted un-reviewed.
  """
  def strategy_review(%Scope{} = scope, projection),
    do: strategy_review(scope, projection, [])

  @doc """
  Adds a draft's governed consequences to a Strategy projection.

  `:market_decision` carries one `capture_market_decision/2`, so active and
  draft consequences and shadow commitments all interpret the same captured
  inputs. Without it the review captures once itself, from `:availability`
  (`MissionControl.availability/1`), so it can shadow-evaluate likely Fleet
  Commitments without re-reading authoritative evidence on every draft edit.
  Review is read-only: it acquires no evidence and publishes no Demands,
  Claims, Reservations or Commitments.
  """
  def strategy_review(%Scope{} = scope, projection, opts) do
    capture =
      Keyword.get_lazy(opts, :market_decision, fn ->
        capture_market_decision(scope, availability: Keyword.get(opts, :availability, %{}))
      end)

    projection
    |> review_fields()
    |> Map.put(:market_decision, Map.take(capture, [:as_of, :version]))
    |> Map.put(:draft_consequences, draft_consequences(capture, projection.draft))
    |> Map.put(:draft_commitments, draft_commitments(capture, projection))
  end

  @doc """
  Captures, once, the fixed local inputs of a Market decision evaluation: one
  decision time, the shared Operational Intelligence Market interpretation
  (original evidence references and explicit coverage gaps), Governed
  Availability and the advisory Capacity Disposition, per Agent.

  Active and draft comparison and market planning evaluate the capture and
  never rebuild prices, provenance, coverage or observation time. It is
  conditional on retained local evidence, not an atomic view of the game.
  Capturing is read-only. `:availability` is `availability/1`; `:as_of` an
  explicit decision time.
  """
  def capture_market_decision(%Scope{} = scope, opts \\ []) do
    as_of = Keyword.get_lazy(opts, :as_of, &Clock.utc_now/0)
    availability = Keyword.get(opts, :availability, %{})

    agents =
      scope
      |> current_agents()
      |> Enum.flat_map(fn agent ->
        case Fleet.system_from_headquarters(agent.headquarters) do
          {:ok, system_symbol} ->
            input = FleetShadow.market_input(agent, system_symbol, as_of)

            [
              %{
                agent: agent,
                system_symbol: system_symbol,
                market_input: input,
                availability: Map.get(availability, agent.id),
                version: market_input_version(input)
              }
            ]

          _ ->
            []
        end
      end)

    %{
      as_of: as_of,
      capacity: FleetCapacity.disposition("get-market"),
      agents: agents,
      version: Enum.map(agents, &{&1.agent.id, &1.version})
    }
  end

  @doc """
  True while a captured Market decision still matches the retained local
  evidence: no relevant Market observation, invalidation or Fleet Generation
  change since capture. A stale capture must not be shown as current;
  activation never dispatches it and plans afresh.
  """
  def market_decision_current?(%Scope{} = scope, %{version: version}),
    do: capture_market_decision(scope).version == version

  # Source version of a captured interpretation: Fleet Generation and the
  # persisted evidence identity of every Marketplace, never the review clock.
  # Ageing from current to stale is not a source change.
  defp market_input_version(input) do
    Evidence.fingerprint({
      input.fleet_generation_id,
      Enum.map(input.markets, &{&1.subject, version_state(&1.state), &1.evidence_id}),
      input.baseline_subjects
    })
  end

  defp version_state(state) when state in [:current, :stale], do: :retained
  defp version_state(state), do: state

  defp review_fields(projection) do
    projection
    |> Map.put(:presets, FleetStrategy.presets())
    |> Map.put(:draft_comparison, draft_comparison(projection))
    |> Map.put(:credit_margin_percent, SpaceTraders.CreditCalibration.active().margin_percent)
  end

  @doc """
  Returns visible Market Candidate Contributions from retained Operational
  Intelligence, planned from `capture` (`capture_market_decision/2`) so it
  shares inputs with the Strategy review; omitted, it captures at the current
  time.
  """
  def market_planning(%Scope{} = scope, capture \\ nil) do
    case FleetStrategy.get(scope).active_revision do
      nil ->
        []

      revision ->
        capture = capture || capture_market_decision(scope)

        Enum.flat_map(capture.agents, fn entry ->
          plan_market_objectives(revision.document, entry, fn objective_index, snapshot ->
            FleetPlanning.plan_market(revision, objective_index, snapshot)
          end)
        end)
    end
  end

  defp actual_credit_change(outcomes) do
    Map.get(outcomes, "net_credit_change", Map.get(outcomes, "credit_change"))
  end

  @doc "Comparable Fleet Generation chapters using only retained outcome evidence."
  def generation_recaps(%Scope{} = scope) do
    case OperatorAuthority.authorize(scope) do
      {:ok, operator_id} -> deployment_generation_recaps(scope, operator_id)
      {:error, _reason} -> []
    end
  end

  defp deployment_generation_recaps(scope, _operator_id) do
    generations = FleetGeneration.list_generations(scope)

    episodes =
      Repo.all(
        from episode in StrategyDecisionEpisode,
          select: episode
      )
      |> Enum.group_by(& &1.fleet_generation_id)

    revisions =
      Repo.all(Revision)
      |> Map.new(&{&1.id, &1})

    Enum.map(generations, fn generation ->
      decisions = episodes |> Map.get(generation.id, []) |> Enum.sort_by(& &1.id, :desc)

      credit_changes =
        for %{classification: :realized, actual_outcomes: outcomes, evidence_references: refs} <-
              decisions,
            refs != [],
            change = actual_credit_change(outcomes),
            is_number(change),
            do: change

      next_generation = Enum.find(generations, &(&1.number == generation.number + 1))
      end_at = generation.retired_at || DateTime.utc_now()

      # Activation times have second precision. A Revision activated in the
      # same second a Generation ended is ambiguous by time alone; activation
      # moves only a live Generation onto the new Revision, so the ended
      # Generation's own Revision decides whether that one governed it.
      final_revision_number =
        if generation.retired_at || generation.fenced_at do
          case Map.get(revisions, generation.fleet_strategy_revision_id) do
            %Revision{number: number} -> number
            nil -> nil
          end
        end

      started_under =
        revisions
        |> Map.values()
        |> Enum.filter(&(DateTime.compare(&1.activated_at, generation.inserted_at) != :gt))

      initial_revision = Map.get(revisions, generation.initial_fleet_strategy_revision_id)

      # New Generations retain their actual establishment Revision. Legacy
      # history without that identity keeps the existing timestamp fallback;
      # never let a same-second activation overwrite known provenance.
      revisions_at_start =
        if initial_revision do
          [initial_revision]
        else
          case Enum.max_by(started_under, & &1.activated_at, DateTime, fn -> nil end) do
            nil ->
              []

            latest ->
              Enum.filter(
                started_under,
                &(DateTime.compare(&1.activated_at, latest.activated_at) == :eq and
                    (is_nil(final_revision_number) or &1.number <= final_revision_number))
              )
          end
        end

      end_second = DateTime.truncate(end_at, :second)

      active_revisions =
        revisions
        |> Map.values()
        |> Enum.filter(fn revision ->
          (is_nil(initial_revision) or revision.number >= initial_revision.number) and
            DateTime.compare(revision.activated_at, generation.inserted_at) != :lt and
            case DateTime.compare(revision.activated_at, end_second) do
              :lt -> true
              :eq -> is_nil(final_revision_number) or revision.number <= final_revision_number
              :gt -> false
            end
        end)

      %{
        generation: generation,
        revisions:
          [
            generation.fleet_strategy_revision_id
            | Enum.map(revisions_at_start, & &1.id) ++
                Enum.map(decisions, & &1.fleet_strategy_revision_id) ++
                Enum.map(active_revisions, & &1.id)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.map(&Map.get(revisions, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(& &1.number)
          |> Enum.sort(),
        objective_outcomes:
          (revisions_at_start ++ active_revisions)
          |> Enum.uniq_by(& &1.id)
          |> Enum.flat_map(&generation_objective_outcomes(generation, &1)),
        realized_credit_change: if(credit_changes == [], do: nil, else: Enum.sum(credit_changes)),
        realized_decisions: Enum.count(decisions, &(&1.classification == :realized)),
        limitations:
          decisions
          |> Enum.filter(&(&1.classification in [:partially_realized, :reset_censored]))
          |> Enum.map(fn
            %{classification: :partially_realized} -> "Decision partly realized"
            %{classification: :reset_censored} -> "Decision interrupted by Server Reset"
          end),
        resumed?: next_generation && not is_nil(next_generation.strategy_capable_at)
      }
    end)
  end

  @doc "Returns one Decision Episode scoped to the authenticated Operator."
  def decision_episode(%Scope{} = scope, id) when is_integer(id) do
    case OperatorAuthority.authorize(scope) do
      {:ok, operator_id} -> deployment_decision_episode(operator_id, id)
      {:error, _reason} -> nil
    end
  end

  def decision_episode(%Scope{}, _id), do: nil

  defp deployment_decision_episode(_operator_id, id) do
    Repo.one(
      from episode in StrategyDecisionEpisode,
        join: generation in assoc(episode, :fleet_generation),
        join: revision in assoc(episode, :fleet_strategy_revision),
        where: episode.id == ^id,
        select: {episode, generation, revision}
    )
    |> case do
      {episode, generation, revision} ->
        decision_episode_projection(episode, generation, revision)

      nil ->
        nil
    end
  end

  @doc "Returns a bounded, newest-first Decision Episode comparison across Fleet Generations."
  def decision_episode_comparison(%Scope{} = scope, limit \\ @decision_episode_comparison_limit)
      when is_integer(limit) and limit > 0 do
    case OperatorAuthority.authorize(scope) do
      {:ok, operator_id} -> deployment_decision_episode_comparison(operator_id, limit)
      {:error, _reason} -> []
    end
  end

  defp deployment_decision_episode_comparison(_operator_id, limit) do
    Repo.all(
      from episode in StrategyDecisionEpisode,
        join: generation in assoc(episode, :fleet_generation),
        join: revision in assoc(episode, :fleet_strategy_revision),
        order_by: [desc: episode.inserted_at, desc: episode.id],
        limit: ^limit,
        select: {episode, generation, revision}
    )
    |> Enum.map(fn {episode, generation, revision} ->
      %{
        id: episode.id,
        fleet_generation_id: episode.fleet_generation_id,
        fleet_generation_number: generation.number,
        fleet_strategy_revision_id: episode.fleet_strategy_revision_id,
        fleet_strategy_revision_number: revision.number,
        expectations: episode.expectations,
        actual_outcomes: episode.actual_outcomes,
        evidence_reference_count: length(episode.evidence_references),
        calibration_version: episode.calibration_version,
        classification: episode.classification
      }
    end)
  end

  defp decision_episode_projection(episode, generation, revision) do
    %{
      id: episode.id,
      fleet_generation_id: episode.fleet_generation_id,
      fleet_generation_number: generation.number,
      fleet_generation_symbol: generation.symbol,
      fleet_strategy_revision_id: episode.fleet_strategy_revision_id,
      fleet_strategy_revision_number: revision && revision.number,
      source_version: episode.source_version,
      evidence_references: episode.evidence_references,
      alternatives: episode.alternatives,
      binding_constraints: episode.binding_constraints,
      expectations: episode.expectations,
      actual_outcomes: episode.actual_outcomes,
      calibration_version: episode.calibration_version,
      classification: episode.classification,
      inserted_at: episode.inserted_at,
      updated_at: episode.updated_at
    }
  end

  defp generation_objective_outcomes(_generation, nil), do: []

  defp generation_objective_outcomes(generation, revision) do
    revision.document
    |> Map.get("objectives", [])
    |> Enum.with_index()
    |> Enum.map(fn {objective, index} ->
      facts = generation.objective_progress[Integer.to_string(index)]

      revision_matches? = facts["revision_id"] == revision.id

      evaluation =
        if is_map(facts) and revision_matches? and objective_evidence_valid?(generation, facts),
          do: FleetStrategy.evaluate_persisted_objective(revision, index, facts),
          else: {:error, :unknown}

      %{revision: revision.number, name: objective["objective"], evaluation: evaluation}
    end)
  end

  defp without_credentials(%{agent: %AgentRecord{} = agent} = projection) do
    %{projection | agent: without_agent_credentials(agent)}
  end

  defp without_agent_credentials(%AgentRecord{} = agent), do: %{agent | agent_token: nil}

  defp draft_comparison(%{draft: draft, active_revision: %Revision{document: document}})
       when is_map(draft) and is_map(document),
       do: FleetStrategy.compare_documents(document, draft)

  defp draft_comparison(_projection), do: nil

  defp draft_consequences(_capture, draft) when not is_map(draft), do: []

  defp draft_consequences(capture, draft) do
    Enum.flat_map(capture.agents, fn entry ->
      plan_market_objectives(draft, entry, fn objective_index, snapshot ->
        FleetPlanning.plan_draft_market(draft, objective_index, snapshot)
      end)
    end)
  end

  defp draft_commitments(_capture, %{draft: draft}) when not is_map(draft), do: []

  defp draft_commitments(capture, %{draft: draft, active_revision: active}) do
    Enum.map(capture.agents, fn
      %{availability: nil} = entry ->
        %{agent: entry.agent, availability: :unknown, active: nil, draft: nil}

      entry ->
        %{
          agent: entry.agent,
          availability: :authoritative,
          active: shadow_summary(entry, capture.capacity, active),
          draft:
            shadow_summary(
              entry,
              capture.capacity,
              %Revision{id: {:draft, entry.agent.id}, document: draft}
            )
        }
    end)
  end

  defp shadow_summary(_entry, _capacity, nil), do: nil

  defp shadow_summary(entry, capacity, %Revision{} = revision) do
    entry.market_input
    |> FleetShadow.compare(revision, entry.availability, capacity)
    |> summarize_shadow()
  end

  defp summarize_shadow({:ok, comparison}) do
    %{
      error: nil,
      expectations: comparison.expectations,
      commitments:
        Enum.map(
          comparison.proposed_choices,
          &Map.take(&1, [:candidate_id, :claims, :expected_value])
        ),
      rejected: Enum.map(comparison.alternatives, &Map.take(&1, [:candidate_id, :reasons])),
      limitations: Enum.flat_map(comparison.planning, & &1.limitations)
    }
  end

  defp summarize_shadow({:error, reason}), do: %{error: reason}

  defp plan_market_objectives(document, %{agent: agent, market_input: snapshot}, plan_objective) do
    document
    |> Map.get("objectives", [])
    |> Enum.with_index()
    |> Enum.map(fn {objective, objective_index} ->
      {:ok, planning} = plan_objective.(objective_index, snapshot)

      %{
        agent: agent,
        objective: objective,
        objective_index: objective_index,
        planning: planning
      }
    end)
  end

  defp objective_evidence_valid?(generation, facts) do
    evidence = facts["evidence_id"] && Repo.get(Observation, facts["evidence_id"])

    Evidence.valid_observation?(evidence) and
      evidence.agent_id == generation.agent_id and
      DateTime.compare(evidence.observed_at, generation.inserted_at) != :lt and
      DateTime.compare(evidence.observed_at, DateTime.utc_now()) != :gt and
      (is_nil(generation.retired_at) or
         DateTime.compare(evidence.observed_at, generation.retired_at) != :gt) and
      (is_nil(generation.retired_at) or
         DateTime.diff(DateTime.utc_now(), evidence.observed_at, :second) <= 300)
  end
end
