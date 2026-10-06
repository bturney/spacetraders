defmodule SpaceTraders.QuiescedTest do
  # Shared sandbox: the worker queries through the test's connection.
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Quiesced

  defmodule Worker do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_info(:work, test_pid) do
      SpaceTraders.Repo.transaction(fn ->
        SpaceTraders.Repo.query!("INSERT INTO quiesced_probe VALUES (1)")
        send(test_pid, :in_transaction)
        SpaceTraders.Repo.query!("SELECT pg_sleep(0.2)")
      end)

      {:noreply, test_pid}
    end
  end

  setup do
    # Session-scoped: visible to the worker through the shared sandbox connection.
    Repo.query!("CREATE TEMP TABLE quiesced_probe (id integer)")
    :ok
  end

  test "test teardown waits out an open transaction before stopping the child" do
    start_supervised!(Quiesced.child_spec({Worker, self()}))
    send(Worker, :work)
    assert_receive :in_transaction

    assert :ok = stop_supervised(Worker)

    refute Process.whereis(Worker)
    assert Repo.query!("SELECT count(*) FROM quiesced_probe").rows == [[1]]
  end

  test "a child that dies takes its wrapper down without a restart" do
    wrapper = start_supervised!(Quiesced.child_spec({Worker, self()}))
    ref = Process.monitor(wrapper)

    Process.exit(Process.whereis(Worker), :kill)

    assert_receive {:DOWN, ^ref, :process, ^wrapper, {:shutdown, :killed}}
  end
end
