defmodule SpaceTraders.Evidence do
  @moduledoc """
  Owns durable Observation Demands and authoritative evidence provenance.

  Emergency Stop resume uses this seam so Fleet Strategy coordinates durable
  authority without invoking or interpreting gameplay reads itself.
  """

  import Ecto.Query

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Clock
  alias SpaceTraders.Evidence.{Observation, ObservationDemand}
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @doc "Creates a durable Observation Demand for one Fleet Strategy consumer."
  def request_demand(%AgentRecord{} = agent, %Revision{} = revision, attrs)
      when is_map(attrs) do
    if strategy_revision_owned_by_agent?(revision, agent) do
      attrs =
        attrs
        |> Map.put(:agent_id, agent.id)
        |> Map.put(:strategy_revision_id, revision.id)

      %ObservationDemand{}
      |> ObservationDemand.create_changeset(attrs)
      |> Repo.insert()
    else
      {:error, :strategy_provenance_mismatch}
    end
  end

  @doc "Atomically withdraws an open demand and creates its replacement."
  def replace_demand(%ObservationDemand{} = demand, attrs, now \\ Clock.utc_now())
      when is_map(attrs) do
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
          :deadline_at,
          :owner,
          :agent_id,
          :strategy_revision_id
        ])
        |> Map.merge(
          Map.take(attrs, [:subject, :required_facts, :freshness_seconds, :deadline_at, :owner])
        )
        |> Map.put(:replaces_id, current.id)

      case Repo.insert(
             ObservationDemand.create_changeset(%ObservationDemand{}, replacement_attrs)
           ) do
        {:ok, replacement} -> replacement
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "Withdraws an open demand without deleting its Strategy provenance."
  def withdraw_demand(%ObservationDemand{} = demand, now \\ Clock.utc_now()) do
    Repo.transaction(fn ->
      demand.id
      |> lock_open_demand!()
      |> Ecto.Changeset.change(withdrawn_at: now)
      |> Repo.update!()
    end)
  end

  @doc "Lists active demands in deadline order."
  def list_open_demands(%AgentRecord{} = agent, now \\ Clock.utc_now()) do
    ObservationDemand
    |> where(
      [demand],
      demand.agent_id == ^agent.id and is_nil(demand.withdrawn_at) and
        is_nil(demand.fulfilled_observation_id) and demand.deadline_at >= ^now
    )
    |> order_by([demand], asc: demand.deadline_at, asc: demand.inserted_at, asc: demand.id)
    |> Repo.all()
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
      observed_at: observed_at,
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
      demand.agent_id == ^agent.id and demand.subject == ^subject and
        is_nil(demand.withdrawn_at) and is_nil(demand.fulfilled_observation_id) and
        demand.deadline_at >= ^now
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

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
