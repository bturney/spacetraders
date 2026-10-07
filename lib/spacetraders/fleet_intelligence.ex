defmodule SpaceTraders.FleetIntelligence do
  alias SpaceTraders.Agent, as: AgentContext
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.{Clock, Evidence}
  alias SpaceTraders.Evidence.Demand
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetPlanning
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
    waypoints = World.waypoints(agent, system_symbol, now, @freshness_seconds)
    refresh_demand_specs(waypoints, system_symbol, now)
  end

  defp refresh_demand_specs(waypoints, system_symbol, now) do
    waypoints
    |> Enum.filter(&marketplace_waypoint?/1)
    |> Enum.filter(&retained_listing_fact?/1)
    |> Enum.map(fn waypoint ->
      fact = waypoint.market.facts["trade_goods"]

      fresh? =
        match?(%{freshness: :fresh, value: goods} when is_list(goods), fact)

      FleetPlanning.market_refresh_demand(%{
        subject: market_subject(system_symbol, waypoint.symbol),
        observed_at: fact.observed_at,
        fresh: fresh?,
        as_of: now,
        freshness_seconds: @freshness_seconds
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
    waypoints = World.waypoints(agent, system_symbol, now, @freshness_seconds)
    baseline_demand_specs(waypoints, system_symbol, now)
  end

  defp baseline_demand_specs(waypoints, system_symbol, now) do
    waypoints
    |> Enum.filter(&marketplace_waypoint?/1)
    |> Enum.reject(&retained_listing_fact?/1)
    |> Enum.map(fn waypoint ->
      FleetPlanning.market_refresh_demand(%{
        subject: market_subject(system_symbol, waypoint.symbol),
        observed_at: now,
        fresh: false,
        as_of: now,
        freshness_seconds: @freshness_seconds
      })
    end)
  end

  @doc "Subjects of the currently known Marketplaces in one System."
  def known_marketplace_subjects(agent, system_symbol, now)
      when is_binary(system_symbol) do
    World.waypoints(agent, system_symbol, now, @freshness_seconds)
    |> marketplace_subjects(system_symbol)
  end

  @doc "Market Observation Demand subject for one Waypoint."
  def market_subject(system_symbol, waypoint_symbol)
      when is_binary(system_symbol) and is_binary(waypoint_symbol) do
    "market:#{system_symbol}:#{waypoint_symbol}"
  end

  defp marketplace_subjects(waypoints, system_symbol) do
    waypoints
    |> Enum.filter(&marketplace_waypoint?/1)
    |> Enum.map(&market_subject(system_symbol, &1.symbol))
    |> Enum.sort()
  end

  # Refresh work covers only subjects that already carry a retained Listing
  # fact, fresh or stale/incomplete. A bare Marketplace with no retained fact
  # has never been observed and belongs to reset-start baseline coverage.
  defp retained_listing_fact?(waypoint) do
    case waypoint.market.facts["trade_goods"] do
      %{state: "known", observed_at: %DateTime{}} -> true
      _ -> false
    end
  end

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
    if credit_growth_objective?(revision) do
      now = Clock.utc_now()
      waypoints = World.waypoints(agent, system_symbol, now, @freshness_seconds)
      subjects = marketplace_subjects(waypoints, system_symbol)

      specs =
        (refresh_demand_specs(waypoints, system_symbol, now) ++
           baseline_demand_specs(waypoints, system_symbol, now))
        |> Enum.uniq_by(& &1.subject)

      with :ok <- Evidence.sync_runtime_demands(agent, revision, specs, now) do
        Evidence.withdraw_market_demands_outside_subjects(agent, revision, subjects, now)
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
      when is_binary(system) and is_map(capacity) do
    with true <- capacity.available_slots > 0 and capacity.backpressure != :sustained,
         :ok <- allocation_available(scope, agent),
         waypoints <- waypoints_for_decision(agent, revision, system),
         :ok <- sync_market_observation_demands(agent, revision, system),
         {kind, index} <- next_objective(revision, waypoints),
         {:ok, ships} <- Fleet.list_ships(agent),
         true <- ships != [],
         opportunities <-
           opportunities(kind, revision, index, waypoints, ships, system, agent.id),
         true <- opportunities != [],
         {:ok, planning} <-
           FleetPlanning.plan_intelligence(revision, index, %{
             as_of: Clock.utc_now(),
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

  defp waypoints_for_decision(agent, revision, system) do
    waypoints = World.waypoints(agent, system, Clock.utc_now(), @freshness_seconds)

    if waypoints == [] do
      discover_waypoints(agent, revision, system)
    else
      waypoints
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
        []

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
            []
        end
    end
  end

  defp retain_waypoints(_agent, []), do: []

  defp retain_waypoints(agent, waypoints) do
    Enum.each(waypoints, fn waypoint ->
      Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
    end)

    World.waypoints(agent, waypoint_system(waypoints), Clock.utc_now(), @freshness_seconds)
  end

  defp waypoint_system([%{system_symbol: system} | _]), do: system
  defp waypoint_system(_), do: "unknown"

  defp next_objective(revision, waypoints) do
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
          if Enum.any?(waypoints, &market_listing_needed?/1),
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

  defp opportunities(:market, revision, index, waypoints, ships, system, agent_id) do
    as_of = Clock.utc_now()

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

    existing_opportunities =
      case FleetPlanning.plan_market(
             revision,
             index,
             FleetPlanning.market_snapshot(
               as_of,
               system,
               agent_id,
               retained_markets(waypoints, system)
             )
             |> Map.put(:observation_costs, costs)
             |> Map.put(
               :credit_margin_percent,
               SpaceTraders.CreditCalibration.active().margin_percent
             )
             |> Map.merge(
               FleetPlanning.baseline_coverage(marketplace_subjects(waypoints, system))
             )
           ) do
        {:ok, %{observation_demands: demands}} ->
          demands
          # A future refresh demand is not an acquisition opportunity yet:
          # only demands whose earliest useful time has passed may acquire.
          |> Enum.filter(fn demand ->
            due_demand?(demand, as_of)
          end)
          |> Enum.flat_map(fn demand ->
            waypoint = Enum.find(waypoints, &String.ends_with?(demand.subject, ":#{&1.symbol}"))
            cost = costs[demand.subject]

            if waypoint && cost do
              [
                %{
                  subject: demand.subject,
                  required_facts: demand.required_facts,
                  facts: waypoint.market.facts,
                  expected_decision_value:
                    demand.expected_value + cost.api_capacity_cost + cost.ship_time_cost,
                  api_capacity_cost: cost.api_capacity_cost,
                  ship_time_cost: cost.ship_time_cost,
                  acquisition: :on_site
                }
              ]
            else
              []
            end
          end)

        _ ->
          []
      end

    initial_opportunities =
      waypoints
      |> Enum.filter(&market_listing_needed?/1)
      |> Enum.flat_map(fn waypoint ->
        subject = "market:#{system}:#{waypoint.symbol}"

        case costs[subject] do
          %{api_capacity_cost: api_cost, ship_time_cost: ship_cost} ->
            coverage? = not retained_listing_fact?(waypoint)

            opportunity = %{
              subject: subject,
              required_facts: ["trade_goods"],
              facts: waypoint.market.facts,
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

  defp retained_markets(waypoints, system) do
    Enum.flat_map(waypoints, fn waypoint ->
      case waypoint.market.facts["trade_goods"] do
        %{state: "known", value: goods, observed_at: observed_at} = fact
        when is_list(goods) ->
          [
            %{
              subject: "market:#{system}:#{waypoint.symbol}",
              observed_at: observed_at,
              trade_goods: goods,
              source: fact.source,
              evidence_id: "intelligence-observation:#{fact.observation_id}"
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp market_listing_needed?(waypoint) do
    case waypoint.market.facts["trade_goods"] do
      nil ->
        marketplace_waypoint?(waypoint)

      %{state: "known_unavailable"} ->
        false

      fact ->
        marketplace_waypoint?(waypoint) and fact[:freshness] != :fresh
    end
  end

  defp marketplace_waypoint?(waypoint) do
    case waypoint.facts["traits"] do
      %{state: "known", value: traits} when is_list(traits) ->
        Enum.any?(traits, &(Map.get(&1, "symbol") == "MARKETPLACE"))

      _ ->
        false
    end
  end

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

  defp allocation_available(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      nil ->
        :ok

      %{commitments: commitments} ->
        if Intents.current(agent) != [] or
             Enum.any?(commitments, &(not completed_intelligence?(&1.id))),
           do: {:error, :ship_claimed},
           else: :ok
    end
  end

  defp completed_intelligence?(commitment_id) do
    Repo.exists?(
      from intent in Intent,
        where:
          intent.fleet_commitment_id == ^commitment_id and
            intent.type == "acquire_intelligence" and intent.status == "completed"
    )
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
