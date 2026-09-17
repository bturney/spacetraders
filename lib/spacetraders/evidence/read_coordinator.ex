defmodule SpaceTraders.Evidence.ReadCoordinator do
  @moduledoc "Coalesces concurrent reads for the same evidence subject."

  use GenServer

  @doc "Starts the short-lived in-flight read coordinator."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Shares one in-flight read with callers requesting the same key."
  def read(key, fun, name \\ __MODULE__) when is_function(fun, 0) do
    case Process.whereis(name) do
      nil ->
        fun.()

      _pid ->
        case GenServer.call(name, {:begin, key}) do
          :owner ->
            result =
              try do
                fun.()
              rescue
                exception -> {:error, SpaceTraders.API.Error.transport(exception)}
              catch
                kind, reason ->
                  {:error, SpaceTraders.API.Error.transport({kind, reason})}
              end

            GenServer.cast(name, {:complete, key, result})
            result

          :waiter ->
            receive do
              {:read_complete, ^key, result} -> result
            end
        end
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_call({:begin, key}, {pid, _ref}, %{pending: pending} = state) do
    case Map.get(pending, key) do
      nil ->
        monitor_ref = Process.monitor(pid)

        entry = %{owner: pid, monitor_ref: monitor_ref, waiters: []}
        {:reply, :owner, %{state | pending: Map.put(pending, key, entry)}}

      %{waiters: waiters} = entry ->
        {:reply, :waiter,
         %{state | pending: Map.put(pending, key, %{entry | waiters: [pid | waiters]})}}
    end
  end

  @impl true
  def handle_cast({:complete, key, result}, %{pending: pending} = state) do
    case Map.pop(pending, key) do
      {nil, pending} ->
        {:noreply, %{state | pending: pending}}

      {%{monitor_ref: monitor_ref, waiters: waiters}, pending} ->
        Process.demonitor(monitor_ref, [:flush])
        Enum.each(waiters, &send(&1, {:read_complete, key, result}))
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, %{pending: pending} = state) do
    case Enum.find(pending, fn {_key, entry} -> entry.monitor_ref == monitor_ref end) do
      nil ->
        {:noreply, state}

      {key, %{waiters: waiters}} ->
        result = {:error, SpaceTraders.API.Error.transport({:read_owner_down, reason})}
        Enum.each(waiters, &send(&1, {:read_complete, key, result}))
        {:noreply, %{state | pending: Map.delete(pending, key)}}
    end
  end
end
