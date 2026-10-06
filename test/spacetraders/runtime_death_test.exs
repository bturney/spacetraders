defmodule SpaceTraders.RuntimeDeathTest do
  # Real commits and a separate observer session, as the interruption matrices use.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Repo, RuntimeDeath}

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    on_exit(fn -> Sandbox.mode(Repo, :manual) end)

    options =
      Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database, :ssl, :socket_options])

    {:ok, observer: start_supervised!({Postgrex, options})}
  end

  test "a death inside a transaction ends the sender's session", %{observer: observer} do
    {sender, backend} = sender(fn work -> Repo.transaction(work) end)

    assert {:disconnected, log} = RuntimeDeath.kill(sender, backend)

    assert log =~ "client #{inspect(sender)} exited"
    refute session?(observer, backend)
  end

  test "a death holding a checkout outside a transaction ends the sender's session",
       %{observer: observer} do
    {sender, backend} = sender(fn work -> Repo.checkout(work) end)

    assert {:disconnected, log} = RuntimeDeath.kill(sender, backend)

    assert log =~ "client #{inspect(sender)} exited"
    refute session?(observer, backend)
  end

  test "a death holding no checkout disconnects nothing", %{observer: observer} do
    {sender, backend} = sender(fn work -> work.() end)

    assert {:idle, log} = RuntimeDeath.kill(sender, backend)

    refute log =~ "disconnected"
    assert session?(observer, backend)
  end

  defp sender(wrap) do
    test = self()

    sender =
      start_supervised!(
        {Task,
         fn ->
           wrap.(fn ->
             [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
             send(test, {:boundary, self(), backend})
             Process.sleep(:infinity)
           end)
         end}
      )

    assert_receive {:boundary, ^sender, backend}
    {sender, backend}
  end

  defp session?(observer, backend) do
    Postgrex.query!(observer, "SELECT 1 FROM pg_stat_activity WHERE pid = $1", [backend]).rows !=
      []
  end
end
