defmodule SpaceTraders.Simulation.NavigationClock do
  @moduledoc """
  Supported, deliberately narrow semantic clock for the navigation diagnostic.

  Wakes are acknowledged work, not evidence of quiescence. The coordinator must
  additionally barrier every registered owner and classify durable work before
  sealing an instant. No gameplay selection or wall transport timeout lives here.
  """
  use GenServer
  @behaviour SpaceTraders.Clock

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def utc_now, do: GenServer.call(__MODULE__, :now)
  @impl true
  def send_at(pid, message, at), do: GenServer.call(__MODULE__, {:schedule, pid, message, at})
  @impl true
  def cancel_timer(ref), do: GenServer.call(__MODULE__, {:cancel, ref})
  def register(pid, kind), do: GenServer.call(__MODULE__, {:register, pid, kind})
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def trace, do: GenServer.call(__MODULE__, :trace)
  def seal(revision), do: GenServer.call(__MODULE__, {:seal, revision})
  def release(lease, at, events), do: GenServer.call(__MODULE__, {:release, lease, at, events})

  def enabled?, do: Application.get_env(:spacetraders, :clock) == __MODULE__

  def work(fun, wake \\ nil) do
    {:ok, token} = GenServer.call(__MODULE__, {:begin, self(), wake})

    try do
      fun.()
    after
      GenServer.call(__MODULE__, {:finish, token})
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       now: Keyword.fetch!(opts, :epoch),
       revision: 0,
       participants: %{},
       timers: %{},
       released: %{},
       active: %{},
       lease: nil,
       failed: nil,
       trace: []
     }}
  end

  @impl true
  def handle_call(:now, _, state), do: {:reply, state.now, state}
  def handle_call(:trace, _, state), do: {:reply, Enum.reverse(state.trace), state}

  def handle_call(:snapshot, _, state) do
    next = state.timers |> Map.values() |> Enum.map(& &1.at) |> Enum.min(DateTime, fn -> nil end)

    {:reply,
     Map.take(state, [:now, :revision, :participants, :active, :released, :failed])
     |> Map.put(:next_wake, next)
     |> Map.put(
       :timeline_ids,
       Enum.flat_map(state.timers, fn
         {_, %{message: {:timeline, event}}} -> [event.id]
         _ -> []
       end)
     ), state}
  end

  def handle_call({:register, pid, kind}, _, state) do
    unless Map.has_key?(state.participants, pid), do: Process.monitor(pid)
    {:reply, :ok, changed(%{state | participants: Map.put(state.participants, pid, kind)})}
  end

  def handle_call({:schedule, pid, message, at}, _, state) do
    reference = make_ref()
    entry = %{pid: pid, message: message, at: at}

    state =
      if Map.has_key?(state.participants, pid),
        do: state,
        else: %{state | failed: :unclassified_timer_owner}

    state = changed(%{state | timers: Map.put(state.timers, reference, entry)})
    state = if DateTime.compare(at, state.now) != :gt, do: deliver_due(state), else: state
    {:reply, reference, state}
  end

  def handle_call({:cancel, reference}, _, state) do
    case Map.pop(state.timers, reference) do
      {nil, _} ->
        {:reply, false, state}

      {entry, timers} ->
        {:reply, max(DateTime.diff(entry.at, state.now, :millisecond), 0),
         changed(%{state | timers: timers})}
    end
  end

  def handle_call({:begin, pid, wake}, _, state) do
    token = make_ref()

    valid =
      Map.has_key?(state.participants, pid) and is_nil(state.lease) and
        (is_nil(wake) or Map.get(state.released, wake) == pid)

    state = if valid, do: state, else: %{state | failed: :unclassified_work}

    state =
      %{state | active: Map.put(state.active, token, pid)}
      |> changed()
      |> record("work_started", %{})

    {:reply, if(valid, do: {:ok, token}, else: {:error, :unclassified_work}),
     %{state | released: Map.delete(state.released, wake)}}
  end

  def handle_call({:finish, token}, _, state) do
    {:reply, :ok,
     %{state | active: Map.delete(state.active, token)}
     |> changed()
     |> record("work_finished", %{})}
  end

  def handle_call({:seal, revision}, _, state) do
    if revision == state.revision and map_size(state.active) == 0 and
         map_size(state.released) == 0 and is_nil(state.failed) and is_nil(state.lease) do
      lease = make_ref()
      {:reply, {:ok, lease}, %{state | lease: lease}}
    else
      {:reply, {:error, :incomplete_drain}, state}
    end
  end

  def handle_call({:release, lease, at, events}, _, %{lease: lease} = state)
      when not is_nil(lease) do
    if DateTime.compare(at, state.now) == :gt and is_nil(state.failed) do
      state =
        %{state | now: at, lease: nil}
        |> changed()
        |> record("world_settled", %{events: events})
        |> record("bot_released", %{})
        |> deliver_due()

      {:reply, :ok, state}
    else
      {:reply, {:error, :invalid_advance}, state}
    end
  end

  def handle_call({:release, _, _, _}, _, state), do: {:reply, {:error, :invalid_lease}, state}

  @impl true
  def handle_info({:DOWN, _, :process, pid, _}, state) do
    {:noreply, changed(%{state | failed: {:participant_down, inspect(pid)}})}
  end

  defp changed(state), do: %{state | revision: state.revision + 1}

  defp record(state, phase, extra) do
    entry = Map.merge(%{ordinal: length(state.trace) + 1, at: state.now, phase: phase}, extra)
    %{state | trace: [entry | state.trace]}
  end

  defp deliver_due(state) do
    state.timers
    |> Enum.filter(fn {_, entry} -> DateTime.compare(entry.at, state.now) != :gt end)
    |> Enum.sort_by(fn {ref, entry} -> {DateTime.to_unix(entry.at, :microsecond), ref} end)
    |> Enum.reduce(state, fn {ref, entry}, acc ->
      send(entry.pid, {:simulation_wake, ref, entry.message})

      %{
        acc
        | timers: Map.delete(acc.timers, ref),
          released: Map.put(acc.released, ref, entry.pid)
      }
    end)
  end
end
