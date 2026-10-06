defmodule SpaceTraders.Quiesce do
  @moduledoc """
  Stops a process only while it holds no database connection (#398).

  An exit signal kills a process that does not trap exits at once, even with a
  connection checked out mid-transaction. Under the test sandbox that death
  makes the ownership proxy disconnect the session, and Postgrex logs the
  disconnect as an error. `stop/2` suspends the process at a moment neither it
  nor a task working for it holds a checkout, and stops it there: an in-flight transaction finishes, and nothing
  else about the stop changes. Test teardown hooks use it; production code has
  no caller.
  """

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
end
