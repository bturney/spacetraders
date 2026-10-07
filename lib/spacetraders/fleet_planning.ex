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
  alias SpaceTraders.MarketSpending
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
    defstruct @enforce_keys ++
                [
                  resource: nil,
                  contract: nil,
                  construction: nil,
                  transfer: nil,
                  ship: nil,
                  refit: nil,
                  coverage: nil
                ]

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
  Baseline Market coverage input for one planning snapshot.

  `baseline_subjects` is the authoritative Market coverage target: every
  currently known Marketplace of the Fleet Generation's headquarters System.
  A subject in `unreachable_subjects` has no admissible acquisition path
  under current capability evidence; it stays unresolved coverage and can
  never support a negative System-wide Market conclusion. Without coverage
  input a snapshot targets its own Market subjects, which keeps legacy
  callers' conclusions unchanged.
  """
  def baseline_coverage(baseline_subjects, unreachable_subjects \\ [])
      when is_list(baseline_subjects) and is_list(unreachable_subjects) do
    %{baseline_subjects: baseline_subjects, unreachable_subjects: unreachable_subjects}
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

  @doc """
  Proposes Market Candidate Contributions for a not-yet-activated draft document.

  Draft planning is deterministic and evidence-bound exactly like revision
  planning. The candidates carry no accepted Revision identity because the
  document has not been activated.
  """
  def plan_draft_market(document, objective_index, snapshot) when is_map(document) do
    plan_market(%Revision{document: document}, objective_index, snapshot)
  end

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
      |> Enum.reduce_while({[], [], [], []}, fn opportunity,
                                                {candidates, demands, limitations, coverage} ->
        case intelligence_opportunity(opportunity, system, as_of, freshness) do
          {:ok, :satisfied} ->
            {:cont, {candidates, demands, limitations, coverage}}

          {:ok, %{coverage: true} = choice} ->
            # One bounded Coverage Contribution collects every open initial
            # Marketplace subject; each contributes one Observation Demand so
            # the subjects stay independently attributable.
            demand =
              coverage_demand(revision, objective_index, snapshot, choice, as_of, freshness)

            {:cont, {candidates, [demand | demands], limitations, [choice | coverage]}}

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

            {:cont, {candidates, [demand | demands], limitations, coverage}}

          {:error, :acquisition_cost_exceeds_value} ->
            {:cont,
             {candidates, demands,
              [
                %{subject: opportunity.subject, reason: :acquisition_cost_exceeds_value}
                | limitations
              ], coverage}}

          {:error, :invalid} ->
            {:halt, :invalid}
        end
      end)
      |> case do
        :invalid ->
          {:error, :invalid_intelligence_planning_input}

        {candidates, demands, limitations, coverage} ->
          candidates =
            case coverage_contribution(revision, objective_index, objective, coverage, as_of) do
              nil -> candidates
              contribution -> [contribution | candidates]
            end

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

  @doc """
  Proposes evidence-bound Ship Offer purchases without claiming a not-yet-owned Ship.

  The game only sells a Ship when an owned Ship is already present at the
  Shipyard's Waypoint, so a Shipyard without a co-located Ship is inadmissible
  rather than merely expensive. Its unmet precondition is reported as a
  limitation so the prerequisite is visible instead of dispatching a purchase
  that cannot succeed.

  Preparation Exposure is derived from the offer's own frame: every empty
  module slot and mounting point owes the Shipyard's modification fee, and that
  cost is reserved with the purchase so later readiness work keeps its headroom.
  Pass `:preparation_credits` to override the derived reserve.
  """
  def plan_ship_acquisition(
        %Revision{} = revision,
        index,
        %{as_of: %DateTime{} = as_of, credits: credits, shipyards: shipyards} = snapshot
      )
      when is_integer(index) and index >= 0 and is_integer(credits) and credits >= 0 and
             is_list(shipyards) do
    with {:ok, objective} <- objective_at(revision, index),
         true <- ship_acquisition_objective?(objective) do
      override = Map.get(snapshot, :preparation_credits)
      owned_ships = Map.get(snapshot, :ships, [])

      if preparation_override_valid?(override) do
        context = %{
          revision: revision,
          index: index,
          objective: objective,
          as_of: as_of,
          override: override,
          owned_ships: owned_ships,
          credits: credits
        }

        {candidates, unmet} =
          Enum.reduce(shipyards, {[], []}, fn yard, acc ->
            case shipyard_offer_evidence(yard, as_of) do
              {:ok, yard} -> plan_yard(context, yard, acc)
              :error -> acc
            end
          end)

        candidates =
          candidates
          |> Enum.sort_by(&{-&1.expected_outcomes.decision_value, &1.id})
          |> add_ship_acquisition_alternatives()

        {:ok,
         result(revision, index, %{as_of: as_of},
           candidate_contributions: candidates,
           limitations: Enum.reverse(unmet)
         )}
      else
        {:error, :invalid_ship_acquisition_planning_input}
      end
    else
      false ->
        {:ok,
         result(revision, index, %{as_of: as_of},
           limitations: [%{subject: :ship_acquisition, reason: :unsupported_ship_objective}]
         )}

      _ ->
        {:error, :invalid_ship_acquisition_planning_input}
    end
  end

  def plan_ship_acquisition(_revision, _index, _snapshot),
    do: {:error, :invalid_ship_acquisition_planning_input}

  @doc """
  Proposes evidence-bound Ship refit Candidates without claiming the refitting Ship.

  An install Candidate sources its module either from authoritative Cargo
  evidence or from a fresh Market Listing; it never assumes a module is in
  Cargo without that evidence, and it is inadmissible when the Listing is
  stale or the Agent cannot afford the purchase. A removal Candidate is
  admissible only with a proven release: the Operator's Revision must
  release that module on that Ship, authoritative readiness must still
  show it installed, and Cargo must have room for the removed unit.

  Because removing one module can remove every matching module, a removal
  Candidate is only valid with an `:all_matching` release scope and declares
  that uncertainty rather than promising a one-module outcome.
  """
  def plan_ship_refit(
        %Revision{} = revision,
        index,
        %{
          as_of: %DateTime{} = as_of,
          credits: credits,
          ships: ships,
          markets: markets,
          targets: targets,
          releases: releases
        }
      )
      when is_integer(index) and index >= 0 and is_integer(credits) and credits >= 0 and
             is_list(ships) and is_list(markets) and is_list(targets) and is_list(releases) do
    with {:ok, objective} <- objective_at(revision, index) do
      if ship_refit_objective?(objective) do
        fresh_markets = refit_supply(markets, as_of)

        {candidates, limitations} =
          for ship <- ships, reduce: {[], []} do
            {candidates, limitations} ->
              case refit_ship_candidates(
                     revision,
                     index,
                     objective,
                     as_of,
                     credits,
                     ship,
                     targets,
                     releases,
                     fresh_markets
                   ) do
                {:ok, ship_candidates, ship_limitations} ->
                  {ship_candidates ++ candidates, ship_limitations ++ limitations}
              end
          end

        candidates =
          candidates
          |> Enum.sort_by(
            &{-&1.expected_outcomes.decision_value, &1.expected_outcomes.expected_cost, &1.id}
          )
          |> add_ship_refit_alternatives()

        {:ok,
         result(revision, index, %{as_of: as_of},
           candidate_contributions: candidates,
           limitations: Enum.reverse(limitations)
         )}
      else
        {:ok,
         result(revision, index, %{as_of: as_of},
           limitations: [%{subject: :ship_refit, reason: :unsupported_ship_objective}]
         )}
      end
    end
  end

  def plan_ship_refit(_revision, _index, _snapshot),
    do: {:error, :invalid_ship_refit_planning_input}

  @doc false
  def ship_refit_objective?(objective) when is_map(objective) do
    Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
      is_binary(text) and String.match?(text, ~r/\brefit\b|\bmodule\b|\boutfit(ting)?\b/i)
    end)
  end

  def ship_refit_objective?(_), do: false

  # Retains only Markets whose Listing evidence is fresh at the decision time.
  defp refit_supply(markets, as_of) do
    Enum.flat_map(markets, fn market ->
      with %DateTime{} = observed_at <- Map.get(market, :observed_at),
           waypoint when is_binary(waypoint) <- Map.get(market, :waypoint),
           evidence_id when is_binary(evidence_id) <- Map.get(market, :evidence_id),
           goods when is_list(goods) <- Map.get(market, :trade_goods),
           true <- fresh?(observed_at, as_of) do
        [
          %{
            system_symbol: Map.get(market, :system_symbol),
            waypoint: waypoint,
            observed_at: observed_at,
            evidence_id: evidence_id,
            source: Map.get(market, :source) || "get_market",
            trade_goods: goods,
            valid_until: DateTime.add(observed_at, @market_evidence_freshness_seconds, :second)
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp fresh?(observed_at, as_of) do
    DateTime.diff(as_of, observed_at, :second) in 0..@market_evidence_freshness_seconds
  end

  defp refit_ship_candidates(
         revision,
         index,
         objective,
         as_of,
         credits,
         ship,
         targets,
         releases,
         fresh_markets
       ) do
    with {:ok, evidence} <- refit_ship_evidence(ship) do
      {installs, install_limitations} =
        install_candidates(targets, ship, evidence, fresh_markets, credits)

      {removals, removal_limitations} =
        removal_candidates(releases, ship, evidence, targets)

      candidates =
        Enum.map(
          installs ++ removals,
          &ship_refit_contribution(revision, index, objective, as_of, ship, &1)
        )

      {:ok, candidates, Enum.reverse(install_limitations ++ removal_limitations)}
    end
  end

  defp refit_ship_evidence(ship) do
    symbol = map_or_nil(ship, :symbol)
    nav = map_or_nil(ship, :nav)
    cargo = map_or_nil(ship, :cargo)
    modules = map_or_nil(ship, :modules)
    frame = map_or_nil(ship, :frame)
    module_slots = frame && map_or_nil(frame, :module_slots)

    cond do
      not is_binary(symbol) ->
        {:error, %{subject: :ship_refit, reason: :ship_identity_unavailable}}

      not is_map(nav) or not is_binary(Map.get(nav, :waypoint_symbol)) ->
        {:limitation, %{subject: symbol, reason: :ship_position_unavailable}}

      not is_map(cargo) or not is_integer(Map.get(cargo, :capacity)) or
          not is_integer(Map.get(cargo, :units)) ->
        {:limitation, %{subject: symbol, reason: :ship_cargo_unavailable}}

      not is_list(modules) or not is_integer(module_slots) ->
        {:limitation, %{subject: symbol, reason: :ship_readiness_unavailable}}

      true ->
        {:ok, %{symbol: symbol, cargo: cargo, modules: modules, module_slots: module_slots}}
    end
  end

  defp install_candidates(targets, ship, evidence, fresh_markets, credits) do
    for target <- targets, is_map(target), reduce: {[], []} do
      {candidates, limitations} ->
        case install_candidate(target, ship, evidence, fresh_markets, credits) do
          :satisfied ->
            {candidates, limitations}

          {:ok, target_candidates} ->
            {Enum.reverse(target_candidates) ++ candidates, limitations}

          {:limitation, limitation} ->
            {candidates, [limitation | limitations]}
        end
    end
    |> then(fn {candidates, limitations} -> {candidates, limitations} end)
  end

  defp install_candidate(target, _ship, evidence, fresh_markets, credits) do
    module_symbols = List.wrap(Map.get(target, :module_symbols, []))
    capability = Map.get(target, :capability)

    cond do
      module_symbols == [] or not is_atom(capability) ->
        {:limitation, %{subject: :ship_refit, reason: :invalid_refit_target}}

      Enum.any?(evidence.modules, &(&1.symbol in module_symbols)) ->
        # The declared capability is already met. The installed module is not
        # released, so no removal may be planned for it either.
        {:limitation, %{subject: evidence.symbol, reason: :refit_capability_already_met}}

      length(evidence.modules) >= evidence.module_slots ->
        {:limitation, %{subject: evidence.symbol, reason: :refit_module_slots_unavailable}}

      true ->
        install_sourcing(module_symbols, capability, evidence, fresh_markets, credits)
    end
  end

  defp install_sourcing(module_symbols, capability, evidence, fresh_markets, credits) do
    symbol = hd(module_symbols)
    cargo = evidence.cargo

    if cargo_units(cargo, symbol) >= 1 do
      {:ok,
       [
         %{
           action: :install,
           module_symbol: symbol,
           capability: capability,
           sourcing: :cargo,
           market: nil,
           purchase_price: 0,
           expected_cost: 0,
           installed_before: module_count(evidence.modules, symbol)
         }
       ]}
    else
      listings =
        Enum.filter(fresh_markets, fn listing ->
          Enum.any?(listing.trade_goods, &(Map.get(&1, :symbol) in module_symbols))
        end)

      cond do
        listings == [] ->
          {:limitation, %{subject: evidence.symbol, reason: :refit_supply_unavailable}}

        free_capacity(cargo) < 1 ->
          {:limitation, %{subject: evidence.symbol, reason: :refit_cargo_capacity_unmet}}

        true ->
          affordable =
            listings
            |> Enum.map(fn listing ->
              price = listing_price(listing, module_symbols)

              cond do
                not is_integer(price) ->
                  nil

                price > credits ->
                  {:limitation, %{subject: listing.waypoint, reason: :refit_supply_unaffordable}}

                true ->
                  %{
                    action: :install,
                    module_symbol: symbol,
                    capability: capability,
                    sourcing: :purchase,
                    market: listing.waypoint,
                    purchase_price: price,
                    expected_cost: price,
                    market_evidence: listing,
                    installed_before: module_count(evidence.modules, symbol)
                  }
              end
            end)
            |> Enum.reject(&is_nil/1)

          candidates = Enum.filter(affordable, &is_map(&1))

          cond do
            candidates != [] ->
              {:ok, candidates}

            true ->
              hd(affordable) ||
                {:limitation, %{subject: evidence.symbol, reason: :refit_supply_unavailable}}
          end
      end
    end
  end

  defp free_capacity(cargo), do: Map.get(cargo, :capacity) - Map.get(cargo, :units)

  defp listing_price(listing, module_symbols) do
    Enum.find_value(listing.trade_goods, fn good ->
      if map_or(good, :symbol) in module_symbols, do: map_or(good, :purchase_price)
    end)
  end

  defp removal_candidates(releases, ship, evidence, targets) do
    ship_symbol = map_or_nil(ship, :symbol)

    {candidates, limitations} =
      for release <- releases, is_map(release), reduce: {[], []} do
        {candidates, limitations} ->
          case removal_candidate(release, ship_symbol, evidence, targets) do
            :skip -> {candidates, limitations}
            {:ok, candidate} -> {[candidate | candidates], limitations}
            {:limitation, limitation} -> {candidates, [limitation | limitations]}
          end
      end

    {Enum.reverse(candidates), limitations}
  end

  defp removal_candidate(release, ship_symbol, evidence, targets) do
    module_symbol = Map.get(release, :module_symbol)
    released_ship = Map.get(release, :ship)

    cond do
      not is_binary(module_symbol) or not is_binary(released_ship) or released_ship != ship_symbol ->
        :skip

      Map.get(release, :scope) != :all_matching ->
        {:limitation, %{subject: ship_symbol, reason: :refit_release_unproven}}

      true ->
        installed = module_count(evidence.modules, module_symbol)
        capability = removal_capability(module_symbol, targets)

        cond do
          installed < 1 ->
            {:limitation, %{subject: ship_symbol, reason: :refit_release_unproven}}

          is_nil(capability) ->
            {:limitation, %{subject: module_symbol, reason: :refit_release_unproven}}

          Map.get(evidence.cargo, :capacity) - Map.get(evidence.cargo, :units) < 1 ->
            {:limitation, %{subject: ship_symbol, reason: :refit_cargo_capacity_unmet}}

          true ->
            {:ok,
             %{
               action: :remove,
               module_symbol: module_symbol,
               capability: capability,
               sourcing: nil,
               market: nil,
               purchase_price: 0,
               expected_cost: 0,
               removal_scope: :all_matching,
               installed_before: installed
             }}
        end
    end
  end

  defp removal_capability(module_symbol, targets) do
    Enum.find_value(targets, fn target ->
      if module_symbol in List.wrap(Map.get(target, :module_symbols, [])),
        do: Map.get(target, :capability)
    end)
  end

  defp ship_refit_contribution(revision, index, objective, as_of, ship, candidate) do
    symbol = map_or(ship, :symbol)
    action = candidate.action
    module_symbol = candidate.module_symbol

    {dependency, valid_until} =
      case candidate do
        %{market_evidence: listing} ->
          dependency = %{
            subject: "market:#{listing.system_symbol}:#{listing.waypoint}",
            required_facts: ["trade_goods"],
            observed_at: listing.observed_at,
            evidence_id: to_string(listing.evidence_id),
            source: listing.source,
            valid_until: listing.valid_until
          }

          {dependency, listing.valid_until}

        _ ->
          dependency = %{
            subject: "ship:#{symbol}",
            required_facts: ["cargo"],
            observed_at: as_of,
            evidence_id: "authoritative:ship:#{symbol}",
            source: "get_my_ship",
            valid_until: DateTime.add(as_of, @market_evidence_freshness_seconds, :second)
          }

          {dependency, DateTime.add(as_of, @market_evidence_freshness_seconds, :second)}
      end

    refit_waypoint =
      case candidate do
        %{action: :install, sourcing: :purchase, market: market} when is_binary(market) ->
          market

        _ ->
          map_or_nil(ship, :nav) && Map.get(map_or_nil(ship, :nav), :waypoint_symbol)
      end

    %CandidateContribution{
      id:
        Evidence.fingerprint(
          {revision.id, index, symbol, action, module_symbol, candidate.market,
           dependency.evidence_id}
        ),
      strategy_revision_id: revision.id,
      objective_index: index,
      objective: objective,
      kind: :ship_refit,
      trade_symbol: module_symbol,
      source_waypoint: refit_waypoint,
      destination_waypoint: refit_waypoint,
      expected_outcomes: %{
        action: action,
        capability: candidate.capability,
        module_symbol: module_symbol,
        expected_cost: candidate.expected_cost,
        decision_value: refit_decision_value(candidate)
      },
      uncertainty: refit_uncertainty(candidate),
      required_roles: [%{role: :fleet_refit, count: 1}],
      required_capabilities: [%{capability: :refit_ship, value: symbol}],
      required_resources: %{
        credits: refit_credits(candidate),
        cargo_capacity: 1,
        ship_count: 1
      },
      dependencies: [dependency],
      validity: %{as_of: as_of, expires_at: valid_until},
      alternatives: [],
      refit:
        Map.merge(
          Map.take(candidate, [
            :sourcing,
            :market,
            :purchase_price,
            :expected_cost,
            :removal_scope,
            :installed_before
          ]),
          %{action: action, module_symbol: module_symbol, capability: candidate.capability}
        )
    }
  end

  # A purchased module is a one-unit Market buy; reserve its calibrated worst case.
  defp refit_credits(%{action: :install, sourcing: :purchase, purchase_price: price})
       when is_integer(price) and price >= 0,
       do: MarketSpending.worst_case_exposure(price, 1)

  defp refit_credits(candidate), do: candidate.expected_cost

  defp refit_decision_value(%{action: :install, sourcing: :cargo}), do: 3
  defp refit_decision_value(%{action: :install}), do: 2
  defp refit_decision_value(%{action: :remove}), do: 1

  defp refit_uncertainty(%{action: :install, sourcing: :purchase}),
    do: %{supply: :market_listing}

  defp refit_uncertainty(%{action: :install}), do: %{supply: :authoritative_cargo}
  defp refit_uncertainty(%{action: :remove}), do: %{removed_units: :all_matching}

  defp add_ship_refit_alternatives(candidates) do
    Enum.map(candidates, fn candidate ->
      alternatives =
        candidates
        |> Enum.reject(&(&1.id == candidate.id))
        |> Enum.map(fn alternative ->
          %{
            id: alternative.id,
            trade_symbol: alternative.trade_symbol,
            source_waypoint: alternative.source_waypoint,
            destination_waypoint: alternative.destination_waypoint,
            expected_outcomes: alternative.expected_outcomes
          }
        end)

      %{candidate | alternatives: alternatives}
    end)
  end

  defp map_or(subject, key) when is_map(subject), do: Map.get(subject, key)
  defp map_or(_subject, _key), do: nil

  defp map_or_nil(subject, key) when is_map(subject), do: Map.get(subject, key)
  defp map_or_nil(_subject, _key), do: nil

  defp module_count(modules, symbol) when is_list(modules) do
    Enum.count(modules, &(&1.symbol == symbol))
  end

  defp module_count(_modules, _symbol), do: 0

  defp preparation_override_valid?(nil), do: true
  defp preparation_override_valid?(credits) when is_integer(credits) and credits >= 0, do: true
  defp preparation_override_valid?(_), do: false

  defp plan_yard(context, yard, {candidates, unmet}) do
    cond do
      not co_located?(yard.waypoint, context.owned_ships) ->
        {candidates, [precondition_limitation(yard.waypoint) | unmet]}

      true ->
        plan_yard_offers(context, yard, candidates, unmet)
    end
  end

  defp precondition_limitation(waypoint) do
    %{
      subject: waypoint,
      reason: :purchase_precondition_unmet,
      prerequisite: %{waypoint: waypoint, required_ship: :any_owned_ship}
    }
  end

  defp plan_yard_offers(context, yard, candidates, unmet) do
    Enum.reduce(yard.ships, {candidates, unmet}, fn offer, {candidates, unmet} ->
      case ship_offer(offer) do
        {:ok, offer} -> plan_offer(context, yard, offer, candidates, unmet)
        :error -> {candidates, unmet}
      end
    end)
  end

  defp plan_offer(context, yard, offer, candidates, unmet) do
    case preparation_credits(context.override, yard, offer) do
      {:ok, preparation} ->
        if offer.purchase_price + preparation <= context.credits do
          contribution =
            ship_acquisition_contribution(
              context.revision,
              context.index,
              context.objective,
              yard,
              offer,
              preparation,
              context.as_of
            )

          {[contribution | candidates], unmet}
        else
          {candidates, unmet}
        end

      :unknown ->
        {candidates, [exposure_limitation(yard.waypoint) | unmet]}
    end
  end

  defp exposure_limitation(waypoint) do
    %{
      subject: waypoint,
      reason: :preparation_exposure_unknown,
      prerequisite: %{
        waypoint: waypoint,
        required_evidence: ["ship_offer_frame", "shipyard_modification_fee"]
      }
    }
  end

  # A Ship satisfies the Purchase Precondition only while it is actually present
  # at the Waypoint. An IN_TRANSIT Ship's waypoint_symbol names its destination,
  # so it must not be read as a position.
  defp co_located?(waypoint, owned_ships) when is_binary(waypoint) and is_list(owned_ships),
    do: Enum.any?(owned_ships, &(Map.get(&1, :waypoint) == waypoint))

  defp co_located?(_waypoint, _owned_ships), do: false

  @doc false
  def ship_acquisition_objective?(objective) when is_map(objective) do
    Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
      is_binary(text) and String.match?(text, ~r/\bships?\b|\bfleet growth\b/i)
    end)
  end

  def ship_acquisition_objective?(_), do: false

  defp shipyard_offer_evidence(
         %{
           system_symbol: system,
           waypoint: waypoint,
           observed_at: %DateTime{} = observed_at,
           evidence_id: evidence_id,
           ships: ships
         } = yard,
         as_of
       )
       when is_binary(system) and is_binary(waypoint) and is_binary(evidence_id) and
              is_list(ships) do
    age = DateTime.diff(as_of, observed_at, :second)

    if age in 0..@market_evidence_freshness_seconds do
      {:ok,
       %{
         system_symbol: system,
         waypoint: waypoint,
         evidence_id: evidence_id,
         observed_at: observed_at,
         ships: ships,
         modifications_fee: fetch(yard, :modifications_fee),
         valid_until: DateTime.add(observed_at, @market_evidence_freshness_seconds, :second)
       }}
    else
      :error
    end
  end

  defp shipyard_offer_evidence(_, _), do: :error

  defp ship_offer(offer) when is_map(offer) do
    type = fetch(offer, :type)
    purchase_price = fetch(offer, :purchase_price)

    engine = offer[:engine] || offer["engine"] || %{}
    engine_speed = fetch(offer, :engine_speed) || fetch(engine, :speed)

    if is_binary(type) and is_integer(purchase_price) and purchase_price >= 0 and
         is_integer(engine_speed) and engine_speed >= 0 do
      {:ok,
       %{
         type: type,
         purchase_price: purchase_price,
         engine_speed: engine_speed,
         module_slots: frame_value(offer, :module_slots),
         mounting_points: frame_value(offer, :mounting_points),
         installed_modules: length(offer[:modules] || offer["modules"] || []),
         installed_mounts: length(offer[:mounts] || offer["mounts"] || [])
       }}
    else
      :error
    end
  end

  defp ship_offer(_), do: :error

  # nil means the offer never carried the value, which is different from a frame
  # that genuinely declares no slots. Preparation Exposure cannot be bounded
  # without both, so absence must not collapse to zero.
  defp frame_value(offer, key) do
    frame = offer[:frame] || offer["frame"]

    if is_map(frame) do
      value = fetch(frame, key)
      if is_integer(value) and value >= 0, do: value, else: nil
    end
  end

  defp fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Macro.underscore(Atom.to_string(key)))
  end

  # Preparation Exposure is the shipyard's own fee for every slot the purchased
  # template leaves empty, so the reserve is derived from observed evidence
  # rather than a guessed per-slot price.
  defp preparation_credits(override, yard, offer) do
    case override do
      nil -> derive_preparation_exposure(yard, offer)
      credits -> {:ok, credits}
    end
  end

  defp derive_preparation_exposure(yard, offer) do
    with slots when is_integer(slots) <- offer.module_slots,
         points when is_integer(points) <- offer.mounting_points,
         fee when is_integer(fee) and fee >= 0 <- fetch(yard, :modifications_fee) do
      {:ok,
       (max(slots - offer.installed_modules, 0) + max(points - offer.installed_mounts, 0)) * fee}
    else
      _unknown -> :unknown
    end
  end

  defp ship_acquisition_contribution(
         revision,
         index,
         objective,
         yard,
         offer,
         preparation_credits,
         as_of
       ) do
    %CandidateContribution{
      id:
        Evidence.fingerprint(
          {revision.id, index, yard.evidence_id, yard.waypoint, offer.type, offer.purchase_price,
           preparation_credits}
        ),
      strategy_revision_id: revision.id,
      objective_index: index,
      objective: objective,
      kind: :ship_acquisition,
      trade_symbol: nil,
      source_waypoint: yard.waypoint,
      destination_waypoint: yard.waypoint,
      expected_outcomes: %{
        decision_value: offer.engine_speed,
        purchase_price: offer.purchase_price,
        preparation_credits: preparation_credits,
        ship_type: offer.type
      },
      uncertainty: %{shipyard_availability: :shared_world_state},
      required_roles: [],
      required_capabilities: [
        %{capability: :ship_offer, value: offer.type},
        %{capability: :ship_readiness, value: %{engine_speed: offer.engine_speed}}
      ],
      required_resources: %{credits: offer.purchase_price + preparation_credits},
      dependencies: [
        %{
          subject: "shipyard:#{yard.system_symbol}:#{yard.waypoint}",
          evidence_id: yard.evidence_id,
          valid_until: yard.valid_until
        }
      ],
      validity: %{as_of: as_of, expires_at: yard.valid_until},
      alternatives: [],
      ship: %{
        type: offer.type,
        purchase_price: offer.purchase_price,
        preparation_credits: preparation_credits,
        readiness: %{engine_speed: offer.engine_speed}
      }
    }
  end

  defp add_ship_acquisition_alternatives(candidates) do
    Enum.map(candidates, fn candidate ->
      alternatives =
        candidates
        |> Enum.reject(&(&1.id == candidate.id))
        |> Enum.map(fn alternative ->
          %{
            id: alternative.id,
            ship_type: alternative.ship.type,
            purchase_price: alternative.ship.purchase_price,
            preparation_credits: alternative.ship.preparation_credits,
            decision_value: alternative.expected_outcomes.decision_value
          }
        end)

      %{candidate | alternatives: alternatives}
    end)
  end

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
                      cost = MarketSpending.worst_case_exposure(listing.purchase_price, batch),
                      cost <= credits do
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
                      required_resources: %{ship_count: 1, credits: cost},
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
        cost = MarketSpending.worst_case_exposure(raw_listing.purchase_price, batch),
        cost <= credits do
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
        required_resources: %{ship_count: 1, credits: cost},
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
         true <- is_integer(freshness) and freshness >= 0 do
      missing = Enum.reject(facts, &fresh_intelligence?(observed[&1], as_of, freshness))

      cond do
        missing == [] ->
          {:ok, :satisfied}

        coverage_subject?(opportunity) and type == "market" and facts == ["trade_goods"] ->
          # #482: baseline coverage unlocks later decisions without assigning
          # a per-Waypoint economic score or charging this subject's travel.
          {:ok, %{coverage: true, subject: opportunity.subject, waypoint: waypoint}}

        true ->
          intelligence_opportunity_with_value(opportunity, type, waypoint, capabilities)
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp intelligence_opportunity(_opportunity, _system, _as_of, _freshness),
    do: {:error, :invalid}

  defp coverage_subject?(%{coverage: true}), do: true
  defp coverage_subject?(_opportunity), do: false

  # One open coverage Observation Demand per subject, due now through the
  # shared Market timing policy. Structural value admits the bounded
  # contribution but does not invent a numeric per-subject estimate.
  defp coverage_demand(revision, objective_index, snapshot, choice, as_of, freshness) do
    market_refresh_demand(%{
      subject: choice.subject,
      observed_at: as_of,
      fresh: false,
      as_of: as_of,
      freshness_seconds: freshness,
      objective_index: objective_index,
      agent_id: Map.get(snapshot, :agent_id),
      strategy_revision_id: revision.id
    })
  end

  # One bounded Coverage Contribution over the explicit finite, named set of
  # open coverage Demands. The sorted subject order is the planner's fixed
  # order; the named set bounds scope and the fixed order bounds churn. The
  # contribution carries the portfolio outcome — observe these subjects —
  # rather than per-subject profit, and leaves no standing promise: it is
  # re-proposed at every Strategy reconciliation for the subjects still open.
  defp coverage_contribution(_revision, _index, _objective, [], _as_of), do: nil

  defp coverage_contribution(revision, index, objective, coverage, as_of) do
    coverage = Enum.reverse(coverage)
    subjects = Enum.map(coverage, & &1.subject)
    waypoints = Enum.map(coverage, & &1.waypoint)
    deadline = DateTime.add(as_of, @observation_demand_deadline_seconds, :second)

    %CandidateContribution{
      id: Evidence.fingerprint({revision.id, index, :market_coverage, subjects}),
      strategy_revision_id: revision.id,
      objective_index: index,
      objective: objective,
      kind: :market_coverage,
      trade_symbol: nil,
      source_waypoint: nil,
      destination_waypoint: hd(waypoints),
      expected_outcomes: %{
        coverage: "baseline_marketplaces",
        subjects: subjects
      },
      uncertainty: %{baseline: :structural_coverage_value},
      required_roles: [%{role: :intelligence_scout, count: 1}],
      required_capabilities: [%{capability: :market_access, waypoints: Enum.sort(waypoints)}],
      required_resources: %{ship_count: 1, credits: 0},
      dependencies:
        Enum.map(subjects, fn subject ->
          %{subject: subject, required_facts: ["trade_goods"], valid_until: deadline}
        end),
      validity: %{as_of: as_of, expires_at: deadline},
      alternatives: [],
      coverage: %{subjects: subjects}
    }
  end

  defp intelligence_opportunity_with_value(opportunity, type, waypoint, capabilities) do
    with value when is_number(value) and value >= 0 <-
           Map.get(opportunity, :expected_decision_value),
         api_cost when is_number(api_cost) and api_cost >= 0 <-
           Map.get(opportunity, :api_capacity_cost),
         ship_cost when is_number(ship_cost) and ship_cost >= 0 <-
           Map.get(opportunity, :ship_time_cost) do
      net = value - api_cost - ship_cost

      if net > 0,
        do: {:ok, %{net_value: net, type: type, waypoint: waypoint, capabilities: capabilities}},
        else: {:error, :acquisition_cost_exceeds_value}
    else
      _ -> {:error, :invalid}
    end
  end

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

    limitations = market_planning_limitations(markets, snapshot, limitations, candidates)

    {:ok,
     result(revision, objective_index, snapshot,
       candidate_contributions: candidates,
       observation_demands: demands,
       limitations: limitations
     )}
  end

  # A negative System-wide Market conclusion requires complete authoritative
  # baseline coverage: unresolved subjects — including unreachable ones — keep
  # the conclusion open and are reported explicitly instead of
  # `no viable Market route`. Legacy snapshots without coverage input keep
  # their previous limitations and conclusions unchanged.
  defp market_planning_limitations(markets, snapshot, limitations, candidates)

  defp market_planning_limitations(markets, snapshot, limitations, candidates) do
    unresolved = unresolved_baseline_subjects(markets, snapshot)

    cond do
      candidates != [] ->
        limitations

      MapSet.size(unresolved) > 0 ->
        limitations ++ coverage_limitations(unresolved, snapshot)

      limitations != [] ->
        limitations

      snapshot.coverage_authoritative and snapshot.baseline_subjects != [] ->
        # Complete baseline coverage with no admissible route is the only
        # negative System-wide Market conclusion.
        [%{subject: :market_planning, reason: :no_viable_market_routes}]

      snapshot.coverage_authoritative ->
        [%{subject: :market_planning, reason: :insufficient_market_evidence}]

      length(markets) < 2 ->
        [%{subject: :market_planning, reason: :insufficient_market_evidence}]

      true ->
        [%{subject: :market_planning, reason: :no_viable_market_routes}]
    end
  end

  defp unresolved_baseline_subjects(markets, %{coverage_authoritative: true} = snapshot) do
    snapshot.baseline_subjects
    |> MapSet.new()
    |> MapSet.difference(MapSet.new(markets, & &1.subject))
  end

  defp unresolved_baseline_subjects(_markets, _snapshot), do: MapSet.new()

  defp coverage_limitations(unresolved, snapshot) do
    unreachable = MapSet.new(snapshot.unreachable_subjects)

    [
      subject_coverage_limitation(
        :incomplete_market_coverage,
        MapSet.difference(unresolved, unreachable)
      ),
      subject_coverage_limitation(
        :unreachable_market_coverage,
        MapSet.intersection(unresolved, unreachable)
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp subject_coverage_limitation(reason, subjects) do
    case MapSet.to_list(subjects) do
      [] ->
        nil

      subjects ->
        %{subject: :market_planning, reason: reason, subjects: Enum.sort(subjects)}
    end
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
      with {:ok, baseline_subjects, unreachable_subjects} <-
             normalize_coverage(markets, snapshot, system_symbol) do
        {:ok,
         %{
           as_of: as_of,
           system_symbol: system_symbol,
           freshness_seconds: freshness_seconds,
           demand_deadline_seconds: demand_deadline_seconds,
           observation_costs: observation_costs,
           agent_id: Map.get(snapshot, :agent_id),
           coverage_authoritative: Map.has_key?(snapshot, :baseline_subjects),
           baseline_subjects: baseline_subjects,
           unreachable_subjects: unreachable_subjects,
           markets: normalize_market_observations(markets)
         }}
      end
    else
      {:error, :invalid_market_planning_input}
    end
  end

  defp normalize_snapshot(_snapshot), do: {:error, :invalid_market_planning_input}

  # Without an explicit authoritative baseline the snapshot's own Market
  # subjects are the target set, so legacy callers keep their conclusions
  # unchanged and no unresolved coverage is invented from absent evidence.
  defp normalize_coverage(markets, snapshot, system_symbol) do
    with {:ok, baseline} <-
           baseline_subjects(Map.get(snapshot, :baseline_subjects), markets, system_symbol),
         {:ok, unreachable} <-
           listed_subjects(Map.get(snapshot, :unreachable_subjects, []), system_symbol),
         :ok <- coverage_subset_check(unreachable, baseline) do
      {:ok, baseline, unreachable}
    end
  end

  defp coverage_subset_check(unreachable, baseline) do
    if MapSet.subset?(MapSet.new(unreachable), MapSet.new(baseline)),
      do: :ok,
      else: {:error, :invalid_market_planning_input}
  end

  defp baseline_subjects(nil, markets, _system_symbol) do
    {:ok, markets |> Enum.map(&market_subject/1) |> Enum.uniq() |> Enum.sort()}
  end

  defp baseline_subjects(subjects, _markets, system_symbol) do
    listed_subjects(subjects, system_symbol)
  end

  defp listed_subjects(subjects, system_symbol) when is_list(subjects) do
    if Enum.all?(subjects, &valid_market_subject?(&1, system_symbol)) do
      {:ok, subjects |> Enum.uniq() |> Enum.sort()}
    else
      {:error, :invalid_market_planning_input}
    end
  end

  defp listed_subjects(_subjects, _system_symbol), do: {:error, :invalid_market_planning_input}

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
          # A currently usable retained Listing still needs its future refresh
          # demand, due at the observation time plus the existing freshness
          # budget. It carries no deadline: inventing one would place a latest
          # acceptable time before the earliest useful time.
          demands = [
            market_refresh_demand(%{
              subject: subject,
              observed_at: market.observed_at,
              fresh: true,
              as_of: snapshot.as_of,
              freshness_seconds: snapshot.freshness_seconds,
              expected_value: market_demand_value(market, snapshot),
              objective_index: objective_index,
              agent_id: snapshot.agent_id,
              strategy_revision_id: revision.id
            })
            | demands
          ]

          {[market | markets], demands, limitations}

        {:error, reason} ->
          # Stale or missing evidence is due now and keeps the existing
          # immediate decision deadline.
          demands =
            case market_demand_value(market, snapshot) do
              value when is_number(value) and value > 0 ->
                [
                  market_refresh_demand(%{
                    subject: subject,
                    observed_at: value_observed_at(market, snapshot),
                    fresh: false,
                    as_of: snapshot.as_of,
                    freshness_seconds: snapshot.freshness_seconds,
                    deadline_seconds: snapshot.demand_deadline_seconds,
                    expected_value: value,
                    objective_index: objective_index,
                    agent_id: snapshot.agent_id,
                    strategy_revision_id: revision.id
                  })
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
      credits: SpaceTraders.MarketSpending.worst_case_exposure(source_good.purchase_price, units),
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

  defp value_observed_at(market, _snapshot), do: market.observed_at

  defp market_goods(market, as_of) do
    observed_at = value(market, :observed_at)
    goods = value(market, :trade_goods)

    if is_struct(observed_at, DateTime) and
         DateTime.compare(observed_at, as_of) in [:eq, :lt] and
         valid_provenance?(market) and is_list(goods),
       do: goods,
       else: []
  end

  @doc """
  One Market refresh Observation Demand description for one retained Listing,
  shared by pure Fleet Planning and runtime synchronization.

  A usable (fresh) retained Listing is due at its observation time plus the
  freshness budget and carries no deadline. A stale or incomplete retained
  Listing is due now with the existing immediate decision deadline. This is
  the single timing policy for Market refresh demands; no caller invents its
  own duration or deadline.
  """
  def market_refresh_demand(
        %{
          subject: subject,
          observed_at: observed_at,
          fresh: fresh?,
          as_of: as_of,
          freshness_seconds: freshness_seconds
        } = attrs
      )
      when is_binary(subject) and is_struct(observed_at, DateTime) do
    deadline_seconds = Map.get(attrs, :deadline_seconds, @observation_demand_deadline_seconds)

    {due_at, deadline_at} =
      if fresh? do
        {DateTime.add(observed_at, freshness_seconds, :second), nil}
      else
        {as_of, DateTime.add(as_of, deadline_seconds, :second)}
      end

    %Demand{
      subject: subject,
      required_facts: ["trade_goods"],
      owner: "fleet_planning",
      deadline_at: deadline_at,
      freshness_seconds: freshness_seconds,
      due_at: due_at,
      agent_id: attrs[:agent_id],
      strategy_revision_id: attrs[:strategy_revision_id],
      strategic_priority: attrs[:objective_index],
      expected_value: attrs[:expected_value],
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
