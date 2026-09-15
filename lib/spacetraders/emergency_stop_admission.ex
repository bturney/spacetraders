defmodule SpaceTraders.EmergencyStopAdmission do
  @moduledoc false

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
      GenServer.call(__MODULE__, {:block, operator_id, guard, token_fingerprints(operator_id)})

    guard
  end

  def engage(operator_id, version, guard) do
    GenServer.call(
      __MODULE__,
      {:engage, operator_id, version, guard, token_fingerprints(operator_id)}
    )
  end

  def cancel_block(operator_id, guard),
    do: GenServer.call(__MODULE__, {:cancel, operator_id, guard})

  def sync(operator_id) do
    case Repo.get_by(Strategy, operator_id: operator_id) do
      %Strategy{emergency_stopped_at: %DateTime{}, emergency_stop_version: version} ->
        GenServer.call(__MODULE__, {:sync, operator_id, version, token_fingerprints(operator_id)})

      _strategy ->
        resume(operator_id, :infinity)
    end
  end

  def resume(operator_id, version),
    do: GenServer.call(__MODULE__, {:delete, operator_id, version})

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
    stop = %{
      version: {:pending, guard},
      fingerprints: fingerprints,
      previous: Map.get(state, operator_id)
    }

    {:reply, :ok, Map.put(state, operator_id, stop)}
  end

  def handle_call({:engage, operator_id, version, guard, fingerprints}, _from, state) do
    state =
      case Map.get(state, operator_id) do
        %{version: {:pending, ^guard}} ->
          Map.put(state, operator_id, %{version: version, fingerprints: fingerprints})

        %{version: current} when is_integer(current) and current <= version ->
          Map.put(state, operator_id, %{version: version, fingerprints: fingerprints})

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

  def handle_call({:sync, operator_id, version, fingerprints}, _from, state) do
    state =
      Map.update(state, operator_id, %{version: version, fingerprints: fingerprints}, fn stop ->
        %{stop | fingerprints: fingerprints}
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

  def handle_call({:mutation_allowed, fingerprint}, _from, state) do
    if Enum.any?(state, fn {_operator_id, stop} -> fingerprint in stop.fingerprints end) do
      {:reply, {:error, :emergency_stopped}, state}
    else
      {:reply, :ok, state}
    end
  end

  defp load_stopped_operators do
    operator_ids =
      Repo.all(
        from(strategy in Strategy,
          where: not is_nil(strategy.emergency_stopped_at),
          select: strategy.operator_id
        )
      )

    accounts =
      Repo.all(
        from(operator in Operator,
          where: operator.id in ^operator_ids,
          select: {operator.id, operator.account_token}
        )
      )

    agents =
      Repo.all(
        from(agent in Agent,
          where: agent.operator_id in ^operator_ids,
          select: {agent.operator_id, agent.agent_token}
        )
      )

    Map.new(operator_ids, fn operator_id ->
      tokens =
        for {owner_id, token} <- accounts ++ agents,
            owner_id == operator_id,
            is_binary(token) and token != "",
            do: fingerprint(token)

      version = Repo.get_by!(Strategy, operator_id: operator_id).emergency_stop_version
      {operator_id, %{version: version, fingerprints: MapSet.new(tokens)}}
    end)
  end

  defp token_fingerprints(operator_id) do
    account_tokens =
      Repo.all(
        from(operator in Operator,
          where: operator.id == ^operator_id,
          select: operator.account_token
        )
      )

    agent_tokens =
      Repo.all(
        from(agent in Agent,
          where: agent.operator_id == ^operator_id,
          select: agent.agent_token
        )
      )

    (account_tokens ++ agent_tokens)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&fingerprint/1)
    |> MapSet.new()
  end

  defp fingerprint(token), do: :crypto.hash(:sha256, token)
end
