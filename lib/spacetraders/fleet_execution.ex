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
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.FleetStrategy.StandingAuthority
  alias SpaceTraders.Repo

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
          Intents.request_commitment_round_trip_sell(
            agent,
            commitment,
            portfolio,
            ship_symbol,
            candidate,
            nil
          )
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
        source_version: Map.get(comparison, :source_version, 0),
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
    case Fleet.list_ships(agent) do
      {:ok, ships} ->
        Enum.map(ships, fn ship ->
          %{
            resource: ship.symbol,
            roles: [:market_trader],
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
    case Fleet.list_ships(agent) do
      {:ok, ships} -> MapSet.new(ships, & &1.symbol)
      _ -> MapSet.new()
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

  defp credit_reservation(commitment) do
    reservations = Map.get(commitment, :reservations, %{})

    Map.get(reservations, "credits") || Map.get(reservations, :credits)
  end

  defp available_credits(availability) do
    reservations = Map.get(availability, :reservations, %{})

    Map.get(reservations, "credits") || Map.get(reservations, :credits)
  end
end
