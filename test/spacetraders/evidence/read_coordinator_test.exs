defmodule SpaceTraders.Evidence.ReadCoordinatorTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Evidence.ReadCoordinator

  test "concurrent compatible reads execute once and share the result" do
    name = unique_name()
    {:ok, pid} = ReadCoordinator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {:ok, counter} = Agent.start_link(fn -> 0 end)
    parent = self()

    read = fn ->
      Agent.update(counter, &(&1 + 1))
      send(parent, :started)
      Process.sleep(20)
      {:ok, :shared}
    end

    first = Task.async(fn -> ReadCoordinator.read(:market, read, name) end)
    assert_receive :started
    second = Task.async(fn -> ReadCoordinator.read(:market, read, name) end)

    assert {:ok, :shared} == Task.await(first)
    assert {:ok, :shared} == Task.await(second)
    assert Agent.get(counter, & &1) == 1
  end

  defp unique_name, do: String.to_atom("read_coordinator_#{System.unique_integer([:positive])}")
end
