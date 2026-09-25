defmodule SpaceTraders.FleetContracts do
  @moduledoc "Contract outcome admission and reconciliation for the active Fleet Strategy."

  import Ecto.Query

  alias SpaceTraders.API.Model.Contract
  alias SpaceTraders.Contracts
  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.Repo
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.SafetyFence.DependencyKey
  alias SpaceTraders.ShipReservation
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}

  @doc "Admits an offered Contract only when its entire bounded consequence is safe."
  def admit_acceptance(
        %Revision{document: %{"objectives" => objectives}} = revision,
        %Contract{accepted: false, fulfilled: false, terms: %{payment: payment}} = contract,
        %{
          as_of: %DateTime{} = as_of,
          credits: credits,
          worst_case_cost: cost,
          estimated_seconds: duration,
          evidence_id: evidence_id
        }
      )
      when is_list(objectives) and is_integer(credits) and is_integer(cost) and cost >= 0 and
             is_integer(duration) and duration >= 0 and is_binary(evidence_id) and
             evidence_id != "" do
    with true <- Enum.any?(objectives, &contract_objective?/1) || {:error, :strategy},
         {:ok, accept_by} <- parse_future(contract.deadline_to_accept, as_of),
         {:ok, complete_by} <- parse_future(contract.terms.deadline, as_of),
         true <- DateTime.compare(complete_by, accept_by) == :gt || {:error, :deadline},
         true <-
           DateTime.compare(DateTime.add(as_of, duration, :second), complete_by) == :lt ||
             {:error, :deadline},
         true <-
           (is_integer(payment.on_accepted) and payment.on_accepted >= 0) ||
             {:error, :unknown_consequence},
         true <-
           (is_integer(payment.on_fulfilled) and payment.on_fulfilled >= 0) ||
             {:error, :unknown_consequence},
         {:ok, authorization} <-
           StandingAuthority.authorize(revision, %{
             revision_id: revision.id,
             evidence_id: evidence_id,
             observed_at: as_of,
             bounds: %{minimum_credits: credits + payment.on_accepted - cost, scraps_ship: false}
           }) do
      {:ok, authorization}
    else
      {:error, reasons} when is_list(reasons) -> {:error, :hard_constraint}
      {:error, reason} -> {:error, reason}
    end
  end

  def admit_acceptance(_revision, _contract, _evidence), do: {:error, :unknown_consequence}

  @doc "Re-reads an offer before acceptance so an ambiguous prior response cannot be replayed."
  def accept_if_admissible(%AgentRecord{} = agent, %Revision{} = revision, contract_id, evidence)
      when is_binary(contract_id) do
    with true <- contract_strategy?(revision) || {:error, :strategy},
         {:ok, contracts} <- Contracts.list_contracts(agent),
         %Contract{} = contract <- Enum.find(contracts, &(&1.id == contract_id)) do
      cond do
        contract.fulfilled ->
          {:ok, :already_fulfilled}

        contract.accepted ->
          with :ok <- reconcile_confirmed_attempts(agent, contract),
               do: {:ok, :already_accepted}

        true ->
          with :ok <- fresh_acceptance_evidence(evidence),
               true <- Contracts.acceptable?(contract) || {:error, :deadline},
               {:ok, overview} <- Agent.agent_overview(agent),
               {:ok, _} <-
                 admit_acceptance(
                   revision,
                   contract,
                   Map.merge(evidence, %{credits: overview.credits, as_of: DateTime.utc_now()})
                 ),
               {:ok, result} <-
                 Agent.handle_game_result(agent, Contracts.accept_contract(agent, contract_id)) do
            if result.contract.accepted,
              do: {:ok, result.contract},
              else: {:error, :acceptance_unconfirmed}
          end
      end
    else
      nil -> {:error, :contract_unavailable}
      error -> error
    end
  end

  defp fresh_acceptance_evidence(%{as_of: %DateTime{} = observed_at}) do
    if DateTime.diff(DateTime.utc_now(), observed_at, :second) in 0..300,
      do: :ok,
      else: {:error, :stale_acceptance_evidence}
  end

  defp fresh_acceptance_evidence(_), do: {:error, :stale_acceptance_evidence}

  @doc "Negotiates one offer only when authoritative Contract state permits another."
  def negotiate_if_available(%AgentRecord{} = agent, %Revision{} = revision, ship_symbol)
      when is_binary(ship_symbol) do
    with true <- contract_strategy?(revision) || {:error, :strategy},
         {:ok, contracts} <- Contracts.list_contracts(agent),
         true <- Contracts.negotiable?(contracts) || {:error, :offer_pending},
         {:ok, _ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:error, :no_current_ship_claim} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, Evidence.get_ship(agent, ship_symbol)),
         true <-
           live_ship.nav.waypoint_symbol == agent.headquarters ||
             {:error, :ship_not_at_headquarters},
         {:ok, overview} <- Agent.agent_overview(agent),
         {:ok, _authorization} <-
           StandingAuthority.authorize(revision, %{
             revision_id: revision.id,
             evidence_id: Evidence.fingerprint({contracts, ship_symbol}),
             observed_at: DateTime.utc_now(),
             bounds: %{minimum_credits: overview.credits, scraps_ship: false}
           }),
         {:ok, result} <-
           Agent.handle_game_result(agent, Contracts.negotiate_contract(agent, ship_symbol)) do
      {:ok, result.contract}
    else
      {:error, reasons} when is_list(reasons) -> {:error, :hard_constraint}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reconciles Contract outcomes from governed game evidence and published Fleet authority."
  def reconcile(%Scope{} = scope, %AgentRecord{} = agent, %Revision{} = revision) do
    with true <- contract_strategy?(revision) || {:error, :strategy},
         :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         {:ok, contracts} <- Contracts.list_contracts(agent),
         :ok <- reconcile_contracts(agent, contracts),
         {:ok, ships} <- Fleet.list_ships(agent),
         {:ok, overview} <- Agent.agent_overview(agent),
         %Generation{} = generation <- current_generation(agent),
         true <- generation.fleet_strategy_revision_id == revision.id || {:error, :strategy},
         [] <- Intents.current(agent) do
      now = DateTime.utc_now()
      accepted = Enum.filter(contracts, &Contracts.active?/1)

      case completed_purchase_awaiting_delivery(scope, agent) do
        {commitment, portfolio, buy} ->
          FleetExecution.continue_after_intent(agent, commitment, portfolio, buy)

        nil ->
          cond do
            ready = Enum.find(accepted, &Contracts.ready?/1) ->
              fulfill_if_ready(agent, revision, ready.id)

            accepted != [] ->
              activate_delivery(
                scope,
                agent,
                revision,
                generation,
                accepted,
                ships,
                overview.credits,
                now
              )

            offer = Enum.find(contracts, &Contracts.acceptable?/1) ->
              case estimate_acceptance(
                     offer,
                     sourcing_listings(agent, now),
                     ships,
                     overview.credits,
                     now
                   ) do
                {:ok, evidence} -> accept_if_admissible(agent, revision, offer.id, evidence)
                error -> error
              end

            true ->
              case Enum.find(ships, &(&1.nav.waypoint_symbol == agent.headquarters)) do
                %{symbol: symbol} -> negotiate_if_available(agent, revision, symbol)
                _ -> {:error, :no_contract_negotiator}
              end
          end
      end
    else
      [_ | _] -> {:error, :ship_execution_in_progress}
      false -> {:error, :strategy}
      nil -> {:error, :generation_unavailable}
      error -> error
    end
  end

  defp reconcile_contracts(agent, contracts) do
    Enum.reduce_while(contracts, :ok, fn contract, :ok ->
      case reconcile_confirmed_attempts(agent, contract) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp reconcile_confirmed_attempts(agent, %Contract{} = contract) do
    MutationAttempts.list_for_agent(agent)
    |> Enum.filter(fn attempt ->
      attempt.state in ["sent_or_unknown", "ambiguous"] and
        ((contract.accepted and attempt.operation_id == "accept-contract" and
            get_in(attempt.prepared_evidence, ["request", "path"]) ==
              "/my/contracts/#{contract.id}/accept") or
           (contract.fulfilled and attempt.operation_id == "fulfill-contract" and
              get_in(attempt.prepared_evidence, ["request", "path"]) ==
                "/my/contracts/#{contract.id}/fulfill"))
    end)
    |> Enum.reduce_while(:ok, fn attempt, :ok ->
      case Agent.agent_overview(agent) do
        {:ok, overview} ->
          basis = "Authoritative Contract state confirms the #{attempt.operation_id} outcome"

          contract_observation =
            Evidence.authoritative_observation(
              "get-contracts",
              [DependencyKey.contract(agent.id, contract.id)],
              %{
                contract: %{
                  id: contract.id,
                  accepted: contract.accepted,
                  fulfilled: contract.fulfilled
                },
                reconciliation: %{
                  mutation_attempt_id: attempt.id,
                  request_fingerprint: attempt.request_fingerprint,
                  outcome: "accepted",
                  basis: basis
                }
              }
            )

          credit_observation =
            Evidence.authoritative_observation(
              "get-my-agent",
              [DependencyKey.agent_credits(agent.id)],
              %{credits: overview.credits}
            )

          case MutationAttempts.reconcile(attempt, :accepted, [
                 contract_observation,
                 credit_observation
               ]) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  defp completed_purchase_awaiting_delivery(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{commitments: commitments} = portfolio ->
        Enum.find_value(commitments, fn commitment ->
          intents =
            Repo.all(
              from intent in Intent,
                where: intent.fleet_commitment_id == ^commitment.id,
                order_by: [asc: intent.id]
            )

          case List.last(intents) do
            %Intent{
              type: "buy",
              status: "completed",
              last_action_result: %{"units" => units},
              parameters: %{"market_trade" => %{"contract_id" => _}}
            } = buy
            when is_integer(units) and units > 0 ->
              {commitment, portfolio, buy}

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc "Estimates acquisition exposure and delivery time from fresh sources and capable Ships."
  def estimate_acceptance(
        %Contract{terms: %{deliver: deliver}} = contract,
        listings,
        ships,
        credits,
        as_of
      )
      when is_list(deliver) and deliver != [] and is_list(listings) and is_list(ships) and
             is_integer(credits) and is_struct(as_of, DateTime) do
    estimates =
      Enum.map(deliver, fn good ->
        matches =
          for listing <- listings,
              listing.trade_symbol == good.trade_symbol and listing.trade_volume > 0 and
                DateTime.diff(as_of, listing.observed_at, :second) in 0..300,
              source_system = waypoint_system(listing.waypoint),
              source_system == waypoint_system(good.destination_symbol),
              ship <- ships,
              ship.nav.system_symbol == source_system,
              ship.nav.status in ["DOCKED", "IN_ORBIT"],
              is_integer(ship.cargo.capacity) and ship.cargo.capacity > 0,
              do: {listing, min(listing.trade_volume, ship.cargo.capacity)}

        case Enum.min_by(
               matches,
               fn {listing, batch} -> {listing.purchase_price, -batch} end,
               fn -> nil end
             ) do
          nil ->
            nil

          {listing, batch} ->
            if is_integer(good.units_required) and is_integer(good.units_fulfilled) and
                 good.units_required > good.units_fulfilled,
               do: begin_estimate(good.units_required - good.units_fulfilled, listing, batch),
               else: nil
        end
      end)

    if Enum.all?(estimates, &is_tuple/1) do
      {:ok,
       %{
         as_of: as_of,
         credits: credits,
         worst_case_cost: Enum.sum_by(estimates, &elem(&1, 0)),
         estimated_seconds: Enum.sum_by(estimates, &elem(&1, 1)),
         evidence_id: Evidence.fingerprint({contract.id, estimates})
       }}
    else
      {:error, :contract_sourcing_unavailable}
    end
  end

  def estimate_acceptance(_, _, _, _, _), do: {:error, :contract_sourcing_unavailable}

  defp begin_estimate(remaining, listing, batch) do
    trips = div(remaining + batch - 1, batch)
    {remaining * listing.purchase_price + 750 * trips, 21_600 * trips, listing.evidence_id}
  end

  defp waypoint_system(waypoint) when is_binary(waypoint) do
    waypoint |> String.split("-") |> Enum.drop(-1) |> Enum.join("-")
  end

  defp waypoint_system(_), do: nil

  defp activate_delivery(scope, agent, revision, generation, contracts, ships, credits, as_of) do
    listings = sourcing_listings(agent, as_of)
    objective_index = Enum.find_index(revision.document["objectives"], &contract_objective?/1)

    available_ships =
      Enum.reject(ships, &(&1.symbol in ShipReservation.reserved_symbols(agent.id)))

    with {:ok, %{candidate_contributions: [_ | _] = candidates}} <-
           FleetPlanning.plan_contracts(revision, objective_index, %{
             as_of: as_of,
             contracts: contracts,
             ships: available_ships,
             listings: listings,
             credits: credits
           }),
         {:ok, selection} <-
           FleetAllocation.select_portfolio(revision, candidates, %{
             as_of: as_of,
             claims:
               Enum.map(available_ships, fn ship ->
                 %{
                   resource: ship.symbol,
                   roles: [:contract_courier],
                   capabilities: %{
                     cargo_transport: ship.cargo.capacity,
                     resource_ship: ship.symbol
                   }
                 }
               end),
             reservations: %{credits: credits}
           }),
         [chosen | _] <- selection.commitments,
         candidate <- Enum.find(candidates, &(&1.id == chosen.candidate_id)),
         {:ok, portfolio} <-
           FleetAllocation.publish_portfolio(
             scope,
             generation.id,
             %{selection | source_version: generation.allocation_version, commitments: [chosen]},
             %{
               evidence_references: candidate.dependencies,
               expectations: candidate.expected_outcomes,
               calibration_version: "contracts-v1"
             }
           ),
         [commitment] <- portfolio.commitments,
         [ship_symbol] <- commitment.claims do
      result =
        if candidate.contract.source == :cargo do
          Intents.request_commitment_contract_delivery(
            agent,
            commitment,
            portfolio,
            ship_symbol,
            %{
              contract_id: candidate.contract.id,
              destination_waypoint: candidate.destination_waypoint,
              trade_symbol: candidate.trade_symbol,
              units: candidate.contract.batch_units
            }
          )
        else
          floor =
            case StandingAuthority.credit_floor(revision) do
              {:ok, amount} -> amount
              _ -> 0
            end

          Intents.request_commitment_round_trip(agent, commitment, portfolio, ship_symbol, %{
            source_waypoint: candidate.source_waypoint,
            destination_waypoint: candidate.destination_waypoint,
            trade_symbol: candidate.trade_symbol,
            units: candidate.contract.batch_units,
            purchase_price: candidate.contract.max_price,
            reserve_credits: floor + 750,
            contract_id: candidate.contract.id
          })
        end

      case result do
        {:ok, %{status: "completed"} = intent} ->
          FleetExecution.continue_after_intent(agent, commitment, portfolio, intent)

        other ->
          other
      end
    else
      nil -> {:error, :contract_delivery_unavailable}
      [] -> {:error, :contract_delivery_unavailable}
      {:ok, %{candidate_contributions: []}} -> {:error, :contract_sourcing_unavailable}
      error -> error
    end
  end

  defp sourcing_listings(agent, as_of) do
    Observation
    |> where([observation], observation.agent_id == ^agent.id)
    |> where([observation], like(observation.subject, "market:%"))
    |> where([observation], observation.observed_at <= ^as_of)
    |> order_by([observation], desc: observation.observed_at, desc: observation.id)
    |> Repo.all()
    |> Enum.uniq_by(& &1.subject)
    |> Enum.flat_map(fn observation ->
      waypoint = observation.subject |> String.split(":") |> List.last()

      Enum.flat_map(observation.facts["trade_goods"] || [], fn good ->
        symbol = good["symbol"] || good[:symbol]
        price = good["purchase_price"] || good[:purchase_price]
        volume = good["trade_volume"] || good[:trade_volume]

        if is_binary(symbol) and is_integer(price) and is_integer(volume),
          do: [
            %{
              waypoint: waypoint,
              trade_symbol: symbol,
              purchase_price: price,
              trade_volume: volume,
              observed_at: observation.observed_at,
              evidence_id: observation.id
            }
          ],
          else: []
      end)
    end)
  end

  defp current_generation(%AgentRecord{id: agent_id}) do
    Repo.one(
      from generation in Generation,
        where:
          generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
            is_nil(generation.retired_at)
    )
  end

  @doc "Reconciles the game result before fulfilling a completely delivered Contract."
  def fulfill_if_ready(%AgentRecord{} = agent, %Revision{} = revision, contract_id)
      when is_binary(contract_id) do
    with true <- contract_strategy?(revision) || {:error, :strategy},
         {:ok, contracts} <- Contracts.list_contracts(agent),
         %Contract{} = contract <- Enum.find(contracts, &(&1.id == contract_id)),
         :ok <- reconcile_confirmed_attempts(agent, contract),
         :ok <- fulfillment_state(contract),
         {:ok, overview} <- Agent.agent_overview(agent),
         {:ok, _authorization} <-
           StandingAuthority.authorize(revision, %{
             revision_id: revision.id,
             evidence_id: Evidence.fingerprint(contract),
             observed_at: DateTime.utc_now(),
             bounds: %{minimum_credits: overview.credits, scraps_ship: false}
           }),
         {:ok, result} <-
           Agent.handle_game_result(agent, Contracts.fulfill_contract(agent, contract_id)) do
      if completed?(result.contract),
        do: {:ok, result.contract},
        else: {:error, :fulfillment_unconfirmed}
    else
      nil -> {:error, :contract_unavailable}
      {:ok, :fulfilled, %Contract{} = contract} -> {:ok, contract}
      {:error, reasons} when is_list(reasons) -> {:error, :hard_constraint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fulfillment_state(%Contract{fulfilled: true} = contract), do: {:ok, :fulfilled, contract}

  defp fulfillment_state(%Contract{} = contract) do
    cond do
      not Contracts.fulfillable?(contract) -> {:error, :contract_unavailable}
      not Contracts.ready?(contract) -> {:error, :delivery_remaining}
      true -> :ok
    end
  end

  defp contract_strategy?(%Revision{document: %{"objectives" => objectives}})
       when is_list(objectives),
       do: Enum.any?(objectives, &contract_objective?/1)

  defp contract_strategy?(_revision), do: false

  @doc "Projects current Contract Pledges against a fresh authoritative Contract read."
  def current_pledges(
        %Scope{operator: %{id: operator_id}} = scope,
        %AgentRecord{operator_id: operator_id} = agent
      ) do
    with {:ok, contracts} <- Contracts.list_contracts(agent),
         %{commitments: commitments} <- FleetAllocation.current_portfolio(scope, agent) do
      commitments
      |> Enum.flat_map(& &1.pledges)
      |> Enum.reduce_while({:ok, []}, fn
        %{"outcome" => ["contract", id, destination, symbol], "amount" => amount} = pledge,
        {:ok, projected}
        when is_integer(amount) and amount >= 0 ->
          case Enum.find(contracts, &(&1.id == id)) do
            %Contract{} = contract ->
              remaining =
                if contract.fulfilled do
                  0
                else
                  case contract.terms do
                    %{deliver: deliver} when is_list(deliver) ->
                      deliver
                      |> Enum.find(
                        &(&1.destination_symbol == destination and &1.trade_symbol == symbol)
                      )
                      |> case do
                        %{units_required: required, units_fulfilled: fulfilled}
                        when is_integer(required) and is_integer(fulfilled) ->
                          max(required - fulfilled, 0)

                        _ ->
                          :unknown
                      end

                    _ ->
                      :unknown
                  end
                end

              if is_integer(remaining),
                do:
                  {:cont,
                   {:ok,
                    [%{outcome: pledge["outcome"], amount: min(amount, remaining)} | projected]}},
                else: {:halt, {:error, :contract_progress_unavailable}}

            nil ->
              {:halt, {:error, :contract_progress_unavailable}}
          end

        %{"outcome" => ["contract" | _]}, {:ok, _projected} ->
          {:halt, {:error, :contract_progress_unavailable}}

        _pledge, {:ok, projected} ->
          {:cont, {:ok, projected}}
      end)
      |> case do
        {:ok, projected} -> {:ok, Enum.reverse(projected)}
        error -> error
      end
    else
      nil -> {:ok, []}
      error -> error
    end
  end

  def current_pledges(_scope, _agent), do: {:error, :not_authorized}

  @doc "Only the game's fulfilled flag establishes a completed Contract."
  def completed?(%Contract{fulfilled: true}), do: true
  def completed?(%Contract{}), do: false

  defp parse_future(value, as_of) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} ->
        if DateTime.compare(date, as_of) == :gt,
          do: {:ok, date},
          else: {:error, :deadline}

      _ ->
        {:error, :deadline}
    end
  end

  defp parse_future(_, _), do: {:error, :deadline}

  @doc "Whether a Strategic Objective explicitly calls for Contract outcomes."
  def contract_objective?(%{"objective" => description}) when is_binary(description),
    do: String.match?(description, ~r/\bcontracts?\b/i)

  def contract_objective?(_), do: false
end
