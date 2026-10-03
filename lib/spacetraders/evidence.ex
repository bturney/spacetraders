defmodule SpaceTraders.Evidence do
  @demand_topic "observation_demands"
  @moduledoc """
  Owns durable Observation Demands and authoritative evidence provenance.

  Emergency Stop resume uses this seam so Fleet Strategy coordinates durable
  authority without invoking or interpreting gameplay reads itself.
  """

  import Ecto.Query

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Clock
  alias SpaceTraders.Evidence.{Demand, Observation, ObservationDemand}
  alias SpaceTraders.Evidence.ReadCoordinator
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @owned_read_deadline_seconds 60
  @owned_read_freshness_seconds 30

  @market_facts ~w(symbol exports imports exchange trade_goods transactions)
  @waypoint_facts ~w(symbol system_symbol type x y orbits orbitals traits modifiers chart faction is_under_construction)
  @construction_facts ~w(symbol is_complete materials)
  @jump_gate_facts ~w(symbol connections)
  @shipyard_facts ~w(symbol ship_types transactions)
  @system_facts ~w(symbol sector type x y waypoints)
  @market_required_facts ~w(exports imports exchange)
  @waypoint_required_facts ~w(symbol system_symbol type traits)
  @construction_required_facts ~w(symbol is_complete materials)
  @jump_gate_required_facts ~w(symbol connections)
  @shipyard_required_facts ~w(symbol ship_types)
  @system_required_facts ~w(symbol)

  @doc "Reads a System through a governed World Observation Demand."
  def get_system(token_or_agent, system_symbol, opts \\ []) when is_binary(system_symbol) do
    governed_read(
      token_or_agent,
      "system:#{system_symbol}",
      "get-system",
      @system_required_facts,
      opts,
      fn reference, read_opts -> API.get_system(reference, system_symbol, read_opts) end
    )
  end

  @doc "Returns the latest governed observation retained for one Agent subject."
  def latest_observation(%AgentRecord{} = agent, subject)
      when is_binary(subject) and subject != "" do
    Observation
    |> where([observation], observation.agent_id == ^agent.id and observation.subject == ^subject)
    |> order_by([observation], desc: observation.observed_at, desc: observation.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Reads one page of Waypoints through a governed World Observation Demand."
  def get_waypoints(token_or_agent, system_symbol, params \\ [], opts \\ [])
      when is_binary(system_symbol) and is_list(params) and is_list(opts) do
    governed_read(
      token_or_agent,
      "waypoints:#{system_symbol}",
      "get-system-waypoints",
      ["waypoints"],
      opts,
      fn reference, read_opts ->
        API.get_waypoints(reference, system_symbol, params, read_opts)
      end,
      {:page, params}
    )
  end

  @doc "Reads every Waypoint page through one governed World demand."
  def get_waypoints_paginated(token_or_agent, system_symbol, params \\ [], opts \\ [])
      when is_binary(system_symbol) and is_list(params) and is_list(opts) do
    governed_read(
      token_or_agent,
      "waypoints:#{system_symbol}",
      "get-system-waypoints",
      ["waypoints"],
      opts,
      fn reference, read_opts ->
        API.get_waypoints_paginated(reference, system_symbol, params, read_opts)
      end,
      {:paginated, params}
    )
  end

  @doc "Reads a Waypoint through a governed World Observation Demand."
  def get_waypoint(token_or_agent, system_symbol, waypoint_symbol, opts \\ [])
      when is_binary(system_symbol) and is_binary(waypoint_symbol) do
    governed_read(
      token_or_agent,
      "waypoint:#{system_symbol}:#{waypoint_symbol}",
      "get-waypoint",
      @waypoint_required_facts,
      opts,
      fn reference, read_opts ->
        API.get_waypoint(reference, system_symbol, waypoint_symbol, read_opts)
      end
    )
  end

  @doc "Reads a Market through a governed Market Observation Demand."
  def get_market(token_or_agent, system_symbol, waypoint_symbol, opts \\ [])
      when is_binary(system_symbol) and is_binary(waypoint_symbol) do
    governed_read(
      token_or_agent,
      "market:#{system_symbol}:#{waypoint_symbol}",
      "get-market",
      @market_required_facts,
      opts,
      fn reference, read_opts ->
        API.get_market(reference, system_symbol, waypoint_symbol, read_opts)
      end
    )
  end

  @doc "Reads Construction state through a governed World Observation Demand."
  def get_construction(token_or_agent, system_symbol, waypoint_symbol, opts \\ [])
      when is_binary(system_symbol) and is_binary(waypoint_symbol) do
    governed_read(
      token_or_agent,
      "construction:#{system_symbol}:#{waypoint_symbol}",
      "get-construction",
      @construction_required_facts,
      opts,
      fn reference, read_opts ->
        API.get_construction(reference, system_symbol, waypoint_symbol, read_opts)
      end
    )
  end

  @doc "Reads Jump Gate state through a governed World Observation Demand."
  def get_jump_gate(token_or_agent, system_symbol, waypoint_symbol, opts \\ [])
      when is_binary(system_symbol) and is_binary(waypoint_symbol) do
    governed_read(
      token_or_agent,
      "jump_gate:#{system_symbol}:#{waypoint_symbol}",
      "get-jump-gate",
      @jump_gate_required_facts,
      opts,
      fn reference, read_opts ->
        API.get_jump_gate(reference, system_symbol, waypoint_symbol, read_opts)
      end
    )
  end

  @doc "Reads Shipyard state through a governed Market Observation Demand."
  def get_shipyard(token_or_agent, system_symbol, waypoint_symbol, opts \\ [])
      when is_binary(system_symbol) and is_binary(waypoint_symbol) do
    governed_read(
      token_or_agent,
      "shipyard:#{system_symbol}:#{waypoint_symbol}",
      "get-shipyard",
      @shipyard_required_facts,
      opts,
      fn reference, read_opts ->
        API.get_shipyard(reference, system_symbol, waypoint_symbol, read_opts)
      end
    )
  end

  defp governed_read(
         token_or_agent,
         subject,
         operation_id,
         default_facts,
         opts,
         read,
         key_suffix \\ nil
       ) do
    credential_ref = credential_reference(token_or_agent)
    agent = owned_agent(credential_ref)
    required_facts = Keyword.get(opts, :required_facts, default_facts)
    demand = typed_demand(agent, subject, required_facts, opts)
    {persisted_demand, demand} = persist_owned_demand(agent, demand)
    request_opts = Keyword.put(opts, :demand, demand)
    key = {operation_id, subject, credential_ref.agent_id, key_suffix}

    result = ReadCoordinator.read(key, fn -> read.(credential_ref, request_opts) end)
    settle_governed_read(result, persisted_demand, agent, subject, operation_id)
  end

  defp settle_governed_read(
         {:ok, value} = result,
         %ObservationDemand{} = demand,
         %AgentRecord{} = agent,
         subject,
         operation_id
       ) do
    demand = Repo.get!(ObservationDemand, demand.id)

    if is_nil(demand.fulfilled_observation_id) do
      facts = read_facts(operation_id, value)

      observation =
        authoritative_observation(operation_id, [subject], facts, Clock.utc_now())

      _ = fulfil_demands(agent, subject, observation)
    end

    result
  rescue
    _error ->
      _ = withdraw_demand(demand)
      result
  end

  defp settle_governed_read(
         result,
         %ObservationDemand{} = demand,
         _agent,
         _subject,
         _operation_id
       ) do
    _ = withdraw_demand(demand)
    result
  end

  defp settle_governed_read(result, nil, _agent, _subject, _operation_id), do: result

  defp read_facts(operation_id, value) do
    response = serialize_read_value(value)

    fields =
      case operation_id do
        "get-market" -> @market_facts
        "get-waypoint" -> @waypoint_facts
        "get-construction" -> @construction_facts
        "get-jump-gate" -> @jump_gate_facts
        "get-shipyard" -> @shipyard_facts
        "get-system" -> @system_facts
        "get-system-waypoints" -> ["waypoints"]
        _ -> []
      end

    facts = if is_map(response), do: Map.take(response, fields), else: %{"waypoints" => response}
    Map.merge(%{"response" => response}, facts)
  end

  @doc "Reads the authoritative Agent record through a typed Observation Demand."
  def get_agent(token_or_agent, opts \\ []) when is_list(opts) do
    owned_read(
      token_or_agent,
      "agent:#{owned_symbol(token_or_agent, "unknown")}",
      "get-my-agent",
      ["response"],
      opts,
      &API.get_agent/2
    )
  end

  @doc "Reads the authoritative owned Fleet through a typed Observation Demand."
  def get_ships(token_or_agent, opts \\ []) when is_list(opts) do
    owned_read(
      token_or_agent,
      "fleet:#{owned_symbol(token_or_agent, "unknown")}",
      "get-my-ships",
      ["response"],
      opts,
      &API.get_ships/2
    )
  end

  @doc "Reads one authoritative Ship through a typed Observation Demand."
  def get_ship(token_or_agent, ship_symbol, opts \\ [])
      when is_binary(ship_symbol) and is_list(opts) do
    owned_read(
      token_or_agent,
      "ship:#{ship_symbol}",
      "get-my-ship",
      ["response"],
      opts,
      fn reference, read_opts ->
        with {:ok, ship} <- API.get_ship(reference, ship_symbol, read_opts),
             :ok <- SpaceTraders.Evidence.ShipObservation.validate(ship, ship_symbol) do
          {:ok, ship}
        end
      end
    )
  end

  @doc "Validates a supplied Ship against its fresh retained authoritative read, or reads anew."
  def recovery_ship(%AgentRecord{} = agent, symbol, supplied, since \\ nil) do
    observation = latest_observation(agent, "ship:#{symbol}")

    if SpaceTraders.Evidence.ShipObservation.matches?(observation, supplied, symbol, since) do
      {:ok, supplied}
    else
      get_ship(agent, symbol, lane: :safety, owner: "ship_execution")
    end
  end

  @doc "Reads authoritative Contracts through a typed Observation Demand."
  def get_contracts(token_or_agent, opts \\ []) when is_list(opts) do
    owned_read(
      token_or_agent,
      "contracts:#{owned_symbol(token_or_agent, "unknown")}",
      "get-contracts",
      ["response"],
      opts,
      &API.get_contracts/2
    )
  end

  defp owned_read(token_or_agent, subject, operation_id, required_facts, opts, read) do
    credential_ref = credential_reference(token_or_agent)
    agent = owned_agent(credential_ref)
    demand = typed_demand(agent, subject, required_facts, opts)
    {persisted_demand, demand} = persist_owned_demand(agent, demand)
    request_opts = Keyword.put(opts, :demand, demand)

    result = read.(credential_ref, request_opts)
    settle_owned_demand(result, persisted_demand, agent, subject, operation_id, demand)
  end

  defp typed_demand(agent, subject, required_facts, opts) do
    now = Clock.utc_now()

    %Demand{
      subject: subject,
      required_facts: required_facts,
      owner: Keyword.get(opts, :owner, "evidence"),
      due_at: now,
      deadline_at:
        Keyword.get(
          opts,
          :deadline_at,
          DateTime.add(now, @owned_read_deadline_seconds, :second)
        ),
      freshness_seconds: Keyword.get(opts, :freshness_seconds, @owned_read_freshness_seconds),
      agent_id: agent && agent.id,
      strategy_revision_id: nil,
      lane: Keyword.get(opts, :lane, :standard),
      strategic_priority: Keyword.get(opts, :strategic_priority),
      expected_value: Keyword.get(opts, :expected_value),
      discovery: Keyword.get(opts, :discovery, false)
    }
  end

  defp persist_owned_demand(nil, demand), do: {nil, demand}

  defp persist_owned_demand(
         %AgentRecord{operator_id: operator_id} = agent,
         %Demand{} = demand
       )
       when is_integer(operator_id) do
    case active_revision(agent.operator_id) do
      %Revision{} = revision ->
        attrs = %{
          subject: demand.subject,
          required_facts: demand.required_facts,
          freshness_seconds: demand.freshness_seconds,
          due_at: demand.due_at,
          deadline_at: demand.deadline_at,
          owner: demand.owner
        }

        case request_demand(agent, revision, attrs) do
          {:ok, persisted} ->
            {persisted, %{demand | strategy_revision_id: revision.id}}

          {:error, _reason} ->
            {nil, demand}
        end

      nil ->
        {nil, demand}
    end
  end

  defp persist_owned_demand(_agent, demand), do: {nil, demand}

  defp settle_owned_demand(
         {:ok, value} = result,
         %ObservationDemand{} = demand,
         agent,
         subject,
         operation_id,
         _typed_demand
       ) do
    observation =
      authoritative_observation(
        operation_id,
        [subject],
        %{response: serialize_read_value(value)},
        Clock.utc_now()
      )

    case fulfil_demands(agent, subject, observation) do
      {:ok, _evidence} -> result
      {:error, _reason} -> result
    end
  rescue
    _error ->
      _ = withdraw_demand(demand)
      result
  end

  defp settle_owned_demand(
         result,
         %ObservationDemand{} = demand,
         _agent,
         _subject,
         _operation_id,
         _typed_demand
       ) do
    _ = withdraw_demand(demand)
    result
  end

  defp settle_owned_demand(
         {:ok, value} = result,
         nil,
         %AgentRecord{} = agent,
         subject,
         operation_id,
         _typed_demand
       ) do
    observation =
      authoritative_observation(
        operation_id,
        [subject],
        %{response: serialize_read_value(value)},
        Clock.utc_now()
      )

    case fulfil_demands(agent, subject, observation) do
      {:ok, _} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_owned_demand(result, nil, _agent, _subject, _operation_id, _typed_demand),
    do: result

  @doc false
  def recovery_observed_at(agent_id, operation_id, dependencies, fallback) do
    agent = Repo.get!(AgentRecord, agent_id)

    subject =
      SpaceTraders.SafetyFence.DependencyKey.observation_subject(
        operation_id,
        dependencies,
        agent.symbol
      )

    case subject && latest_observation(agent, subject) do
      %Observation{operation_id: ^operation_id, observed_at: observed_at} -> observed_at
      _ -> DateTime.add(fallback, -1, :microsecond)
    end
  end

  defp active_revision(operator_id) do
    Revision
    |> join(:inner, [revision], strategy in Strategy,
      on: strategy.id == revision.fleet_strategy_id
    )
    |> where(
      [revision, strategy],
      strategy.operator_id == ^operator_id and strategy.active_revision_id == revision.id
    )
    |> Repo.one()
  end

  defp credential_reference(%AgentRecord{} = agent), do: AgentTokenReference.new(agent)
  defp credential_reference(%AgentTokenReference{} = reference), do: reference

  defp owned_agent(%AgentTokenReference{agent_id: agent_id}) when is_integer(agent_id),
    do: Repo.get(AgentRecord, agent_id)

  defp owned_agent(%AgentTokenReference{}), do: nil

  defp owned_symbol(%AgentRecord{symbol: symbol}, _fallback), do: symbol

  defp owned_symbol(%AgentTokenReference{agent_id: agent_id}, fallback)
       when is_integer(agent_id) do
    case Repo.get(AgentRecord, agent_id) do
      %AgentRecord{symbol: symbol} -> symbol
      _agent -> fallback
    end
  end

  defp owned_symbol(%AgentTokenReference{}, fallback), do: fallback

  defp serialize_read_value(value), do: stringify_keys(value)

  defp normalize_demand_datetime(attrs) do
    attrs
    |> Map.update(:due_at, nil, fn
      %DateTime{} = datetime -> microsecond_precision(datetime)
      value -> value
    end)
    |> Map.update(:deadline_at, nil, fn
      %DateTime{} = datetime -> microsecond_precision(datetime)
      value -> value
    end)
  end

  defp microsecond_precision(%DateTime{} = datetime) do
    {usec, _precision} = datetime.microsecond
    %{datetime | microsecond: {usec, 6}}
  end

  @doc "Creates a durable Observation Demand for one Fleet Strategy consumer."
  def request_demand(%AgentRecord{} = agent, %Revision{} = revision, attrs)
      when is_map(attrs) do
    if strategy_revision_owned_by_agent?(revision, agent) do
      attrs =
        attrs
        |> normalize_demand_datetime()
        |> Map.put(:agent_id, agent.id)
        |> Map.put(:strategy_revision_id, revision.id)

      %ObservationDemand{}
      |> ObservationDemand.create_changeset(attrs)
      |> Repo.insert()
      |> tap(fn
        {:ok, _demand} -> notify_demand_change(agent.id)
        _error -> :ok
      end)
    else
      {:error, :strategy_provenance_mismatch}
    end
  end

  @doc "Atomically withdraws an open demand and creates its replacement."
  def replace_demand(%ObservationDemand{} = demand, attrs, now \\ Clock.utc_now())
      when is_map(attrs) do
    now = microsecond_precision(now)

    Repo.transaction(fn ->
      current = lock_open_demand!(demand.id)

      current
      |> Ecto.Changeset.change(withdrawn_at: now)
      |> Repo.update!()

      replacement_attrs =
        current
        |> Map.take([
          :subject,
          :required_facts,
          :freshness_seconds,
          :due_at,
          :deadline_at,
          :owner,
          :agent_id,
          :strategy_revision_id
        ])
        |> Map.merge(
          Map.take(attrs, [
            :subject,
            :required_facts,
            :freshness_seconds,
            :due_at,
            :deadline_at,
            :owner
          ])
        )
        |> Map.put(:replaces_id, current.id)

      case Repo.insert(
             ObservationDemand.create_changeset(%ObservationDemand{}, replacement_attrs)
           ) do
        {:ok, replacement} -> replacement
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> tap(fn
      {:ok, replacement} -> notify_demand_change(replacement.agent_id)
      _error -> :ok
    end)
  end

  @doc "Withdraws an open demand without deleting its Strategy provenance."
  def withdraw_demand(%ObservationDemand{} = demand, now \\ Clock.utc_now()) do
    now = microsecond_precision(now)

    Repo.transaction(fn ->
      demand.id
      |> lock_open_demand!()
      |> Ecto.Changeset.change(withdrawn_at: now)
      |> Repo.update!()
    end)
    |> tap(fn {:ok, withdrawn} -> notify_demand_change(withdrawn.agent_id) end)
  end

  @doc """
  Lists open demands in earliest-useful-time order.

  Open means not withdrawn and not fulfilled. A missed `deadline_at` never
  removes a demand from this query: overdue work stays durably visible as a
  decision limitation instead of silently disappearing.
  """
  def list_open_demands(%AgentRecord{} = agent) do
    ObservationDemand
    |> where(
      [demand],
      demand.agent_id == ^agent.id and is_nil(demand.withdrawn_at) and
        is_nil(demand.fulfilled_observation_id)
    )
    |> order_by([demand], asc: demand.due_at, asc: demand.inserted_at, asc: demand.id)
    |> Repo.all()
  end

  @doc """
  Returns strategy-provenanced Market Demand subjects durably settled by
  fulfillment or withdrawal.
  """
  def settled_demand_subjects(%AgentRecord{} = agent, revision_id, subjects)
      when is_integer(revision_id) and is_list(subjects) do
    ObservationDemand
    |> where(
      [demand],
      demand.agent_id == ^agent.id and demand.strategy_revision_id == ^revision_id and
        demand.owner == "fleet_planning" and demand.subject in ^subjects
    )
    |> where(
      [demand],
      not is_nil(demand.fulfilled_observation_id) or not is_nil(demand.withdrawn_at)
    )
    |> select([demand], demand.subject)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns the earliest useful time among all open demands, or `nil`.

  This is the durable ground truth from which the scheduler reconstructs its
  one earliest due wakeup on boot and after every demand change; process timer
  memory is only a wakeup optimization.
  """
  def earliest_due_at do
    ObservationDemand
    |> where(
      [demand],
      not is_nil(demand.agent_id) and is_nil(demand.withdrawn_at) and
        is_nil(demand.fulfilled_observation_id)
    )
    |> select([demand], min(demand.due_at))
    |> Repo.one()
  end

  @doc """
  Returns every open demand whose earliest useful time has passed, soonest first.
  """
  def due_demands(now \\ Clock.utc_now()) do
    now = microsecond_precision(now)

    ObservationDemand
    |> where(
      [demand],
      not is_nil(demand.agent_id) and is_nil(demand.withdrawn_at) and
        is_nil(demand.fulfilled_observation_id) and
        demand.due_at <= ^now
    )
    |> order_by([demand], asc: demand.due_at, asc: demand.inserted_at, asc: demand.id)
    |> Repo.all()
  end

  @doc """
  Withdraws every open demand owned by one Agent without deleting its Strategy
  provenance.

  Fleet Generation retirement and fencing use this to retire a lost Strategy's
  demands: the rows stay durably attributed to their Strategy revision and
  owner, and simply stop participating in scheduling and demand queries.
  """
  def withdraw_agent_demands(agent_id, now \\ Clock.utc_now()) when is_integer(agent_id) do
    now = microsecond_precision(now)

    {withdrawn, _} =
      ObservationDemand
      |> where(
        [demand],
        demand.agent_id == ^agent_id and is_nil(demand.withdrawn_at) and
          is_nil(demand.fulfilled_observation_id)
      )
      |> Repo.update_all(set: [withdrawn_at: now, updated_at: now])

    if withdrawn > 0, do: notify_demand_change(agent_id)
    :ok
  end

  @doc """
  Persists one future Observation Demand per runtime planning description,
  idempotently, with at most one open demand per consumer (`owner`) and
  subject for the active Agent and Strategy Revision.

  For each description:

  - an open demand whose `due_at` matches is left untouched;
  - an open demand whose `due_at` is already due or overdue keeps its timing,
    so API backpressure cannot silently extend the requirement;
  - an open future demand is replaced (provenance preserved through
    `replaces_id`) only when the description moves to a later useful time,
    which happens when newer evidence was retained;
  - with no open demand, a new one is created and, when a previous demand for
    the same consumer and subject exists, chained to it through `replaces_id`;
  - duplicate open demands for the same consumer and subject are consolidated:
    the newest is retained or replaced, older strays are withdrawn.

  Fail-fast: returns the first error and stops; descriptions before it may
  have been persisted. Invalid descriptions (non-map values or rejected
  changesets) return `{:error, term}` instead of silently claiming success.
  """
  def sync_runtime_demands(
        %AgentRecord{} = agent,
        %Revision{} = revision,
        specs,
        now \\ Clock.utc_now()
      )
      when is_list(specs) do
    now = microsecond_precision(now)

    Enum.reduce_while(specs, :ok, fn
      spec, acc when is_map(spec) ->
        case sync_one_runtime_demand(agent, revision, spec, now) do
          :ok -> {:cont, acc}
          {:ok, _demand} -> {:cont, acc}
          {:error, _} = error -> {:halt, error}
        end

      _spec, _acc ->
        {:halt, {:error, :invalid_runtime_demand_spec}}
    end)
  end

  defp sync_one_runtime_demand(agent, revision, spec, now) do
    opens =
      ObservationDemand
      |> where(
        [demand],
        demand.agent_id == ^agent.id and demand.subject == ^spec.subject and
          demand.strategy_revision_id == ^revision.id and demand.owner == ^spec.owner and
          is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id)
      )
      |> order_by([demand], desc: demand.inserted_at, desc: demand.id)
      |> Repo.all()

    due_at = microsecond_precision(spec.due_at)

    case opens do
      [] ->
        create_runtime_demand(agent, revision, spec, due_at)

      # One open demand per consumer and subject: consolidate owner-scoped
      # strays first, then retain or replace the single current row.
      [newest | strays] ->
        Enum.each(strays, fn stray ->
          _ = withdraw_demand(stray, now)
        end)

        cond do
          # The description matches the currently armed demand: idempotent
          # no-op.
          DateTime.compare(due_at, newest.due_at) == :eq ->
            {:ok, newest}

          # API backpressure: an already-due or overdue demand keeps its timing
          # when the description would only move it later. A description that
          # becomes due now or earlier supersedes it instead.
          DateTime.compare(newest.due_at, now) != :gt and
              DateTime.compare(due_at, newest.due_at) == :gt ->
            {:ok, newest}

          # The description supersedes the retained future demand (due now or
          # earlier), or newer evidence moved a future useful time forward:
          # replace through provenance with the full desired timing, clearing
          # any deadline the new description does not carry.
          true ->
            replace_demand(
              newest,
              %{
                required_facts: spec.required_facts,
                freshness_seconds: spec.freshness_seconds,
                due_at: due_at,
                deadline_at: Map.get(spec, :deadline_at)
              },
              now
            )
        end
    end
  end

  defp create_runtime_demand(agent, revision, spec, due_at) do
    # Replacement provenance chains only within the same consumer and the same
    # Strategy Revision: a new owner or a superseding Revision starts fresh.
    predecessor =
      ObservationDemand
      |> where(
        [demand],
        demand.agent_id == ^agent.id and demand.subject == ^spec.subject and
          demand.strategy_revision_id == ^revision.id and demand.owner == ^spec.owner
      )
      |> order_by([demand], desc: demand.inserted_at, desc: demand.id)
      |> limit(1)
      |> Repo.one()

    attrs =
      %{
        subject: spec.subject,
        required_facts: spec.required_facts,
        freshness_seconds: spec.freshness_seconds,
        due_at: due_at,
        deadline_at: Map.get(spec, :deadline_at),
        owner: spec.owner
      }
      |> maybe_put_replaces(predecessor)

    case request_demand(agent, revision, attrs) do
      {:ok, demand} -> {:ok, demand}
      {:error, _changeset} -> {:error, :runtime_demand_not_created}
    end
  end

  defp maybe_put_replaces(attrs, nil), do: attrs
  defp maybe_put_replaces(attrs, predecessor), do: Map.put(attrs, :replaces_id, predecessor.id)

  @doc """
  Withdraws every open demand pinned to a superseded Strategy Revision of one
  Operator, preserving the rows and their Strategy provenance.
  """
  def withdraw_superseded_demands(operator_id, active_revision_id)
      when is_integer(operator_id) and is_integer(active_revision_id) do
    now = Clock.utc_now()

    {withdrawn, agent_ids} =
      ObservationDemand
      |> join(:inner, [demand], revision in Revision,
        on: revision.id == demand.strategy_revision_id
      )
      |> join(:inner, [demand, revision], strategy in Strategy,
        on: strategy.id == revision.fleet_strategy_id
      )
      |> where(
        [demand, revision, strategy],
        strategy.operator_id == ^operator_id and
          demand.strategy_revision_id != ^active_revision_id and
          is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id)
      )
      |> select([demand], demand.agent_id)
      |> Repo.update_all(set: [withdrawn_at: now, updated_at: now])

    if withdrawn > 0 do
      agent_ids
      |> List.wrap()
      |> Enum.uniq()
      |> Enum.filter(&is_integer/1)
      |> Enum.each(&notify_demand_change/1)
    end

    :ok
  end

  @doc """
  Withdraws open `fleet_planning` Market refresh demands whose subject is no
  longer a known Marketplace under the active Strategy Revision, preserving
  rows and provenance.

  Subjects still known — including never-observed Marketplaces that merely
  lack Listing evidence — are never withdrawn here: first-time coverage is
  reset-start baseline work, and missing evidence alone is not lost relevance.
  """
  def withdraw_market_demands_outside_subjects(
        %AgentRecord{} = agent,
        %Revision{} = revision,
        subjects,
        now \\ Clock.utc_now()
      )
      when is_list(subjects) do
    now = microsecond_precision(now)

    {withdrawn, _} =
      ObservationDemand
      |> where(
        [demand],
        demand.agent_id == ^agent.id and
          demand.strategy_revision_id == ^revision.id and
          demand.owner == "fleet_planning" and like(demand.subject, "market:%") and
          demand.subject not in ^subjects and
          is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id)
      )
      |> Repo.update_all(set: [withdrawn_at: now, updated_at: now])

    if withdrawn > 0, do: notify_demand_change(agent.id)
    :ok
  end

  @doc """
  Marks open demands whose optional `deadline_at` has passed with the durable
  `deadline_missed_at` limitation instant.

  The demands remain open and late authoritative evidence may still fulfil
  them; the marker only preserves the historical limitation. Idempotent.
  """
  def mark_missed_deadlines(now \\ Clock.utc_now()) do
    now = microsecond_precision(now)

    {marked, _} =
      ObservationDemand
      |> where(
        [demand],
        not is_nil(demand.deadline_at) and is_nil(demand.deadline_missed_at) and
          demand.deadline_at < ^now and
          is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id)
      )
      |> Repo.update_all(set: [deadline_missed_at: now])

    {:ok, marked}
  end

  @doc "Returns the durable authoritative evidence that fulfilled a demand."
  def evidence_for_demand(%ObservationDemand{} = demand) do
    demand = Repo.get!(ObservationDemand, demand.id)

    case demand.fulfilled_observation_id do
      nil -> {:error, :evidence_pending}
      observation_id -> {:ok, Repo.get!(Observation, observation_id)}
    end
  end

  defmodule AuthoritativeObservation do
    @moduledoc "A successful authoritative read with the facts used for reconciliation."
    @enforce_keys [:operation_id, :observed_at, :dependency_keys, :facts, :response_fingerprint]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  defmodule ConstraintAccounting do
    @moduledoc "The bounded consequence and evaluation of every active Hard Constraint."
    @enforce_keys [:consequence_bound, :hard_constraints]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  @doc "Fulfils every compatible open demand with one authoritative observation."
  def fulfil_demands(
        %AgentRecord{} = agent,
        subject,
        %AuthoritativeObservation{} = observation,
        %DateTime{} = now \\ Clock.utc_now()
      )
      when is_binary(subject) do
    now = microsecond_precision(now)

    with true <- valid_observation?(observation),
         true <- subject in observation.dependency_keys do
      Repo.transaction(fn ->
        demands = compatible_demands(agent, subject, observation, now)
        persisted_facts = stringify_keys(observation.facts)

        persisted =
          Repo.insert!(%Observation{
            agent_id: agent.id,
            subject: subject,
            operation_id: observation.operation_id,
            dependency_keys: observation.dependency_keys,
            facts: persisted_facts,
            response_fingerprint: fingerprint(persisted_facts),
            observed_at: observation.observed_at
          })

        _ = FleetGeneration.observe_observation(agent, persisted)

        ids = Enum.map(demands, & &1.id)

        if ids != [] do
          ObservationDemand
          |> where([demand], demand.id in ^ids)
          |> Repo.update_all(set: [fulfilled_observation_id: persisted.id, updated_at: now])
        end

        fulfilled =
          ObservationDemand
          |> where([demand], demand.id in ^ids)
          |> order_by([demand], asc: demand.inserted_at, asc: demand.id)
          |> Repo.all()

        %{observation: persisted, demands: fulfilled}
      end)
      |> tap(fn
        {:ok, %{observation: %{operation_id: "get-market"} = persisted}} ->
          Phoenix.PubSub.broadcast(
            SpaceTraders.PubSub,
            "fleet_market_evidence",
            {:market_evidence_observed, persisted.agent_id, persisted.subject}
          )

        _ ->
          :ok
      end)
      |> tap(fn
        {:ok, %{observation: persisted}} -> notify_demand_change(persisted.agent_id)
        _error -> :ok
      end)
    else
      false -> {:error, :authoritative_observation_required}
    end
  end

  @doc "Builds verifiable provenance for facts returned by an authoritative read operation."
  def authoritative_observation(
        operation_id,
        dependency_keys,
        facts,
        observed_at \\ DateTime.utc_now()
      )
      when is_list(dependency_keys) and is_map(facts) and map_size(facts) > 0 do
    %{classification: :read} = OperationInventory.fetch!(operation_id)

    %AuthoritativeObservation{
      operation_id: operation_id,
      observed_at: microsecond_precision(observed_at),
      dependency_keys: Enum.uniq(dependency_keys),
      facts: facts,
      response_fingerprint: fingerprint(facts)
    }
  end

  @doc "Records the operation-specific conclusion drawn from a fresh authoritative read."
  def reconciliation_observation(
        operation_id,
        %Attempt{} = attempt,
        outcome,
        basis,
        observed_at \\ DateTime.utc_now()
      )
      when outcome in [:accepted, :absent, :bounded_unknown] and is_binary(basis) and basis != "" do
    authoritative_observation(
      operation_id,
      attempt.dependency_keys,
      %{
        reconciliation: %{
          mutation_attempt_id: attempt.id,
          request_fingerprint: attempt.request_fingerprint,
          outcome: Atom.to_string(outcome),
          basis: basis
        }
      },
      observed_at
    )
  end

  @doc "Records how the bounded consequence satisfies each active Hard Constraint."
  def constraint_accounting(consequence_bound, hard_constraints)
      when is_binary(consequence_bound) and consequence_bound != "" and
             is_list(hard_constraints) do
    %ConstraintAccounting{
      consequence_bound: consequence_bound,
      hard_constraints: hard_constraints
    }
  end

  def valid_observation?(%AuthoritativeObservation{} = observation) do
    operation = OperationInventory.fetch!(observation.operation_id)

    operation.classification == :read and observation.dependency_keys != [] and
      is_map(observation.facts) and map_size(observation.facts) > 0 and
      observation.response_fingerprint == fingerprint(observation.facts)
  rescue
    KeyError -> false
  end

  def valid_observation?(%Observation{} = observation) do
    operation = OperationInventory.fetch!(observation.operation_id)

    operation.classification == :read and observation.dependency_keys != [] and
      is_map(observation.facts) and map_size(observation.facts) > 0 and
      observation.response_fingerprint == fingerprint(observation.facts)
  rescue
    KeyError -> false
  end

  def valid_observation?(_observation), do: false

  def serialize(%AuthoritativeObservation{} = observation) do
    observation
    |> Map.from_struct()
    |> Map.update!(:observed_at, &DateTime.to_iso8601/1)
  end

  def serialize(%ConstraintAccounting{} = accounting), do: Map.from_struct(accounting)

  def validate_constraint_accounting(
        %Attempt{} = attempt,
        %ConstraintAccounting{consequence_bound: bound, hard_constraints: evaluations}
      ) do
    constraints =
      case attempt.strategy_revision_id && Repo.get(Revision, attempt.strategy_revision_id) do
        %{document: %{"hard_constraints" => values}} when is_list(values) -> values
        _revision -> []
      end

    evaluated_constraints = Enum.map(evaluations, &Map.get(&1, :constraint, &1["constraint"]))

    valid_evaluations? =
      Enum.all?(evaluations, fn evaluation ->
        satisfied = Map.get(evaluation, :satisfied, evaluation["satisfied"])
        evidence = Map.get(evaluation, :evidence, evaluation["evidence"])
        satisfied == true and is_binary(evidence) and evidence != ""
      end)

    if is_binary(bound) and bound != "" and valid_evaluations? and
         MapSet.new(evaluated_constraints) == MapSet.new(constraints) do
      :ok
    else
      {:error, :hard_constraint_accounting_required}
    end
  end

  def validate_constraint_accounting(_attempt, _accounting),
    do: {:error, :hard_constraint_accounting_required}

  @doc false
  def fingerprint(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "Refreshes authoritative Agent and Ship state before post-stop planning."
  def refresh_for_emergency_stop_resume(%Scope{operator: operator}) do
    operator
    |> Agent.list_agents()
    |> Enum.reduce_while(:ok, fn agent, :ok ->
      case FleetGeneration.agent_overview(agent) do
        {:ok, _overview} ->
          case Fleet.list_ships(agent) do
            {:ok, _ships} -> {:cont, :ok}
            _error -> {:halt, {:error, :authoritative_refresh_required}}
          end

        {:error, :stale_agent} ->
          {:cont, :ok}

        _error ->
          {:halt, {:error, :authoritative_refresh_required}}
      end
    end)
  end

  defp compatible_demands(agent, subject, observation, now) do
    fact_names =
      observation.facts
      |> Enum.filter(fn {_name, value} -> established_fact?(value) end)
      |> MapSet.new(fn {name, _value} -> to_string(name) end)

    ObservationDemand
    |> where(
      [demand],
      # An optional or already-missed deadline never blocks fulfillment;
      # only evidence acquired before the demand's earliest useful time is
      # not useful to it.
      demand.agent_id == ^agent.id and demand.subject == ^subject and
        is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id) and
        demand.due_at <= ^observation.observed_at
    )
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.filter(fn demand ->
      fresh_after = DateTime.add(now, -demand.freshness_seconds, :second)

      DateTime.compare(observation.observed_at, fresh_after) in [:eq, :gt] and
        DateTime.compare(observation.observed_at, now) in [:eq, :lt] and
        MapSet.subset?(MapSet.new(demand.required_facts), fact_names)
    end)
  end

  defp established_fact?(nil), do: false

  defp established_fact?(%{state: state})
       when state in [:unknown, :known_unavailable, "unknown", "known_unavailable"],
       do: false

  defp established_fact?(%{"state" => state})
       when state in [:unknown, :known_unavailable, "unknown", "known_unavailable"],
       do: false

  defp established_fact?(_value), do: true

  defp notify_demand_change(agent_id) when is_integer(agent_id) do
    Phoenix.PubSub.broadcast(
      SpaceTraders.PubSub,
      @demand_topic,
      {:observation_demands_changed, agent_id}
    )
  end

  defp notify_demand_change(_agent_id), do: :ok

  defp strategy_revision_owned_by_agent?(revision_record, agent) do
    Revision
    |> join(:inner, [demand_revision], strategy in Strategy,
      on: strategy.id == demand_revision.fleet_strategy_id
    )
    |> where(
      [demand_revision, strategy],
      demand_revision.id == ^revision_record.id and strategy.operator_id == ^agent.operator_id
    )
    |> Repo.exists?()
  end

  defp lock_open_demand!(id) do
    current =
      ObservationDemand
      |> where([current], current.id == ^id)
      |> lock("FOR UPDATE")
      |> Repo.one!()

    if is_nil(current.withdrawn_at) and is_nil(current.fulfilled_observation_id),
      do: current,
      else: Repo.rollback(:demand_not_open)
  end

  defp stringify_keys(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify_keys(%_{} = value), do: value |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
