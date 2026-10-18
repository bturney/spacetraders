defmodule SpaceTraders.Simulation.NavigationDrainTest do
  use SpaceTraders.DataCase, async: false
  alias SpaceTraders.Simulation.{NavigationClock, NavigationTracer}

  defmodule ArrivalOwner do
    use GenServer
    use SpaceTraders.Simulation.NavigationParticipant, casts: true
    def start_link(event), do: GenServer.start_link(__MODULE__, event)

    def init_participant(event) do
      NavigationClock.send_at(self(), {:timeline, event}, event.due_at)
      {:ok, nil}
    end

    def handle_participant_info(_, state), do: {:noreply, state}
    def handle_participant_cast(_, state), do: {:noreply, state}
  end

  test "durable UTC Arrival waits are discovered through PG, not only process timers" do
    previous = Application.get_env(:spacetraders, :clock)
    start_supervised!({NavigationClock, epoch: ~U[2026-01-01 00:00:00Z]})
    Application.put_env(:spacetraders, :clock, NavigationClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    {:ok, event} =
      SpaceTraders.Timeline.schedule_event(:ship, "TEST-1", :arrival, ~U[2026-01-01 00:00:10Z])

    start_supervised!({ArrivalOwner, event})
    assert %{next_wake: at} = NavigationTracer.drain!(System.monotonic_time(:millisecond) + 1000)
    assert DateTime.compare(at, ~U[2026-01-01 00:00:10Z]) == :eq
  end
end
