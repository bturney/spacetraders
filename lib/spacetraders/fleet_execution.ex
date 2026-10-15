defmodule SpaceTraders.FleetExecution do
  @moduledoc """
  Runtime activation of Fleet Allocation decisions into governed Ship
  execution.

  Fleet Allocation (`SpaceTraders.FleetAllocation.MarketDomain`) owns the
  Market reconciliation lifecycle and calls in here one published
  Commitment at a time: `activate_round_trip/4` and `activate_observation/5`
  start a root Intent, and `continue_after_intent/4` resumes a Commitment's
  next leg. This module also reports governed availability.
  """

  import Ecto.Query

  alias SpaceTraders.{Agent, Clock}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, MarketDomain, Portfolio}
  alias SpaceTraders.FleetGeneration.Generation
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
    with %Generation{} <- FleetAllocation.active_generation(agent),
         {:ok, markets} <- governed_market_access(agent),
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

  @doc """
  Dispatches the observation a published intelligence Commitment selected on
  its claimed Ship.

  The instruction is the selected Waypoint and the open Observation Demand
  whose subject, required facts and freshness the acquisition must satisfy.
  """
  def activate_observation(agent, commitment, %Portfolio{} = portfolio, waypoint, demand) do
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
          trade_work_profile: SpaceTraders.FleetAllocation.MarketWorkRate.ship_profile(ship),
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
