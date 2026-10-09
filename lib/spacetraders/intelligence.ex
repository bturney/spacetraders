defmodule SpaceTraders.Intelligence do
  @moduledoc "Persisted, provenance-bearing observations of the game world."

  import Ecto.Query

  require Logger

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Evidence.Observation, as: EvidenceObservation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Intelligence.{Fact, Observation, Survey}
  alias SpaceTraders.{Clock, Repo}

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
  @scanned_waypoint_fields [
    :symbol,
    :system_symbol,
    :type,
    :x,
    :y,
    :orbitals,
    :traits,
    :chart,
    :faction
  ]
  @market_composition_fields [:symbol, :exports, :imports, :exchange]
  @market_listing_fields @market_composition_fields ++ [:trade_goods, :transactions]
  @shipyard_fields [:symbol, :ship_types, :ships, :transactions, :modifications_fee]
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
  # The established Market Listing freshness budget. It applies to Market
  # Listings only, never to Waypoint or resource facts.
  @market_freshness_seconds 300

  @doc "Records a Survey returned by an on-site survey action."
  def record_survey(%AgentRecord{} = agent, survey, waypoint_symbol, opts \\ []) do
    attrs = %{
      agent_id: agent.id,
      waypoint_symbol: waypoint_symbol,
      signature: survey.signature,
      symbol: survey.symbol,
      size: survey.size,
      expiration: parse_datetime(survey.expiration),
      deposits: Enum.map(survey.deposits || [], &%{"symbol" => &1.symbol}),
      source: Keyword.get(opts, :source, "survey"),
      observing_ship_symbol: Keyword.get(opts, :observing_ship_symbol),
      observed_at: Keyword.get(opts, :observed_at, now())
    }

    %Survey{}
    |> Survey.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :symbol,
           :size,
           :expiration,
           :deposits,
           :source,
           :observing_ship_symbol,
           :observed_at,
           :updated_at
         ]},
      conflict_target: [:agent_id, :signature]
    )
  end

  @doc "Returns one usable Survey for an Agent at an extraction Waypoint."
  def usable_survey(%AgentRecord{} = agent, waypoint_symbol, now \\ now()) do
    Survey
    |> where(
      [survey],
      survey.agent_id == ^agent.id and survey.waypoint_symbol == ^waypoint_symbol and
        survey.expiration > ^now and is_nil(survey.exhausted_at)
    )
    |> order_by([survey], desc: survey.inserted_at, desc: survey.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Marks a Survey unusable after an authoritative extraction rejection."
  def exhaust_survey(%AgentRecord{} = agent, signature) do
    {_, _} =
      Survey
      |> where([survey], survey.agent_id == ^agent.id and survey.signature == ^signature)
      |> Repo.update_all(set: [exhausted_at: now()])

    :ok
  end

  @doc "Records one Waypoint observation without claiming omitted fields are false."
  def observe_waypoint(%AgentRecord{} = agent, waypoint, opts \\ []) do
    fields =
      case Keyword.get(opts, :source) do
        "get_waypoints" -> @waypoint_listing_fields
        "scan_waypoints" -> @scanned_waypoint_fields
        _ -> @waypoint_fields
      end

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

  def observe_shipyard(%AgentRecord{} = agent, system_symbol, shipyard, opts \\ []) do
    payload =
      if Keyword.get(opts, :offers_visible, false),
        do: shipyard,
        else: Map.put(shipyard, :ships, nil)

    observe(agent, "shipyard", system_symbol, shipyard.symbol, payload, @shipyard_fields, opts)
  end

  @doc "Records authoritative Construction progress as independently refreshable facts."
  def observe_construction(%AgentRecord{} = agent, system_symbol, construction, opts \\ []) do
    {payload, fields} = construction_fields(construction)
    observe(agent, "construction", system_symbol, construction.symbol, payload, fields, opts)
  end

  @doc "Records a Jump Gate's connections without inferring endpoint readiness."
  def observe_jump_gate(%AgentRecord{} = agent, system_symbol, gate, opts \\ []) do
    observe(agent, "jump_gate", system_symbol, gate.symbol, gate, [:connections], opts)
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
    subject_type = to_string(subject_type)

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

  def known_waypoints(%AgentRecord{} = agent, system_symbol) when is_binary(system_symbol) do
    Fact
    |> where(
      [fact],
      fact.agent_id == ^agent.id and fact.subject_type == "waypoint" and
        fact.subject_system_symbol == ^system_symbol and fact.field == "symbol" and
        fact.state == "known" and is_nil(fact.invalidated_at)
    )
    |> select([fact], fact.subject_symbol)
    |> distinct(true)
    |> Repo.all()
    |> Enum.sort()
  end

  @doc """
  Returns known Marketplace Waypoint symbols in one System in stable order.

  A Waypoint is a known Marketplace when its newest Waypoint traits fact
  retained at `decision_time`, and still valid then, lists the Marketplace
  trait.
  """
  def marketplace_waypoints(%AgentRecord{} = agent, system_symbol, decision_time \\ now())
      when is_binary(system_symbol) do
    agent
    |> newest_facts_at("waypoint", system_symbol, "traits", decision_time)
    |> Enum.filter(fn {fact, _observation, _evidence} ->
      fact.state == "known" and valid_at?(fact, decision_time) and
        Enum.any?(
          Map.get(fact.value || %{}, "value") || [],
          &(Map.get(&1, "symbol") == @marketplace_trait)
        )
    end)
    |> Enum.map(fn {fact, _observation, _evidence} -> fact.subject_symbol end)
    |> Enum.sort()
  end

  @doc """
  The single read-only interpretation of retained Market Listings and
  known-Marketplace coverage for one Agent System at one fixed decision time.

  Runtime Market planning, shadow evaluation, Strategy review and coverage
  read this. The result is directly a Fleet Planning Market snapshot
  (`:as_of`, `:system_symbol`, `:agent_id`, `:freshness_seconds`, `:markets`,
  `:baseline_subjects`). It acquires nothing, publishes nothing and never
  restamps evidence time.

  Each `:markets` entry is the newest non-omitted `trade_goods` fact retained
  at the decision time for one Market (ties: the later retained record), with
  its own original acquisition time and a `:state`:

  - `:current` - exactly linked governed evidence of this Agent's current
    Fleet Generation, well-formed and within the Market freshness budget;
    the only state that can support an actionable trade;
  - `:stale` - aged out; justifies re-observation, never a trade;
  - `:invalidated` - explicitly invalidated by the decision time; no fallback
    to older Listings;
  - `:untraceable` - legacy or unlinked record; kept visible, never support;
  - `:wrong_generation` - governed evidence of another Fleet Generation;
  - `:malformed` - a Listing that is not a well-formed list of goods;
  - `:unavailable` - the game declared the Listing unreadable;
  - `:future` - only evidence after the decision time exists.

  `:baseline_subjects` are the Marketplaces known at the decision time;
  `:coverage_gaps` names each one without a `:current` Listing, keeping
  never-observed Marketplaces explicit (`:never_observed`). Known-Marketplace
  coverage never proves System discovery, so `:system_discovery` is
  `:unproven`.
  """
  def market_interpretation(%AgentRecord{} = agent, system_symbol, %DateTime{} = decision_time)
      when is_binary(system_symbol) do
    generation_id = current_generation_id(agent)

    retained =
      agent
      |> newest_facts_at("market", system_symbol, "trade_goods", decision_time)
      |> Enum.map(&market_listing(&1, system_symbol, decision_time, generation_id))

    retained_subjects = MapSet.new(retained, & &1.subject)

    future =
      agent
      |> future_subjects("market", system_symbol, "trade_goods", decision_time)
      |> Enum.map(&market_subject(system_symbol, &1))
      |> Enum.reject(&MapSet.member?(retained_subjects, &1))
      |> Enum.map(&unsupported_listing(&1, :future))

    markets = Enum.sort_by(retained ++ future, & &1.subject)
    states = Map.new(markets, &{&1.subject, &1.state})

    baseline =
      agent
      |> marketplace_waypoints(system_symbol, decision_time)
      |> Enum.map(&market_subject(system_symbol, &1))

    %{
      as_of: decision_time,
      system_symbol: system_symbol,
      agent_id: agent.id,
      fleet_generation_id: generation_id,
      freshness_seconds: @market_freshness_seconds,
      markets: markets,
      baseline_subjects: baseline,
      coverage_gaps:
        Enum.flat_map(baseline, fn subject ->
          case Map.get(states, subject, :never_observed) do
            :current -> []
            reason -> [%{subject: subject, reason: reason}]
          end
        end),
      system_discovery: :unproven
    }
  end

  defp market_subject(system_symbol, waypoint_symbol),
    do: "market:#{system_symbol}:#{waypoint_symbol}"

  # Newest non-omitted fact per subject among records acquired at or before
  # the decision time. Equal acquisition times select the later record.
  defp newest_facts_at(agent, subject_type, system_symbol, field, decision_time) do
    Fact
    |> join(:inner, [fact], observation in assoc(fact, :observation))
    |> join(:left, [_fact, observation], evidence in EvidenceObservation,
      on: evidence.id == observation.evidence_observation_id
    )
    |> where(
      [fact, observation],
      fact.agent_id == ^agent.id and fact.subject_type == ^subject_type and
        fact.subject_system_symbol == ^system_symbol and fact.field == ^field and
        fact.state != "unknown" and observation.observed_at <= ^decision_time
    )
    |> distinct([fact], asc: fact.subject_symbol)
    |> order_by([fact, observation],
      asc: fact.subject_symbol,
      desc: observation.observed_at,
      desc: observation.id
    )
    |> select([fact, observation, evidence], {fact, observation, evidence})
    |> Repo.all()
  end

  defp future_subjects(agent, subject_type, system_symbol, field, decision_time) do
    Fact
    |> join(:inner, [fact], observation in assoc(fact, :observation))
    |> where(
      [fact, observation],
      fact.agent_id == ^agent.id and fact.subject_type == ^subject_type and
        fact.subject_system_symbol == ^system_symbol and fact.field == ^field and
        fact.state != "unknown" and observation.observed_at > ^decision_time
    )
    |> select([fact], fact.subject_symbol)
    |> distinct(true)
    |> Repo.all()
  end

  defp valid_at?(%Fact{invalidated_at: nil}, _decision_time), do: true

  defp valid_at?(%Fact{invalidated_at: invalidated_at}, decision_time),
    do: DateTime.compare(invalidated_at, decision_time) == :gt

  defp market_listing({fact, observation, evidence}, system_symbol, decision_time, generation_id) do
    subject = market_subject(system_symbol, fact.subject_symbol)
    goods = Map.get(fact.value || %{}, "value")

    cond do
      not valid_at?(fact, decision_time) ->
        unsupported_listing(subject, :invalidated)

      fact.state == "known_unavailable" ->
        unsupported_listing(subject, :unavailable)

      not traceable?(evidence, observation, subject) ->
        %{
          unsupported_listing(subject, :untraceable)
          | observed_at: observation.observed_at,
            source: observation.source,
            trade_goods: goods
        }

      DateTime.compare(evidence.observed_at, decision_time) == :gt ->
        unsupported_listing(subject, :future)

      true ->
        %{
          subject: subject,
          state: governed_state(evidence, goods, decision_time, generation_id),
          observed_at: evidence.observed_at,
          evidence_id: "evidence-observation:#{evidence.id}",
          source: evidence.operation_id,
          fleet_generation_id: evidence.fleet_generation_id,
          trade_goods: goods
        }
    end
  end

  defp unsupported_listing(subject, state) do
    %{
      subject: subject,
      state: state,
      observed_at: nil,
      evidence_id: nil,
      source: nil,
      fleet_generation_id: nil,
      trade_goods: nil
    }
  end

  # Exact persisted lineage only: equal payloads never establish a source.
  defp traceable?(%EvidenceObservation{} = evidence, observation, subject) do
    evidence.agent_id == observation.agent_id and evidence.subject == subject and
      evidence.operation_id == "get-market"
  end

  defp traceable?(nil, _observation, _subject), do: false

  defp governed_state(evidence, goods, decision_time, generation_id) do
    cond do
      evidence.fleet_generation_id != generation_id ->
        :wrong_generation

      not well_formed_listing?(goods) ->
        :malformed

      DateTime.diff(decision_time, evidence.observed_at, :second) > @market_freshness_seconds ->
        :stale

      true ->
        :current
    end
  end

  defp well_formed_listing?(goods) when is_list(goods) do
    Enum.all?(goods, fn good ->
      is_map(good) and is_binary(good["symbol"]) and
        non_negative_integer?(good["purchase_price"]) and
        non_negative_integer?(good["sell_price"]) and is_integer(good["trade_volume"]) and
        good["trade_volume"] > 0
    end)
  end

  defp well_formed_listing?(_goods), do: false

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp current_generation_id(agent) do
    Repo.one(
      from generation in Generation,
        where: generation.agent_id == ^agent.id and is_nil(generation.retired_at),
        select: generation.id
    )
  end

  @doc "Returns current facts and invalidated facts separately for subject inspection."
  def subject_with_stale(%AgentRecord{} = agent, subject_type, system_symbol, symbol) do
    facts =
      Fact
      |> join(:inner, [fact], observation in assoc(fact, :observation))
      |> where(
        [fact],
        fact.agent_id == ^agent.id and fact.subject_type == ^to_string(subject_type) and
          fact.subject_system_symbol == ^system_symbol and fact.subject_symbol == ^symbol
      )
      |> order_by([fact, observation], desc: observation.observed_at, desc: fact.id)
      |> preload([_fact, observation], observation: observation)
      |> Repo.all()

    %{
      current:
        facts
        |> Enum.reject(& &1.invalidated_at)
        |> facts_by_field(),
      stale:
        facts
        |> Enum.filter(& &1.invalidated_at)
        |> facts_by_field()
    }
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
  def invalidate(
        %AgentRecord{} = agent,
        subject_type,
        system_symbol,
        symbol,
        fields \\ :all,
        opts \\ []
      ) do
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

    query =
      if to_string(subject_type) == "waypoint",
        do: where(query, [fact], fact.field not in ["symbol", "system_symbol"]),
        else: query

    {count, _} = Repo.update_all(query, set: [invalidated_at: now()])
    emit_invalidation(agent, subject_type, system_symbol, symbol, fields, count, opts)
    {:ok, count}
  end

  # Bounded cause and counts only. Agent and subject identities are log
  # metadata, never telemetry metadata that could become metric labels.
  defp emit_invalidation(agent, subject_type, system_symbol, symbol, fields, count, opts) do
    cause = Keyword.get(opts, :cause, :unspecified)
    field_count = if fields == :all, do: 0, else: length(fields)

    :telemetry.execute(
      [:spacetraders, :intelligence, :invalidation],
      %{facts: count, requested_fields: field_count},
      %{cause: cause, subject_type: to_string(subject_type)}
    )

    Logger.info("Intelligence facts invalidated",
      cause: cause,
      invalidated_facts: count,
      agent_id: agent.id,
      subject_type: to_string(subject_type),
      system_symbol: system_symbol,
      subject_symbol: symbol
    )
  end

  defp observe(agent, subject_type, system, symbol, payload, fields, opts) do
    evidence = Keyword.get(opts, :evidence)

    attrs = %{
      agent_id: agent.id,
      observing_ship_symbol: Keyword.get(opts, :observing_ship_symbol),
      source: Keyword.get(opts, :source, "api"),
      subject_type: subject_type,
      subject_system_symbol: system,
      subject_symbol: symbol,
      observed_at: Keyword.get_lazy(opts, :observed_at, fn -> acquisition_time(evidence) end),
      evidence_observation_id: evidence && evidence.id
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

  # A projection of governed evidence keeps the evidence's original
  # acquisition time; the projection clock never restamps it.
  defp acquisition_time(%EvidenceObservation{observed_at: observed_at}),
    do: DateTime.truncate(observed_at, :second)

  defp acquisition_time(nil), do: now()

  defp marketplace?(%{traits: traits}) do
    Enum.any?(traits || [], &(&1.symbol == @marketplace_trait))
  end

  defp marketplace?(_), do: false

  defp construction_fields(construction) do
    materials = construction.materials || []

    material_facts =
      Enum.flat_map(materials, fn material ->
        remaining = max((material.required || 0) - (material.fulfilled || 0), 0)
        prefix = "material:#{material.trade_symbol}"

        [
          {"#{prefix}:required", material.required},
          {"#{prefix}:fulfilled", material.fulfilled},
          {"#{prefix}:remaining", remaining}
        ]
      end)

    Map.new([{"complete", construction.is_complete} | material_facts])
    |> then(fn payload -> {payload, Map.keys(payload)} end)
  end

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

      if not is_nil(value) do
        {"known", normalize(value)}
      else
        {"unknown", nil}
      end
    end
  end

  # A partial endpoint must not erase an earlier usable fact. Unknown remains
  # visible only when it is the only observation for that field.
  defp usable_fact(facts), do: Enum.find(facts, &(&1.state != "unknown")) || List.first(facts)

  defp facts_by_field(facts) do
    facts
    |> Enum.group_by(& &1.field)
    |> Map.new(fn {field, field_facts} -> {field, usable_fact(field_facts) |> present_fact()} end)
  end

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

  defp parse_datetime(value) when is_binary(value), do: DateTime.from_iso8601(value) |> elem(1)

  defp now, do: Clock.utc_now() |> DateTime.truncate(:second)
end
