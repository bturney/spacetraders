defmodule SpaceTraders.FleetPlanning do
  @moduledoc """
  Deterministically proposes evidence-bound Candidate Contributions.

  Planning is pure: it describes required resources and Observation Demands but
  never claims resources, creates execution work, or invokes gameplay.
  """

  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Demand
  alias SpaceTraders.API.Model.Contract
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetStrategy.Revision

  @market_evidence_freshness_seconds 300
  @observation_demand_deadline_seconds 60
  @refinery_modules ~w(MODULE_MINERAL_PROCESSOR_I MODULE_MICRO_REFINERY_I MODULE_ORE_REFINERY_I)

  @doc "Whether the Ship's observed modules can refine ore for a known material outcome."
  def refinery_capable?(ship) do
    Enum.any?(Map.get(ship, :modules) || [], &(&1.symbol in @refinery_modules))
  end

  defmodule CandidateContribution do
    @moduledoc "An objective-specific proposal that Fleet Allocation may accept or reject."

    @enforce_keys [
      :id,
      :strategy_revision_id,
      :objective_index,
      :objective,
      :kind,
      :trade_symbol,
      :source_waypoint,
      :destination_waypoint,
      :expected_outcomes,
      :uncertainty,
      :required_roles,
      :required_capabilities,
      :required_resources,
      :dependencies,
      :validity,
      :alternatives
    ]
    defstruct @enforce_keys ++ [resource: nil, contract: nil, construction: nil, transfer: nil]

    @type t :: %__MODULE__{}
  end

  @doc "Builds the standard Market evidence snapshot used by Fleet Planning."
  def market_snapshot(%DateTime{} = as_of, system_symbol, agent_id, markets)
      when is_binary(system_symbol) and is_list(markets) do
    %{
      as_of: as_of,
      system_symbol: system_symbol,
      agent_id: agent_id,
      freshness_seconds: @market_evidence_freshness_seconds,
      demand_deadline_seconds: @observation_demand_deadline_seconds,
      markets: markets
    }
  end

  @doc """
  Proposes Market Candidate Contributions for one Strategic Objective.

  The snapshot fixes the decision time with `:as_of` and supplies
  `:freshness_seconds` plus a list of Markets. Each Market has an evidence
  `:subject`, `:observed_at`, and `:trade_goods`. Optional `:agent_id` and
  `:demand_deadline_seconds` values are copied into proposed Observation
  Demands. The function performs no persistence or gameplay calls.
  """
  def plan_market(%Revision{} = revision, objective_index, snapshot)
      when is_integer(objective_index) and objective_index >= 0 and is_map(snapshot) do
    with {:ok, objective} <- objective_at(revision, objective_index),
         {:ok, normalized} <- normalize_snapshot(snapshot) do
      if market_objective?(objective) do
        plan_market_objective(revision, objective_index, objective, normalized)
      else
        {:ok,
         result(revision, objective_index, normalized,
           limitations: [%{subject: :market_planning, reason: :unsupported_market_objective}]
         )}
      end
    end
  end

  def plan_market(%Revision{}, _objective_index, _snapshot),
    do: {:error, :invalid_market_planning_input}

  def plan_intelligence(%Revision{} = revision, objective_index, snapshot)
      when is_integer(objective_index) and objective_index >= 0 and is_map(snapshot) do
    with {:ok, objective} <- objective_at(revision, objective_index),
         %{as_of: %DateTime{} = as_of, system_symbol: system, opportunities: opportunities} <-
           snapshot,
         true <- is_binary(system) and is_list(opportunities) do
      deadline = DateTime.add(as_of, 60, :second)
      freshness = Map.get(snapshot, :freshness_seconds, 300)

      opportunities
      |> Enum.sort_by(&Map.get(&1, :subject, ""))
      |> Enum.reduce_while({[], [], []}, fn opportunity, {candidates, demands, limitations} ->
        case intelligence_opportunity(opportunity, system, as_of, freshness) do
          {:ok, :satisfied} ->
            {:cont, {candidates, demands, limitations}}

          {:ok, %{net_value: net, type: type} = choice} ->
            demand = %Demand{
              subject: opportunity.subject,
              required_facts: opportunity.required_facts,
              owner: "fleet_planning",
              deadline_at: deadline,
              freshness_seconds: freshness,
              agent_id: Map.get(snapshot, :agent_id),
              strategy_revision_id: revision.id,
              strategic_priority: objective_index,
              expected_value: net,
              discovery: type == "waypoint"
            }

            candidates =
              if opportunity.acquisition == :on_site,
                do: [
                  intelligence_contribution(
                    revision,
                    objective_index,
                    objective,
                    choice,
                    opportunity,
                    deadline
                  )
                  | candidates
                ],
                else: candidates

            {:cont, {candidates, [demand | demands], limitations}}

          {:error, :acquisition_cost_exceeds_value} ->
            {:cont,
             {candidates, demands,
              [
                %{subject: opportunity.subject, reason: :acquisition_cost_exceeds_value}
                | limitations
              ]}}

          {:error, :invalid} ->
            {:halt, :invalid}
        end
      end)
      |> case do
        :invalid ->
          {:error, :invalid_intelligence_planning_input}

        {candidates, demands, limitations} ->
          {:ok,
           result(revision, objective_index, %{as_of: as_of},
             candidate_contributions: Enum.reverse(candidates),
             observation_demands: Enum.reverse(demands),
             limitations: Enum.reverse(limitations)
           )}
      end
    else
      _ -> {:error, :invalid_intelligence_planning_input}
    end
  end

  def plan_intelligence(_revision, _objective_index, _snapshot),
    do: {:error, :invalid_intelligence_planning_input}

  @doc "Proposes one bounded resource outcome per capable Ship from fresh game evidence."
  def plan_resources(
        %Revision{} = revision,
        index,
        %{
          as_of: %DateTime{} = as_of,
          ships: ships,
          waypoints: waypoints
        } = snapshot
      )
      when is_list(ships) and is_list(waypoints) and is_integer(index) and index >= 0 do
    with {:ok, objective} <- objective_at(revision, index) do
      freshness = Map.get(snapshot, :freshness_seconds, 300)

      candidates =
        for ship <- ships,
            waypoint <- waypoints,
            candidate <- [
              resource_contribution(
                revision,
                index,
                objective,
                ship,
                waypoint,
                Map.get(snapshot, :surveys, []),
                as_of,
                freshness
              )
            ],
            not is_nil(candidate),
            do: candidate

      {:ok, result(revision, index, %{as_of: as_of}, candidate_contributions: candidates)}
    end
  end

  def plan_resources(_revision, _index, _snapshot), do: {:error, :invalid_resource_planning_input}

  @doc "Proposes contract delivery from authoritative remaining work and fresh sourcing evidence."
  def plan_contracts(%Revision{} = revision, index, %{
        as_of: %DateTime{} = as_of,
        contracts: contracts,
        ships: ships,
        listings: listings,
        credits: credits
      })
      when is_list(contracts) and is_list(ships) and is_list(listings) and
             is_integer(credits) and credits >= 0 do
    with {:ok, objective} <- objective_at(revision, index) do
      candidates =
        for true <- [FleetContracts.contract_objective?(objective)],
            %Contract{
              accepted: true,
              fulfilled: false,
              terms: %{deliver: deliver, deadline: deadline}
            } = contract <- contracts,
            {:ok, expires_at, _} <- [DateTime.from_iso8601(deadline || "")],
            DateTime.compare(expires_at, as_of) == :gt,
            good <- deliver || [],
            is_integer(good.units_required) and is_integer(good.units_fulfilled),
            remaining = max(good.units_required - good.units_fulfilled, 0),
            remaining > 0,
            ship <- ships,
            %{symbol: ship_symbol, cargo: %{capacity: capacity}} <- [ship],
            is_integer(capacity) and capacity > 0,
            listing <- listings ++ held_contract_cargo(ship, good, contract, as_of),
            Map.get(listing, :ship_symbol, ship_symbol) == ship_symbol,
            listing.trade_symbol == good.trade_symbol,
            is_binary(listing.waypoint) and is_binary(listing.evidence_id),
            is_integer(listing.purchase_price) and listing.purchase_price >= 0,
            is_integer(listing.trade_volume) and listing.trade_volume > 0,
            %DateTime{} = observed_at <- [listing.observed_at],
            DateTime.compare(observed_at, as_of) != :gt,
            DateTime.diff(as_of, observed_at, :second) <= @market_evidence_freshness_seconds,
            batch = min(remaining, min(capacity, listing.trade_volume)),
            cost = batch * listing.purchase_price,
            cost <= credits do
          %CandidateContribution{
            id:
              Evidence.fingerprint(
                {revision.id, index, contract.id, good.destination_symbol, good.trade_symbol,
                 ship_symbol, good.units_fulfilled, listing.evidence_id}
              ),
            strategy_revision_id: revision.id,
            objective_index: index,
            objective: objective,
            kind: :contract_delivery,
            trade_symbol: good.trade_symbol,
            source_waypoint: listing.waypoint,
            destination_waypoint: good.destination_symbol,
            expected_outcomes: %{
              decision_value: 1,
              contract_id: contract.id,
              units_remaining: remaining,
              batch_units: batch
            },
            uncertainty: %{shared_progress: :may_change},
            required_roles: [%{role: :contract_courier, count: 1}],
            required_capabilities: [
              %{capability: :cargo_transport, minimum_capacity: batch},
              %{capability: :resource_ship, value: ship_symbol}
            ],
            required_resources: %{ship_count: 1, credits: cost},
            dependencies: [
              %{
                subject: "contracts:#{contract.id}",
                evidence_id: Evidence.fingerprint(contract),
                valid_until: expires_at
              },
              %{
                subject: "market:#{listing.waypoint}",
                evidence_id: listing.evidence_id,
                valid_until:
                  DateTime.add(observed_at, @market_evidence_freshness_seconds, :second)
              }
            ],
            validity: %{
              as_of: as_of,
              expires_at:
                Enum.min_by(
                  [
                    expires_at,
                    DateTime.add(observed_at, @market_evidence_freshness_seconds, :second)
                  ],
                  &DateTime.to_unix/1
                )
            },
            alternatives: [],
            contract: %{
              id: contract.id,
              units_remaining: remaining,
              batch_units: batch,
              max_price: listing.purchase_price,
              source: Map.get(listing, :source, :market)
            }
          }
        end

      transfers =
        for true <- [FleetContracts.contract_objective?(objective)],
            %Contract{
              accepted: true,
              fulfilled: false,
              terms: %{deliver: deliver, deadline: deadline}
            } = contract <-
              contracts,
            {:ok, expires_at, _} <- [DateTime.from_iso8601(deadline || "")],
            DateTime.compare(expires_at, as_of) == :gt,
            good <- deliver || [],
            is_integer(good.units_required) and is_integer(good.units_fulfilled),
            good.units_required > good.units_fulfilled,
            candidate <-
              transfer_contributions(
                revision,
                index,
                objective,
                :contract_delivery,
                %{
                  id: contract.id,
                  waypoint: good.destination_symbol,
                  symbol: good.trade_symbol,
                  remaining: good.units_required - good.units_fulfilled,
                  credits: credits,
                  evidence: %{
                    subject: "contracts:#{contract.id}",
                    evidence_id: Evidence.fingerprint(contract),
                    valid_until: expires_at
                  }
                },
                ships
              ),
            do: candidate

      {:ok,
       result(revision, index, %{as_of: as_of},
         candidate_contributions:
           Enum.sort_by(
             candidates ++ transfers,
             &{if(&1.contract.source == :cargo, do: 0, else: 1), &1.id}
           )
       )}
    end
  end

  def plan_contracts(_revision, _index, _snapshot), do: {:error, :invalid_contract_planning_input}

  @doc "Proposes Construction supply from a dated authoritative project read and fresh sourcing Listings."
  def plan_construction(
        %Revision{} = revision,
        index,
        %{
          as_of: %DateTime{} = as_of,
          constructions: constructions,
          ships: ships,
          listings: listings,
          credits: credits
        } = snapshot
      )
      when is_integer(index) and index >= 0 and is_list(constructions) and is_list(ships) and
             is_list(listings) and is_integer(credits) and credits >= 0 do
    with {:ok, objective} <- objective_at(revision, index) do
      {candidates, limitations} =
        if construction_objective?(objective) do
          constructions
          |> Enum.sort_by(& &1.construction.symbol)
          |> Enum.reduce({[], []}, fn observation, {candidates, limitations} ->
            case construction_evidence(observation, as_of) do
              {:ok, construction, valid_until} ->
                proposed =
                  for %{required: required, fulfilled: fulfilled, trade_symbol: symbol} <-
                        construction.materials || [],
                      is_binary(symbol) and is_integer(required) and is_integer(fulfilled),
                      remaining = max(required - fulfilled, 0),
                      remaining > 0,
                      ship <- ships,
                      %{symbol: ship_symbol, cargo: %{capacity: capacity}} <- [ship],
                      is_integer(capacity) and capacity > 0,
                      listing <-
                        listings ++ held_construction_cargo(ship, symbol, construction, as_of),
                      Map.get(listing, :ship_symbol, ship_symbol) == ship_symbol,
                      listing.trade_symbol == symbol,
                      is_binary(listing.waypoint) and is_binary(listing.evidence_id),
                      is_integer(listing.purchase_price) and listing.purchase_price >= 0,
                      is_integer(listing.trade_volume) and listing.trade_volume > 0,
                      %DateTime{} = observed_at <- [listing.observed_at],
                      DateTime.diff(as_of, observed_at, :second) in 0..@market_evidence_freshness_seconds,
                      batch = min(remaining, min(capacity, listing.trade_volume)),
                      cost = batch * listing.purchase_price,
                      cost + 750 <= credits do
                    listing_until =
                      DateTime.add(observed_at, @market_evidence_freshness_seconds, :second)

                    expires_at = Enum.min_by([valid_until, listing_until], &DateTime.to_unix/1)

                    %CandidateContribution{
                      id:
                        Evidence.fingerprint(
                          {revision.id, index, construction.symbol, symbol, ship_symbol, required,
                           fulfilled, listing.waypoint, listing.purchase_price,
                           listing.trade_volume, Map.get(listing, :source, :market)}
                        ),
                      strategy_revision_id: revision.id,
                      objective_index: index,
                      objective: objective,
                      kind: :construction_delivery,
                      trade_symbol: symbol,
                      source_waypoint: listing.waypoint,
                      destination_waypoint: construction.symbol,
                      expected_outcomes: %{
                        decision_value: 1,
                        units_remaining: remaining,
                        batch_units: batch
                      },
                      uncertainty: %{shared_progress: :may_change},
                      required_roles: [%{role: :construction_courier, count: 1}],
                      required_capabilities: [
                        %{capability: :cargo_transport, minimum_capacity: batch},
                        %{capability: :resource_ship, value: ship_symbol}
                      ],
                      required_resources: %{ship_count: 1, credits: cost + 750},
                      dependencies: [
                        %{
                          subject:
                            "construction:#{observation.system_symbol}:#{construction.symbol}",
                          evidence_id: observation.evidence_id,
                          valid_until: valid_until
                        },
                        %{
                          subject: "market:#{listing.waypoint}",
                          evidence_id: listing.evidence_id,
                          valid_until: listing_until
                        }
                      ],
                      validity: %{
                        as_of: as_of,
                        expires_at: expires_at,
                        conditions: [
                          %{fact: :remaining_material, trade_symbol: symbol, minimum: batch}
                        ]
                      },
                      alternatives: [],
                      construction: %{
                        system: observation.system_symbol,
                        waypoint: construction.symbol,
                        units_remaining: remaining,
                        batch_units: batch,
                        max_price: listing.purchase_price,
                        source: Map.get(listing, :source, :market)
                      }
                    }
                  end

                upstream =
                  upstream_contributions(
                    revision,
                    index,
                    objective,
                    observation,
                    as_of,
                    valid_until,
                    ships,
                    listings,
                    credits,
                    Map.get(snapshot, :upstream_opportunities, [])
                  )

                transfers =
                  for %{required: required, fulfilled: fulfilled, trade_symbol: symbol} <-
                        construction.materials || [],
                      is_binary(symbol) and is_integer(required) and is_integer(fulfilled),
                      required > fulfilled,
                      pair <-
                        transfer_contributions(
                          revision,
                          index,
                          objective,
                          :construction_delivery,
                          %{
                            waypoint: construction.symbol,
                            system: observation.system_symbol,
                            symbol: symbol,
                            remaining: required - fulfilled,
                            credits: credits,
                            evidence: %{
                              subject:
                                "construction:#{observation.system_symbol}:#{construction.symbol}",
                              evidence_id: observation.evidence_id,
                              valid_until: valid_until
                            }
                          },
                          ships
                        ),
                      do: pair

                {candidates ++ proposed ++ upstream ++ transfers, limitations}

              {:error, reason} ->
                {candidates,
                 limitations ++ [%{subject: observation.construction.symbol, reason: reason}]}
            end
          end)
        else
          {[], [%{subject: :construction_planning, reason: :unsupported_construction_objective}]}
        end

      {:ok,
       result(revision, index, %{as_of: as_of},
         candidate_contributions:
           Enum.sort_by(
             candidates,
             &{if(&1.construction.source == :cargo, do: 0, else: 1), &1.id}
           ),
         limitations: limitations
       )}
    end
  end

  def plan_construction(_revision, _index, _snapshot),
    do: {:error, :invalid_construction_planning_input}

  defp construction_evidence(%{construction: %{is_complete: true}}, _as_of),
    do: {:error, :construction_complete}

  defp construction_evidence(
         %{
           construction: %{is_complete: false, materials: materials} = construction,
           observed_at: %DateTime{} = observed_at,
           evidence_id: id,
           system_symbol: system
         },
         as_of
       )
       when is_list(materials) and is_binary(id) and id != "" and is_binary(system) do
    if DateTime.diff(as_of, observed_at, :second) in 0..@market_evidence_freshness_seconds,
      do:
        {:ok, construction,
         DateTime.add(observed_at, @market_evidence_freshness_seconds, :second)},
      else: {:error, :stale_construction_evidence}
  end

  defp construction_evidence(_, _), do: {:error, :construction_evidence_unavailable}

  defp held_construction_cargo(
         %{symbol: ship_symbol, cargo: %{inventory: inventory}},
         symbol,
         construction,
         as_of
       )
       when is_list(inventory) do
    case Enum.find(inventory, &(&1.symbol == symbol)) do
      %{units: units} when is_integer(units) and units > 0 ->
        [
          %{
            waypoint: construction.symbol,
            trade_symbol: symbol,
            purchase_price: 0,
            trade_volume: units,
            observed_at: as_of,
            ship_symbol: ship_symbol,
            source: :cargo,
            evidence_id: Evidence.fingerprint({ship_symbol, symbol, units})
          }
        ]

      _ ->
        []
    end
  end

  defp held_construction_cargo(_, _, _, _), do: []

  defp transfer_contributions(revision, index, objective, kind, recipient, ships) do
    for source <- ships,
        target <- ships,
        source.symbol != target.symbol,
        %{waypoint_symbol: waypoint, status: source_status} <- [Map.get(source, :nav)],
        %{waypoint_symbol: ^waypoint, status: target_status} <- [Map.get(target, :nav)],
        source_status != "IN_TRANSIT" and target_status != "IN_TRANSIT",
        %{capacity: capacity, units: used} <- [Map.get(target, :cargo)],
        is_integer(capacity) and is_integer(used) and capacity > used,
        supply <- transfer_supply(source, recipient.symbol),
        batch = min(recipient.remaining, min(supply.units, capacity - used)),
        batch > 0,
        recipient.credits >= 750 do
      producer_id =
        Evidence.fingerprint(
          {revision.id, index, kind, recipient.waypoint, recipient.symbol, source.symbol,
           target.symbol, recipient.remaining, batch, supply.mode,
           Evidence.fingerprint(source.cargo)}
        )

      dependency_id = "transfer:#{producer_id}"
      recipient_dependency = recipient.evidence

      producer = %CandidateContribution{
        id: producer_id,
        strategy_revision_id: revision.id,
        objective_index: index,
        objective: objective,
        kind: :cargo_transfer,
        trade_symbol: recipient.symbol,
        source_waypoint: waypoint,
        destination_waypoint: waypoint,
        expected_outcomes: %{decision_value: 2, batch_units: batch},
        uncertainty: %{cargo: :authoritative_at_dispatch},
        required_roles: [%{role: :cargo_producer, count: 1}],
        required_capabilities:
          [%{capability: :resource_ship, value: source.symbol}] ++
            if(supply.mode == :refine,
              do: [%{capability: :resource_mode, value: :refine}],
              else: []
            ),
        required_resources: %{
          "cargo:#{source.symbol}:#{supply.reserved_symbol}" =>
            if(supply.mode == :held, do: batch, else: supply.reserved_units),
          ship_count: 1
        },
        dependencies: [recipient_dependency],
        validity: %{expires_at: recipient_dependency.valid_until},
        alternatives: [],
        transfer: %{source_ship: source.symbol, target_ship: target.symbol, units: batch},
        resource: supply.resource,
        contract: if(kind == :contract_delivery, do: %{source: :transfer}, else: nil),
        construction: if(kind == :construction_delivery, do: %{source: :transfer}, else: nil)
      }

      delivery = %CandidateContribution{
        id: Evidence.fingerprint({producer_id, :delivery}),
        strategy_revision_id: revision.id,
        objective_index: index,
        objective: objective,
        kind: kind,
        trade_symbol: recipient.symbol,
        source_waypoint: waypoint,
        destination_waypoint: recipient.waypoint,
        expected_outcomes: %{
          decision_value: 2,
          units_remaining: recipient.remaining,
          batch_units: batch
        },
        uncertainty: %{shared_progress: :may_change},
        required_roles: [
          %{
            role:
              if(kind == :contract_delivery, do: :contract_courier, else: :construction_courier),
            count: 1
          }
        ],
        required_capabilities: [
          %{capability: :resource_ship, value: target.symbol},
          %{capability: :cargo_transport, minimum_capacity: batch}
        ],
        required_resources: %{
          "cargo_capacity:#{target.symbol}" => batch,
          ship_count: 1,
          credits: 750
        },
        dependencies: [
          recipient_dependency,
          %{id: dependency_id, kind: :acquisition, candidate_id: producer_id, amount: batch}
        ],
        validity: %{expires_at: recipient_dependency.valid_until},
        alternatives: [],
        contract:
          if(kind == :contract_delivery,
            do: %{id: recipient.id, source: :transfer, batch_units: batch},
            else: nil
          ),
        construction:
          if(kind == :construction_delivery,
            do: %{
              system: recipient.system,
              waypoint: recipient.waypoint,
              source: :transfer,
              batch_units: batch
            },
            else: nil
          )
      }

      [producer, delivery]
    end
    |> List.flatten()
  end

  defp transfer_supply(%{cargo: %{inventory: inventory}} = ship, symbol)
       when is_list(inventory) do
    held =
      for %{symbol: ^symbol, units: units} <- inventory,
          is_integer(units) and units > 0,
          do: %{
            mode: :held,
            units: units,
            reserved_symbol: symbol,
            reserved_units: units,
            resource: nil
          }

    refinery? = refinery_capable?(ship)

    ore = Enum.find(inventory, &(&1.symbol == symbol <> "_ORE"))

    refined =
      if (refinery? and symbol in ~w(IRON COPPER SILVER GOLD ALUMINUM PLATINUM URANITE MERITIUM) and
            ore) && is_integer(ore.units) && ore.units >= 100,
         do: [
           %{
             mode: :refine,
             units: 10,
             reserved_symbol: symbol <> "_ORE",
             reserved_units: 100,
             resource: %{mode: :refine, produce: symbol, survey: nil}
           }
         ],
         else: []

    held ++ refined
  end

  defp transfer_supply(_, _), do: []

  # A recipe is not inferred from commodity names. The caller supplies an
  # independently observed market-effect hypothesis, whose baseline Listings
  # and Construction progress remain explicit validity conditions.
  defp upstream_contributions(
         revision,
         index,
         objective,
         observation,
         as_of,
         construction_until,
         ships,
         listings,
         credits,
         opportunities
       ) do
    construction = observation.construction

    for hypothesis <- opportunities,
        %{
          part_symbol: part,
          raw_symbol: raw,
          source_waypoint: source,
          destination_waypoint: destination,
          expected_part_units: units,
          expected_supply: supply,
          expected_purchase_price: price,
          evidence_id: hypothesis_id,
          observed_at: %DateTime{} = hypothesis_at
        } <- [hypothesis],
        is_binary(hypothesis_id) and hypothesis_id != "" and is_binary(part) and
          is_binary(raw) and is_binary(source) and is_binary(destination) and
          is_binary(supply) and is_integer(price) and price >= 0 and
          is_integer(units) and units > 0,
        DateTime.diff(as_of, hypothesis_at, :second) in 0..@market_evidence_freshness_seconds,
        %{required: required, fulfilled: fulfilled} <-
          Enum.filter(construction.materials || [], &(&1.trade_symbol == part)),
        is_integer(required) and is_integer(fulfilled) and required > fulfilled,
        part_listing <- listings,
        part_listing.waypoint == destination and part_listing.trade_symbol == part,
        is_binary(part_listing.evidence_id) and is_integer(part_listing.purchase_price) and
          (part_listing.purchase_price > price or
             (is_binary(Map.get(part_listing, :supply)) and
                Map.get(part_listing, :supply) != supply)),
        %DateTime{} = part_at <- [part_listing.observed_at],
        DateTime.diff(as_of, part_at, :second) in 0..@market_evidence_freshness_seconds,
        raw_listing <- listings,
        raw_listing.waypoint == source and raw_listing.trade_symbol == raw,
        is_binary(raw_listing.evidence_id) and is_integer(raw_listing.purchase_price) and
          raw_listing.purchase_price >= 0 and is_integer(raw_listing.trade_volume) and
          raw_listing.trade_volume > 0,
        %DateTime{} = raw_at <- [raw_listing.observed_at],
        DateTime.diff(as_of, raw_at, :second) in 0..@market_evidence_freshness_seconds,
        ship <- ships,
        %{symbol: ship_symbol, cargo: %{capacity: capacity}} <- [ship],
        is_integer(capacity) and capacity > 0,
        batch = min(units, min(raw_listing.trade_volume, capacity)),
        cost = batch * raw_listing.purchase_price,
        cost + 750 <= credits do
      dependencies = [
        %{
          subject: "construction:#{observation.system_symbol}:#{construction.symbol}",
          evidence_id: observation.evidence_id,
          valid_until: construction_until
        },
        %{
          subject: "market:#{source}",
          evidence_id: raw_listing.evidence_id,
          valid_until: DateTime.add(raw_at, @market_evidence_freshness_seconds, :second)
        },
        %{
          subject: "market:#{destination}",
          evidence_id: part_listing.evidence_id,
          valid_until: DateTime.add(part_at, @market_evidence_freshness_seconds, :second)
        },
        %{
          subject: "hypothesis:#{hypothesis_id}",
          evidence_id: hypothesis_id,
          valid_until: DateTime.add(hypothesis_at, @market_evidence_freshness_seconds, :second)
        }
      ]

      expires_at = dependencies |> Enum.map(& &1.valid_until) |> Enum.min_by(&DateTime.to_unix/1)

      %CandidateContribution{
        id:
          Evidence.fingerprint(
            {revision.id, index, construction.symbol, part, required, fulfilled, hypothesis_id,
             raw_listing.waypoint, raw_listing.purchase_price, part_listing.waypoint,
             part_listing.purchase_price, Map.get(part_listing, :supply), ship_symbol}
          ),
        strategy_revision_id: revision.id,
        objective_index: index,
        objective: objective,
        kind: :construction_upstream,
        trade_symbol: raw,
        source_waypoint: source,
        destination_waypoint: destination,
        expected_outcomes: %{
          decision_value:
            max(
              (part_listing.purchase_price - price) * batch,
              if(Map.get(part_listing, :supply) != supply, do: batch, else: 0)
            ),
          market_effect: %{
            part_symbol: part,
            supply: supply,
            purchase_price: price,
            expected_part_units: batch
          }
        },
        uncertainty: %{market_effect: :hypothesis, realized_effect: :requires_fresh_listing},
        required_roles: [%{role: :construction_supplier, count: 1}],
        required_capabilities: [
          %{capability: :cargo_transport, minimum_capacity: batch},
          %{capability: :resource_ship, value: ship_symbol}
        ],
        required_resources: %{ship_count: 1, credits: cost + 750},
        dependencies: dependencies,
        validity: %{
          as_of: as_of,
          expires_at: expires_at,
          conditions: [
            %{fact: :construction_remaining, trade_symbol: part, minimum: 1},
            %{fact: :part_purchase_price, operator: :greater_than, value: price}
          ]
        },
        alternatives: [],
        construction: %{
          system: observation.system_symbol,
          waypoint: construction.symbol,
          part_symbol: part,
          source: :upstream,
          batch_units: batch,
          max_price: raw_listing.purchase_price,
          baseline_price: part_listing.purchase_price,
          baseline_supply: Map.get(part_listing, :supply),
          hypothesis: hypothesis
        }
      }
    end
  end

  def construction_objective?(%{"objective" => description}) when is_binary(description),
    do: String.match?(description, ~r/\b(construction|jump gate)\b/i)

  def construction_objective?(_), do: false

  defp held_contract_cargo(
         %{symbol: ship_symbol, cargo: %{inventory: inventory}},
         good,
         contract,
         as_of
       )
       when is_list(inventory) do
    case Enum.find(inventory, &(&1.symbol == good.trade_symbol)) do
      %{units: units} when is_integer(units) and units > 0 ->
        [
          %{
            waypoint: good.destination_symbol,
            trade_symbol: good.trade_symbol,
            purchase_price: 0,
            trade_volume: units,
            observed_at: as_of,
            evidence_id:
              Evidence.fingerprint({contract.id, ship_symbol, good.trade_symbol, units}),
            ship_symbol: ship_symbol,
            source: :cargo
          }
        ]

      _ ->
        []
    end
  end

  defp held_contract_cargo(_, _, _, _), do: []

  defp resource_contribution(
         revision,
         index,
         objective,
         ship,
         waypoint,
         surveys,
         as_of,
         freshness
       ) do
    with %{
           symbol: ship_symbol,
           nav: %{system_symbol: system},
           cargo: cargo,
           mounts: mounts,
           modules: modules,
           cooldown: cooldown
         } <- ship,
         %{
           symbol: symbol,
           subject: {:waypoint, ^system, waypoint_symbol},
           facts: %{"type" => type_fact}
         } <-
           waypoint,
         true <- symbol == waypoint_symbol,
         %{
           state: "known",
           freshness: :fresh,
           value: type,
           observed_at: %DateTime{} = observed_at,
           observation_id: evidence_id
         } <- type_fact,
         true <- DateTime.compare(observed_at, as_of) != :gt,
         true <- DateTime.diff(as_of, observed_at, :second) <= freshness,
         true <- is_integer(cargo.capacity) and is_integer(cargo.units),
         true <- not cooldown_active?(cooldown, as_of),
         mode when not is_nil(mode) <- resource_mode(type, mounts || [], modules || [], cargo),
         survey <- Enum.find(surveys, &usable_survey?(&1, symbol, as_of)) do
      {kind, produced, consumed} = mode
      required = if kind == :refine, do: 100, else: 1

      capacity =
        if kind == :refine,
          do: cargo.capacity - cargo.units + 100,
          else: cargo.capacity - cargo.units

      if capacity < required or (kind == :refine and ship.nav.waypoint_symbol != symbol) do
        nil
      else
        dependency = %{
          subject: "waypoint:#{ship.nav.system_symbol}:#{symbol}",
          required_facts: ["type"],
          observed_at: observed_at,
          evidence_id: to_string(evidence_id),
          source: type_fact.source,
          valid_until: DateTime.add(observed_at, freshness, :second)
        }

        %CandidateContribution{
          id:
            Evidence.fingerprint(
              {revision.id, index, ship_symbol, kind, produced, symbol, evidence_id,
               survey && survey.signature}
            ),
          strategy_revision_id: revision.id,
          objective_index: index,
          objective: objective,
          kind: :resource_acquisition,
          trade_symbol: produced,
          source_waypoint: symbol,
          destination_waypoint: symbol,
          expected_outcomes: %{
            cargo_units: if(kind == :refine, do: 10, else: 1),
            decision_value: if(ship.nav.waypoint_symbol == symbol, do: 2, else: 1),
            trade_symbol: produced
          },
          uncertainty: %{yield: :game_determined, consumed: consumed},
          required_roles: [%{role: :resource_gatherer, count: 1}],
          required_capabilities: [
            %{capability: :resource_mode, value: kind},
            %{capability: :resource_ship, value: ship.symbol}
          ],
          required_resources: %{ship_count: 1},
          dependencies: [dependency],
          validity: %{as_of: as_of, expires_at: dependency.valid_until},
          alternatives: [],
          # The optional Survey remains evidence-bound and is rechecked at dispatch.
          resource: %{mode: kind, produce: produced, survey: survey && survey_payload(survey)}
        }
      end
    else
      _ -> nil
    end
  end

  defp resource_mode(type, mounts, modules, cargo) do
    refinery? =
      Enum.any?(
        modules,
        &(&1.symbol in ~w(MODULE_MINERAL_PROCESSOR_I MODULE_MICRO_REFINERY_I MODULE_ORE_REFINERY_I))
      )

    cond do
      refinery? and
          Enum.any?(
            ~w(IRON COPPER SILVER GOLD ALUMINUM PLATINUM URANITE MERITIUM),
            &(cargo_units(cargo, &1 <> "_ORE") >= 100)
          ) ->
        produce =
          Enum.find(
            ~w(IRON COPPER SILVER GOLD ALUMINUM PLATINUM URANITE MERITIUM),
            &(cargo_units(cargo, &1 <> "_ORE") >= 100)
          )

        {:refine, produce, produce <> "_ORE"}

      type in ["ASTEROID", "ENGINEERED_ASTEROID", "ASTEROID_FIELD", "DEBRIS_FIELD"] and
          Enum.any?(mounts, &String.starts_with?(&1.symbol, "MOUNT_MINING_LASER")) ->
        {:extract, nil, nil}

      type == "GAS_GIANT" and
          Enum.any?(mounts, &String.starts_with?(&1.symbol, "MOUNT_GAS_SIPHON")) ->
        {:siphon, nil, nil}

      true ->
        nil
    end
  end

  defp cargo_units(cargo, symbol) do
    case Enum.find(cargo.inventory || [], &(&1.symbol == symbol)) do
      %{units: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp cooldown_active?(%{remaining_seconds: seconds}, _as_of)
       when is_integer(seconds) and seconds > 0,
       do: true

  defp cooldown_active?(_, _), do: false

  defp usable_survey?(
         %{symbol: symbol, signature: signature, expiration: expiration},
         symbol,
         as_of
       )
       when is_binary(signature) and is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, expires, _} -> DateTime.compare(expires, as_of) == :gt
      _ -> false
    end
  end

  defp usable_survey?(_, _, _), do: false

  defp survey_payload(survey) do
    %{
      "symbol" => survey.symbol,
      "signature" => survey.signature,
      "expiration" => survey.expiration,
      "size" => survey.size,
      "deposits" => Enum.map(survey.deposits || [], &%{"symbol" => &1.symbol})
    }
  end

  defp intelligence_opportunity(opportunity, system, as_of, freshness) when is_map(opportunity) do
    with subject when is_binary(subject) <- Map.get(opportunity, :subject),
         [type, ^system, waypoint] when type in ["market", "shipyard", "waypoint"] <-
           String.split(subject, ":"),
         true <- String.starts_with?(waypoint, system <> "-"),
         facts when is_list(facts) and facts != [] <- Map.get(opportunity, :required_facts),
         true <- Enum.all?(facts, &(is_binary(&1) and &1 != "")),
         observed when is_map(observed) <- Map.get(opportunity, :facts),
         acquisition when acquisition in [:public, :on_site] <-
           Map.get(opportunity, :acquisition),
         capabilities when is_list(capabilities) <-
           Map.get(opportunity, :required_capabilities, []),
         true <- Enum.all?(capabilities, &valid_capability?/1),
         value when is_number(value) and value >= 0 <-
           Map.get(opportunity, :expected_decision_value),
         api_cost when is_number(api_cost) and api_cost >= 0 <-
           Map.get(opportunity, :api_capacity_cost),
         ship_cost when is_number(ship_cost) and ship_cost >= 0 <-
           Map.get(opportunity, :ship_time_cost),
         true <- is_integer(freshness) and freshness >= 0 do
      missing = Enum.reject(facts, &fresh_intelligence?(observed[&1], as_of, freshness))
      net = value - api_cost - ship_cost

      cond do
        missing == [] ->
          {:ok, :satisfied}

        net <= 0 ->
          {:error, :acquisition_cost_exceeds_value}

        true ->
          {:ok, %{net_value: net, type: type, waypoint: waypoint, capabilities: capabilities}}
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp intelligence_opportunity(_opportunity, _system, _as_of, _freshness),
    do: {:error, :invalid}

  defp valid_capability?(%{capability: capability}) when is_atom(capability), do: true
  defp valid_capability?(_capability), do: false

  defp fresh_intelligence?(
         %{state: "known", observed_at: %DateTime{} = observed_at},
         as_of,
         freshness
       ) do
    age = DateTime.diff(as_of, observed_at, :second)
    age >= 0 and age <= freshness
  end

  defp fresh_intelligence?(_fact, _as_of, _freshness), do: false

  defp intelligence_contribution(revision, index, objective, choice, opportunity, deadline) do
    %CandidateContribution{
      id:
        Evidence.fingerprint(
          {revision.id, index, opportunity.subject, opportunity.required_facts}
        ),
      strategy_revision_id: revision.id,
      objective_index: index,
      objective: objective,
      kind: :intelligence_acquisition,
      trade_symbol: nil,
      source_waypoint: nil,
      destination_waypoint: choice.waypoint,
      expected_outcomes: %{decision_value: choice.net_value},
      uncertainty: %{decision_value_estimate: opportunity.expected_decision_value},
      required_roles: [%{role: :intelligence_scout, count: 1}],
      required_capabilities: choice.capabilities,
      required_resources: %{ship_count: 1, credits: 0},
      dependencies: [],
      validity: %{as_of: DateTime.add(deadline, -60, :second), expires_at: deadline},
      alternatives: []
    }
  end

  defp plan_market_objective(revision, objective_index, objective, snapshot) do
    {markets, demands, limitations} = classify_markets(revision, objective_index, snapshot)

    candidates =
      markets
      |> candidate_routes(revision, objective_index, objective, snapshot)
      |> add_alternatives()

    limitations =
      if candidates == [] and limitations == [] do
        reason =
          if length(markets) < 2,
            do: :insufficient_market_evidence,
            else: :no_viable_market_routes

        [%{subject: :market_planning, reason: reason}]
      else
        limitations
      end

    {:ok,
     result(revision, objective_index, snapshot,
       candidate_contributions: candidates,
       observation_demands: demands,
       limitations: limitations
     )}
  end

  defp result(revision, objective_index, snapshot, overrides) do
    Map.merge(
      %{
        strategy_revision_id: revision.id,
        objective_index: objective_index,
        evidence_as_of: snapshot.as_of,
        candidate_contributions: [],
        observation_demands: [],
        limitations: []
      },
      Map.new(overrides)
    )
  end

  defp objective_at(%Revision{document: %{"objectives" => objectives}}, objective_index)
       when is_list(objectives) do
    case Enum.fetch(objectives, objective_index) do
      {:ok, objective} when is_map(objective) -> {:ok, objective}
      _ -> {:error, :objective_not_found}
    end
  end

  defp objective_at(_revision, _objective_index), do: {:error, :objective_not_found}

  defp normalize_snapshot(
         %{
           as_of: %DateTime{} = as_of,
           system_symbol: system_symbol,
           freshness_seconds: freshness_seconds,
           markets: markets
         } = snapshot
       )
       when is_binary(system_symbol) and system_symbol != "" and is_integer(freshness_seconds) and
              freshness_seconds >= 0 and is_list(markets) do
    demand_deadline_seconds = Map.get(snapshot, :demand_deadline_seconds, 60)
    observation_costs = Map.get(snapshot, :observation_costs, %{})

    if is_integer(demand_deadline_seconds) and demand_deadline_seconds >= 0 and
         is_map(observation_costs) and
         Enum.all?(observation_costs, fn {subject, cost} ->
           is_binary(subject) and is_map(cost) and
             is_number(cost[:api_capacity_cost]) and cost[:api_capacity_cost] >= 0 and
             is_number(cost[:ship_time_cost]) and cost[:ship_time_cost] >= 0
         end) and
         Enum.all?(
           markets,
           &(is_map(&1) and valid_market_subject?(market_subject(&1), system_symbol))
         ) do
      {:ok,
       %{
         as_of: as_of,
         system_symbol: system_symbol,
         freshness_seconds: freshness_seconds,
         demand_deadline_seconds: demand_deadline_seconds,
         observation_costs: observation_costs,
         agent_id: Map.get(snapshot, :agent_id),
         markets: normalize_market_observations(markets)
       }}
    else
      {:error, :invalid_market_planning_input}
    end
  end

  defp normalize_snapshot(_snapshot), do: {:error, :invalid_market_planning_input}

  defp normalize_market_observations(markets) do
    markets
    |> Enum.group_by(&market_subject/1)
    |> Enum.map(fn {_subject, observations} ->
      Enum.max_by(observations, fn observation ->
        {observed_at_sort_value(observation), Evidence.fingerprint(observation)}
      end)
    end)
    |> Enum.sort_by(&market_subject/1)
  end

  defp observed_at_sort_value(%{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_at_sort_value(_observation), do: -1

  defp classify_markets(revision, objective_index, snapshot) do
    snapshot.markets
    |> Enum.reduce({[], [], []}, fn market, {markets, demands, limitations} ->
      subject = market_subject(market)

      case usable_market(market, snapshot) do
        {:ok, market} ->
          {[market | markets], demands, limitations}

        {:error, reason} ->
          demands =
            case market_demand_value(market, snapshot) do
              value when is_number(value) and value > 0 ->
                [
                  observation_demand(revision, objective_index, snapshot, subject, value)
                  | demands
                ]

              _ ->
                demands
            end

          limitation = %{subject: subject, reason: reason}
          {markets, demands, [limitation | limitations]}
      end
    end)
    |> then(fn {markets, demands, limitations} ->
      {
        Enum.sort_by(markets, &{&1.subject, &1.observed_at}),
        demands |> Enum.uniq_by(& &1.subject) |> Enum.sort_by(& &1.subject),
        limitations
        |> Enum.uniq_by(&{&1.subject, &1.reason})
        |> Enum.sort_by(&{&1.subject, &1.reason})
      }
    end)
  end

  defp usable_market(
         %{observed_at: %DateTime{} = observed_at, trade_goods: trade_goods} = market,
         snapshot
       )
       when is_list(trade_goods) do
    age = DateTime.diff(snapshot.as_of, observed_at, :second)
    goods = trade_goods |> Enum.map(&normalize_good/1) |> Enum.filter(&valid_good?/1)

    cond do
      age < 0 ->
        {:error, :inconsistent_market_evidence}

      value(market, :state) == :stale ->
        {:error, :stale_market_evidence}

      age > snapshot.freshness_seconds ->
        {:error, :stale_market_evidence}

      length(goods) != length(trade_goods) ->
        {:error, :insufficient_market_evidence}

      not valid_provenance?(market) ->
        {:error, :insufficient_market_evidence}

      true ->
        {:ok,
         %{
           subject: market_subject(market),
           waypoint: waypoint_from_subject(market_subject(market)),
           observed_at: observed_at,
           evidence_age_seconds: age,
           evidence_id: value(market, :evidence_id),
           source: value(market, :source),
           trade_goods: Enum.sort_by(goods, &good_key/1)
         }}
    end
  end

  defp usable_market(_market, _snapshot), do: {:error, :insufficient_market_evidence}

  defp normalize_good(good) when is_map(good) do
    %{
      symbol: value(good, :symbol),
      purchase_price: value(good, :purchase_price),
      sell_price: value(good, :sell_price),
      trade_volume: value(good, :trade_volume),
      supply: value(good, :supply),
      activity: value(good, :activity)
    }
  end

  defp normalize_good(_good), do: %{}

  defp valid_good?(good) do
    is_binary(good[:symbol]) and is_integer(good[:purchase_price]) and
      good.purchase_price >= 0 and is_integer(good[:sell_price]) and good.sell_price >= 0 and
      is_integer(good[:trade_volume]) and good.trade_volume > 0
  end

  defp candidate_routes(markets, revision, objective_index, objective, snapshot) do
    candidates =
      for source <- markets,
          destination <- markets,
          source.subject != destination.subject,
          source_good <- source.trade_goods,
          destination_good <- destination.trade_goods,
          source_good.symbol == destination_good.symbol,
          destination_good.sell_price > source_good.purchase_price do
        contribution(
          revision,
          objective_index,
          objective,
          source,
          source_good,
          destination,
          destination_good,
          snapshot
        )
      end

    candidates
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(fn candidate ->
      {
        -candidate.expected_outcomes.maximum_credit_change,
        -candidate.expected_outcomes.credit_change_per_unit,
        candidate.source_waypoint,
        candidate.destination_waypoint,
        candidate.trade_symbol,
        candidate.id
      }
    end)
  end

  defp contribution(
         revision,
         objective_index,
         objective,
         source,
         source_good,
         destination,
         destination_good,
         snapshot
       ) do
    units = min(source_good.trade_volume, destination_good.trade_volume)
    spread = destination_good.sell_price - source_good.purchase_price

    expected_outcomes = %{
      credit_change_per_unit: spread,
      maximum_credit_change: spread * units,
      maximum_units: units
    }

    dependencies =
      [dependency(source, snapshot), dependency(destination, snapshot)]
      |> Enum.sort_by(& &1.subject)

    required_resources = %{
      credits: source_good.purchase_price * units,
      cargo_capacity: units,
      ship_count: 1
    }

    identity = %{
      strategy_revision_id: revision.id,
      objective_index: objective_index,
      trade_symbol: source_good.symbol,
      source: source.subject,
      destination: destination.subject,
      expected_outcomes: expected_outcomes,
      required_resources: required_resources,
      dependencies: dependencies
    }

    %CandidateContribution{
      id: Evidence.fingerprint(identity),
      strategy_revision_id: revision.id,
      objective_index: objective_index,
      objective: objective,
      kind: :market_trade,
      trade_symbol: source_good.symbol,
      source_waypoint: source.waypoint,
      destination_waypoint: destination.waypoint,
      expected_outcomes: expected_outcomes,
      uncertainty: %{
        source_evidence_age_seconds: source.evidence_age_seconds,
        destination_evidence_age_seconds: destination.evidence_age_seconds,
        source_market_signal: market_signal(source_good),
        destination_market_signal: market_signal(destination_good),
        unaccounted_costs: [:fuel, :travel_time]
      },
      required_roles: [%{role: :market_trader, count: 1}],
      required_capabilities: [
        %{capability: :cargo_transport, minimum_capacity: units},
        %{
          capability: :market_access,
          waypoints: Enum.sort([source.waypoint, destination.waypoint])
        }
      ],
      required_resources: required_resources,
      dependencies: dependencies,
      validity: %{
        as_of: snapshot.as_of,
        expires_at: Enum.min_by(dependencies, & &1.valid_until, DateTime).valid_until,
        conditions: [
          %{fact: :source_purchase_price, operator: :equals, value: source_good.purchase_price},
          %{fact: :destination_sell_price, operator: :equals, value: destination_good.sell_price},
          %{fact: :positive_spread, operator: :greater_than, value: 0}
        ]
      },
      alternatives: []
    }
  end

  defp dependency(market, snapshot) do
    %{
      subject: market.subject,
      required_facts: ["trade_goods"],
      observed_at: market.observed_at,
      evidence_id: market.evidence_id,
      source: market.source,
      freshness_seconds: snapshot.freshness_seconds,
      valid_until: DateTime.add(market.observed_at, snapshot.freshness_seconds, :second)
    }
  end

  defp market_demand_value(market, snapshot) do
    subject = market_subject(market)

    with %{api_capacity_cost: api_cost, ship_time_cost: ship_cost}
         when is_number(api_cost) and api_cost >= 0 and is_number(ship_cost) and ship_cost >= 0 <-
           snapshot.observation_costs[subject],
         %DateTime{} = observed_at <- value(market, :observed_at),
         true <- DateTime.compare(observed_at, snapshot.as_of) in [:eq, :lt],
         goods when is_list(goods) <- value(market, :trade_goods),
         true <- valid_provenance?(market) do
      source_goods = goods |> Enum.map(&normalize_good/1) |> Enum.filter(&valid_good?/1)

      gross =
        for source_good <- source_goods,
            other <- snapshot.markets,
            market_subject(other) != subject,
            other_good <- market_goods(other, snapshot.as_of),
            destination_good = normalize_good(other_good),
            valid_good?(destination_good),
            source_good.symbol == destination_good.symbol do
          max(
            destination_good.sell_price - source_good.purchase_price,
            source_good.sell_price - destination_good.purchase_price
          ) *
            min(source_good.trade_volume, destination_good.trade_volume)
        end

      Enum.max(gross, fn -> 0 end) - api_cost - ship_cost
    else
      _ -> nil
    end
  end

  defp market_goods(market, as_of) do
    observed_at = value(market, :observed_at)
    goods = value(market, :trade_goods)

    if is_struct(observed_at, DateTime) and
         DateTime.compare(observed_at, as_of) in [:eq, :lt] and
         valid_provenance?(market) and is_list(goods),
       do: goods,
       else: []
  end

  defp observation_demand(revision, objective_index, snapshot, subject, expected_value) do
    %Demand{
      subject: subject,
      required_facts: ["trade_goods"],
      owner: "fleet_planning",
      deadline_at: DateTime.add(snapshot.as_of, snapshot.demand_deadline_seconds, :second),
      freshness_seconds: snapshot.freshness_seconds,
      agent_id: snapshot.agent_id,
      strategy_revision_id: revision.id,
      strategic_priority: objective_index,
      expected_value: expected_value,
      discovery: false
    }
  end

  defp add_alternatives(candidates) do
    alternatives = Map.new(candidates, &{&1.id, alternative(&1)})

    Enum.map(candidates, fn candidate ->
      candidate_alternatives =
        candidates
        |> Enum.reject(&(&1.id == candidate.id))
        |> Enum.map(&Map.fetch!(alternatives, &1.id))

      %{candidate | alternatives: candidate_alternatives}
    end)
  end

  defp alternative(candidate) do
    Map.take(candidate, [
      :id,
      :trade_symbol,
      :source_waypoint,
      :destination_waypoint,
      :expected_outcomes
    ])
  end

  defp market_signal(good) do
    %{supply: good.supply, activity: good.activity, trade_volume: good.trade_volume}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp valid_provenance?(market) do
    is_binary(value(market, :evidence_id)) and value(market, :evidence_id) != "" and
      is_binary(value(market, :source)) and value(market, :source) != ""
  end

  defp market_objective?(%{"kind" => "continuous"} = objective) do
    [objective["objective"], objective["evaluation"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&Regex.match?(~r/\bcredits?\b/i, &1))
  end

  defp market_objective?(_objective), do: false

  defp good_key(good) do
    {good.symbol, good.purchase_price, good.sell_price, good.trade_volume, good.supply,
     good.activity}
  end

  defp market_subject(market) when is_map(market) do
    value(market, :subject) || ""
  end

  defp market_subject(_market), do: ""

  defp valid_market_subject?(subject, expected_system) when is_binary(subject) do
    case String.split(subject, ":") do
      ["market", ^expected_system, waypoint] ->
        String.starts_with?(waypoint, expected_system <> "-")

      _ ->
        false
    end
  end

  defp valid_market_subject?(_subject, _expected_system), do: false

  defp waypoint_from_subject(subject), do: subject |> String.split(":") |> List.last()
end
