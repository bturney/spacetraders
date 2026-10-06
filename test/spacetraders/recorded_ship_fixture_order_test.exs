defmodule SpaceTraders.RecordedShipFixtureOrderTest do
  # Guards the probe the stateful suites run at teardown: it must stay silent on
  # a clean fixture and name each kind of leak.
  use ExUnit.Case, async: false

  alias SpaceTraders.FixtureLeakProbe

  setup_all do
    {:ok, baseline: FixtureLeakProbe.baseline()}
  end

  test "a clean fixture leaves no leaks", %{baseline: baseline} do
    assert FixtureLeakProbe.leaks(baseline) == []
  end

  test "a leaked application key is named", %{baseline: baseline} do
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)
    on_exit(fn -> restore(baseline[:clock]) end)

    assert [leak] = FixtureLeakProbe.leaks(baseline)
    assert leak =~ "application key :clock"
  end

  test "a leaked runtime process is named", %{baseline: baseline} do
    start_supervised!({SpaceTraders.TestClock, DateTime.utc_now()})

    assert [leak] = FixtureLeakProbe.leaks(baseline)
    assert leak =~ "runtime process SpaceTraders.TestClock"
  end

  test "a leaked ShipServer is named", %{baseline: baseline} do
    {:ok, pid} = Agent.start_link(fn -> :ok end)
    {:ok, _} = DynamicSupervisor.start_child(SpaceTraders.Fleet.ShipSupervisor, child(pid))
    on_exit(&SpaceTraders.Quiesced.stop_all_ships/0)

    assert FixtureLeakProbe.leaks(baseline) == ["ShipServers left running"]
  end

  test "a leaked shared Req stub is named", %{baseline: baseline} do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)

    assert FixtureLeakProbe.leaks(baseline) == ["shared Req stub mode"]
  end

  defp restore({:ok, value}), do: Application.put_env(:spacetraders, :clock, value)
  defp restore(:error), do: Application.delete_env(:spacetraders, :clock)

  defp child(pid) do
    %{id: make_ref(), start: {Agent, :start_link, [fn -> pid end]}, restart: :temporary}
  end
end
