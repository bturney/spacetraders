defmodule SpaceTraders.FleetAllocation do
  @moduledoc """
  Applies Fleet Strategy ordering to evidence-bound candidate plans and selects
  coherent Fleet Commitment portfolios without publishing command authority.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, StrategyDecisionEpisode}
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning.CandidateContribution
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.{ManualIntervention, Outbox, Repo, ShipReservation}

  alias SpaceTraders.FleetStrategy.{
    ObjectiveEvaluation,
    PreferenceEvaluation,
    Revision,
    StandingAuthority
  }

  defmodule FleetCommitment do
    @moduledoc "An accepted Candidate Contribution and its resource protections."

    @enforce_keys [
      :id,
      :candidate_id,
      :objective_index,
      :claims,
      :reservations,
      :pledges,
      :dependencies,
      :expected_value,
      :unwind_cost,
      :decisive_reason
    ]
    defstruct @enforce_keys
  end

  defmodule PortfolioCandidate do
    @moduledoc "A typed Fleet Allocation proposal for a Candidate Contribution."

    @enforce_keys [
      :id,
      :strategy_revision_id,
      :objective_index,
      :claims,
      :reservations,
      :pledges,
      :dependencies,
      :expected_value,
      :unwind_cost
    ]
    defstruct @enforce_keys
  end

  @doc """
  Selects a deterministic, coherent Fleet Commitment portfolio.

  Candidate maps declare requested exclusive `:claims`, fungible
  `:reservations`, and outcome `:pledges`. Availability declares the exclusive
  resources and fungible capacities the Fleet may commit. Availability may also
  carry the current `:source_version`, which binds the selection to the durable
  allocation state. Selection is pure; publishing the returned protections as
  active authority is a separate step.
  """
  def select_portfolio(%Revision{} = revision, candidates, availability),
    do: select_portfolio(revision, candidates, availability, [])

  def select_portfolio(%Revision{} = revision, candidates, availability, current_commitments)
      when is_list(candidates) and is_map(availability) and is_list(current_commitments) do
    with {:ok, candidates} <- normalize_candidates(candidates, availability),
         true <- valid_allocation_input?(revision, candidates, availability, current_commitments) do
      {:ok, build_portfolio(revision, candidates, availability, current_commitments)}
    else
      _invalid -> {:error, :invalid_allocation_input}
    end
  end

  def select_portfolio(_revision, _candidates, _availability, _current_commitments),
    do: {:error, :invalid_allocation_input}

  @doc "Publishes a selected portfolio and its causal evidence against one source version."
  def publish_portfolio(
        %Scope{operator: %{id: operator_id}} = scope,
        generation_id,
        %{
          revision_id: revision_id,
          source_version: source_version,
          commitments: commitments,
          rejected: rejected
        } = selection,
        %{
          evidence_references: evidence_references,
          expectations: expectations,
          calibration_version: calibration_version
        } = decision
      )
      when is_integer(generation_id) and is_integer(revision_id) and is_list(commitments) and
             is_list(rejected) and is_list(evidence_references) and is_map(expectations) and
             is_binary(calibration_version) and calibration_version != "" and
             is_integer(source_version) and source_version >= 0 do
    if valid_published_commitments?(commitments) do
      notification = fn portfolio ->
        %{
          topic: "fleet_allocation:#{operator_id}",
          event: "fleet_commitment_portfolio_published",
          payload: %{
            "portfolio_id" => portfolio.id,
            "decision_episode_id" => portfolio.strategy_decision_episode_id,
            "version" => portfolio.version
          }
        }
      end

      Outbox.publish(notification, fn ->
        portfolio =
          publish_selected_portfolio(
            operator_id,
            generation_id,
            revision_id,
            selection,
            evidence_references,
            expectations,
            calibration_version,
            source_version
          )

        :ok =
          FleetGeneration.record_objective_evaluations(
            scope,
            Repo.get!(Revision, revision_id),
            [decision],
            notify?: false
          )

        portfolio
      end)
    else
      {:error, :invalid_publication}
    end
  end

  def publish_portfolio(_scope, _generation_id, _selection, _decision),
    do: {:error, :invalid_publication}

  @doc "Returns the current complete portfolio for the authenticated Operator's active generation."
  def current_portfolio(%Scope{operator: %{id: operator_id}}) do
    current_portfolio_query(operator_id)
    |> Repo.one()
  end

  @doc "Returns the current portfolio for one Agent's active Fleet Generation."
  def current_portfolio(%Scope{operator: %{id: operator_id}}, %AgentRecord{id: agent_id}) do
    current_portfolio_query(operator_id)
    |> where([_portfolio, generation], generation.agent_id == ^agent_id)
    |> Repo.one()
  end

  defp current_portfolio_query(operator_id) do
    Portfolio
    |> join(:inner, [portfolio], generation in Generation,
      on: generation.id == portfolio.fleet_generation_id
    )
    |> where(
      [portfolio, generation],
      portfolio.operator_id == ^operator_id and is_nil(portfolio.superseded_at) and
        is_nil(generation.fenced_at) and is_nil(generation.retired_at)
    )
    |> order_by([portfolio], desc: portfolio.version)
    |> preload([:commitments, :strategy_decision_episode])
  end

  @doc "Records confirmed outcomes and terminal classification for one Decision Episode."
  def record_decision_outcome(
        %Scope{operator: %{id: operator_id}},
        episode_id,
        classification,
        actual_outcomes
      )
      when is_integer(episode_id) and
             classification in [:realized, :partially_realized, :superseded] and
             is_map(actual_outcomes) do
    update_decision_outcome(episode_id, operator_id, classification, actual_outcomes)
  end

  def record_decision_outcome(_scope, _episode_id, _classification, _actual_outcomes),
    do: {:error, :invalid_decision_outcome}

  @doc false
  def record_portfolio_outcome(%Portfolio{} = portfolio, classification, actual_outcomes)
      when classification in [:realized, :partially_realized, :superseded] and
             is_map(actual_outcomes) do
    update_decision_outcome(
      portfolio.strategy_decision_episode_id,
      portfolio.operator_id,
      classification,
      actual_outcomes
    )
  end

  @doc "Records completed Market and resource outcomes left pending by a process restart."
  def reconcile_completed_outcomes do
    StrategyDecisionEpisode
    |> where([episode], episode.classification == :still_evaluating)
    |> join(:inner, [episode], portfolio in Portfolio,
      on: portfolio.strategy_decision_episode_id == episode.id
    )
    |> join(:inner, [_episode, portfolio], commitment in Commitment,
      on: commitment.fleet_commitment_portfolio_id == portfolio.id
    )
    |> join(:inner, [_episode, _portfolio, commitment], intent in Intent,
      on: intent.fleet_commitment_id == commitment.id
    )
    |> where(
      [_episode, _portfolio, _commitment, intent],
      intent.type in ["sell", "acquire_resources"] and intent.status == "completed"
    )
    |> where(
      [_episode, _portfolio, _commitment, intent],
      intent.type != "sell" or
        is_nil(fragment("? #> '{market_trade,construction_upstream}'", intent.parameters))
    )
    |> select([episode], episode)
    |> distinct(true)
    |> Repo.all()
    |> Enum.each(fn episode ->
      _ =
        update_decision_outcome(
          episode.id,
          episode.operator_id,
          :realized,
          realized_outcomes(episode.id)
        )
    end)

    :ok
  end

  @doc "Safely releases the current portfolio when no replacement remains admissible."
  def unwind_current_portfolio(%Scope{operator: %{id: operator_id}}, generation_id)
      when is_integer(generation_id) do
    Outbox.publish(
      fn portfolio ->
        %{
          topic: "fleet_allocation:#{operator_id}",
          event: "fleet_commitment_portfolio_unwound",
          payload: %{
            "portfolio_id" => portfolio.id,
            "decision_episode_id" => portfolio.strategy_decision_episode_id
          }
        }
      end,
      fn ->
        do_unwind_current_portfolio(operator_id, generation_id)
      end
    )
  end

  def unwind_current_portfolio(_scope, _generation_id), do: {:error, :invalid_unwind}

  @doc "Returns the current Fleet Commitment Claim authorizing one Ship."
  def current_ship_claim(agent, ship_symbol, opts \\ [])

  def current_ship_claim(
        %AgentRecord{id: agent_id, operator_id: operator_id},
        ship_symbol,
        opts
      )
      when is_integer(operator_id) and is_binary(ship_symbol) do
    query =
      from claim in "fleet_commitment_claims",
        join: commitment in Commitment,
        on: commitment.id == claim.fleet_commitment_id,
        join: portfolio in Portfolio,
        on: portfolio.id == claim.fleet_commitment_portfolio_id,
        join: generation in Generation,
        on: generation.id == portfolio.fleet_generation_id,
        where:
          claim.resource == ^ship_symbol and portfolio.operator_id == ^operator_id and
            generation.agent_id == ^agent_id and is_nil(portfolio.superseded_at) and
            is_nil(generation.fenced_at) and is_nil(generation.retired_at) and
            commitment.unwind_state == :not_required,
        select: %{
          commitment_id: commitment.id,
          candidate_id: commitment.candidate_id,
          portfolio_id: portfolio.id,
          portfolio_version: portfolio.version,
          decision_episode_id: portfolio.strategy_decision_episode_id
        }

    query = if Keyword.get(opts, :lock, false), do: lock(query, "FOR SHARE"), else: query

    case Repo.one(query) do
      nil -> {:error, :no_current_ship_claim}
      claim -> {:ok, claim}
    end
  end

  def current_ship_claim(_agent, _ship_symbol, _opts),
    do: {:error, :no_current_ship_claim}

  @doc false
  def authorize_ship_execution(agent, ship_symbol, opts \\ [])

  def authorize_ship_execution(
        %AgentRecord{id: agent_id, operator_id: operator_id} = agent,
        ship_symbol,
        opts
      )
      when is_integer(operator_id) and is_binary(ship_symbol) do
    active_generation? =
      Repo.exists?(
        from generation in Generation,
          where:
            generation.agent_id == ^agent_id and generation.operator_id == ^operator_id and
              is_nil(generation.fenced_at) and is_nil(generation.retired_at)
      )

    active_revision? =
      Repo.exists?(
        from strategy in Strategy,
          where: strategy.operator_id == ^operator_id and not is_nil(strategy.active_revision_id)
      )

    if active_generation? or active_revision? do
      case current_ship_claim(agent, ship_symbol, opts) do
        {:error, :no_current_ship_claim} = error ->
          if ManualIntervention.authorized?(operator_id, ship_symbol, opts[:intent_id]) do
            {:ok, %{commitment_id: nil, portfolio_id: nil, portfolio_version: nil}}
          else
            error
          end

        claim ->
          claim
      end
    else
      # Fleet Commitment and authenticated Manual Intervention remain the
      # supported execution authorities.
      {:ok, %{commitment_id: nil, portfolio_id: nil, portfolio_version: nil}}
    end
  end

  def authorize_ship_execution(%AgentRecord{operator_id: nil}, _ship_symbol, _opts),
    do: {:ok, %{commitment_id: nil, portfolio_id: nil, portfolio_version: nil}}

  def authorize_ship_execution(_agent, _ship_symbol, _opts),
    do: {:error, :no_current_ship_claim}

  @doc "Returns structured Ship Execution infeasibility evidence to Fleet Allocation."
  def report_infeasibility(
        %AgentRecord{operator_id: operator_id} = agent,
        ship_symbol,
        evidence,
        state_change
      )
      when is_integer(operator_id) and is_binary(ship_symbol) and is_map(evidence) and
             is_function(state_change, 0) do
    notification = fn _result ->
      claim =
        case current_ship_claim(agent, ship_symbol) do
          {:ok, claim} -> claim
          {:error, :no_current_ship_claim} -> %{}
        end

      payload =
        %{
          "ship_symbol" => ship_symbol,
          "commitment_id" => claim[:commitment_id],
          "candidate_id" => claim[:candidate_id],
          "portfolio_id" => claim[:portfolio_id],
          "portfolio_version" => claim[:portfolio_version],
          "decision_episode_id" => claim[:decision_episode_id]
        }
        |> Map.merge(json_safe(evidence))

      %{
        topic: "fleet_allocation:#{operator_id}",
        event: "ship_execution_infeasible",
        payload: payload
      }
    end

    Outbox.publish(notification, state_change)
  end

  def report_infeasibility(_agent, _ship_symbol, _evidence, _state_change),
    do: {:error, :invalid_infeasibility_evidence}

  defp publish_selected_portfolio(
         operator_id,
         generation_id,
         revision_id,
         selection,
         evidence_references,
         expectations,
         calibration_version,
         expected_source_version
       ) do
    strategy =
      Repo.one(
        from strategy in Strategy,
          where: strategy.operator_id == ^operator_id,
          lock: "FOR SHARE"
      )

    if is_nil(strategy) or strategy.active_revision_id != revision_id do
      Repo.rollback(:stale_source)
    end

    {updated_generations, _} =
      Repo.update_all(
        from(generation in Generation,
          where:
            generation.id == ^generation_id and generation.operator_id == ^operator_id and
              generation.fleet_strategy_revision_id == ^revision_id and
              generation.allocation_version == ^expected_source_version and
              is_nil(generation.fenced_at) and is_nil(generation.retired_at)
        ),
        inc: [allocation_version: 1],
        set: [updated_at: DateTime.utc_now(:second)]
      )

    if updated_generations != 1, do: Repo.rollback(:stale_source)

    # Reservation and allocation serialize on the same Ship rows. A stale
    # planning snapshot cannot claim a Ship that an Operator has reserved.
    claimed_symbols =
      selection.commitments
      |> Enum.flat_map(& &1.claims)
      |> Enum.uniq()
      |> Enum.sort()

    claimed_ships =
      Repo.all(
        from ship in Ship,
          join: generation in Generation,
          on: generation.agent_id == ship.agent_id,
          where: generation.id == ^generation_id and ship.symbol in ^claimed_symbols,
          order_by: ship.id,
          lock: "FOR UPDATE OF s0",
          select: ship.id
      )

    if length(claimed_ships) != length(claimed_symbols) or
         Repo.exists?(
           from reservation in ShipReservation,
             where: reservation.ship_id in ^claimed_ships and is_nil(reservation.released_at)
         ) do
      Repo.rollback(:ship_reserved)
    end

    now = DateTime.utc_now()

    current_portfolio_ids =
      from portfolio in Portfolio,
        where:
          portfolio.fleet_generation_id == ^generation_id and is_nil(portfolio.superseded_at),
        select: portfolio.id

    supersede_portfolios(current_portfolio_ids, now)

    revision = Repo.get!(Revision, revision_id)

    episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: operator_id,
        fleet_generation_id: generation_id,
        fleet_strategy_revision_id: revision_id,
        source_version: expected_source_version,
        evidence_references: json_safe(evidence_references),
        alternatives: json_safe(selection.rejected),
        binding_constraints:
          revision.document
          |> Map.get("hard_constraints", [])
          |> Enum.map(fn
            rule when is_binary(rule) -> %{"rule" => rule}
            rule -> json_safe(rule)
          end),
        expectations: json_safe(expectations),
        calibration_version: calibration_version
      })

    portfolio =
      Repo.insert!(%Portfolio{
        operator_id: operator_id,
        fleet_generation_id: generation_id,
        fleet_strategy_revision_id: revision_id,
        strategy_decision_episode_id: episode.id,
        version: expected_source_version + 1
      })

    Enum.each(selection.commitments, fn commitment ->
      persisted_commitment =
        Repo.insert!(%Commitment{
          fleet_commitment_portfolio_id: portfolio.id,
          candidate_id: commitment.candidate_id,
          objective_index: commitment.objective_index,
          claims: commitment.claims,
          reservations: json_safe(commitment.reservations),
          pledges: json_safe(commitment.pledges),
          dependencies: json_safe(commitment.dependencies),
          expected_value: commitment.expected_value * 1.0,
          unwind_cost: commitment.unwind_cost * 1.0,
          decisive_reason: commitment.decisive_reason
        })

      claims =
        Enum.map(commitment.claims, fn resource ->
          %{
            fleet_commitment_portfolio_id: portfolio.id,
            fleet_commitment_id: persisted_commitment.id,
            resource: resource
          }
        end)

      if claims != [], do: Repo.insert_all("fleet_commitment_claims", claims)
    end)

    Repo.preload(portfolio, [:commitments, :strategy_decision_episode])
  end

  defp json_safe(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp json_safe(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), json_safe(value)} end)
  end

  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_safe()
  defp json_safe(nil), do: nil
  defp json_safe(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp json_safe(value), do: value

  defp update_decision_outcome(episode_id, operator_id, classification, actual_outcomes) do
    query =
      StrategyDecisionEpisode
      |> where([episode], episode.id == ^episode_id and episode.operator_id == ^operator_id)
      |> where([episode], episode.classification == :still_evaluating)
      |> select([episode], episode)

    case Repo.update_all(
           query,
           [
             set: [
               classification: classification,
               actual_outcomes: json_safe(actual_outcomes),
               updated_at: DateTime.utc_now()
             ]
           ],
           returning: true
         ) do
      {1, [episode]} -> {:ok, episode}
      {0, []} -> {:error, :decision_episode_not_evaluating}
    end
  end

  defp do_unwind_current_portfolio(operator_id, generation_id) do
    now = DateTime.utc_now()

    portfolio =
      Repo.one(
        from portfolio in Portfolio,
          join: generation in Generation,
          on: generation.id == portfolio.fleet_generation_id,
          where:
            portfolio.operator_id == ^operator_id and
              portfolio.fleet_generation_id == ^generation_id and
              is_nil(portfolio.superseded_at) and is_nil(generation.fenced_at) and
              is_nil(generation.retired_at),
          preload: [:commitments, :strategy_decision_episode],
          lock: "FOR UPDATE"
      )

    if portfolio do
      supersede_portfolios([portfolio.id], now)
      %{portfolio | superseded_at: now}
    else
      Repo.rollback(:no_current_portfolio)
    end
  end

  defp supersede_portfolios(portfolio_ids, now) do
    portfolio_ids =
      case portfolio_ids do
        %Ecto.Query{} = query -> Repo.all(query)
        ids -> ids
      end

    episode_ids =
      from(portfolio in Portfolio,
        where: portfolio.id in ^portfolio_ids,
        select: portfolio.strategy_decision_episode_id
      )
      |> Repo.all()

    if unresolved_commitment_intent?(portfolio_ids),
      do: Repo.rollback(:unresolved_commitment_evidence)

    Repo.update_all(
      from(commitment in Commitment,
        where: commitment.fleet_commitment_portfolio_id in ^portfolio_ids
      ),
      set: [unwind_state: :released]
    )

    Repo.update_all(
      from(portfolio in Portfolio, where: portfolio.id in ^portfolio_ids),
      set: [superseded_at: now]
    )

    Enum.each(episode_ids, fn episode_id ->
      case Repo.get(StrategyDecisionEpisode, episode_id) do
        %{classification: :still_evaluating} = episode ->
          Repo.update!(
            Ecto.Changeset.change(episode,
              classification: :superseded,
              actual_outcomes: realized_economics(episode_id),
              updated_at: now
            )
          )

        _episode ->
          :ok
      end
    end)
  end

  defp realized_economics(episode_id) do
    totals =
      from(intent in Intent,
        join: commitment in Commitment,
        on: commitment.id == intent.fleet_commitment_id,
        join: portfolio in Portfolio,
        on: portfolio.id == commitment.fleet_commitment_portfolio_id,
        where:
          portfolio.strategy_decision_episode_id == ^episode_id and intent.status == "completed" and
            intent.type in ["buy", "sell"],
        select: {intent.type, intent.last_action_result}
      )
      |> Repo.all()
      |> Enum.reduce(%{purchase_cost: 0, sale_revenue: 0}, fn {type, result}, totals ->
        amount = get_in(result || %{}, ["transaction", "total_price"])

        if is_number(amount) do
          key = if type == "buy", do: :purchase_cost, else: :sale_revenue
          Map.update!(totals, key, &(&1 + amount))
        else
          totals
        end
      end)

    Map.put(totals, :credit_change, totals.sale_revenue - totals.purchase_cost)
  end

  defp realized_outcomes(episode_id) do
    result = realized_economics(episode_id)

    resource_yields =
      Repo.all(
        from intent in Intent,
          join: commitment in Commitment,
          on: commitment.id == intent.fleet_commitment_id,
          join: portfolio in Portfolio,
          on: portfolio.id == commitment.fleet_commitment_portfolio_id,
          where:
            portfolio.strategy_decision_episode_id == ^episode_id and
              intent.status == "completed" and intent.type == "acquire_resources",
          select: intent.last_action_result
      )
      |> Enum.map(fn evidence ->
        Map.take(evidence || %{}, ["kind", "yield", "cargo", "reconciled"])
      end)

    if resource_yields == [], do: result, else: Map.put(result, :resource_yields, resource_yields)
  end

  defp unresolved_commitment_intent?(portfolio_ids) do
    Repo.exists?(
      from(intent in Intent,
        join: commitment in Commitment,
        on: commitment.id == intent.fleet_commitment_id,
        where:
          commitment.fleet_commitment_portfolio_id in ^portfolio_ids and
            intent.caller == "commitment" and
            intent.status in ^Intent.unfinished_states()
      )
    )
  end

  defp valid_published_commitments?(commitments) do
    valid? =
      Enum.all?(commitments, fn
        %FleetCommitment{} = commitment ->
          commitment.candidate_id != "" and commitment.objective_index >= 0 and
            Enum.all?(commitment.claims, &(is_binary(&1) and &1 != "")) and
            Enum.all?(commitment.reservations, fn {_resource, amount} ->
              is_number(amount) and amount >= 0
            end) and valid_published_pledges?(commitment.pledges)

        _other ->
          false
      end)

    if valid? do
      claims = Enum.flat_map(commitments, & &1.claims)
      length(claims) == MapSet.size(MapSet.new(claims))
    else
      false
    end
  end

  defp valid_published_pledges?(pledges) when is_list(pledges) do
    Enum.all?(pledges, fn
      %{outcome: _outcome, amount: amount, backing: backing} when is_tuple(backing) ->
        is_number(amount) and amount >= 0

      _pledge ->
        false
    end)
  end

  defp valid_published_pledges?(_pledges), do: false

  defp build_portfolio(revision, candidates, availability, current_commitments) do
    claims = availability |> Map.get(:claims, []) |> Enum.map(&claim_id/1) |> MapSet.new()
    reservations = Map.get(availability, :reservations, %{})
    current = Map.new(current_commitments, &{&1.candidate_id, &1})

    {commitments, rejected, _claims, _reservations} =
      candidates
      |> Enum.sort_by(&selection_key(&1, candidates, current, reservations))
      |> Enum.reduce({[], [], MapSet.new(), %{}}, fn candidate,
                                                     {accepted, denied, used_claims,
                                                      used_reservations} ->
        candidate = assign_claims(candidate, used_claims, current)

        reasons =
          resource_rejections(
            candidate,
            claims,
            reservations,
            used_claims,
            used_reservations,
            accepted,
            availability.as_of
          )

        if reasons == [] do
          commitment = commitment(revision, candidate)

          {
            [commitment | accepted],
            denied,
            MapSet.union(used_claims, MapSet.new(candidate.claims)),
            merge_reservations(used_reservations, candidate.reservations)
          }
        else
          rejection = %{
            candidate_id: candidate.id,
            reasons: reasons,
            alternative: candidate.source,
            decisive_reason:
              rejection_explanation(candidate, accepted, current, reasons, reservations)
          }

          {accepted, [rejection | denied], used_claims, used_reservations}
        end
      end)

    %{
      revision_id: revision.id,
      source_version: Map.get(availability, :source_version, 0),
      commitments: Enum.reverse(commitments),
      rejected: Enum.reverse(rejected)
    }
  end

  defp selection_key(candidate, candidates, current, capacities) do
    switching_cost =
      current
      |> Map.values()
      |> Enum.filter(&candidate_replaces?(candidate, &1, capacities))
      |> Enum.sum_by(& &1.unwind_cost)

    retained_value = candidate.expected_value - switching_cost

    retained? = Enum.any?(Map.values(current), &same_commitment?(candidate, &1))

    {candidate.objective_index, dependency_depth(candidate, candidates), -retained_value,
     not retained?, candidate.id}
  end

  defp dependency_depth(candidate, candidates, seen \\ MapSet.new()) do
    if MapSet.member?(seen, candidate.id) do
      0
    else
      by_id = Map.new(candidates, &{&1.id, &1})

      depths =
        candidate.dependencies
        |> Enum.flat_map(fn
          %{kind: :acquisition, candidate_id: candidate_id} ->
            case Map.fetch(by_id, candidate_id) do
              {:ok, provider} ->
                [dependency_depth(provider, candidates, MapSet.put(seen, candidate.id))]

              :error ->
                []
            end

          _dependency ->
            []
        end)

      case depths do
        [] -> 0
        depths -> Enum.max(depths) + 1
      end
    end
  end

  defp normalize_candidates(candidates, availability) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, normalized} ->
      case normalize_candidate(candidate, availability) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | normalized]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      :error -> :error
    end
  end

  defp normalize_candidate(%CandidateContribution{} = contribution, availability) do
    claim_options = eligible_claims(contribution, Map.get(availability, :claims, []))
    claim_count = Map.get(contribution.required_resources, :ship_count, 0)

    expected_value =
      Map.get(
        contribution.expected_outcomes,
        :maximum_credit_change,
        Map.get(
          contribution.expected_outcomes,
          :decision_value,
          Map.get(contribution.expected_outcomes, :credit_change, 0)
        )
      )

    reservations =
      Map.drop(contribution.required_resources, [:ship_count, :cargo_capacity])

    {:ok,
     %{
       id: contribution.id,
       objective_index: contribution.objective_index,
       claims: [],
       claim_options: claim_options,
       claim_count: claim_count,
       reservations: reservations,
       pledges: [],
       pledge_amount:
         case contribution.kind do
           :contract_delivery -> contribution.contract.units_remaining
           :construction_delivery -> contribution.construction.batch_units
           _ -> expected_value
         end,
       pledge_outcome:
         case contribution.kind do
           :contract_delivery ->
             {:contract, contribution.contract.id, contribution.destination_waypoint,
              contribution.trade_symbol}

           :construction_delivery ->
             {:construction, contribution.destination_waypoint, contribution.trade_symbol}

           :construction_upstream ->
             {:strategic_objective, contribution.objective_index}

           _ ->
             {:strategic_objective, contribution.objective_index}
         end,
       dependencies: contribution.dependencies,
       validity: contribution.validity,
       expected_value: expected_value,
       unwind_cost: 0,
       strategy_revision_id: contribution.strategy_revision_id,
       source: contribution
     }}
  end

  defp normalize_candidate(%PortfolioCandidate{} = candidate, _availability) do
    {:ok,
     candidate
     |> Map.from_struct()
     |> Map.put_new(:claim_options, nil)
     |> Map.put_new(:claim_count, length(Map.get(candidate, :claims, [])))
     |> Map.put_new(:validity, %{})
     |> Map.put_new(:source, candidate)}
  end

  defp normalize_candidate(_candidate, _availability), do: :error

  defp eligible_claims(contribution, claims) do
    claims
    |> Enum.filter(&claim_supports?(&1, contribution))
    |> Enum.map(&claim_id/1)
    |> Enum.sort()
  end

  defp claim_supports?(%{roles: roles, capabilities: capabilities}, contribution)
       when is_list(roles) and is_map(capabilities) do
    roles_satisfied? =
      Enum.all?(contribution.required_roles, fn requirement ->
        requirement.role in roles
      end)

    capabilities_satisfied? =
      Enum.all?(contribution.required_capabilities, fn
        %{capability: :cargo_transport, minimum_capacity: minimum} ->
          Map.get(capabilities, :cargo_transport, 0) >= minimum

        %{capability: :market_access, waypoints: waypoints} ->
          MapSet.subset?(
            MapSet.new(waypoints),
            MapSet.new(Map.get(capabilities, :market_access, []))
          )

        %{capability: :resource_ship, value: symbol} ->
          Map.get(capabilities, :resource_ship) == symbol

        %{capability: :resource_mode, value: mode} ->
          mode in Map.get(capabilities, :resource_mode, [])

        %{capability: capability} = requirement ->
          Map.get(capabilities, capability) == Map.get(requirement, :value, true)
      end)

    roles_satisfied? and capabilities_satisfied?
  end

  defp claim_supports?(_claim, _contribution), do: false

  defp claim_id(%{resource: resource}), do: resource
  defp claim_id(resource), do: resource

  defp assign_claims(%{claim_options: nil} = candidate, _used_claims, _current), do: candidate

  defp assign_claims(candidate, used_claims, current) do
    retained_claims =
      case Map.fetch(current, candidate.id) do
        {:ok, commitment} -> commitment.claims
        :error -> []
      end

    all_current_claims =
      current
      |> Map.values()
      |> Enum.flat_map(& &1.claims)

    free_claims = Enum.reject(candidate.claim_options, &(&1 in all_current_claims))

    claims =
      (retained_claims ++ free_claims ++ candidate.claim_options)
      |> Enum.uniq()
      |> Enum.filter(&(&1 in candidate.claim_options))
      |> Enum.reject(&MapSet.member?(used_claims, &1))
      |> Enum.take(candidate.claim_count)

    pledges =
      if candidate.pledge_amount > 0 and claims != [] do
        [
          %{
            outcome: candidate.pledge_outcome,
            amount: candidate.pledge_amount,
            backing: {:claim, hd(claims)}
          }
        ]
      else
        []
      end

    %{candidate | claims: claims, pledges: pledges}
  end

  defp valid_allocation_input?(revision, candidates, availability, current_commitments) do
    objectives =
      if is_map(revision.document), do: Map.get(revision.document, "objectives", []), else: []

    objective_count = if is_list(objectives), do: length(objectives), else: 0

    valid_candidates? =
      Enum.all?(candidates, &valid_candidate?(&1, revision.id, objective_count))

    valid_current? =
      Enum.all?(current_commitments, fn
        %FleetCommitment{id: {revision_id, _candidate_id}} -> revision_id == revision.id
        _commitment -> false
      end)

    objective_count > 0 and valid_candidates? and unique_ids?(candidates, :id) and
      valid_availability?(availability) and valid_current? and
      unique_ids?(current_commitments, :candidate_id)
  end

  defp unique_ids?(items, key) do
    ids = Enum.map(items, &Map.fetch!(&1, key))
    Enum.uniq(ids) == ids
  end

  defp valid_candidate?(candidate, revision_id, objective_count) when is_map(candidate) do
    candidate[:strategy_revision_id] == revision_id and is_binary(candidate[:id]) and
      candidate.id != "" and
      is_integer(candidate[:objective_index]) and candidate.objective_index >= 0 and
      candidate.objective_index < objective_count and is_list(candidate[:claims]) and
      Enum.uniq(candidate.claims) == candidate.claims and is_map(candidate[:reservations]) and
      Enum.all?(candidate.reservations, fn {_resource, amount} ->
        is_number(amount) and amount >= 0
      end) and is_list(candidate[:pledges]) and is_list(candidate[:dependencies]) and
      is_number(candidate[:expected_value]) and is_number(candidate[:unwind_cost]) and
      candidate.unwind_cost >= 0 and is_integer(candidate[:claim_count]) and
      candidate.claim_count >= 0 and
      (is_nil(candidate[:claim_options]) or is_list(candidate[:claim_options])) and
      is_map(candidate[:validity])
  end

  defp valid_candidate?(_candidate, _revision_id, _objective_count), do: false

  defp valid_availability?(availability) do
    source_version = Map.get(availability, :source_version, 0)

    is_struct(availability[:as_of], DateTime) and is_list(availability[:claims]) and
      is_map(availability[:reservations]) and is_integer(source_version) and source_version >= 0 and
      Enum.all?(availability.reservations, fn {_resource, amount} ->
        is_number(amount) and amount >= 0
      end)
  end

  defp rejection_explanation(candidate, accepted, current, reasons, capacities) do
    retained_conflict =
      Enum.find(accepted, fn commitment ->
        Map.has_key?(current, commitment.candidate_id) and same_priority?(candidate, commitment) and
          resources_overlap?(candidate, commitment, capacities)
      end)

    replacing_conflict =
      Enum.find(accepted, fn commitment ->
        Map.has_key?(current, candidate.id) and same_priority?(candidate, commitment) and
          resources_overlap?(candidate, commitment, capacities)
      end)

    cond do
      retained_conflict &&
          candidate.expected_value <=
            retained_conflict.expected_value + retained_conflict.unwind_cost ->
        "Rejected because its expected improvement did not exceed the retained commitment's unwind cost."

      replacing_conflict ->
        "Rejected because the replacement's expected improvement exceeded this commitment's unwind cost."

      :claim_conflict in reasons ->
        "Rejected because an exclusive resource was unavailable or already claimed."

      :insufficient_reservation in reasons ->
        "Rejected because its fungible Reservations would exceed available capacity."

      :unbacked_pledge in reasons ->
        "Rejected because every Pledge must have explicit resource or acquisition backing."

      :unsatisfied_dependency in reasons ->
        "Rejected because a declared dependency is not currently satisfied."
    end
  end

  defp same_priority?(candidate, commitment),
    do: candidate.objective_index == commitment.objective_index

  defp candidate_replaces?(candidate, commitment, capacities) do
    same_priority?(candidate, commitment) and not same_commitment?(candidate, commitment) and
      (candidate.id == commitment.candidate_id or
         resources_overlap?(candidate, commitment, capacities))
  end

  defp same_commitment?(candidate, commitment) do
    claims_match? =
      if is_list(candidate.claim_options) do
        length(commitment.claims) == candidate.claim_count and
          Enum.all?(commitment.claims, &(&1 in candidate.claim_options))
      else
        candidate.claims == commitment.claims
      end

    pledges_match? =
      if is_list(candidate.claim_options), do: true, else: candidate.pledges == commitment.pledges

    candidate.id == commitment.candidate_id and claims_match? and
      candidate.reservations == commitment.reservations and
      candidate.dependencies == commitment.dependencies and pledges_match?
  end

  defp resources_overlap?(candidate, commitment, capacities) do
    claims_overlap? =
      if is_list(candidate.claim_options) do
        candidate.claim_options
        |> Enum.reject(&(&1 in commitment.claims))
        |> length() < candidate.claim_count
      else
        not MapSet.disjoint?(MapSet.new(candidate.claims), MapSet.new(commitment.claims))
      end

    reservations_overlap? =
      Enum.any?(candidate.reservations, fn {resource, amount} ->
        amount + Map.get(commitment.reservations, resource, 0) >
          Map.get(capacities, resource, 0)
      end)

    claims_overlap? or reservations_overlap?
  end

  defp resource_rejections(
         candidate,
         available_claims,
         capacities,
         used_claims,
         used_reservations,
         accepted,
         as_of
       ) do
    claim_conflict? =
      length(candidate.claims) < candidate.claim_count or
        Enum.any?(candidate.claims, fn claim ->
          not MapSet.member?(available_claims, claim) or MapSet.member?(used_claims, claim)
        end)

    insufficient_reservation? =
      Enum.any?(candidate.reservations, fn {resource, amount} ->
        amount + Map.get(used_reservations, resource, 0) > Map.get(capacities, resource, 0)
      end)

    unbacked_pledge? = not pledges_backed?(candidate)
    unsatisfied_dependency? = not dependencies_satisfied?(candidate, accepted, as_of)

    []
    |> maybe_reject(claim_conflict?, :claim_conflict)
    |> maybe_reject(insufficient_reservation?, :insufficient_reservation)
    |> maybe_reject(unbacked_pledge?, :unbacked_pledge)
    |> maybe_reject(unsatisfied_dependency?, :unsatisfied_dependency)
  end

  defp dependencies_satisfied?(candidate, accepted, as_of) do
    candidate_valid? =
      case Map.get(candidate.validity, :expires_at) do
        %DateTime{} = expires_at -> DateTime.compare(expires_at, as_of) in [:eq, :gt]
        nil -> true
        _invalid -> false
      end

    candidate_valid? and
      Enum.all?(candidate.dependencies, fn
        %{kind: :acquisition, candidate_id: candidate_id, amount: amount}
        when is_binary(candidate_id) and is_number(amount) and amount > 0 ->
          Enum.any?(accepted, &(&1.candidate_id == candidate_id))

        %{state: :satisfied} ->
          true

        %{valid_until: %DateTime{} = valid_until} ->
          DateTime.compare(valid_until, as_of) in [:eq, :gt]

        _dependency ->
          false
      end)
  end

  defp pledges_backed?(candidate) do
    individually_backed? = Enum.all?(candidate.pledges, &backed_pledge?(&1, candidate))

    reserved_pledges =
      candidate.pledges
      |> Enum.reduce(%{}, fn
        %{amount: amount, backing: {:reservation, resource}}, totals when is_number(amount) ->
          Map.update(totals, resource, amount, &(&1 + amount))

        _pledge, totals ->
          totals
      end)

    acquisition_pledges =
      candidate.pledges
      |> Enum.reduce(%{}, fn
        %{amount: amount, backing: {:dependency, dependency_id}}, totals when is_number(amount) ->
          Map.update(totals, dependency_id, amount, &(&1 + amount))

        _pledge, totals ->
          totals
      end)

    individually_backed? and
      Enum.all?(reserved_pledges, fn {resource, amount} ->
        amount <= Map.get(candidate.reservations, resource, 0)
      end) and
      Enum.all?(acquisition_pledges, fn {dependency_id, amount} ->
        Enum.any?(candidate.dependencies, fn
          %{id: ^dependency_id, kind: :acquisition, amount: available} -> amount <= available
          _dependency -> false
        end)
      end)
  end

  defp backed_pledge?(%{amount: amount, backing: {:claim, resource}}, candidate)
       when is_number(amount) and amount > 0,
       do: resource in candidate.claims

  defp backed_pledge?(%{amount: amount, backing: {:reservation, resource}}, candidate)
       when is_number(amount) and amount > 0,
       do: Map.get(candidate.reservations, resource, 0) > 0

  defp backed_pledge?(%{amount: amount, backing: {:dependency, dependency_id}}, candidate)
       when is_number(amount) and amount > 0 do
    Enum.any?(candidate.dependencies, fn
      %{id: ^dependency_id, kind: :acquisition} -> true
      _dependency -> false
    end)
  end

  defp backed_pledge?(_pledge, _candidate), do: false

  defp maybe_reject(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reject(reasons, false, _reason), do: reasons

  defp merge_reservations(used, requested) do
    Map.merge(used, requested, fn _resource, left, right -> left + right end)
  end

  defp commitment(revision, candidate) do
    %FleetCommitment{
      id: {revision.id, candidate.id},
      candidate_id: candidate.id,
      objective_index: candidate.objective_index,
      claims: candidate.claims,
      reservations: candidate.reservations,
      pledges: candidate.pledges,
      dependencies: candidate.dependencies,
      expected_value: candidate.expected_value,
      unwind_cost: candidate.unwind_cost,
      decisive_reason:
        "Selected as the highest-ranked feasible contribution at its Strategic Priority."
    }
  end

  def rank_plans(%Scope{} = scope, plans) do
    case FleetStrategy.get(scope).active_revision do
      %Revision{} = revision -> {:ok, rank(revision, plans)}
      nil -> {:error, :strategy_not_active}
    end
  end

  @doc "Selects a fresh post-stop plan and only then restores mutation admission."
  def complete_emergency_stop_resume(%Scope{} = scope, plans, expected_emergency_stop_version) do
    with %{emergency_resume_prepared_at: %DateTime{} = prepared_at} <- FleetStrategy.get(scope),
         {:ok, %{admissible: [selected | _]} = ranking} <- rank_plans(scope, plans),
         true <- fresh_plan?(selected, prepared_at),
         {:ok, projection} <-
           FleetStrategy.complete_emergency_stop_resume(scope, expected_emergency_stop_version) do
      {:ok, %{ranking: ranking, strategy: projection}}
    else
      {:ok, %{admissible: []}} -> {:error, :fresh_plan_required}
      false -> {:error, :fresh_plan_required}
      %{emergency_resume_prepared_at: nil} -> {:error, :resume_not_prepared}
      error -> error
    end
  end

  defp fresh_plan?(%{safety: %{observed_at: %DateTime{} = observed_at}}, prepared_at),
    do: DateTime.compare(observed_at, prepared_at) in [:eq, :gt]

  defp fresh_plan?(_plan, _prepared_at), do: false

  defp rank(%Revision{document: %{"objectives" => objectives}} = revision, plans)
       when is_list(objectives) and is_list(plans) do
    {admissible, rejected} =
      Enum.reduce(plans, {[], []}, fn plan, {admitted, denied} ->
        reasons = plan_rejections(revision, plan)

        if reasons == [] do
          {[plan | admitted], denied}
        else
          {admitted, [%{plan: plan, reasons: reasons} | denied]}
        end
      end)

    ordered = Enum.sort(admissible, &plan_before?(&1, &2, length(objectives)))
    %{revision_id: revision.id, admissible: ordered, rejected: Enum.reverse(rejected)}
  end

  defp plan_rejections(%Revision{document: document} = revision, plan) do
    if is_map(plan) do
      objectives = Map.fetch!(document, "objectives")
      preferences = Map.fetch!(document, "preferences")

      cond do
        not ObjectiveEvaluation.matching_objectives?(
          revision.id,
          objectives,
          Map.get(plan, :objective_evaluations)
        ) ->
          ["Every Strategic Objective requires one complete matching evaluation."]

        not PreferenceEvaluation.matching?(
          revision.id,
          preferences,
          Map.get(plan, :preference_evaluations)
        ) ->
          ["Every Preference requires one complete revision-bound evaluation."]

        true ->
          case StandingAuthority.authorize(revision, Map.get(plan, :safety, %{})) do
            {:ok, _authorization} -> []
            {:error, reasons} -> reasons
          end
      end
    else
      ["A plan must provide complete revision-bound evaluations and safety evidence."]
    end
  end

  defp plan_before?(left, right, objective_count) do
    case compare_keys(plan_keys(left, objective_count), plan_keys(right, objective_count)) do
      :equal -> preference_scores(left) >= preference_scores(right)
      :left -> true
      :right -> false
    end
  end

  defp plan_keys(plan, objective_count) do
    plan
    |> Map.fetch!(:objective_evaluations)
    |> Enum.take(objective_count)
    |> Enum.map(&ObjectiveEvaluation.comparison_key/1)
  end

  defp preference_scores(plan) do
    plan
    |> Map.fetch!(:preference_evaluations)
    |> Enum.map(&Map.fetch!(&1, :score))
  end

  defp compare_keys([], []), do: :equal
  defp compare_keys([same | left], [same | right]), do: compare_keys(left, right)
  defp compare_keys([left | _], [right | _]) when left > right, do: :left
  defp compare_keys([_left | _], [_right | _]), do: :right
end
