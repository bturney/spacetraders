defmodule SpaceTraders.RuntimeDeath do
  @moduledoc """
  Kills a runtime sender at a protocol boundary, as the interruption tests
  simulate a crash (#398).

  A sender killed holding a checkout (inside a transaction or not) dies with its
  sandbox connection, so the ownership proxy disconnects that session and
  Postgrex logs the disconnect as an error. That disconnect is the death's
  expected effect: `kill/2` captures it, asserts it names the sender, and waits
  until a separate session sees the sender's session (`backend`) end, which is
  also what rolls back any uncommitted write. A sender killed holding no
  checkout disconnects nothing.
  """

  import ExUnit.Assertions

  @connection [:hostname, :port, :username, :password, :database, :ssl, :socket_options]

  @spec kill(pid(), integer()) :: {:disconnected | :idle, String.t()}
  def kill(sender, backend) do
    holds_connection? = SpaceTraders.Quiesce.holds_connection?(sender)

    {:ok, log} =
      ExUnit.CaptureLog.with_log(fn ->
        ref = Process.monitor(sender)
        Process.exit(sender, :kill)
        assert_receive {:DOWN, ^ref, :process, ^sender, :killed}
        if holds_connection?, do: await_session_end(backend)
        :ok
      end)

    if holds_connection? do
      assert log =~ ~r/(client|owner) #{Regex.escape(inspect(sender))} exited/
      {:disconnected, log}
    else
      refute log =~ "disconnected"
      {:idle, log}
    end
  end

  defp await_session_end(backend) do
    {:ok, observer} =
      SpaceTraders.Repo.config() |> Keyword.take(@connection) |> Postgrex.start_link()

    try do
      await_session_end(observer, backend, 500)
    after
      GenServer.stop(observer)
    end
  end

  defp await_session_end(_observer, backend, 0),
    do: flunk("PostgreSQL session #{backend} outlived its killed sender")

  defp await_session_end(observer, backend, attempts) do
    if session?(observer, backend) do
      Process.sleep(10)
      await_session_end(observer, backend, attempts - 1)
    end
  end

  defp session?(observer, backend) do
    Postgrex.query!(observer, "SELECT 1 FROM pg_stat_activity WHERE pid = $1", [backend]).rows !=
      []
  end
end
