defmodule SpaceTraders.RuntimeAuthorityTest do
  use SpaceTraders.DataCase

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.RuntimeAuthority

  @moduletag skip:
               SpaceTraders.Repo.__adapter__() != Ecto.Adapters.Postgres &&
                 "runtime authority requires PostgreSQL"

  test "exactly one runtime holds mutation authority" do
    lock_key = System.unique_integer([:positive])

    first =
      start_supervised!(
        Supervisor.child_spec(
          {RuntimeAuthority, name: :first_authority, lock_key: lock_key, require_cutover?: false},
          id: :first_authority
        )
      )

    _second =
      start_supervised!(
        Supervisor.child_spec(
          {RuntimeAuthority,
           name: :second_authority, lock_key: lock_key, require_cutover?: false},
          id: :second_authority
        )
      )

    assert :ok = RuntimeAuthority.execution_allowed?(:first_authority)

    assert {:error, :runtime_authority_unavailable} =
             RuntimeAuthority.execution_allowed?(:second_authority)

    assert is_pid(first)
    stop_supervised!(:first_authority)

    assert_eventually(fn -> RuntimeAuthority.execution_allowed?(:second_authority) == :ok end)
  end

  test "does not claim mutation authority before PostgreSQL cutover completes" do
    name = :pre_cutover_authority

    start_supervised!(
      {RuntimeAuthority, name: name, lock_key: System.unique_integer([:positive])}
    )

    assert {:error, :runtime_authority_unavailable} = RuntimeAuthority.execution_allowed?(name)
  end

  test "a reconnected database session must reacquire the advisory lock" do
    lock_key = System.unique_integer([:positive])

    start_supervised!(
      Supervisor.child_spec(
        {RuntimeAuthority,
         name: :reconnecting_authority, lock_key: lock_key, require_cutover?: false},
        id: :reconnecting_authority
      )
    )

    start_supervised!(
      Supervisor.child_spec(
        {RuntimeAuthority,
         name: :replacement_authority, lock_key: lock_key, require_cutover?: false},
        id: :replacement_authority
      )
    )

    assert :ok = RuntimeAuthority.execution_allowed?(:reconnecting_authority)

    %{rows: [[backend_pid]]} =
      Repo.query!(
        "SELECT pid FROM pg_locks WHERE locktype = 'advisory' AND classid = 0 AND objid = $1::oid AND objsubid = 1 AND granted",
        [lock_key]
      )

    Repo.query!("SELECT pg_terminate_backend($1)", [backend_pid])

    assert_eventually(fn ->
      RuntimeAuthority.execution_allowed?(:replacement_authority) == :ok
    end)

    assert {:error, :runtime_authority_unavailable} =
             RuntimeAuthority.execution_allowed?(:reconnecting_authority)

    stop_supervised!(:replacement_authority)

    assert_eventually(fn ->
      RuntimeAuthority.execution_allowed?(:reconnecting_authority) == :ok
    end)
  end

  test "lock loss suppresses new mutations" do
    previous = Application.get_env(:spacetraders, RuntimeAuthority)
    Application.put_env(:spacetraders, RuntimeAuthority, enabled: true)

    on_exit(fn -> Application.put_env(:spacetraders, RuntimeAuthority, previous) end)

    pid =
      start_supervised!(
        {RuntimeAuthority, lock_key: System.unique_integer([:positive]), require_cutover?: false}
      )

    assert :ok = Agent.execution_allowed?(%AgentRecord{})
    assert is_pid(pid)
    stop_supervised!(RuntimeAuthority)

    assert {:error, :runtime_authority_unavailable} =
             Agent.execution_allowed?(%AgentRecord{})

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      send(self(), :mutation_dispatched)
      flunk("mutation reached HTTP transport without runtime authority")
    end)

    assert {:error, :runtime_authority_unavailable} =
             SpaceTraders.API.accept_contract("TOKEN", "CONTRACT-1")

    refute_received :mutation_dispatched
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
