defmodule SpaceTraders.RuntimeAuthority do
  @moduledoc """
  Holds the PostgreSQL session lock that grants this runtime mutation authority.

  A runtime without the lock remains available for observation but must reject
  every new gameplay mutation.
  """

  use GenServer

  @default_lock_key 1_397_765_443
  @retry_ms 100
  @heartbeat_ms 1_000
  @connection_options [
    :hostname,
    :port,
    :username,
    :password,
    :database,
    :ssl,
    :socket_options,
    :timeout,
    :connect_timeout
  ]

  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  def execution_allowed?(server \\ __MODULE__) do
    if enabled?() or server != __MODULE__ do
      try do
        if GenServer.call(server, :authorized?),
          do: :ok,
          else: {:error, :runtime_authority_unavailable}
      catch
        :exit, _ -> {:error, :runtime_authority_unavailable}
      end
    else
      :ok
    end
  end

  def enabled? do
    Application.get_env(:spacetraders, __MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  @impl true
  def init(options) do
    lock_key = Keyword.get(options, :lock_key, @default_lock_key)
    {:ok, connection} = Postgrex.start_link(connection_options())

    state = %{
      authorized?: false,
      backend_pid: nil,
      connection: connection,
      lock_key: lock_key,
      require_cutover?: Keyword.get(options, :require_cutover?, true)
    }

    {:ok, acquire(state)}
  end

  @impl true
  def handle_call(:authorized?, _from, state) do
    {authorized?, state} = verify_authority(state)
    {:reply, authorized?, state}
  end

  @impl true
  def handle_info(:acquire, state), do: {:noreply, acquire(state)}

  def handle_info(:heartbeat, state) do
    case verify_authority(state) do
      {true, state} ->
        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        {:noreply, state}

      {false, state} ->
        Process.send_after(self(), :acquire, @retry_ms)
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, %{connection: connection}) do
    GenServer.stop(connection)
  catch
    :exit, _ -> :ok
  end

  defp acquire(%{authorized?: true} = state), do: state

  defp acquire(state) do
    if state.require_cutover? and not cutover_complete?(state.connection) do
      Process.send_after(self(), :acquire, @retry_ms)
      state
    else
      acquire_lock(state)
    end
  end

  defp acquire_lock(state) do
    case Postgrex.query(
           state.connection,
           "SELECT pg_try_advisory_lock($1), pg_backend_pid()",
           [state.lock_key]
         ) do
      {:ok, %{rows: [[true, backend_pid]]}} ->
        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        %{state | authorized?: true, backend_pid: backend_pid}

      {:ok, %{rows: [[false, _backend_pid]]}} ->
        Process.send_after(self(), :acquire, @retry_ms)
        state

      {:error, _reason} ->
        Process.send_after(self(), :acquire, @retry_ms)
        %{state | authorized?: false, backend_pid: nil}
    end
  end

  defp verify_authority(%{authorized?: false} = state), do: {false, state}

  defp verify_authority(state) do
    case Postgrex.query(
           state.connection,
           """
           SELECT pg_backend_pid(), EXISTS (
             SELECT 1 FROM pg_locks
             WHERE locktype = 'advisory'
               AND pid = pg_backend_pid()
               AND classid = ($1::bigint >> 32)::oid
               AND objid = ($1::bigint & 4294967295)::oid
               AND objsubid = 1
               AND granted
           )
           """,
           [state.lock_key]
         ) do
      {:ok, %{rows: [[backend_pid, true]]}} when backend_pid == state.backend_pid ->
        {true, state}

      _ ->
        {false, %{state | authorized?: false, backend_pid: nil}}
    end
  end

  defp cutover_complete?(connection) do
    case Postgrex.query(
           connection,
           "SELECT store FROM runtime_authority WHERE name = 'durable_truth'",
           []
         ) do
      {:ok, %{rows: [["postgresql"]]}} -> true
      _ -> false
    end
  end

  defp connection_options do
    SpaceTraders.Repo.config()
    |> Keyword.take(@connection_options)
  end
end
