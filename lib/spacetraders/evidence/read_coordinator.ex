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
                exception -> {:error, exception}
              catch
                kind, reason -> {:error, {kind, reason}}
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
        {:reply, :owner, %{state | pending: Map.put(pending, key, %{owner: pid, waiters: []})}}

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

      {%{waiters: waiters}, pending} ->
        Enum.each(waiters, &send(&1, {:read_complete, key, result}))
        {:noreply, %{state | pending: pending}}
    end
  end
end
