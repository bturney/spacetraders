defmodule SpaceTraders.QuiescedPendingCheckoutTest do
  # #818: a checkout request still queued at the ownership proxy owns no Holder
  # table yet, but the proxy hands the connection to the (suspended) requester as
  # soon as it runs. Stopping the requester then disconnects the session, and
  # Postgrex logs `owner/client ... exited` outside any test's capture.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Quiesced, Repo}

  defmodule Requester do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid, name: __MODULE__)

    @impl true
    def init(test_pid), do: {:ok, test_pid}

    @impl true
    def handle_info(:work, test_pid) do
      Repo.query!("SELECT 1")
      send(test_pid, :queried)
      {:noreply, test_pid}
    end
  end

  test "a child with an unserved checkout request is stopped only after it checks in" do
    owner = Sandbox.start_owner!(Repo, shared: false)
    on_exit(fn -> Sandbox.stop_owner(owner) end)

    start_supervised!(Quiesced.child_spec({Requester, self()}))
    Sandbox.allow(Repo, owner, Process.whereis(Requester))

    # Suspension is owned by the suspending process, so it also resumes. The
    # proxy runs again only while the stop is polling for a quiet moment.
    proxy = proxy_of(owner)
    test = self()

    resumer =
      Task.async(fn ->
        :erlang.suspend_process(proxy)
        send(test, :proxy_suspended)

        receive do
          :resume -> :erlang.resume_process(proxy)
        end
      end)

    assert_receive :proxy_suspended
    send(Requester, :work)
    wait_until(fn -> awaiting_checkout?(Process.whereis(Requester)) end)
    Process.send_after(resumer.pid, :resume, 100)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = stop_supervised(Requester)
        Task.await(resumer)
        # Postgrex logs a disconnect asynchronously; give it time to show.
        Process.sleep(200)
      end)

    assert_received :queried
    refute log =~ "exited"
    refute log =~ "disconnected"
  end

  # Ownership proxy of `owner`: the process holding its idle Holder table.
  defp proxy_of(owner) do
    Enum.find_value(:ets.all(), fn table ->
      with DBConnection.Holder <- :ets.info(table, :name),
           pid when is_pid(pid) <- :ets.info(table, :owner),
           %{owner: {^owner, _}} <- safe_state(pid) do
        pid
      else
        _ -> nil
      end
    end) || flunk("no ownership proxy found for the sandbox owner")
  end

  defp safe_state(pid) do
    :sys.get_state(pid, 100)
  catch
    _, _ -> nil
  end

  defp awaiting_checkout?(pid) do
    {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)
    Enum.any?(stack, &match?({DBConnection.Holder, :checkout_call, _, _}, &1))
  end

  defp wait_until(fun, attempts \\ 500) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(10) && wait_until(fun, attempts - 1)
    end
  end
end
