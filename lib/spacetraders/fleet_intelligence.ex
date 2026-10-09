defmodule SpaceTraders.FleetIntelligence do
  alias SpaceTraders.Agent, as: AgentContext
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.{Clock, Evidence}
  alias SpaceTraders.Evidence.Demand
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetShadow
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Intelligence
  alias SpaceTraders.World

  alias SpaceTraders.Repo

  import Ecto.Query

  @freshness_seconds 300
  @api_cost 0.1
  @distance_cost 0.01
  @market_api_cost 5
  @market_distance_cost 1
  @initial_market_decision_value 10.0

  @doc "Whether the revision declares the continuous credit-growth objective that consumes Market Listings."
  def credit_growth_objective?(%Revision{} = revision), do: credit_objective(revision) != nil

  @doc """
  Describes one durable Market refresh demand per Marketplace with retained
  Listing evidence, without persisting or acquiring anything.

  The descriptions are typed `%Evidence.Demand{}` structs built through the
  shared `FleetPlanning.market_refresh_demand/1` timing policy. Marketplaces
  with no retained Listing fact are deliberately absent: first-time coverage
  demands are reset-start baseline work described by
  `baseline_market_demand_specs/3`.
  """
  def market_refresh_demand_specs(agent, system_symbol, now)
      when is_binary(system_symbol) do
    agent
    |> Intelligence.market_interpretation(system_symbol, now)
    |> refresh_demand_specs()
  end

  # Only a `:current` interpreted Listing waits for its freshness budget;
  # every other retained Listing is due now for replacement evidence.
  defp refresh_demand_specs(interpretation) do
    interpretation
    |> retained_marketplace_listings()
    |> Enum.map(fn market ->
      FleetPlanning.market_refresh_demand(%{
        subject: market.subject,
        observed_at: market.observed_at,
        fresh: market.state == :current,
        as_of: interpretation.as_of,
        freshness_seconds: interpretation.freshness_seconds
      })
    end)
  end

  @doc """
  Describes one durable reset-start baseline Observation Demand per known
  Marketplace that has no retained Listing fact, without persisting or
  acquiring anything.

  A never-observed Marketplace is incomplete evidence for the Market decision
  that is already pending, so the shared `FleetPlanning.market_refresh_demand/1`
  timing policy makes each baseline subject due now with the immediate
  decision deadline. No timing is invented here.
  """
  def baseline_market_demand_specs(agent, system_symbol, now)
      when is_binary(system_symbol) do
    agent
    |> Intelligence.market_interpretation(system_symbol, now)
    |> baseline_demand_specs()
  end

  defp baseline_demand_specs(interpretation) do
    interpretation
    |> baseline_gap_subjects()
    |> Enum.map(fn subject ->
      FleetPlanning.market_refresh_demand(%{
        subject: subject,
        observed_at: interpretation.as_of,
        fresh: false,
        as_of: interpretation.as_of,
        freshness_seconds: interpretation.freshness_seconds
      })
    end)
  end

  # Refresh work covers only known Marketplaces whose interpreted Listing has
  # its own retained acquisition time, whatever its state. A known
  # Marketplace without one (never observed, invalidated, future-only or
  # unreadable) belongs to reset-start baseline coverage.
  defp retained_marketplace_listings(interpretation) do
    baseline = MapSet.new(interpretation.baseline_subjects)

    Enum.filter(
      interpretation.markets,
      &(MapSet.member?(baseline, &1.subject) and retained_listing?(&1))
    )
  end

  defp baseline_gap_subjects(interpretation) do
    retained =
      interpretation
      |> retained_marketplace_listings()
      |> MapSet.new(& &1.subject)

    Enum.reject(interpretation.baseline_subjects, &MapSet.member?(retained, &1))
  end

  defp retained_listing?(%{observed_at: %DateTime{}}), do: true
  defp retained_listing?(_market), do: false

  @doc """
  Synchronizes durable Market refresh Observation Demands for the active Agent
  and Strategy Revision.

  Under the continuous credit-growth objective, synchronization establishes
  the durable demand set for every currently known Marketplace:

  - every Marketplace with retained Listing evidence gets one open,
    independently attributable refresh demand per consumer: usable Listings
    are due at their observation time plus the existing Market freshness
    budget, stale or incomplete evidence is due now;
  - every known Marketplace without retained Listing evidence keeps exactly
    one open reset-start baseline demand due now, so first-time coverage
    survives restart and never depends on a Market polling scan.

  Synchronization is idempotent and never extends an already-due demand, so
  API backpressure leaves overdue timing unchanged.

  Demands whose subject is no longer a known Marketplace have lost Strategy
  relevance and are withdrawn with preserved provenance; a Marketplace that
  merely lacks Listing evidence is never withdrawn, so reset-start baseline
  coverage is untouched.
  """
  def sync_market_observation_demands(agent, revision, system_symbol)
      when is_binary(system_symbol) do
    sync_market_demands(
      agent,
      revision,
      Intelligence.market_interpretation(agent, system_symbol, Clock.utc_now())
    )
  end

  defp sync_market_demands(agent, revision, interpretation) do
    if credit_growth_objective?(revision) do
      now = interpretation.as_of

      specs =
        (refresh_demand_specs(interpretation) ++ baseline_demand_specs(interpretation))
        |> Enum.uniq_by(& &1.subject)

      with :ok <- Evidence.sync_runtime_demands(agent, revision, specs, now) do
        Evidence.withdraw_market_demands_outside_subjects(
          agent,
          revision,
          interpretation.baseline_subjects,
          now
        )
      end
    else
      :ok
    end
  end

  def reconcile(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        system,
        capacity
      )
      when is_binary(system) do
    # One decision time fixes Waypoint projection, Market interpretation,
    # demand timing and intelligence planning alike.
    with true <- FleetCapacity.proceed?(capacity),
         %{occupied: occupied} <- FleetExecution.intelligence_occupancy(scope, agent),
         {now, waypoints} <- waypoints_for_decision(agent, revision, system),
         market = FleetShadow.market_input(agent, system, now),
         :ok <- sync_market_demands(agent, revision, market),
         {kind, index} <- next_objective(revision, waypoints, market),
         true <- free_ship_known?(agent, occupied),
         {:ok, ships} <- Fleet.list_ships(agent),
         ships <- Enum.reject(ships, &(&1.symbol in occupied)),
         true <- ships != [],
         opportunities <- opportunities(kind, revision, index, waypoints, ships, system, market),
         true <- opportunities != [],
         {:ok, planning} <-
           FleetPlanning.plan_intelligence(revision, index, %{
             as_of: now,
             system_symbol: system,
             agent_id: agent.id,
             freshness_seconds: @freshness_seconds,
             opportunities: opportunities
           }) do
      FleetExecution.activate_intelligence(scope, agent, revision, planning, capacity)
    else
      _ -> {:error, :no_decision_relevant_intelligence}
    end
  end

  # The decision time follows any Waypoint discovery, so discovered
  # Marketplaces are retained before the interpretation reads them.
  defp waypoints_for_decision(agent, revision, system) do
    now = Clock.utc_now()

    case World.waypoints(agent, system, now, @freshness_seconds) do
      [] ->
        discover_waypoints(agent, revision, system)
        now = Clock.utc_now()
        {now, World.waypoints(agent, system, now, @freshness_seconds)}

      waypoints ->
        {now, waypoints}
    end
  end

  defp discover_waypoints(agent, revision, system) do
    priorities =
      [
        chart_objective(revision),
        credit_objective(revision),
        shipyard_objective(revision),
        resource_objective(revision)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case priorities do
      [] ->
        :ok

      [priority | _] ->
        request = [
          owner: "fleet_planning",
          discovery: true,
          expected_value: 1.0 - @api_cost,
          strategic_priority: priority,
          freshness_seconds: @freshness_seconds,
          required_facts: ["waypoints"]
        ]

        result =
          Evidence.get_waypoints_paginated(
            AgentTokenReference.new(agent),
            system,
            [],
            request
          )

        case AgentContext.handle_game_result(agent, result) do
          {:ok, waypoints} ->
            retain_waypoints(agent, waypoints)

          {:error, _reason, waypoints} when is_list(waypoints) ->
            retain_waypoints(agent, waypoints)

          _ ->
            :ok
        end
    end
  end

  defp retain_waypoints(agent, waypoints) do
    Enum.each(waypoints, fn waypoint ->
      Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
    end)
  end

  defp next_objective(revision, waypoints, market_input) do
    chart =
      case chart_objective(revision) do
        {index, _} ->
          if(Enum.any?(waypoints, &(not chart_known?(&1))), do: [{:chart, index}], else: [])

        _ ->
          []
      end

    market =
      case credit_objective(revision) do
        {index, _} ->
          if listing_gaps(market_input) != [],
            do: [{:market, index}],
            else: []

        _ ->
          []
      end

    shipyard =
      case shipyard_objective(revision) do
        {index, _} ->
          if Enum.any?(waypoints, &(shipyard_waypoint?(&1) and not shipyard_listing_fresh?(&1))),
            do: [{:shipyard, index}],
            else: []

        _ ->
          []
      end

    Enum.min_by(chart ++ market ++ shipyard, &elem(&1, 1), fn -> nil end)
  end

  defp credit_objective(%Revision{document: %{"objectives" => objectives}})
       when is_list(objectives) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if is_map(objective) and objective["kind"] == "continuous" and
           Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
             is_binary(text) and String.match?(text, ~r/\bcredits?\b/i)
           end),
         do: {index, objective}
    end)
  end

  defp credit_objective(_revision), do: nil

  defp resource_objective(%Revision{document: %{"objectives" => objectives}}) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
           is_binary(text) and
             String.match?(
               text,
               ~r/\bextract\b|\bsiphon\b|\bmin(e|ing)\b|\brefin(e|ing)\b|\bresources?\b/i
             )
         end),
         do: {index, objective}
    end)
  end

  defp shipyard_objective(%Revision{document: %{"objectives" => objectives}})
       when is_list(objectives) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if is_map(objective) and
           Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
             is_binary(text) and String.match?(text, ~r/\bships?\b|\bfleet growth\b/i)
           end),
         do: {index, objective}
    end)
  end

  defp shipyard_objective(_revision), do: nil

  defp shipyard_waypoint?(waypoint) do
    case waypoint.facts["traits"] do
      %{state: "known", value: traits} when is_list(traits) ->
        Enum.any?(traits, &(Map.get(&1, "symbol") == "SHIPYARD"))

      _ ->
        false
    end
  end

  defp shipyard_listing_fresh?(waypoint) do
    Enum.all?(["ship_types", "ships"], fn field ->
      match?(%{state: "known", freshness: :fresh}, waypoint.shipyard.facts[field])
    end)
  end

  defp opportunities(:chart, _revision, _index, waypoints, ships, system, _agent_id),
    do: chart_opportunities(waypoints, ships, system)

  defp opportunities(:shipyard, _revision, _index, waypoints, ships, system, _agent_id) do
    Enum.flat_map(waypoints, fn waypoint ->
      if shipyard_waypoint?(waypoint) and not shipyard_listing_fresh?(waypoint) do
        cost =
          ships
          |> Enum.map(&travel_cost(&1, waypoint, waypoints))
          |> Enum.filter(&is_number/1)
          |> Enum.min(fn -> nil end)

        if is_number(cost) do
          [
            %{
              subject: "shipyard:#{system}:#{waypoint.symbol}",
              required_facts: ["ship_types", "ships"],
              facts: waypoint.shipyard.facts,
              expected_decision_value: 1.0,
              api_capacity_cost: @api_cost,
              ship_time_cost: cost,
              acquisition: :on_site
            }
          ]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp opportunities(:market, revision, index, waypoints, ships, system, market_input) do
    as_of = market_input.as_of

    costs =
      for waypoint <- waypoints,
          cost =
            ships
            |> Enum.map(&travel_cost(&1, waypoint, waypoints))
            |> Enum.filter(&is_number/1)
            |> Enum.min(fn -> nil end),
          is_number(cost),
          into: %{},
          do: {
            "market:#{system}:#{waypoint.symbol}",
            %{
              api_capacity_cost: @market_api_cost,
              ship_time_cost: cost * @market_distance_cost / @distance_cost
            }
          }

    markets = Map.new(market_input.markets, &{&1.subject, &1})

    existing_opportunities =
      case FleetPlanning.plan_market(
             revision,
             index,
             Map.put(market_input, :observation_costs, costs)
           ) do
        {:ok, %{observation_demands: demands}} ->
          demands
          # A future refresh demand is not an acquisition opportunity yet:
          # only demands whose earliest useful time has passed may acquire.
          |> Enum.filter(fn demand ->
            due_demand?(demand, as_of)
          end)
          |> Enum.flat_map(fn demand ->
            case costs[demand.subject] do
              %{} = cost ->
                [
                  %{
                    subject: demand.subject,
                    required_facts: demand.required_facts,
                    facts: listing_facts(markets[demand.subject]),
                    expected_decision_value:
                      demand.expected_value + cost.api_capacity_cost + cost.ship_time_cost,
                    api_capacity_cost: cost.api_capacity_cost,
                    ship_time_cost: cost.ship_time_cost,
                    acquisition: :on_site
                  }
                ]

              nil ->
                []
            end
          end)

        _ ->
          []
      end

    initial_opportunities =
      market_input
      |> listing_gaps()
      |> Enum.flat_map(fn subject ->
        case costs[subject] do
          %{api_capacity_cost: api_cost, ship_time_cost: ship_cost} ->
            coverage? = not retained_listing?(Map.get(markets, subject, %{}))

            opportunity = %{
              subject: subject,
              required_facts: ["trade_goods"],
              facts: listing_facts(markets[subject]),
              api_capacity_cost: api_cost,
              ship_time_cost: ship_cost,
              acquisition: :on_site,
              coverage: coverage?
            }

            [
              if(coverage?,
                do: opportunity,
                else:
                  Map.put(opportunity, :expected_decision_value, @initial_market_decision_value)
              )
            ]

          _ ->
            []
        end
      end)

    Enum.uniq_by(existing_opportunities ++ initial_opportunities, & &1.subject)
  end

  defp due_demand?(%Demand{due_at: nil}, _as_of), do: true

  defp due_demand?(%Demand{due_at: due_at}, as_of),
    do: DateTime.compare(due_at, as_of) != :gt

  # Known Marketplaces whose Listing the interpretation does not hold as
  # current. A Listing the game declared unreadable is not re-acquired.
  defp listing_gaps(market_input) do
    for %{subject: subject, reason: reason} <- market_input.coverage_gaps,
        reason != :unavailable,
        do: subject
  end

  # Only a current interpreted Listing satisfies an observation; every other
  # state leaves the fact to acquire.
  defp listing_facts(%{state: :current, observed_at: observed_at}),
    do: %{"trade_goods" => %{state: "known", observed_at: observed_at}}

  defp listing_facts(_market), do: %{}

  defp chart_objective(%Revision{document: %{"objectives" => objectives}})
       when is_list(objectives) do
    objectives
    |> Enum.with_index()
    |> Enum.find_value(fn {objective, index} ->
      if is_map(objective) and objective["kind"] == "attain" and
           Enum.any?([objective["objective"], objective["evaluation"]], fn text ->
             is_binary(text) and String.match?(text, ~r/\bchart\b|\bcharted\b/i)
           end),
         do: {index, objective}
    end)
  end

  defp chart_objective(_revision), do: nil

  # Occupancy is local state: when every known Ship is fenced there is nothing
  # to plan for, so no game request is spent finding that out.
  defp free_ship_known?(agent, occupied) do
    symbols = Repo.all(from ship in Ship, where: ship.agent_id == ^agent.id, select: ship.symbol)
    symbols == [] or Enum.any?(symbols, &(&1 not in occupied))
  end

  defp chart_opportunities(waypoints, ships, system) do
    Enum.flat_map(waypoints, fn waypoint ->
      if chart_known?(waypoint) do
        []
      else
        ship_cost =
          ships
          |> Enum.map(&travel_cost(&1, waypoint, waypoints))
          |> Enum.filter(&is_number/1)
          |> Enum.min(fn -> nil end)

        if is_number(ship_cost) do
          [
            %{
              subject: "waypoint:#{system}:#{waypoint.symbol}",
              required_facts: ["chart"],
              facts: waypoint.facts,
              expected_decision_value: 1.0,
              api_capacity_cost: @api_cost,
              ship_time_cost: ship_cost,
              acquisition: :on_site,
              required_capabilities: [%{capability: :waypoint_scan}, %{capability: :chart}]
            }
          ]
        else
          []
        end
      end
    end)
  end

  defp chart_known?(waypoint) do
    case waypoint.facts["chart"] do
      %{state: "known", value: %{"submitted_by" => by}} when is_binary(by) -> true
      _ -> false
    end
  end

  defp travel_cost(%{nav: %{system_symbol: system, waypoint_symbol: symbol}}, waypoint, known)
       when system == elem(waypoint.subject, 1) do
    if symbol == waypoint.symbol do
      0.0
    else
      current = Enum.find(known, &(&1.symbol == symbol))

      with %{facts: %{"x" => %{state: "known", value: x1}, "y" => %{state: "known", value: y1}}} <-
             current,
           %{"x" => %{state: "known", value: x2}, "y" => %{state: "known", value: y2}} <-
             waypoint.facts,
           true <- Enum.all?([x1, y1, x2, y2], &is_number/1) do
        :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2)) * @distance_cost
      else
        _ -> nil
      end
    end
  end

  defp travel_cost(_ship, _waypoint, _known), do: nil
end
