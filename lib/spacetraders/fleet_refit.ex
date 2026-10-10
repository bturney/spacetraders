defmodule SpaceTraders.FleetRefit do
  @moduledoc """
  Selects and reconciles autonomous Ship refit under Fleet Commitments.

  A Fleet Commitment declares a target capability; planning proposes refit
  Candidates with the authoritative supply and price at reachable Markets,
  Fleet Allocation claims the Ship and reserves credits and Cargo, and the
  claimed Intent navigates to the supply Market, buys the module when needed,
  performs the install or removal mutation, and reconciles the authoritative
  installed-module state before the Commitment completes.

  ADR 0011: `MutationAttempts` is the sole authority on whether a dispatched
  mutation happened; recovery reconciles that attempt from the narrowest
  authoritative resource, and the Decision Episode references reconciled
  attempts rather than writing a second copy of the same fact.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.{Intelligence, Repo, ShipReservation}

  @doc "Selects and dispatches a refit Candidate, or resumes one already claimed."
  def reconcile(%Scope{} = scope, %AgentRecord{} = agent, %Revision{} = revision, system)
      when is_binary(system) do
    case FleetAllocation.current_portfolio(scope, agent) do
      nil -> acquire(scope, agent, revision, system)
      portfolio -> resume(scope, agent, portfolio)
    end
  end

  def reconcile(_scope, _agent, _revision, _system), do: {:error, :ship_refit_unavailable}

  defp acquire(scope, agent, revision, system) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         index when is_integer(index) <- objective_index(revision),
         %Generation{} = generation <- active_generation(agent, revision),
         true <- Intents.current(agent) == [],
         {:ok, overview} <- SpaceTraders.Agent.agent_overview(agent),
         {:ok, floor} <- StandingAuthority.credit_floor(revision),
         true <- is_integer(overview.credits) and overview.credits >= floor,
         {:ok, ships} <- Fleet.list_ships(agent),
         ships <-
           Enum.reject(ships, &(&1.symbol in ShipReservation.reserved_symbols(agent.id))),
         as_of = DateTime.utc_now(),
         {:ok, planning} <-
           FleetPlanning.plan_ship_refit(revision, index, %{
             as_of: as_of,
             credit_margin_percent: SpaceTraders.CreditCalibration.active().margin_percent,
             credits: overview.credits,
             ships: ships,
             markets: market_supply(agent, system, as_of),
             targets: revision_targets(revision, index),
             releases: revision_releases(revision)
           }),
         {:ok, selected} <-
           FleetAllocation.select_portfolio(revision, planning.candidate_contributions, %{
             as_of: as_of,
             claims: Enum.map(ships, &refit_claim/1),
             reservations: %{credits: overview.credits}
           }),
         [commitment | _] <- selected.commitments,
         candidate <-
           Enum.find(planning.candidate_contributions, &(&1.id == commitment.candidate_id)),
         true <- not is_nil(candidate),
         :ok <- authorize_refit(revision, overview.credits, candidate),
         {:ok, portfolio} <-
           FleetAllocation.publish_portfolio(
             scope,
             generation.id,
             %{
               selected
               | commitments: [commitment],
                 rejected:
                   rejected_candidates(selected.rejected, candidate, planning.limitations),
                 source_version: generation.allocation_version
             },
             %{
               evidence_references: candidate.dependencies,
               expectations: refit_expectations(candidate),
               calibration_version: "ship-refit-v1"
             }
           ),
         [persisted] <- portfolio.commitments,
         [ship_symbol] <- persisted.claims do
      Intents.request_commitment_refit(agent, persisted, portfolio, ship_symbol, candidate)
    else
      _ -> {:error, :ship_refit_unavailable}
    end
  end

  defp resume(scope, agent, portfolio) do
    with {:ok, ship_symbol} <- refit_ship_symbol(portfolio),
         {:ok, intent} <- refit_intent(agent, portfolio) do
      case intent.status do
        "completed" ->
          conclude(scope, agent, portfolio, intent, ship_symbol)

        status when status in ["active", "waiting", "awaiting_confirmation", "blocked"] ->
          {:error, :ship_refit_in_progress}

        "infeasible" ->
          conclude_superseded(scope, portfolio)

        _ ->
          {:error, :ship_refit_unavailable}
      end
    end
  end

  defp refit_ship_symbol(portfolio) do
    case Enum.filter(portfolio.commitments, &(&1.unwind_state == :not_required)) do
      [%{claims: [ship_symbol]}] when is_binary(ship_symbol) -> {:ok, ship_symbol}
      _ -> {:error, :no_refit_claim}
    end
  end

  defp refit_intent(_agent, portfolio) do
    intent =
      Repo.one(
        from intent in Intent,
          join: commitment in Commitment,
          on: commitment.id == intent.fleet_commitment_id,
          where:
            commitment.fleet_commitment_portfolio_id == ^portfolio.id and
              intent.type in ["install_module", "remove_module"] and
              intent.caller == "commitment",
          order_by: [desc: intent.id],
          limit: 1
      )

    if intent, do: {:ok, intent}, else: {:error, :no_refit_intent}
  end

  # ADR 0011: the episode's actual outcomes reference the reconciled attempt;
  # the authoritative readiness read decides whether the declared capability holds.
  defp conclude(scope, agent, portfolio, intent, ship_symbol) do
    expectations = portfolio.strategy_decision_episode.expectations
    module_symbol = expectations["module_symbol"]
    installed_before = expectations["installed_before"]

    with {:ok, ready} <- read_readiness(agent, ship_symbol) do
      installed_after = ready_modules_count(ready.modules, module_symbol)
      attempt = reconcile_attempt(intent)

      classification =
        if attempt_declared_outcome?(expectations, installed_before, installed_after),
          do: :realized,
          else: :partially_realized

      outcome = refit_outcome(expectations, installed_before, installed_after, attempt)

      with {:ok, _episode} <-
             FleetAllocation.record_decision_outcome(
               scope,
               portfolio.strategy_decision_episode_id,
               classification,
               outcome
             ),
           {:ok, _portfolio} <-
             FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id) do
        if classification == :realized do
          {:ok, %{ship_symbol: ship_symbol, module_symbol: module_symbol, portfolio: portfolio}}
        else
          {:error, :ship_refit_readiness_mismatch}
        end
      end
    end
  end

  defp conclude_superseded(scope, portfolio) do
    expectations = portfolio.strategy_decision_episode.expectations

    outcome =
      Map.merge(string_expectations(expectations), %{
        "actual" => "not_realized",
        "reason" => "refit_intent_infeasible"
      })

    with {:ok, _episode} <-
           FleetAllocation.record_decision_outcome(
             scope,
             portfolio.strategy_decision_episode_id,
             :superseded,
             outcome
           ),
         {:ok, _portfolio} <-
           FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id) do
      {:error, :ship_refit_infeasible}
    end
  end

  defp refit_outcome(expectations, installed_before, installed_after, attempt) do
    Map.merge(string_expectations(expectations), %{
      "installed_before" => installed_before,
      "installed_after" => installed_after,
      # The Candidate's expected cost prices the Commitment; the price the buy
      # leg actually paid is the actual result the episode retains.
      "actual_cost" => Map.get(expectations, "purchased_price") || 0,
      "reconciliation" => attempt_projection(attempt)
    })
  end

  defp attempt_projection(nil),
    do: %{"mutation_attempt_id" => nil, "state" => "none", "basis" => "no_dispatched_attempt"}

  defp attempt_projection(%Attempt{} = attempt) do
    %{
      "mutation_attempt_id" => attempt.id,
      "state" => attempt.state,
      "request_fingerprint" => attempt.request_fingerprint,
      "basis" => "reconciled_mutation_attempt"
    }
  end

  # The attempt is identified by its Intent provenance, not by the Intent's
  # current in-flight action, so the episode can reference the attempt after
  # the Intent completed.
  defp reconcile_attempt(intent) do
    Repo.one(
      from attempt in Attempt,
        where:
          fragment("? @> ?", attempt.provenance, ^%{"intent_id" => intent.id}) and
            attempt.state in ["prepared", "sent_or_unknown", "ambiguous", "succeeded", "rejected"],
        order_by: [desc: attempt.prepared_at, desc: attempt.id],
        limit: 1
    )
  end

  # The Candidate declared the readiness gate: an install completes when the
  # authoritative read proves the module aboard; a removal completes when the
  # authoritative read proves the module gone.
  defp attempt_declared_outcome?(expectations, installed_before, installed_after) do
    case Map.get(expectations, "action") do
      "install" -> installed_after == installed_before + 1
      "remove" -> installed_after == 0 and installed_after < installed_before
    end
  end

  defp ready_modules_count(modules, symbol) when is_list(modules),
    do: Enum.count(modules, &(&1.symbol == symbol))

  defp ready_modules_count(_modules, _symbol), do: 0

  defp read_readiness(agent, ship_symbol) do
    SpaceTraders.Agent.handle_game_result(
      agent,
      Evidence.get_ship(AgentTokenReference.new(agent), ship_symbol,
        owner: "fleet_reconciliation",
        required_facts: ["readiness"]
      )
    )
  end

  defp refit_claim(ship) do
    %{
      resource: ship.symbol,
      roles: [:fleet_refit],
      capabilities: %{
        refit_ship: ship.symbol,
        cargo_transport: cargo_capacity(ship)
      }
    }
  end

  defp cargo_capacity(%{cargo: %{capacity: capacity}}) when is_integer(capacity), do: capacity
  defp cargo_capacity(_), do: 0

  defp authorize_refit(revision, credits, candidate) do
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

  defp refit_expectations(candidate) do
    Map.merge(candidate.expected_outcomes, %{
      module_symbol: candidate.refit.module_symbol,
      action: candidate.refit.action,
      capability: candidate.refit.capability,
      expected_cost: candidate.refit.expected_cost,
      installed_before: candidate.refit.installed_before,
      alternatives: candidate.alternatives,
      opportunity_cost: %{
        foregone_decision_value:
          candidate.alternatives
          |> Enum.map(&get_in(&1, [:expected_outcomes, :decision_value]))
          |> Enum.max(fn -> 0 end)
      }
    })
  end

  defp string_expectations(expectations) do
    Map.new(expectations, fn
      {key, value} when is_atom(key) and not is_boolean(key) ->
        {Atom.to_string(key), json_safe(value)}

      {key, value} ->
        {key, json_safe(value)}
    end)
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(value) when is_struct(value), do: json_safe(Map.from_struct(value))
  defp json_safe(value) when is_tuple(value), do: Tuple.to_list(value)

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), json_safe(v)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: to_string(value)

  defp json_safe(value), do: value

  defp rejected_candidates(rejected, candidate, limitations) do
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

  defp limitation_rejection(limitation) do
    %{
      candidate_id: nil,
      reasons: [limitation.reason],
      alternative: nil,
      decisive_reason: %{subject: limitation.subject, unmet: limitation.reason}
    }
  end

  defp objective_index(%Revision{document: %{"objectives" => objectives}}) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if FleetPlanning.ship_refit_objective?(objective), do: index
    end)
  end

  defp objective_index(_revision), do: nil

  defp revision_targets(revision, index) when is_integer(index) do
    with %{"objectives" => objectives} <- revision.document,
         objective when is_map(objective) <- Enum.at(objectives, index),
         module_symbols when is_list(module_symbols) and module_symbols != [] <-
           Map.get(objective, "target_modules", []) do
      [%{capability: refit_capability(objective), module_symbols: module_symbols}]
    else
      _ -> []
    end
  end

  defp revision_targets(_revision, _index), do: []

  defp refit_capability(objective) do
    case Map.get(objective, "capability") do
      capability when is_binary(capability) and capability != "" ->
        String.to_existing_atom(capability)

      _ ->
        :declared_capability
    end
  end

  defp revision_releases(revision) do
    case revision.document do
      %{"releases" => releases} when is_list(releases) ->
        Enum.flat_map(releases, fn release ->
          with ship when is_binary(ship) <- Map.get(release, "ship"),
               module_symbol when is_binary(module_symbol) <- Map.get(release, "module_symbol") do
            [
              %{
                ship: ship,
                module_symbol: module_symbol,
                scope:
                  case Map.get(release, "scope") do
                    "all_matching" -> :all_matching
                    _ -> nil
                  end
              }
            ]
          else
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  # Module supply comes from the shared Market interpretation: only a
  # `:current` Listing (linked governed evidence of this Generation, fresh,
  # well-formed, not after the decision time) can support a purchase.
  defp market_supply(agent, system, as_of) do
    agent
    |> Intelligence.market_interpretation(system, as_of)
    |> Map.fetch!(:markets)
    |> Enum.flat_map(fn
      %{state: :current, subject: "market:" <> _ = subject} = listing ->
        [
          %{
            system_symbol: system,
            waypoint: subject |> String.split(":") |> List.last(),
            observed_at: listing.observed_at,
            evidence_id: listing.evidence_id,
            source: listing.source,
            trade_goods: Enum.map(listing.trade_goods, &market_good/1)
          }
        ]

      _ ->
        []
    end)
  end

  # Waypoint intelligence projects Listing values with string keys; planning
  # reads them as atom-keyed model fields.
  defp market_good(good) when is_map(good) do
    Map.new(good, fn
      {key, value} when is_binary(key) ->
        {String.to_existing_atom(key), value}

      pair ->
        pair
    end)
  end

  defp market_good(good), do: good

  defp active_generation(agent, revision) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent.id and
            generation.fleet_strategy_revision_id == ^revision.id and
            is_nil(generation.fenced_at) and is_nil(generation.retired_at)
    )
  end
end
