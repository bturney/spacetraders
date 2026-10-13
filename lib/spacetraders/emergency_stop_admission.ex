defmodule SpaceTraders.EmergencyStopAdmission do
  @moduledoc false

  # Process-local admission cache for durable Emergency Stop intent. A stop is
  # global Operator intent: it fingerprints every credential in the deployment,
  # not only its author's, so no Agent row can send a mutation around it.

  use GenServer

  import Ecto.Query, warn: false

  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def block(operator_id) do
    guard = make_ref()

    :ok =
      GenServer.call(__MODULE__, {:block, operator_id, guard, token_fingerprints()})

    guard
  end

  def engage(operator_id, version, guard) do
    GenServer.call(
      __MODULE__,
      {:engage, operator_id, version, guard, token_fingerprints()}
    )
  end

  def cancel_block(operator_id, guard),
    do: GenServer.call(__MODULE__, {:cancel, operator_id, guard})

  def track_credential(operator_id, token) when is_binary(token) and token != "" do
    GenServer.call(__MODULE__, {:track_credential, operator_id, fingerprint(token)})
  end

  def track_credential(_operator_id, _token), do: :ok

  def resume(operator_id, version),
    do: GenServer.call(__MODULE__, {:delete, operator_id, version})

  @doc "Rebuilds the cache from durable state. Used to reset test isolation."
  def clear, do: GenServer.call(__MODULE__, :clear)

  def mutation_allowed?(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:mutation_allowed, fingerprint(token)})
  end

  def mutation_allowed?(_token), do: {:error, :mutation_authority_unknown}

  @impl true
  def init(:ok) do
    state = load_stopped_operators()

    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:block, operator_id, guard, fingerprints}, _from, state) do
    previous = Map.get(state, operator_id)

    stop = %{
      version: {:pending, guard},
      fingerprints: merge_fingerprints(previous, fingerprints),
      previous: previous
    }

    {:reply, :ok, Map.put(state, operator_id, stop)}
  end

  def handle_call({:engage, operator_id, version, guard, fingerprints}, _from, state) do
    state =
      case Map.get(state, operator_id) do
        %{version: {:pending, ^guard}, fingerprints: guarded_fingerprints} ->
          Map.put(state, operator_id, %{
            version: version,
            fingerprints: MapSet.union(guarded_fingerprints, fingerprints)
          })

        %{version: current, fingerprints: current_fingerprints}
        when is_integer(current) and current <= version ->
          Map.put(state, operator_id, %{
            version: version,
            fingerprints: MapSet.union(current_fingerprints, fingerprints)
          })

        _newer_stop ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call({:cancel, operator_id, guard}, _from, state) do
    state =
      case Map.get(state, operator_id) do
        %{version: {:pending, ^guard}, previous: nil} ->
          Map.delete(state, operator_id)

        %{version: {:pending, ^guard}, previous: previous} ->
          Map.put(state, operator_id, previous)

        _other ->
          state
      end

    {:reply, :ok, state}
  end

  # Any engaged stop covers a credential stored while it holds.
  def handle_call({:track_credential, _operator_id, fingerprint}, _from, state) do
    state =
      Map.new(state, fn {stop_owner, stop} ->
        {stop_owner, %{stop | fingerprints: MapSet.put(stop.fingerprints, fingerprint)}}
      end)

    {:reply, :ok, state}
  end

  def handle_call({:delete, operator_id, version}, _from, state) do
    state =
      case Map.get(state, operator_id) do
        nil ->
          state

        %{version: {:pending, _guard}} ->
          state

        %{version: current} when version == :infinity or current <= version ->
          Map.delete(state, operator_id)

        _newer_stop ->
          state
      end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{}}
  end

  def handle_call({:mutation_allowed, fingerprint}, _from, state) do
    if Enum.any?(state, fn {_operator_id, stop} -> fingerprint in stop.fingerprints end) do
      {:reply, {:error, :emergency_stopped}, state}
    else
      {:reply, :ok, state}
    end
  end

  defp load_stopped_operators do
    stops =
      Repo.all(
        from(strategy in Strategy,
          where: not is_nil(strategy.emergency_stopped_at),
          select: {strategy.operator_id, strategy.emergency_stop_version}
        )
      )

    fingerprints = if stops == [], do: MapSet.new(), else: token_fingerprints()

    Map.new(stops, fn {operator_id, version} ->
      {operator_id, %{version: version, fingerprints: fingerprints}}
    end)
  end

  defp token_fingerprints do
    account_tokens = Repo.all(from(operator in Operator, select: operator.account_token))
    agent_tokens = Repo.all(from(agent in Agent, select: agent.agent_token))

    (account_tokens ++ agent_tokens)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&fingerprint/1)
    |> MapSet.new()
  end

  defp merge_fingerprints(nil, fingerprints), do: fingerprints

  defp merge_fingerprints(stop, fingerprints),
    do: MapSet.union(stop.fingerprints, fingerprints)

  defp fingerprint(token), do: :crypto.hash(:sha256, token)
end
