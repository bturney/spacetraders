defmodule SpaceTraders.Intelligence do
  @moduledoc "Persisted, provenance-bearing observations of the game world."

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence.{Fact, Observation}
  alias SpaceTraders.Repo

  @waypoint_fields [
    :symbol,
    :system_symbol,
    :type,
    :x,
    :y,
    :orbits,
    :orbitals,
    :traits,
    :modifiers,
    :chart,
    :faction,
    :is_under_construction
  ]
  @waypoint_listing_fields [:symbol, :system_symbol, :type, :x, :y, :orbits, :orbitals, :traits]
  @market_composition_fields [:symbol, :exports, :imports, :exchange]
  @market_listing_fields @market_composition_fields ++ [:trade_goods, :transactions]
  @baseline_waypoint_fields [
    :symbol,
    :type,
    :x,
    :y,
    :orbits,
    :orbitals,
    :traits,
    :modifiers,
    :is_under_construction
  ]
  @marketplace_trait "MARKETPLACE"

  @doc "Records one Waypoint observation without claiming omitted fields are false."
  def observe_waypoint(%AgentRecord{} = agent, waypoint, opts \\ []) do
    fields =
      if Keyword.get(opts, :source) == "get_waypoints",
        do: @waypoint_listing_fields,
        else: @waypoint_fields

    observe(
      agent,
      "waypoint",
      waypoint.system_symbol,
      waypoint.symbol,
      waypoint,
      fields,
      opts
    )
  end

  @doc "Records one Market Listing observation, optionally tied to its observing Ship."
  def observe_market(%AgentRecord{} = agent, system_symbol, market, opts \\ []) do
    fields =
      if Keyword.get(opts, :observing_ship_symbol),
        do: @market_listing_fields,
        else: @market_composition_fields

    observe(agent, "market", system_symbol, market.symbol, market, fields, opts)
  end

  @doc "Records an authoritative declaration that a field cannot currently be read."
  def mark_unavailable(
        %AgentRecord{} = agent,
        subject_type,
        system_symbol,
        symbol,
        fields,
        opts \\ []
      ) do
    observe(
      agent,
      subject_type,
      system_symbol,
      symbol,
      %{},
      fields,
      Keyword.put(opts, :unavailable, true)
    )
  end

  @doc "Returns current usable facts for one subject, grouped by field with provenance."
  def subject(%AgentRecord{} = agent, subject_type, system_symbol, symbol) do
    facts =
      Fact
      |> join(:inner, [fact], observation in assoc(fact, :observation))
      |> where(
        [fact],
        fact.agent_id == ^agent.id and fact.subject_type == ^to_string(subject_type) and
          fact.subject_system_symbol == ^system_symbol and fact.subject_symbol == ^symbol and
          is_nil(fact.invalidated_at)
      )
      |> order_by([fact, observation], desc: observation.observed_at, desc: fact.id)
      |> preload([_fact, observation], observation: observation)
      |> Repo.all()

    facts
    |> Enum.group_by(& &1.field)
    |> Map.new(fn {field, field_facts} -> {field, usable_fact(field_facts) |> present_fact()} end)
  end

  @doc "Returns baseline fact gaps for the supplied authoritative System Waypoints."
  def waypoint_coverage(%AgentRecord{} = agent, system_symbol, waypoints)
      when is_list(waypoints) do
    Map.new(waypoints, fn waypoint ->
      facts = subject(agent, :waypoint, system_symbol, waypoint.symbol)

      required =
        if marketplace?(waypoint),
          do: @baseline_waypoint_fields ++ Enum.map(@market_composition_fields, &{:market, &1}),
          else: @baseline_waypoint_fields

      missing =
        required
        |> Enum.reject(&known?(agent, system_symbol, waypoint.symbol, facts, &1))
        |> Enum.map(&coverage_field_name/1)

      {waypoint.symbol, %{missing: missing, complete?: missing == []}}
    end)
  end

  @doc "Marks mutable facts for a subject stale after a confirmed mutation or precondition conflict."
  def invalidate(%AgentRecord{} = agent, subject_type, system_symbol, symbol, fields \\ :all) do
    query =
      Fact
      |> where(
        [fact],
        fact.agent_id == ^agent.id and fact.subject_type == ^to_string(subject_type) and
          fact.subject_system_symbol == ^system_symbol and fact.subject_symbol == ^symbol and
          is_nil(fact.invalidated_at)
      )

    query =
      if fields == :all,
        do: query,
        else: where(query, [fact], fact.field in ^Enum.map(fields, &to_string/1))

    {count, _} = Repo.update_all(query, set: [invalidated_at: now()])
    {:ok, count}
  end

  defp observe(agent, subject_type, system, symbol, payload, fields, opts) do
    attrs = %{
      agent_id: agent.id,
      observing_ship_symbol: Keyword.get(opts, :observing_ship_symbol),
      source: Keyword.get(opts, :source, "api"),
      subject_type: subject_type,
      subject_system_symbol: system,
      subject_symbol: symbol,
      observed_at: Keyword.get(opts, :observed_at, now())
    }

    Repo.transaction(fn ->
      observation = Repo.insert!(Observation.changeset(%Observation{}, attrs))

      Enum.each(fields, fn field ->
        {state, value} = field_value(payload, field, opts)

        Repo.insert!(
          Fact.changeset(%Fact{}, %{
            observation_id: observation.id,
            agent_id: agent.id,
            subject_type: subject_type,
            subject_system_symbol: system,
            subject_symbol: symbol,
            field: to_string(field),
            state: state,
            value: wrap_value(value)
          })
        )
      end)

      observation
    end)
  end

  defp marketplace?(%{traits: traits}) do
    Enum.any?(traits || [], &(&1.symbol == @marketplace_trait))
  end

  defp marketplace?(_), do: false

  defp known?(_agent, _system, _symbol, facts, field) when is_atom(field) do
    match?(%Fact{state: "known"}, Map.get(facts, to_string(field)))
  end

  defp known?(agent, system, symbol, _facts, {:market, field}) do
    match?(%Fact{state: "known"}, subject(agent, :market, system, symbol)[to_string(field)])
  end

  defp coverage_field_name({:market, field}), do: "market_#{field}"
  defp coverage_field_name(field), do: to_string(field)

  defp field_value(payload, field, opts) do
    if opts[:unavailable] do
      {"known_unavailable", nil}
    else
      value = Map.get(payload, field)

      if not is_nil(value) or opts[:source] == "get_waypoint" do
        {"known", normalize(value)}
      else
        {"unknown", nil}
      end
    end
  end

  # A partial endpoint must not erase an earlier usable fact. Unknown remains
  # visible only when it is the only observation for that field.
  defp usable_fact(facts), do: Enum.find(facts, &(&1.state != "unknown")) || List.first(facts)

  defp present_fact(nil), do: nil
  defp present_fact(%Fact{value: %{"value" => value}} = fact), do: %{fact | value: value}
  defp present_fact(fact), do: fact

  defp wrap_value(nil), do: nil
  defp wrap_value(value), do: %{"value" => value}

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> normalize()
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(value), do: value
  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
