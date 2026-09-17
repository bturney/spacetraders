defmodule SpaceTraders.MissionControl do
  @moduledoc """
  Read projections for the authenticated Operator's Mission Control adapter.

  The caller supplies an authenticated `SpaceTraders.Agent.Scope`. This module
  owns the Operator-to-Agent scoping boundary and exposes no gameplay commands.
  Read failures remain in each Fleet snapshot so adapters can render unknown or
  stale state without substituting cached values.
  """

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.{Agent, Fleet, FleetGeneration, FleetStrategy, Intelligence}

  @evaluation_fact_keys %{
    "change" => :change,
    "current" => :current,
    "elapsed_seconds" => :elapsed_seconds,
    "expected_seconds_to_target" => :expected_seconds_to_target,
    "feasible?" => :feasible?,
    "horizon_seconds" => :horizon_seconds,
    "required_margin" => :required_margin,
    "target" => :target
  }

  @doc "Returns the signed-in Operator's Agents for adapter subscriptions."
  def agents(%Scope{operator: operator}) do
    operator
    |> Agent.list_agents()
    |> Enum.map(&without_agent_credentials/1)
  end

  @doc "Returns the dashboard projections for the signed-in Operator's Agents."
  def dashboard(%Scope{} = scope), do: dashboard(scope, agents(scope))

  @doc "Projects a previously scoped Agent list after adapter subscriptions are established."
  def dashboard(%Scope{} = scope, agents) do
    agents
    |> Enum.filter(&owned_by?(&1, scope))
    |> Enum.map(&Agent.get_agent(scope, &1.id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Fleet.command_snapshot/1)
    |> Enum.map(&without_credentials/1)
  end

  @doc "Returns the authenticated Operator's Fleet Strategy review projection."
  def strategy(%Scope{} = scope) do
    FleetStrategy.get(scope)
    |> Map.put(:presets, FleetStrategy.presets())
  end

  @doc "Returns the concise Fleet Strategy and Fleet Generation read projection."
  def overview(%Scope{} = scope) do
    strategy = strategy(scope)
    generations = FleetGeneration.list_generations(scope)
    snapshots = dashboard(scope)

    %{
      strategy: strategy,
      generations: generations,
      fleets: Enum.map(snapshots, &fleet_overview(&1, generations)),
      objectives: objective_overviews(strategy.active_revision, generations)
    }
  end

  @doc """
  Refreshes one Operator-owned Agent in an existing dashboard projection.

  An Agent outside the supplied scope cannot be read and leaves the projection
  unchanged. A failed refresh replaces prior values with the new explicit error.
  """
  def refresh_agent(%Scope{operator: operator}, projections, agent_id) do
    case Agent.get_agent(operator, agent_id) do
      nil ->
        projections

      agent ->
        Enum.map(projections, fn projection ->
          if projection.agent.id == agent.id do
            agent |> Fleet.command_snapshot() |> without_credentials()
          else
            projection
          end
        end)
    end
  end

  @doc "Reads one Waypoint's Market projection for an Operator-owned Agent."
  def waypoint_market(%Scope{} = scope, %AgentRecord{} = agent, waypoint) do
    if owned_by?(agent, scope) do
      Fleet.waypoint_market(agent, waypoint)
    else
      {:error, :waypoint_unavailable}
    end
  end

  @doc "Reads current and stale Waypoint readiness facts for an Operator-owned Agent."
  def waypoint_readiness(%Scope{} = scope, %AgentRecord{} = agent, waypoint) do
    if owned_by?(agent, scope) do
      waypoint_facts =
        Intelligence.subject(agent, :waypoint, waypoint.system_symbol, waypoint.symbol)

      if waypoint.is_under_construction == true do
        _ = Fleet.waypoint_construction(agent, waypoint)
      end

      construction =
        Intelligence.subject_with_stale(
          agent,
          :construction,
          waypoint.system_symbol,
          waypoint.symbol
        )

      if waypoint.type == "JUMP_GATE" do
        _ = Fleet.waypoint_jump_gate(agent, waypoint)
      end

      gate =
        Intelligence.subject_with_stale(
          agent,
          :jump_gate,
          waypoint.system_symbol,
          waypoint.symbol
        )

      market =
        Intelligence.subject_with_stale(
          agent,
          :market,
          waypoint.system_symbol,
          waypoint.symbol
        )

      waypoint_facts
      |> Map.merge(namespace_facts(construction.current, "construction"))
      |> Map.merge(namespace_facts(construction.stale, "construction_stale"))
      |> Map.merge(namespace_facts(gate.current, "jump_gate"))
      |> Map.merge(namespace_facts(gate.stale, "jump_gate_stale"))
      |> Map.merge(namespace_facts(market.stale, "market_stale"))
    else
      %{}
    end
  end

  @doc "Returns current and stale Market Intelligence for an Operator-owned Waypoint."
  def market_intelligence(%Scope{} = scope, %AgentRecord{} = agent, waypoint) do
    if owned_by?(agent, scope) do
      Intelligence.subject_with_stale(agent, :market, waypoint.system_symbol, waypoint.symbol)
    else
      %{current: %{}, stale: %{}}
    end
  end

  @doc "Returns observed Marketplace Waypoints for an Operator-owned Agent."
  def marketplace_waypoints(%Scope{} = scope, %AgentRecord{} = agent, system_symbol) do
    if owned_by?(agent, scope) do
      Intelligence.marketplace_waypoints(agent, system_symbol)
    else
      []
    end
  end

  @doc "Returns a usable Survey for an Operator-owned Agent, when one exists."
  def usable_survey(%Scope{} = scope, %AgentRecord{} = agent, waypoint_symbol) do
    if owned_by?(agent, scope) do
      Intelligence.usable_survey(agent, waypoint_symbol)
    end
  end

  defp owned_by?(%AgentRecord{operator_id: operator_id}, %Scope{operator: %{id: operator_id}}),
    do: true

  defp owned_by?(_agent, _scope), do: false

  defp without_credentials(%{agent: %AgentRecord{} = agent} = projection) do
    %{projection | agent: without_agent_credentials(agent)}
  end

  defp without_agent_credentials(%AgentRecord{} = agent), do: %{agent | agent_token: nil}

  defp fleet_overview(snapshot, generations) do
    generation =
      Enum.find(generations, &(&1.agent_id == snapshot.agent.id and is_nil(&1.retired_at)))

    Map.take(snapshot, [:agent, :stale?, :overview, :ships, :activity, :control])
    |> Map.put(:generation, generation)
  end

  defp objective_overviews(nil, _generations), do: []

  defp objective_overviews(revision, generations) do
    generation =
      Enum.find(generations, fn generation ->
        generation.fleet_strategy_revision_id == revision.id and is_nil(generation.retired_at)
      end)

    revision.document
    |> Map.get("objectives", [])
    |> Enum.with_index()
    |> Enum.map(fn {objective, index} ->
      facts = generation && Map.get(generation.objective_progress, Integer.to_string(index))

      %{
        objective: objective,
        evaluation:
          if(is_map(facts),
            do: FleetStrategy.evaluate_objective(revision, index, atomize_keys(facts)),
            else: {:error, :unknown}
          )
      }
    end)
  end

  defp atomize_keys(facts),
    do: Map.new(facts, fn {key, value} -> {@evaluation_fact_keys[key], value} end)

  defp namespace_facts(facts, namespace) do
    Map.new(facts, fn {field, fact} -> {"#{namespace}.#{field}", fact} end)
  end
end
