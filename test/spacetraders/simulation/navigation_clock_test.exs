defmodule SpaceTraders.Simulation.NavigationClockTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.Simulation.NavigationClock

  test "world settlement precedes acknowledged bot wakes and spawned work drains at the same instant" do
    start_supervised!({NavigationClock, epoch: ~U[2026-10-18 00:00:00Z]})
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          {:simulation_wake, reference, :arrival} ->
            NavigationClock.work(
              fn ->
                send(parent, {:continued, NavigationClock.utc_now()})
                NavigationClock.send_at(parent, :spawned, NavigationClock.utc_now())
              end,
              reference
            )

            send(parent, {:worker_finished, self()})
            receive do: (:stop -> :ok)

          :stop ->
            :ok
        end
      end)

    try do
      NavigationClock.register(worker, :ship)
      NavigationClock.register(self(), :ship)
      NavigationClock.send_at(worker, :arrival, ~U[2026-10-18 00:00:10Z])
      snapshot = NavigationClock.snapshot()
      assert {:ok, lease} = NavigationClock.seal(snapshot.revision)
      # The coordinator invokes synchronous world settlement before committing time.
      send(self(), :world_settled)
      assert :ok = NavigationClock.release(lease, ~U[2026-10-18 00:00:10Z], [%{kind: "arrival"}])
      assert_receive :world_settled
      assert_receive {:continued, ~U[2026-10-18 00:00:10.000000Z]}
      assert_receive {:simulation_wake, reference, :spawned}
      assert_receive {:worker_finished, ^worker}

      assert {:error, :incomplete_drain} =
               NavigationClock.seal(NavigationClock.snapshot().revision)

      NavigationClock.work(fn -> :ok end, reference)
      assert {:ok, _lease} = NavigationClock.seal(NavigationClock.snapshot().revision)

      assert Enum.map(NavigationClock.trace(), & &1.phase) ==
               [
                 "world_settled",
                 "bot_released",
                 "work_started",
                 "work_finished",
                 "work_started",
                 "work_finished"
               ]
    after
      send(worker, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end
end
