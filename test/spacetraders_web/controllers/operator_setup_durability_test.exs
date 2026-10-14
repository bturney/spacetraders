defmodule SpaceTradersWeb.OperatorSetupDurabilityTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Agent, FleetGeneration, Repo}
  alias SpaceTraders.Agent.Operator

  @endpoint SpaceTradersWeb.Endpoint
  @emails ["contender-one@example.com", "contender-two@example.com"]
  @password "durable setup password"

  setup do
    Sandbox.mode(Repo, :auto)
    Sandbox.checkout(Repo, sandbox: false)
    refute Agent.has_operators?()

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      Repo.all(from o in Operator, where: o.email in ^@emails, select: o.id)
      |> Enum.each(&SpaceTraders.AgentFixtures.cleanup_operator_fixture/1)

      SpaceTraders.EmergencyStopAdmission.clear()
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "competing HTTP setup submissions establish one independently observed committed authenticated Operator" do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE operators IN SHARE ROW EXCLUSIVE MODE")
          send(parent, :held)

          receive do
            :release -> :ok
          after
            10_000 -> flunk("setup serialization lock was not released")
          end
        end)
      end)

    assert_receive :held

    contenders =
      for email <- @emails do
        Task.async(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:submitting, backend})

            conn =
              post(build_conn(), "/setup", %{
                "operator" => %{
                  "email" => email,
                  "password" => @password,
                  "password_confirmation" => @password,
                  "account_token" => "ACCOUNT_SECRET_#{email}"
                }
              })

            {email, conn}
          end)
        end)
      end

    assert_receive {:submitting, first_backend}
    assert_receive {:submitting, second_backend}
    assert first_backend != second_backend
    [[observer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    refute observer_backend in [first_backend, second_backend]

    # Both public requests passed the empty UI guard and are actually waiting
    # inside PostgreSQL. Sharing a sandbox connection would not prove this race.
    await_blocked(first_backend)
    await_blocked(second_backend)
    refute Agent.has_operators?()
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)

    results = Enum.map(contenders, &Task.await(&1, 10_000))

    [{winner_email, winner}] =
      Enum.filter(results, fn {_, conn} -> get_session(conn, :operator_token) end)

    [{loser_email, loser}] =
      Enum.reject(results, fn {_, conn} -> get_session(conn, :operator_token) end)

    assert redirected_to(winner) == "/mission-control"
    assert redirected_to(loser) == "/operators/log-in"

    # Observe publication BEFORE a lazy adoption read can repair missing setup
    # publication. The observer has a different connection; both senders exited.
    operator = Agent.get_operator_by_email(winner_email)
    assert operator.confirmed_at
    assert Repo.aggregate(Operator, :count) == 1

    assert [[operator.id, nil]] ==
             Repo.query!("SELECT operator_id, fleet_generation_id FROM current_fleet_identity").rows

    refute Agent.get_operator_by_email(loser_email)
    assert operator.account_token == "ACCOUNT_SECRET_#{winner_email}"

    assert {authenticated, _} =
             Agent.get_operator_by_session_token(get_session(winner, :operator_token))

    assert authenticated.id == operator.id
    assert Agent.get_operator_by_email_and_password(winner_email, @password).id == operator.id
    assert {:ok, %{state: :empty, operator: canonical}} = FleetGeneration.current_fleet()
    assert canonical.id == operator.id

    # A new request after the senders disappear remains closed, even with a new
    # email, password and AccountToken. It cannot overwrite the accepted setup.
    repeated =
      post(build_conn(), "/setup", %{
        "operator" => %{"email" => loser_email, "password" => @password}
      })

    assert redirected_to(repeated) == "/operators/log-in"
    refute get_session(repeated, :operator_token)
    assert Repo.aggregate(Operator, :count) == 1
  end

  test "interrupted setup rolls back both encrypted credentials and canonical authority" do
    assert {:error, :interrupted} =
             Repo.transaction(fn ->
               assert {:ok, _} =
                        Agent.register_operator(%{
                          email: hd(@emails),
                          password: @password,
                          account_token: "INTERRUPTED_SECRET"
                        })

               Repo.rollback(:interrupted)
             end)

    observer =
      Task.async(fn ->
        refute Agent.has_operators?()

        assert [[nil, nil]] ==
                 Repo.query!(
                   "SELECT operator_id, fleet_generation_id FROM current_fleet_identity"
                 ).rows
      end)

    Task.await(observer)
    assert {:ok, operator} = Agent.register_operator(%{email: hd(@emails), password: @password})
    assert Agent.get_operator_by_email_and_password(operator.email, @password).id == operator.id
  end

  defp await_blocked(backend, remaining \\ 500)
  defp await_blocked(_backend, 0), do: flunk("setup contender did not wait inside PostgreSQL")

  defp await_blocked(backend, remaining) do
    case Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend]).rows do
      [[true]] ->
        :ok

      _ ->
        Process.sleep(10)
        await_blocked(backend, remaining - 1)
    end
  end
end
