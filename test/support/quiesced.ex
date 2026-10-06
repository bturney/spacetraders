defmodule SpaceTraders.Quiesced do
  @moduledoc """
  Test-supervised runtime child that never stops mid-transaction (#398).

  ExUnit stops `start_supervised` children with an exit signal; a GenServer that
  does not trap exits dies at once, even mid-transaction. A process that dies
  holding a sandbox connection makes the ownership proxy disconnect it, and
  Postgrex logs that disconnect as an error. Wrapping the child here stops it
  at a moment it holds no connection.

      start_supervised!(Quiesced.child_spec({Reconciler, []}))
      stop_supervised(Reconciler)

  `stop_ship/1` and `stop_all_ships/0` do the same for ship servers, which tests
  stop between cases. Production `ShipServer.stop/1` stays plain.

  Quiescing suspends the process and polls DBConnection's internal
  `DBConnection.Holder` ETS tables; that is test-only teardown, so it lives here.

  The wrapper keeps the child's id. A child that dies on its own (a test killing
  the runtime) takes the wrapper down with it, without a restart.
  """

  use GenServer

  def child_spec(child) do
    %{id: id, start: start} = Supervisor.child_spec(child, [])
    %{id: id, start: {__MODULE__, :start_link, [start]}, restart: :temporary}
  end

  @doc false
  def start_link(start), do: GenServer.start_link(__MODULE__, start)

  @doc "Stops the ship's server, if running, while it holds no database connection."
  @spec stop_ship(String.t()) :: :ok
  def stop_ship(ship_symbol) do
    case Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship_symbol) do
      [{pid, _}] -> terminate_ship(pid)
      [] -> :ok
    end
  end

  @doc "Stops every running ship server, each while it holds no database connection."
  @spec stop_all_ships() :: :ok
  def stop_all_ships do
    SpaceTraders.Fleet.ShipSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> terminate_ship(pid)
      _ -> :ok
    end)
  end

  defp terminate_ship(pid) do
    stop(pid, &DynamicSupervisor.terminate_child(SpaceTraders.Fleet.ShipSupervisor, &1))
    :ok
  end

  # DBConnection gives each checkout's holder table to the client for the
  # duration of the checkout. A process holds a connection when it owns one, or
  # when a task working for it does (Ecto runs parallel preloads in tasks that
  # share the caller's sandbox connection through `$callers`).
  @holder DBConnection.Holder
  @poll_ms 5
  @attempts 1_000

  @doc """
  Runs `stop` on `pid` while it is suspended holding no connection.

  After about five seconds of continuous checkouts, `stop` runs anyway.
  """
  @spec stop(pid(), (pid() -> result)) :: result when result: term()
  def stop(pid, stop) do
    await_checkin(pid, @attempts)
    stop.(pid)
  after
    resume(pid)
  end

  defp await_checkin(pid, 0), do: suspend(pid)

  defp await_checkin(pid, attempts) do
    if suspend(pid) and holds_connection?(pid) do
      resume(pid)
      Process.sleep(@poll_ms)
      await_checkin(pid, attempts - 1)
    end
  end

  @doc "Whether `pid`, or a task working for it, has a database connection checked out."
  @spec holds_connection?(pid()) :: boolean()
  def holds_connection?(pid) do
    Enum.any?(:ets.all(), fn table ->
      :ets.info(table, :name) == @holder and acting_for?(:ets.info(table, :owner), pid)
    end)
  end

  defp acting_for?(pid, pid), do: true

  defp acting_for?(owner, pid) when is_pid(owner) do
    case Process.info(owner, :dictionary) do
      {:dictionary, dictionary} -> pid in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end

  defp acting_for?(_owner, _pid), do: false

  defp suspend(pid) do
    :erlang.suspend_process(pid)
  rescue
    ArgumentError -> false
  end

  defp resume(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> false
  end

  @impl true
  def init({module, function, args}) do
    Process.flag(:trap_exit, true)

    case apply(module, function, args) do
      {:ok, child} -> {:ok, child}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, child, reason}, child), do: {:stop, {:shutdown, reason}, nil}
  def handle_info(_message, child), do: {:noreply, child}

  @impl true
  def terminate(_reason, nil), do: :ok

  def terminate(_reason, child) do
    stop(child, &Process.exit(&1, :shutdown))

    receive do
      {:EXIT, ^child, _} -> :ok
    end
  end
end
