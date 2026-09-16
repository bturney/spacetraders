defmodule SpaceTraders.Evidence do
  @moduledoc """
  Owns authoritative observations used to admit recovery transitions.

  Emergency Stop resume uses this seam so Fleet Strategy coordinates durable
  authority without invoking or interpreting gameplay reads itself.
  """

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.API.OperationInventory

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

  defp fingerprint(facts) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(facts, [:deterministic]))
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
end
