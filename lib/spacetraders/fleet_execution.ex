defmodule SpaceTraders.FleetExecution do
  @moduledoc """
  Runtime activation of Fleet Allocation decisions into governed Ship
  execution.

  `reconcile_market_domain/5` is the single runtime entry for the Market
  pilot domain (Market trade, Marketplace coverage and compatible retained
  Commitments). It gathers governed availability, planning and occupancy and
  admits dispatchable Candidates; Fleet Allocation
  (`SpaceTraders.FleetAllocation.MarketDomain`) selects one versioned
  portfolio and publishes it atomically with its Strategy Decision Episode.
  Only then does this module dispatch the root Intents: buy, travel, sell
  round trips and intelligence acquisitions through governed operations.
  """

  import Ecto.Query

  require Logger

  alias SpaceTraders.{Agent, Clock}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.Fleet.{Intent, Intents, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetCapacity

  @coverage_kinds [:market_coverage, :intelligence_acquisition]
  alias SpaceTraders.FleetAllocation.{Commitment, MarketDomain, Portfolio, StructuralStall}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetShadow
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.FleetStrategy.StandingAuthority
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo
  alias SpaceTraders.ShipReservation

  @doc "Returns the credit floor for a Revision, or `{:error, :no_credit_floor}`."
  defdelegate credit_floor(revision), to: StandingAuthority

  @doc """
  Returns governed availability for one Agent from authoritative evidence.

  Owned Ships become Claims carrying the Market reach of their System's
  governed waypoint evidence, and observed credits become Reservations. Roles
  and non-Market capabilities mirror execution availability. Returns
  `{:error, :availability_unknown}` when Ships, credits, or the System cannot
  be established, so a reviewer can state the limitation instead of assuming
  zero capacity. The caller is responsible for scoping the Agent.
  """
  def governed_availability(%AgentRecord{} = agent) do
    with {:ok, markets} <- governed_market_access(agent),
         {:ok, ships} <- Fleet.list_ships(agent),
         credits when is_integer(credits) <- agent_credits(agent) do
      {:ok,
       %{
         as_of: Clock.utc_now(),
         claims: market_claims(agent, ships, markets),
         reservations: %{credits: credits}
       }}
    else
      _ -> {:error, :availability_unknown}
    end
  end

  @doc "Returns true when Credit Reservations cover worst-case exposure within the floor."
  defdelegate reservation_covers_exposure?(commitment, revision, availability),
    to: MarketDomain

  @doc """
  The one Fleet Allocation decision for the Market pilot domain: Market
  trade, Marketplace coverage (and the other intelligence the Strategy wants)
  and compatible retained Fleet Commitments.

  Every evidence boundary of the domain (Market evidence, Waypoint
  intelligence, due Observation Demands, withdrawn purchases) calls this one
  entry, so callback order cannot preempt the comparison. At one decision
  time it plans trade and intelligence Candidate Contributions from the same
  shared Market input, retains busy or unrelated Commitments (an unfinished
  Intent or a completed buy inside its leg handoff fences only its own
  Ship), releases finished pilot work, and asks Fleet Allocation for one
  versioned portfolio. The selected Commitments publish together beside the
  retained work, then their root Intents dispatch.

  Every outcome is explicit: a published portfolio, retained work, an API
  capacity deferral, unknown availability, a Neutral Wait minted only by
  Fleet Allocation, or a rejected publication recorded as a durable Strategy
  Decision Episode with its reason. Each emits bounded G2 telemetry.
  """
  def reconcile_market_domain(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        system_symbol,
        capacity
      )
      when is_binary(system_symbol) do
    generation = current_generation(agent)
    reconciled = reconcile_revision_change(scope, revision, generation)
    current = FleetAllocation.current_portfolio(scope, agent)

    {result, counts} =
      cond do
        match?({:error, _reason}, reconciled) ->
          {reconciled, %{}}

        FleetCapacity.proceed?(capacity) ->
          allocate_market_domain(scope, agent, revision, system_symbol, current, generation)

        true ->
          {capacity_deferral(agent, capacity, current), %{}}
      end

    portfolio = FleetAllocation.current_portfolio(scope, agent)

    stall =
      StructuralStall.observe(agent, revision, portfolio, %{result: result, counts: counts})

    observe_market_domain(agent, revision, portfolio, stall, result, counts)
  end

  # The Governor's explicit deferral is not authoritative evidence of an empty
  # portfolio, so it never mints or disturbs a Neutral Wait.
  # The result carries the Governor's advisory retry time and the Agent's
  # still-open Observation Demands, whose durable due times a deferral never
  # moves, so the missing evidence is explicitly deferred, not infeasible.
  defp capacity_deferral(agent, capacity, current) do
    deferral = %{
      reason: :capacity_deferred,
      retry_at: Map.get(capacity || %{}, :retry_at),
      pending_demands: Evidence.list_open_demands(agent)
    }

    if current,
      do: {:ok, Map.merge(deferral, %{action: :retained_for_capacity, portfolio: current})},
      else: {:ok, Map.put(deferral, :action, :deferred_for_capacity)}
  end

  defp allocate_market_domain(scope, agent, revision, system, current, generation) do
    settling = if generation, do: FleetAllocation.settling_commitments(generation.id), else: []
    resume_awaiting_sells(agent, current, settling)
    occupancy = domain_occupancy(agent, current, settling)

    if no_free_ship?(agent, occupancy.occupied) do
      # Occupancy is local state: with every known Ship fenced there is
      # nothing to allocate, so no game request is spent finding that out.
      {{:ok, %{action: :retained, portfolio: current, reason: :all_ships_occupied}}, %{}}
    else
      with {:ok, availability} <- allocation_availability(agent),
           free = free_claims(availability, occupancy.occupied),
           {:ok, planned} <-
             FleetIntelligence.plan_contributions(
               agent,
               revision,
               system,
               MapSet.to_list(occupancy.occupied)
             ),
           {:ok, trade} <-
             FleetShadow.plan_market(planned.market, revision, %{availability | claims: free}) do
        planning = trade ++ List.wrap(planned.intelligence)

        demands =
          if planned.intelligence, do: planned.intelligence.observation_demands, else: []

        held = %{occupancy: occupancy, availability: availability, free: free}
        decide(scope, agent, revision, current, held, planning, demands)
      else
        {:error, reason} -> {{:error, reason}, %{}}
      end
    end
  end

  # `held` is the boundary's one read of what the Fleet already holds: the
  # occupancy of current work, governed availability and the free Claims.
  defp decide(scope, agent, revision, current, held, planning, demands) do
    %{occupancy: occupancy, availability: availability, free: free} = held
    candidates = Enum.flat_map(planning, & &1.candidate_contributions)
    planned_ids = MapSet.new(candidates, & &1.id)

    # Finished or idle pilot work is re-proposed by planning or released; a
    # re-proposed Commitment keeps its identity instead of churning.
    {kept, released} =
      Enum.split_with(occupancy.releasable, fn commitment ->
        MapSet.member?(planned_ids, commitment.candidate_id) and
          not MapSet.member?(occupancy.completed_intelligence, commitment.id)
      end)

    retained = occupancy.retained ++ kept
    kept_ships = MapSet.new(Enum.flat_map(kept, & &1.claims))
    claims = Enum.reject(free, &MapSet.member?(kept_ships, &1.resource))

    # Retained work is current-Revision work: a settling old-Revision scout
    # holds its own Ship, never the single-scout slot of the active Revision.
    {candidates, dispatch, unavailable} =
      admissible_candidates(agent, candidates, retained, demands)

    counts = %{
      trade_candidates: Enum.count(candidates, &(&1.kind == :market_trade)),
      coverage_candidates: Enum.count(candidates, &(&1.kind in @coverage_kinds)),
      claimable_ships: length(claims)
    }

    case MarketDomain.select(revision, candidates, availability, claims, unavailable) do
      {:ok, selection} ->
        plan = %{
          retained: retained,
          released: released,
          selection: selection,
          decision: domain_decision(planning, candidates, selection.commitments),
          dispatch: dispatch,
          planning: planning
        }

        result =
          case MarketDomain.publish(scope, agent, revision, current, plan) do
            {:published, portfolio} -> published(portfolio, agent, plan)
            other -> other
          end

        {result, Map.put(counts, :selected, length(selection.commitments))}

      {:error, reason} ->
        {{:error, reason}, counts}
    end
  end

  # A Candidate a retained Commitment already pursues is never duplicated; one
  # retained Coverage Commitment admits no second coverage Candidate (the
  # single-scout policy); an intelligence Candidate without its current open
  # Observation Demand cannot dispatch and is rejected with that reason.
  defp admissible_candidates(agent, candidates, retained, demands) do
    retained_ids = MapSet.new(retained, & &1.candidate_id)
    coverage_retained? = Enum.any?(retained, &coverage_commitment?/1)

    {admitted, dispatch, unavailable} =
      candidates
      |> Enum.reject(fn candidate ->
        MapSet.member?(retained_ids, candidate.id) or
          (coverage_retained? and candidate.kind == :market_coverage)
      end)
      |> Enum.reduce({[], %{}, []}, fn candidate, {admitted, dispatch, unavailable} ->
        case dispatch_spec(agent, candidate, demands) do
          nil ->
            rejection = %{
              candidate_id: candidate.id,
              reasons: [:observation_demand_unavailable],
              decisive_reason:
                "Rejected because its current open Observation Demand is unavailable."
            }

            {admitted, dispatch, [rejection | unavailable]}

          spec ->
            {[candidate | admitted], Map.put(dispatch, candidate.id, spec), unavailable}
        end
      end)

    {Enum.reverse(admitted), dispatch, Enum.reverse(unavailable)}
  end

  defp dispatch_spec(_agent, %{kind: :market_trade} = candidate, _demands),
    do: {:trade, candidate}

  defp dispatch_spec(agent, %{kind: kind} = candidate, demands) when kind in @coverage_kinds do
    case selected_observation_subject(agent, candidate, demands) do
      nil -> nil
      {waypoint, demand} -> {:intelligence, waypoint, demand}
    end
  end

  defp dispatch_spec(_agent, _candidate, _demands), do: nil

  defp coverage_commitment?(commitment) do
    Enum.any?(commitment.dependencies, fn dependency ->
      match?(%{"subject" => "market:" <> _}, dependency) and
        not Map.has_key?(dependency, "evidence_id")
    end)
  end

  defp domain_decision(planning, candidates, selected) do
    selected_ids = MapSet.new(selected, & &1.candidate_id)

    trade_selected? =
      Enum.any?(candidates, &(&1.kind == :market_trade and MapSet.member?(selected_ids, &1.id)))

    %{
      evidence_references: domain_evidence_references(planning),
      expectations: %{
        expected_value: Enum.sum_by(selected, & &1.expected_value),
        commitment_count: length(selected)
      },
      calibration_version:
        if(trade_selected?,
          do: FleetAllocation.market_calibration_version(),
          else: "intelligence-v1"
        )
    }
  end

  defp domain_evidence_references(planning) do
    planning
    |> Enum.flat_map(&Map.get(&1, :candidate_contributions, []))
    |> Enum.flat_map(&Map.get(&1, :dependencies, []))
    |> Enum.flat_map(fn
      %{evidence_id: id} when is_binary(id) ->
        [%{"kind" => "market", "id" => id}]

      %{subject: subject} when is_binary(subject) ->
        [%{"kind" => "observation", "subject" => subject, "operation_id" => "get-market"}]

      _dependency ->
        []
    end)
    |> Enum.uniq()
  end

  # The published portfolio's newly selected Commitments dispatch their root
  # Intents; retained Commitments keep the work they already hold.
  defp published(portfolio, agent, plan) do
    commitments =
      for proposal <- plan.selection.commitments,
          persisted <- portfolio.commitments,
          persisted.candidate_id == proposal.candidate_id,
          do: persisted

    dispatched =
      Map.new(commitments, fn commitment ->
        spec = Map.fetch!(plan.dispatch, commitment.candidate_id)
        {commitment.candidate_id, dispatch(agent, portfolio, commitment, spec)}
      end)

    {:ok,
     %{
       action: if(commitments == [], do: :released, else: :published),
       portfolio: portfolio,
       commitments: commitments,
       dispatched: dispatched,
       selection: plan.selection,
       planning: plan.planning
     }}
  end

  # Dispatch failures stay in the result (and the Reconciler's log): the
  # published Commitment and its Episode are already the durable decision.
  defp dispatch(agent, portfolio, commitment, {:trade, candidate}),
    do: activate_round_trip(agent, commitment, portfolio, candidate)

  defp dispatch(agent, portfolio, commitment, {:intelligence, waypoint, demand}) do
    with {:ok, ship_symbol} <- claimed_ship_symbol(commitment),
         [type, _system, _waypoint] <- String.split(demand.subject, ":") do
      Intents.request_commitment_intelligence(agent, commitment, portfolio, ship_symbol, %{
        subject_type: String.to_existing_atom(type),
        waypoint: waypoint,
        required_facts: demand.required_facts,
        freshness_seconds: demand.freshness_seconds
      })
    else
      _ -> {:error, :invalid_observation_subject}
    end
  end

  # A Portfolio selected under an older Revision is not current authority
  # (#684, #686). Each Market boundary, before occupancy is read: settled
  # old-Revision Intents retire (nothing in flight, no unresolved Mutation
  # Attempt, no pending arrival); the stale Portfolio retires, its unsettled
  # Commitments kept as `:settling` narrow fences on their own Ships; and
  # settling Commitments whose effects have settled release. Retirement
  # never replays or rewrites an effect; the old Episode keeps it. Every step
  # is local state and idempotent, so a lost wake only delays it.
  defp reconcile_revision_change(_scope, _revision, nil), do: :ok

  defp reconcile_revision_change(scope, %Revision{id: active}, %Generation{} = generation) do
    for intent <- FleetAllocation.revision_change_intents(generation.id, active),
        {:ok, retired} <- [Intents.supersede_for_revision_change(intent, active)] do
      Logger.info("Fleet Allocation retired a stale-Revision Intent",
        agent_id: generation.agent_id,
        fleet_generation_id: generation.id,
        intent_id: retired.id,
        commitment_id: retired.fleet_commitment_id,
        active_revision_id: active
      )
    end

    with :ok <- retire_stale_portfolio(scope, active, generation) do
      release_settled(generation, active)
    end
  end

  defp retire_stale_portfolio(scope, active, generation) do
    case FleetAllocation.retire_stale_portfolio(scope, generation.id, active) do
      {:ok, %{portfolio: portfolio} = retired} ->
        Logger.info("Fleet Allocation retired a stale-Revision Portfolio",
          agent_id: generation.agent_id,
          fleet_generation_id: generation.id,
          portfolio_id: portfolio.id,
          portfolio_revision_id: portfolio.fleet_strategy_revision_id,
          active_revision_id: active,
          decision_episode_id: portfolio.strategy_decision_episode_id,
          commitment_ids: retired.released,
          settling: Enum.map(retired.settling, &{&1.commitment_id, &1.reason})
        )

        :ok

      {:error, :no_stale_portfolio} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_settled(generation, active) do
    case FleetAllocation.release_settled_commitments(generation.id) do
      {:ok, released} ->
        Enum.each(released, &log_settled(&1, generation, active))

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A disposition that ended with Cargo still aboard is reported, not hidden:
  # the fence lasts only while a sale is under way.
  defp log_settled(released, generation, active) do
    {level, message} =
      if released.undisposed_units > 0,
        do: {:warning, "Fleet Allocation released a settled Commitment with inherited Cargo aboard"},
        else: {:info, "Fleet Allocation released a settled Commitment"}

    Logger.log(level, message,
      agent_id: generation.agent_id,
      fleet_generation_id: generation.id,
      commitment_id: released.commitment_id,
      portfolio_id: released.portfolio_id,
      active_revision_id: active,
      undisposed_units: released.undisposed_units
    )
  end

  # Current Commitments split into retained work (busy: an unresolved Intent
  # or leg handoff; or outside the pilot domain) and releasable pilot work.
  # `occupied` holds the Ships retained work or any unfinished Intent fences.
  defp domain_occupancy(agent, current, settling) do
    commitments = if current, do: current.commitments, else: []
    ids = Enum.map(commitments, & &1.id)

    unresolved =
      if current, do: FleetAllocation.unresolved_commitment_ids(current.id), else: MapSet.new()

    intelligence =
      Repo.all(
        from intent in Intent,
          where: intent.fleet_commitment_id in ^ids and intent.type == "acquire_intelligence",
          select: {intent.fleet_commitment_id, intent.status}
      )

    completed_intelligence = for {id, "completed"} <- intelligence, into: MapSet.new(), do: id
    intelligence_ids = MapSet.new(intelligence, &elem(&1, 0))

    {releasable, retained} =
      Enum.split_with(commitments, fn commitment ->
        not MapSet.member?(unresolved, commitment.id) and
          (MapSet.member?(intelligence_ids, commitment.id) or market_commitment?(commitment))
      end)

    intent_ship_ids = agent |> Intents.current() |> Enum.map(& &1.ship_id)

    intent_ships =
      Repo.all(from ship in Ship, where: ship.id in ^intent_ship_ids, select: ship.symbol)

    %{
      retained: retained,
      releasable: releasable,
      completed_intelligence: completed_intelligence,
      occupied:
        MapSet.new(
          Enum.flat_map(retained ++ settling, & &1.claims) ++ intent_ships
        )
    }
  end

  defp market_commitment?(commitment),
    do: Enum.any?(commitment.dependencies, &match?(%{"subject" => "market:" <> _}, &1))

  # A completed buy whose selected sell was never requested (the sender died
  # between the two legs, or the sell leg was refused) continues here at the
  # next Market boundary or boot. Only `completed` buys inside the bounded
  # handoff qualify and only when no later Intent exists, so an unconfirmed
  # purchase is never replayed and a leg is never requested twice. The sell
  # itself still passes the Intent engine's quote and authority checks.
  # A settling Commitment's inherited Cargo continues the same way: its sale
  # is the disposition the active Revision authorizes.
  defp resume_awaiting_sells(agent, current, settling) do
    if current do
      for buy <- FleetAllocation.awaiting_sell_buys(current.id),
          %Commitment{} = commitment <- [Repo.get(Commitment, buy.fleet_commitment_id)] do
        continue_after_intent(agent, commitment, current, buy)
      end
    end

    for commitment <- settling,
        portfolio = commitment.fleet_commitment_portfolio,
        buy <- FleetAllocation.awaiting_sell_buys(portfolio.id),
        buy.fleet_commitment_id == commitment.id do
      continue_after_intent(agent, commitment, portfolio, buy)
    end

    :ok
  end

  defp no_free_ship?(agent, occupied) do
    symbols = Repo.all(from ship in Ship, where: ship.agent_id == ^agent.id, select: ship.symbol)
    symbols != [] and Enum.all?(symbols, &MapSet.member?(occupied, &1))
  end

  defp free_claims(availability, occupied),
    do: Enum.reject(availability.claims, &MapSet.member?(occupied, &1.resource))

  # G2: one bounded record per domain decision, unchanged repeats included.
  # Ids stay log metadata only, never metric labels.
  defp observe_market_domain(agent, revision, portfolio, stall, result, counts) do
    {kind, reason} = domain_outcome(result)

    :telemetry.execute(
      [:spacetraders, :fleet_allocation, :market_domain],
      Map.merge(
        %{count: 1, trade_candidates: 0, coverage_candidates: 0, claimable_ships: 0, selected: 0},
        counts
      ),
      %{result: kind, decisive_reason: reason}
    )

    level = if kind in [:error, :publication_rejected], do: :warning, else: :info

    level = if match?({:stalled, _}, stall), do: :warning, else: level

    Logger.log(
      level,
      "Fleet Allocation Market domain decision",
      [
        result: kind,
        decisive_reason: reason,
        agent_id: agent.id,
        fleet_generation_id: portfolio && portfolio.fleet_generation_id,
        active_revision_id: revision.id,
        portfolio_revision_id: portfolio && portfolio.fleet_strategy_revision_id,
        portfolio_id: portfolio && portfolio.id,
        commitment_ids: portfolio && Enum.map(portfolio.commitments, & &1.id),
        decision_episode_id: decision_episode_id(result, portfolio)
      ] ++ stall_metadata(stall)
    )

    result
  end

  defp decision_episode_id({:ok, %{episode: %{id: id}}}, _portfolio), do: id
  defp decision_episode_id({:ok, %{neutral_wait: %{id: id}}}, _portfolio), do: id
  defp decision_episode_id(_result, %Portfolio{strategy_decision_episode_id: id}), do: id
  defp decision_episode_id(_result, _portfolio), do: nil

  defp stall_metadata({:stalled, episode}),
    do: [stall_reason: episode.stall_reason, stall_episode_id: episode.id]

  defp stall_metadata(:healthy), do: []

  defp domain_outcome({:error, reason}), do: {:error, FleetAllocation.bounded_reason(reason)}

  defp domain_outcome({:ok, %{action: :publication_rejected, reason: reason}}),
    do: {:publication_rejected, FleetAllocation.bounded_reason(reason)}

  defp domain_outcome({:ok, %{action: :published, selection: selection}}),
    do: {:published, selected_reason(selection.commitments)}

  defp domain_outcome({:ok, %{action: action} = result}),
    do: {action, FleetAllocation.bounded_reason(Map.get(result, :reason, action))}

  defp selected_reason(selected) do
    kinds =
      selected
      |> Enum.map(&if(trade_proposal?(&1), do: :trade, else: :coverage))
      |> Enum.uniq()
      |> Enum.sort()

    case kinds do
      [:coverage, :trade] -> :trade_and_coverage_selected
      [:trade] -> :trade_selected
      _ -> :coverage_selected
    end
  end

  defp trade_proposal?(%{dependencies: dependencies}),
    do: Enum.any?(dependencies, &match?(%{evidence_id: id} when is_binary(id), &1))

  # Execution revalidates one next observation at a time against the current
  # strategy-provenanced Demands. Settled subjects are skipped in the planner's
  # fixed order; an unexplained missing Demand stops execution rather than
  # acquiring unsupported evidence.
  defp selected_observation_subject(
         agent,
         %{
           kind: :market_coverage,
           strategy_revision_id: revision_id,
           coverage: %{subjects: subjects}
         },
         _demands
       ) do
    open_demands =
      agent
      |> Evidence.list_open_demands()
      |> Enum.filter(fn demand ->
        demand.owner == "fleet_planning" and demand.strategy_revision_id == revision_id and
          demand.subject in subjects
      end)
      |> Map.new(&{&1.subject, &1})

    settled = Evidence.settled_demand_subjects(agent, revision_id, subjects)

    subjects
    |> Enum.reduce_while(nil, fn subject, _selection ->
      case Map.fetch(open_demands, subject) do
        {:ok, demand} ->
          {:halt, {waypoint_from_subject(subject), demand}}

        :error ->
          if MapSet.member?(settled, subject), do: {:cont, nil}, else: {:halt, nil}
      end
    end)
  end

  defp selected_observation_subject(_agent, candidate, demands) do
    case Enum.find(demands, &String.ends_with?(&1.subject, ":#{candidate.destination_waypoint}")) do
      nil -> nil
      demand -> {candidate.destination_waypoint, demand}
    end
  end

  defp waypoint_from_subject(subject), do: subject |> String.split(":") |> List.last()

  @doc """
  Dispatches the authoritative buy leg of the round trip on the claimed Ship.

  The buy intent navigates to the source Market, docks, and buys the admissible
  quantity through governed operations. ShipServer arrivals re-enter the same
  intent and the sell leg continues through `continue_after_intent/4`.
  """
  def activate_round_trip(agent, commitment, %Portfolio{} = portfolio, candidate) do
    with {:ok, ship_symbol} <- claimed_ship_symbol(commitment),
         {:ok, intent} <-
           Intents.request_commitment_round_trip(
             agent,
             commitment,
             portfolio,
             ship_symbol,
             candidate
           ) do
      if intent.type == "buy" and intent.status == "completed" do
        continue_after_intent(agent, commitment, portfolio, intent)
      else
        {:ok, intent}
      end
    end
  end

  @doc "Continues a commitment-owned round trip after one leg completes."
  def continue_after_intent(agent, commitment, %Portfolio{} = portfolio, intent) do
    case intent do
      %{
        type: "acquire_resources",
        status: "completed",
        parameters: %{
          "transfer" => %{
            "source_ship" => source,
            "target_ship" => target,
            "units" => units,
            "delivery" => delivery
          },
          "produce" => symbol
        },
        last_action_result: %{"cargo" => %{"inventory" => inventory}}
      }
      when is_integer(units) and units > 0 and is_list(inventory) ->
        if Enum.any?(inventory, &(&1["symbol"] == symbol and &1["units"] >= units)) do
          continue_after_production(
            agent,
            commitment,
            portfolio,
            intent,
            source,
            target,
            symbol,
            units,
            delivery
          )
        else
          {:error, :production_cargo_unconfirmed}
        end

      %{
        type: "transfer",
        status: "completed",
        parameters: %{
          "target_ship" => target_ship,
          "transfer_delivery" => %{"type" => type} = delivery
        },
        last_action_result: %{"units" => units}
      }
      when is_integer(units) and units > 0 ->
        with {:ok, claim} <- FleetAllocation.current_ship_claim(agent, target_ship),
             true <- claim.portfolio_id == portfolio.id,
             %Commitment{} = hauler <- Repo.get(Commitment, claim.commitment_id),
             true <-
               Enum.any?(hauler.dependencies, &(&1["candidate_id"] == commitment.candidate_id)) do
          dispatch_transferred_delivery(
            agent,
            portfolio,
            hauler,
            target_ship,
            intent,
            type,
            delivery,
            units
          )
        else
          _ -> {:error, :transfer_dependency_unavailable}
        end

      %{
        type: "buy",
        status: "completed",
        last_action_result: %{"units" => 0},
        parameters: %{"market_trade" => %{"construction" => _}}
      } ->
        reconcile_construction(agent, portfolio)

      %{
        type: "buy",
        status: "completed",
        last_action_result: %{"units" => 0},
        parameters: %{"market_trade" => %{"construction_upstream" => _}}
      } ->
        {:error, :upstream_purchase_unavailable}

      %{
        type: "sell",
        status: "completed",
        parameters: %{"market_trade" => %{"construction_upstream" => _}}
      } ->
        with {:ok, _episode} <-
               FleetConstruction.reconcile_upstream_sale(agent, portfolio, intent) do
          reconcile_construction(agent, portfolio)
        end

      %{
        type: "buy",
        status: "completed",
        last_action_result: %{"units" => units},
        parameters: %{"market_trade" => %{"construction" => project} = candidate}
      }
      when is_integer(units) and units > 0 ->
        with {:ok, ship_symbol} <- claimed_ship_symbol(commitment) do
          case Intents.request_commitment_construction_delivery(
                 agent,
                 commitment,
                 portfolio,
                 ship_symbol,
                 %{
                   system: project["system"],
                   waypoint: project["waypoint"],
                   trade_symbol: candidate["trade_symbol"],
                   units: units
                 }
               ) do
            {:ok, %{status: "completed"} = delivered} ->
              continue_after_intent(agent, commitment, portfolio, delivered)

            other ->
              other
          end
        end

      %{
        type: "deliver",
        status: "completed",
        parameters: %{"recipient" => %{"type" => "construction"}}
      } ->
        reconcile_construction(agent, portfolio)

      %{
        type: "buy",
        status: "completed",
        last_action_result: %{"units" => 0},
        parameters: %{"market_trade" => %{"contract_id" => _}}
      } ->
        with %Revision{} = revision <- Repo.get(Revision, portfolio.fleet_strategy_revision_id),
             %{} = operator <- Repo.get(SpaceTraders.Agent.Operator, agent.operator_id) do
          FleetContracts.reconcile(Scope.for_operator(operator), agent, revision)
        end

      %{
        type: "buy",
        status: "completed",
        last_action_result: %{"units" => units},
        parameters: %{"market_trade" => %{"contract_id" => contract_id} = candidate}
      }
      when is_integer(units) and units > 0 ->
        with {:ok, ship_symbol} <- claimed_ship_symbol(commitment) do
          case Intents.request_commitment_contract_delivery(
                 agent,
                 commitment,
                 portfolio,
                 ship_symbol,
                 %{
                   contract_id: contract_id,
                   destination_waypoint: candidate["destination_waypoint"],
                   trade_symbol: candidate["trade_symbol"],
                   units: units
                 }
               ) do
            {:ok, %{status: "completed"} = delivered} ->
              continue_after_intent(agent, commitment, portfolio, delivered)

            other ->
              other
          end
        end

      %{type: "buy", status: "completed", parameters: %{"market_trade" => %{"contract_id" => _}}} ->
        {:error, :invalid_purchase_evidence}

      %{type: "buy", status: "completed", parameters: %{"market_trade" => %{"construction" => _}}} ->
        {:error, :invalid_purchase_evidence}

      %{
        type: "deliver",
        status: "completed",
        parameters: %{"recipient" => %{"type" => "contract", "contract_id" => _contract_id}}
      } ->
        with %Revision{} = revision <- Repo.get(Revision, portfolio.fleet_strategy_revision_id),
             %{} = operator <- Repo.get(SpaceTraders.Agent.Operator, agent.operator_id) do
          FleetContracts.reconcile(Scope.for_operator(operator), agent, revision)
        end

      %{type: "buy", status: "completed", parameters: %{"market_trade" => candidate}} ->
        with {:ok, ship_symbol} <- claimed_ship_symbol(commitment) do
          case Intents.request_commitment_round_trip_sell(
                 agent,
                 commitment,
                 portfolio,
                 ship_symbol,
                 candidate,
                 nil
               ) do
            {:ok, %{status: "completed"} = sell} = result ->
              if Map.has_key?(candidate, "construction_upstream") do
                continue_after_intent(agent, commitment, portfolio, sell)
              else
                FleetAllocation.record_trade_outcome(portfolio)
                result
              end

            result ->
              result
          end
        end

      # The sell leg finished on a later Ship arrival, not inline with the buy.
      %{type: "sell", status: "completed", parameters: %{"market_trade" => _}} ->
        _ = FleetAllocation.record_trade_outcome(portfolio)
        :ok

      _ ->
        :ok
    end
  end

  defp continue_after_production(
         agent,
         producer,
         portfolio,
         production,
         source,
         target,
         symbol,
         units,
         delivery
       ) do
    existing =
      Repo.one(
        from intent in SpaceTraders.Fleet.Intent,
          where:
            intent.fleet_commitment_id == ^producer.id and intent.type == "transfer" and
              intent.inserted_at >= ^production.inserted_at,
          order_by: [desc: intent.id],
          limit: 1
      )

    if existing do
      if existing.status == "completed",
        do: continue_after_intent(agent, producer, portfolio, existing),
        else: {:ok, existing}
    else
      with {:ok, claim} <- FleetAllocation.current_ship_claim(agent, target),
           true <- claim.portfolio_id == portfolio.id,
           %Commitment{} = hauler <- Repo.get(Commitment, claim.commitment_id),
           true <- Enum.any?(hauler.dependencies, &(&1["candidate_id"] == producer.candidate_id)),
           {:ok, transfer} <-
             Intents.request_commitment_transfer(agent, producer, hauler, portfolio, %{
               source_ship: source,
               target_ship: target,
               trade_symbol: symbol,
               units: units,
               delivery: delivery
             }) do
        if transfer.status == "completed",
          do: continue_after_intent(agent, producer, portfolio, transfer),
          else: {:ok, transfer}
      else
        _ -> {:error, :transfer_dependency_unavailable}
      end
    end
  end

  defp dispatch_transferred_delivery(
         agent,
         portfolio,
         hauler,
         ship_symbol,
         transfer,
         type,
         delivery,
         units
       ) do
    ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: agent.id, symbol: ship_symbol)

    existing =
      Repo.one(
        from intent in SpaceTraders.Fleet.Intent,
          where:
            intent.ship_id == ^ship.id and intent.fleet_commitment_id == ^hauler.id and
              intent.type == "deliver" and intent.inserted_at >= ^transfer.inserted_at,
          order_by: [desc: intent.id],
          limit: 1
      )

    if existing do
      {:ok, existing}
    else
      result =
        case type do
          "construction" ->
            Intents.request_commitment_construction_delivery(
              agent,
              hauler,
              portfolio,
              ship_symbol,
              %{
                system: delivery["system"],
                waypoint: delivery["waypoint"],
                trade_symbol: delivery["trade_symbol"],
                units: units
              }
            )

          "contract" ->
            Intents.request_commitment_contract_delivery(agent, hauler, portfolio, ship_symbol, %{
              contract_id: delivery["contract_id"],
              destination_waypoint: delivery["waypoint"],
              trade_symbol: delivery["trade_symbol"],
              units: units
            })
        end

      case result do
        {:ok, %{status: "completed"} = delivered} ->
          continue_after_intent(agent, hauler, portfolio, delivered)

        other ->
          other
      end
    end
  end

  defp reconcile_construction(agent, portfolio) do
    with %Revision{} = revision <- Repo.get(Revision, portfolio.fleet_strategy_revision_id),
         %{} = operator <- Repo.get(SpaceTraders.Agent.Operator, agent.operator_id) do
      FleetConstruction.reconcile(Scope.for_operator(operator), agent, revision)
    end
  end

  defp current_generation(%AgentRecord{id: agent_id}) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
            is_nil(generation.retired_at)
    )
  end

  # A missing live Ship, credit, or Market-reach fact is unknown availability,
  # not zero availability. Treating it as zero would let a transient API error
  # manufacture a Neutral Wait from a non-authoritative allocation result, and
  # would let coverage acquisition proceed against fabricated capacity.
  defp allocation_availability(agent) do
    with {:ok, availability} <- governed_availability(agent),
         %Generation{} = generation <- current_generation(agent) do
      {:ok, Map.put(availability, :source_version, generation.allocation_version)}
    else
      _ -> {:error, :availability_unknown}
    end
  end

  defp governed_market_access(%AgentRecord{} = agent) do
    with {:ok, system_symbol} <- Fleet.system_from_headquarters(agent.headquarters) do
      {:ok, Intelligence.marketplace_waypoints(agent, system_symbol)}
    end
  end

  defp market_claims(agent, ships, markets) do
    reserved = MapSet.new(ShipReservation.reserved_symbols(agent.id))

    ships
    |> Enum.reject(&MapSet.member?(reserved, &1.symbol))
    |> Enum.map(fn ship ->
      %{
        resource: ship.symbol,
        roles: ship_roles(ship),
        capabilities: %{
          frame: frame_symbol(ship),
          fuel_capacity: fuel_capacity(ship),
          fuel: fuel(ship),
          position: position(ship),
          cargo_transport: cargo_capacity(ship),
          chart: true,
          waypoint_scan: sensor_mount?(ship),
          market_access: markets
        }
      }
    end)
  end

  # Roles follow capability: only a Ship with a hold can trade; any Ship can
  # scout. Allocation then picks the cheapest capable Ship per role.
  defp ship_roles(ship) do
    if cargo_capacity(ship) > 0,
      do: [:market_trader, :intelligence_scout],
      else: [:intelligence_scout]
  end

  defp frame_symbol(%{frame: %{symbol: symbol}}), do: symbol
  defp frame_symbol(_ship), do: nil

  # Fuel tank size stands in for fuel use per leg; solar-powered probes carry
  # none and so cost nothing to move.
  defp fuel_capacity(%{fuel: %{capacity: capacity}}) when is_integer(capacity), do: capacity
  defp fuel_capacity(_ship), do: 0

  # Fuel in the tank and where the Ship is: Fleet Planning offers a trade
  # only to a Ship that can reach it with known fuel stops.
  defp fuel(%{fuel: %{current: current, capacity: capacity}})
       when is_integer(current) and is_integer(capacity),
       do: %{current: current, capacity: capacity}

  defp fuel(_ship), do: nil

  defp position(%{nav: %{waypoint_symbol: waypoint} = nav} = ship) when is_binary(waypoint) do
    point =
      case SpaceTraders.Fleet.FuelReach.position(ship) do
        {:ok, %{x: x, y: y}} -> %{x: x, y: y}
        {:error, _reason} -> %{}
      end

    Map.merge(point, %{waypoint: waypoint, flight_mode: Map.get(nav, :flight_mode)})
  end

  defp position(_ship), do: nil

  defp cargo_capacity(%{cargo: %{capacity: capacity}}) when is_integer(capacity), do: capacity
  defp cargo_capacity(_ship), do: 0

  defp sensor_mount?(%{mounts: mounts}) when is_list(mounts) do
    Enum.any?(mounts, fn mount ->
      is_binary(mount.symbol) and String.starts_with?(mount.symbol, "MOUNT_SENSOR_ARRAY")
    end)
  end

  defp sensor_mount?(_ship), do: false

  defp agent_credits(%AgentRecord{} = agent) do
    case Agent.agent_overview(agent) do
      {:ok, overview} when is_map(overview) -> Map.get(overview, :credits)
      _ -> nil
    end
  end

  defp claimed_ship_symbol(%{claims: [ship_symbol | _]}) when is_binary(ship_symbol),
    do: {:ok, ship_symbol}

  defp claimed_ship_symbol(_commitment), do: {:error, :no_claimed_ship}
end
