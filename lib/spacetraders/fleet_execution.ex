defmodule SpaceTraders.FleetExecution do
  @moduledoc """
  Activates one eligible Market Fleet Commitment into governed Ship execution.

  Only a shadow-validated eligible Market commitment may activate Ship
  execution. Eligibility requires that the commitment's Credit Reservations
  cover the worst-case purchase, fuel, and bounded-loss exposure without
  crossing the Hard Constraint credit floor. Activation publishes the selected
  portfolio atomically (Claim + Reservations + Strategy Decision Episode), then
  dispatches the authoritative buy, travel, sell round trip on the claimed Ship
  through governed operations.
  """

  import Ecto.Query

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetShadow
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.FleetStrategy.StandingAuthority
  alias SpaceTraders.Repo
  alias SpaceTraders.ShipReservation

  @fuel_allowance_credits 500
  @bounded_loss_credits 250

  @doc "Returns the worst-case credit exposure allowance for one Market commitment."
  def worst_case_exposure(credit_reservation) when is_number(credit_reservation),
    do: credit_reservation + @fuel_allowance_credits + @bounded_loss_credits

  @doc "Returns the credit floor for a Revision, or `{:error, :no_credit_floor}`."
  defdelegate credit_floor(revision), to: StandingAuthority

  @doc """
  Returns the shadow-validated eligible Market commitment for one Agent.

  A proposed choice is eligible only when it carries a Claim on a Ship the
  Agent owns and its Credit Reservations cover the worst-case purchase, fuel,
  and bounded-loss exposure without crossing the Hard Constraint credit floor.
  """
  def eligible_market_commitment(
        comparison,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        availability
      )
      when is_map(comparison) and is_map(availability) do
    owned_ship_symbols = owned_ship_symbols(agent)

    comparison
    |> Map.get(:proposed_choices, [])
    |> Enum.find(fn commitment ->
      claims_owned_ship?(commitment, owned_ship_symbols) and
        reservation_covers_exposure?(commitment, revision, availability)
    end)
  end

  @doc "Returns true when Credit Reservations cover worst-case exposure within the floor."
  def reservation_covers_exposure?(commitment, %Revision{} = revision, availability)
      when is_map(commitment) and is_map(availability) do
    reservation = credit_reservation(commitment)
    available = available_credits(availability)

    with {:ok, floor} <- StandingAuthority.credit_floor(revision),
         true <- is_number(reservation) and reservation >= 0,
         true <- is_number(available) and available >= 0 do
      available - worst_case_exposure(reservation) >= floor
    else
      _ -> false
    end
  end

  @doc """
  Publishes one eligible Market commitment and activates its round trip.

  Returns `{:error, :no_eligible_market_commitment}` when the shadow-validated
  comparison proposes no eligible commitment for the Agent.
  """
  def activate_market(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        comparison
      )
      when is_map(comparison) do
    availability = availability(scope, agent)

    case eligible_market_commitment(comparison, agent, revision, availability) do
      nil ->
        {:error, :no_eligible_market_commitment}

      commitment ->
        with {:ok, candidate} <- market_candidate(comparison, commitment),
             {:ok, portfolio} <- publish_eligible(scope, agent, revision, comparison, commitment),
             {:ok, round_trip} <- activate_round_trip(agent, commitment, portfolio, candidate) do
          {:ok,
           %{
             commitment: commitment,
             portfolio: portfolio,
             round_trip: round_trip,
             expectations: Map.get(comparison, :expectations, %{}),
             contribution: contribution(portfolio)
           }}
        end
    end
  end

  def activate_intelligence(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        %{candidate_contributions: candidates, observation_demands: demands},
        %{available_slots: slots, backpressure: pressure}
      )
      when is_list(candidates) and is_list(demands) do
    cond do
      slots <= 0 or pressure == :sustained ->
        {:error, :api_capacity_unavailable}

      candidates == [] ->
        {:error, :no_decision_relevant_intelligence}

      true ->
        do_activate_intelligence(scope, agent, revision, candidates, demands)
    end
  end

  defp do_activate_intelligence(scope, agent, revision, candidates, demands) do
    availability = availability(scope, agent)
    owned_ships = owned_ship_symbols(agent)

    with {:ok, selection} <-
           FleetAllocation.select_portfolio(revision, candidates, availability),
         commitment when not is_nil(commitment) <-
           Enum.find(selection.commitments, fn commitment ->
             claims_owned_ship?(commitment, owned_ships) and
               reservation_covers_exposure?(commitment, revision, availability)
           end),
         candidate when not is_nil(candidate) <-
           Enum.find(candidates, &(&1.id == commitment.candidate_id)),
         demand when not is_nil(demand) <-
           Enum.find(
             demands,
             &String.ends_with?(&1.subject, ":#{candidate.destination_waypoint}")
           ),
         %Generation{} = generation <- current_generation(agent),
         {:ok, portfolio} <-
           FleetAllocation.publish_portfolio(
             scope,
             generation.id,
             %{
               revision_id: revision.id,
               source_version: generation.allocation_version,
               commitments: [commitment],
               rejected: selection.rejected
             },
             %{
               evidence_references: candidate.dependencies,
               expectations: candidate.expected_outcomes,
               calibration_version: "intelligence-v1"
             }
           ),
         [persisted] <- portfolio.commitments,
         [ship_symbol] <- persisted.claims,
         [type, _system, _waypoint] <- String.split(demand.subject, ":"),
         {:ok, intent} <-
           Intents.request_commitment_intelligence(agent, persisted, portfolio, ship_symbol, %{
             subject_type: String.to_existing_atom(type),
             waypoint: candidate.destination_waypoint,
             required_facts: demand.required_facts,
             freshness_seconds: demand.freshness_seconds
           }) do
      {:ok, %{commitment: persisted, portfolio: portfolio, intent: intent}}
    else
      nil -> {:error, :no_eligible_intelligence_commitment}
      _ -> {:error, :intelligence_activation_unavailable}
    end
  end

  @doc "Reconciles an active Market Commitment against fresh Listings and capacity."
  def replan_market(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        previous,
        snapshot,
        capacity
      )
      when is_map(previous) and is_map(snapshot) do
    availability = availability(scope, agent)
    current = FleetAllocation.current_portfolio(scope, agent)

    with {:ok, comparison} <-
           FleetShadow.replan(
             previous,
             snapshot,
             revision,
             availability,
             capacity,
             current_commitments: if(current, do: current.commitments, else: [])
           ) do
      reconcile_market_replan(scope, agent, revision, current, comparison, capacity)
    end
  end

  @doc false
  def reconcile_market_evidence(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        system_symbol,
        capacity
      )
      when is_binary(system_symbol) do
    availability = availability(scope, agent)
    current = FleetAllocation.current_portfolio(scope, agent)

    with {:ok, comparison} <-
           FleetShadow.compare_market(agent, revision, system_symbol, availability, capacity) do
      reconcile_market_replan(scope, agent, revision, current, comparison, capacity)
    end
  end

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
              record_realized_economics(portfolio, intent, sell)
              result

            result ->
              result
          end
        end

      _ ->
        :ok
    end
  end

  @doc "Returns the last completed sell Intent for a commitment, or nil."
  def last_realized_sell(%Commitment{} = commitment) do
    Repo.one(
      from intent in SpaceTraders.Fleet.Intent,
        where:
          intent.fleet_commitment_id == ^commitment.id and intent.type == "sell" and
            intent.status == "completed",
        order_by: [desc: intent.id],
        limit: 1
    )
  end

  @doc "Returns the last completed buy Intent for a commitment, or nil."
  def last_realized_buy(%Commitment{} = commitment) do
    Repo.one(
      from intent in SpaceTraders.Fleet.Intent,
        where:
          intent.fleet_commitment_id == ^commitment.id and intent.type == "buy" and
            intent.status == "completed",
        order_by: [desc: intent.id],
        limit: 1
    )
  end

  defp publish_eligible(scope, agent, revision, comparison, commitment) do
    with %Generation{} = generation <- current_generation(agent) do
      selection = %{
        revision_id: revision.id,
        # The Fleet Generation, not a stale shadow comparison, owns the CAS
        # version for a replacement portfolio.
        source_version: generation.allocation_version,
        commitments: [commitment],
        rejected: Map.get(comparison, :alternatives, [])
      }

      decision = %{
        evidence_references: evidence_references(comparison),
        expectations: Map.get(comparison, :expectations, %{}),
        calibration_version: Map.get(comparison, :calibration_version, "market-v1")
      }

      FleetAllocation.publish_portfolio(scope, generation.id, selection, decision)
    end
  end

  defp evidence_references(comparison) do
    comparison
    |> Map.get(:planning, [])
    |> Enum.flat_map(&Map.get(&1, :candidate_contributions, []))
    |> Enum.flat_map(&Map.get(&1, :dependencies, []))
    |> Enum.map(&%{"kind" => "market", "id" => &1.evidence_id})
    |> Enum.uniq()
  end

  defp contribution(%Portfolio{commitments: commitments}) do
    %{
      commitment_count: length(commitments),
      expected_value: Enum.sum_by(commitments, & &1.expected_value)
    }
  end

  defp current_generation(%AgentRecord{id: agent_id}) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
            is_nil(generation.retired_at)
    )
  end

  defp availability(%Scope{operator: operator}, agent) do
    %{
      as_of: DateTime.utc_now(),
      claims: availability_claims(agent),
      reservations: availability_reservations(operator, agent)
    }
  end

  defp availability_claims(agent) do
    reserved = MapSet.new(ShipReservation.reserved_symbols(agent.id))

    case Fleet.list_ships(agent) do
      {:ok, ships} ->
        ships
        |> Enum.reject(&MapSet.member?(reserved, &1.symbol))
        |> Enum.map(fn ship ->
          %{
            resource: ship.symbol,
            roles: [:market_trader, :intelligence_scout],
            capabilities: %{cargo_transport: cargo_capacity(ship)}
          }
        end)

      _ ->
        []
    end
  end

  defp cargo_capacity(%{cargo: %{capacity: capacity}}) when is_integer(capacity), do: capacity
  defp cargo_capacity(_ship), do: 0

  defp availability_reservations(_operator, agent) do
    case agent_credits(agent) do
      credits when is_integer(credits) -> %{credits: credits}
      _ -> %{credits: 0}
    end
  end

  defp agent_credits(%AgentRecord{} = agent) do
    case Agent.agent_overview(agent) do
      {:ok, overview} when is_map(overview) -> Map.get(overview, :credits)
      _ -> nil
    end
  end

  defp owned_ship_symbols(%AgentRecord{} = agent) do
    reserved = MapSet.new(ShipReservation.reserved_symbols(agent.id))

    case Fleet.list_ships(agent) do
      {:ok, ships} ->
        ships |> Enum.reject(&MapSet.member?(reserved, &1.symbol)) |> MapSet.new(& &1.symbol)

      _ ->
        MapSet.new()
    end
  end

  defp claims_owned_ship?(%{claims: claims}, owned) when is_list(claims),
    do: Enum.any?(claims, &MapSet.member?(owned, &1))

  defp claims_owned_ship?(_commitment, _owned), do: false

  defp claimed_ship_symbol(%{claims: [ship_symbol | _]}) when is_binary(ship_symbol),
    do: {:ok, ship_symbol}

  defp claimed_ship_symbol(_commitment), do: {:error, :no_claimed_ship}

  defp market_candidate(comparison, commitment) do
    candidate =
      comparison
      |> Map.get(:planning, [])
      |> Enum.flat_map(&Map.get(&1, :candidate_contributions, []))
      |> Enum.find(&(&1.id == commitment.candidate_id))

    case candidate do
      %SpaceTraders.FleetPlanning.CandidateContribution{} = candidate -> {:ok, candidate}
      _ -> {:error, :market_candidate_missing}
    end
  end

  defp reconcile_market_replan(
         _scope,
         _agent,
         _revision,
         current,
         %{replan_trigger: :unchanged},
         _capacity
       ) do
    {:ok, %{action: :retained, portfolio: current}}
  end

  defp reconcile_market_replan(_scope, _agent, _revision, current, comparison, %{
         available_slots: slots,
         backpressure: pressure
       })
       when slots == 0 or pressure == :sustained do
    if current do
      # Capacity is evidence for allocation: retain a still-authorized commitment
      # rather than churn claims while the Governor cannot admit the replacement.
      {:ok, %{action: :retained_for_capacity, portfolio: current, comparison: comparison}}
    else
      {:ok, %{action: :deferred_for_capacity, comparison: comparison}}
    end
  end

  defp reconcile_market_replan(scope, agent, revision, current, comparison, _capacity) do
    case eligible_market_commitment(comparison, agent, revision, availability(scope, agent)) do
      %{candidate_id: candidate_id} when current != nil ->
        if Enum.any?(current.commitments, &(&1.candidate_id == candidate_id)) do
          {:ok, %{action: :retained, portfolio: current, comparison: comparison}}
        else
          activate_replanned_market(scope, agent, revision, current, comparison)
        end

      nil when current != nil ->
        with {:ok, portfolio} <-
               FleetAllocation.unwind_current_portfolio(scope, current.fleet_generation_id) do
          {:ok, %{action: :unwound, portfolio: portfolio, comparison: comparison}}
        end

      nil ->
        {:ok, %{action: :no_admissible_commitment, comparison: comparison}}

      _commitment ->
        activate_replanned_market(scope, agent, revision, current, comparison)
    end
  end

  defp activate_replanned_market(scope, agent, revision, current, comparison) do
    with {:ok, result} <- activate_market(scope, agent, revision, comparison) do
      {:ok, Map.put(result, :action, if(current, do: :superseded, else: :activated))}
    end
  end

  defp credit_reservation(commitment) do
    reservations = Map.get(commitment, :reservations, %{})

    Map.get(reservations, "credits") || Map.get(reservations, :credits)
  end

  defp available_credits(availability) do
    reservations = Map.get(availability, :reservations, %{})

    Map.get(reservations, "credits") || Map.get(reservations, :credits)
  end

  defp record_realized_economics(portfolio, buy, sell) do
    purchase = get_in(buy.last_action_result, ["transaction", "total_price"])
    sale = get_in(sell.last_action_result, ["transaction", "total_price"])

    if is_number(purchase) and is_number(sale) do
      FleetAllocation.record_portfolio_outcome(portfolio, :realized, %{
        credit_change: sale - purchase,
        purchase_cost: purchase,
        sale_revenue: sale
      })
    end
  end
end
