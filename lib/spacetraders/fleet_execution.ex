defmodule SpaceTraders.FleetExecution do
  @moduledoc """
  Activates one eligible Market Fleet Commitment into governed Ship execution.

  Only a shadow-validated eligible Market commitment may activate Ship
  execution. Eligibility requires that the commitment's Credit Reservations
  cover calibrated Market purchase exposure without
  crossing the Hard Constraint credit floor. Activation publishes the selected
  portfolio atomically (Claim + Reservations + Strategy Decision Episode), then
  dispatches the authoritative buy, travel, sell round trip on the claimed Ship
  through governed operations.
  """

  import Ecto.Query

  alias SpaceTraders.{Agent, Clock}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetShadow
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.FleetStrategy.StandingAuthority
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo
  alias SpaceTraders.ShipReservation

  @doc "Returns calibrated exposure for a quoted Market purchase cost."
  def worst_case_exposure(quoted_cost) when is_integer(quoted_cost),
    do: SpaceTraders.MarketSpending.worst_case_exposure(quoted_cost, 1)

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

  @doc """
  Returns the shadow-validated eligible Market commitment for one Agent.

  A proposed choice is eligible only when it carries a Claim on a Ship the
  Agent owns and its Credit Reservations cover calibrated purchase exposure
  without crossing the Hard Constraint credit floor.
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
      available - reservation >= floor
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
    with {:ok, availability} <- allocation_availability(agent) do
      activate_market(scope, agent, revision, comparison, availability)
    end
  end

  defp activate_market(
         %Scope{} = scope,
         %AgentRecord{} = agent,
         %Revision{} = revision,
         comparison,
         availability
       ) do
    case eligible_market_commitment(comparison, agent, revision, availability) do
      nil ->
        {:error, :no_eligible_market_commitment}

      commitment ->
        with {:ok, candidate} <- market_candidate(comparison, commitment),
             {:ok, portfolio} <- publish_eligible(scope, agent, revision, comparison, commitment),
             {:ok, persisted} <- published_commitment(portfolio, commitment),
             {:ok, round_trip} <- activate_round_trip(agent, persisted, portfolio, candidate) do
          {:ok,
           %{
             commitment: persisted,
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
        capacity
      )
      when is_list(candidates) and is_list(demands) do
    cond do
      not FleetCapacity.proceed?(capacity) ->
        {:error, :api_capacity_unavailable}

      candidates == [] ->
        {:error, :no_decision_relevant_intelligence}

      true ->
        do_activate_intelligence(scope, agent, revision, candidates, demands)
    end
  end

  defp do_activate_intelligence(scope, agent, revision, candidates, demands) do
    with {:ok, availability} <- allocation_availability(agent) do
      do_activate_intelligence(scope, agent, revision, candidates, demands, availability)
    else
      _ -> {:error, :intelligence_activation_unavailable}
    end
  end

  defp do_activate_intelligence(scope, agent, revision, candidates, demands, availability) do
    owned_ships = MapSet.new(Enum.map(availability.claims, & &1.resource))

    with {:ok, selection} <-
           FleetAllocation.select_portfolio(revision, candidates, availability),
         commitment when not is_nil(commitment) <-
           Enum.find(selection.commitments, fn commitment ->
             claims_owned_ship?(commitment, owned_ships) and
               reservation_covers_exposure?(commitment, revision, availability)
           end),
         candidate when not is_nil(candidate) <-
           Enum.find(candidates, &(&1.id == commitment.candidate_id)),
         {:ok, {waypoint, demand}} <- current_observation_subject(agent, candidate, demands),
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
             waypoint: waypoint,
             required_facts: demand.required_facts,
             freshness_seconds: demand.freshness_seconds
           }) do
      {:ok, %{commitment: persisted, portfolio: portfolio, intent: intent}}
    else
      {:error, :current_observation_demand_unavailable} ->
        {:error, :intelligence_activation_unavailable}

      nil ->
        {:error, :no_eligible_intelligence_commitment}

      _ ->
        {:error, :intelligence_activation_unavailable}
    end
  end

  defp current_observation_subject(agent, candidate, demands) do
    case selected_observation_subject(agent, candidate, demands) do
      nil -> {:error, :current_observation_demand_unavailable}
      selection -> {:ok, selection}
    end
  end

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
    current = FleetAllocation.current_portfolio(scope, agent)

    case allocation_availability(agent) do
      {:ok, availability} ->
        with {:ok, comparison} <-
               FleetShadow.replan(
                 previous,
                 snapshot,
                 revision,
                 availability,
                 capacity,
                 current_commitments: if(current, do: current.commitments, else: [])
               ) do
          reconcile_market_replan(
            scope,
            agent,
            revision,
            current,
            comparison,
            capacity,
            availability
          )
        end

      {:error, :availability_unknown} = error ->
        capacity_deferral_or_error(current, capacity, error)
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
    current = FleetAllocation.current_portfolio(scope, agent)

    case allocation_availability(agent) do
      {:ok, availability} ->
        with {:ok, comparison} <-
               FleetShadow.compare_market(agent, revision, system_symbol, availability, capacity) do
          reconcile_market_replan(
            scope,
            agent,
            revision,
            current,
            comparison,
            capacity,
            availability
          )
        end

      {:error, :availability_unknown} = error ->
        capacity_deferral_or_error(current, capacity, error)
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
                record_realized_economics(portfolio, intent, sell)
                result
              end

            result ->
              result
          end
        end

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

  defp published_commitment(%Portfolio{commitments: commitments}, %{candidate_id: candidate_id}) do
    case Enum.find(commitments, &(&1.candidate_id == candidate_id)) do
      %Commitment{} = commitment -> {:ok, commitment}
      _ -> {:error, :published_commitment_missing}
    end
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

  # The Governor's explicit deferral wins over availability collection. It is
  # not authoritative evidence of an empty portfolio, so it cannot mint or
  # disturb a Neutral Wait.
  defp capacity_deferral_or_error(current, capacity, error) do
    cond do
      FleetCapacity.proceed?(capacity) -> error
      current -> {:ok, %{action: :retained_for_capacity, portfolio: current}}
      true -> {:ok, %{action: :deferred_for_capacity}}
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
        roles: [:market_trader, :intelligence_scout],
        capabilities: %{
          cargo_transport: cargo_capacity(ship),
          chart: true,
          waypoint_scan: sensor_mount?(ship),
          market_access: markets
        }
      }
    end)
  end

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
         _capacity,
         _availability
       ) do
    {:ok, %{action: :retained, portfolio: current}}
  end

  defp reconcile_market_replan(
         scope,
         agent,
         revision,
         current,
         comparison,
         capacity,
         availability
       ) do
    cond do
      not FleetCapacity.proceed?(capacity) and current ->
        # Capacity is evidence for allocation: retain a still-authorized commitment
        # rather than churn claims while the Governor cannot admit the replacement.
        {:ok, %{action: :retained_for_capacity, portfolio: current, comparison: comparison}}

      not FleetCapacity.proceed?(capacity) ->
        {:ok, %{action: :deferred_for_capacity, comparison: comparison}}

      true ->
        replan_market_commitments(scope, agent, revision, current, comparison, availability)
    end
  end

  defp replan_market_commitments(scope, agent, revision, current, comparison, availability) do
    if current &&
         Enum.any?(current.commitments, fn commitment ->
           Enum.any?(
             commitment.dependencies,
             &String.starts_with?(&1["subject"] || "", "construction:")
           )
         end) do
      {:ok, %{action: :retained, portfolio: current, comparison: comparison}}
    else
      do_reconcile_market_replan(scope, agent, revision, current, comparison, availability)
    end
  end

  defp do_reconcile_market_replan(scope, agent, revision, current, comparison, availability) do
    case eligible_market_commitment(comparison, agent, revision, availability) do
      %{candidate_id: candidate_id} when current != nil ->
        if Enum.any?(current.commitments, &(&1.candidate_id == candidate_id)) do
          {:ok, %{action: :retained, portfolio: current, comparison: comparison}}
        else
          activate_replanned_market(scope, agent, revision, current, comparison, availability)
        end

      nil when current != nil ->
        with {:ok, portfolio} <-
               FleetAllocation.unwind_current_portfolio(scope, current.fleet_generation_id) do
          {:ok, %{action: :unwound, portfolio: portfolio, comparison: comparison}}
        end

      nil ->
        # The single Neutral Wait mint site (ADR 0012): the authoritative
        # zero-admissible result plus durable future evidence for its
        # unresolved subjects records the wait. Every other producer outcome —
        # unknown availability, capacity deferral, infeasibility — never
        # reaches it, and a reconciliation without future evidence fails
        # closed: the result stands, no wait is minted.
        mint_neutral_wait(scope, agent, revision, comparison)

      _commitment ->
        activate_replanned_market(scope, agent, revision, current, comparison, availability)
    end
  end

  defp mint_neutral_wait(scope, agent, revision, comparison) do
    selection = neutral_wait_selection(comparison)

    with %Generation{} = generation <- current_generation(agent),
         {:ok, _episode} <-
           FleetAllocation.record_neutral_wait(scope, generation, revision, selection) do
      {:ok, %{action: :no_admissible_commitment, comparison: comparison}}
    else
      _not_a_wait ->
        {:ok, %{action: :no_admissible_commitment, comparison: comparison}}
    end
  end

  # The reconciliation's enumerated result binding for the mint: the planning
  # entries' unresolved limitations and Observation Demands carry the binding
  # limitation, the re-evaluation evidence, and the candidate record detail.
  defp neutral_wait_selection(comparison) do
    planning = Map.get(comparison, :planning, [])

    demands =
      planning
      |> Enum.flat_map(&Map.get(&1, :observation_demands, []))
      |> Enum.reject(&is_nil(Map.get(&1, :subject)))
      |> Enum.uniq_by(&Map.get(&1, :subject))

    %{
      action: :no_admissible_commitment,
      source_version: Map.get(comparison, :source_version, 0),
      planning: planning,
      reconciled_subjects: Map.get(comparison, :reconciled_subjects, []),
      observation_demands: demands,
      binding_limitation: binding_limitation(planning),
      evidence_references: observation_references(demands),
      candidates: Enum.flat_map(planning, &Map.get(&1, :candidate_contributions, [])),
      rejections: Map.get(comparison, :alternatives, []),
      calibration_version: Map.get(comparison, :calibration_version)
    }
  end

  defp binding_limitation(planning) do
    planning
    |> Enum.flat_map(&Map.get(&1, :limitations, []))
    |> Enum.find(&neutral_wait_limitation?/1)
    |> case do
      nil -> %{}
      limitation -> limitation
    end
  end

  defp neutral_wait_limitation?(%{reason: reason})
       when reason in [
              :incomplete_market_coverage,
              :unreachable_market_coverage,
              :no_viable_market_routes,
              :insufficient_market_evidence
            ],
       do: true

  defp neutral_wait_limitation?(%{"reason" => reason})
       when reason in [
              "incomplete_market_coverage",
              "unreachable_market_coverage",
              "no_viable_market_routes",
              "insufficient_market_evidence"
            ],
       do: true

  defp neutral_wait_limitation?(_limitation), do: false

  defp observation_references(demands) do
    Enum.map(demands, fn demand ->
      %{
        "kind" => "observation",
        "subject" => to_string(demand.subject),
        "operation_id" => "get-market"
      }
    end)
  end

  defp activate_replanned_market(scope, agent, revision, current, comparison, availability) do
    with {:ok, result} <- activate_market(scope, agent, revision, comparison, availability) do
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
