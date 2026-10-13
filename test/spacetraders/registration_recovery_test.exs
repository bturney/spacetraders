defmodule SpaceTraders.RegistrationRecoveryTest do
  @moduledoc """
  Registration outcomes survive response loss, local interruption and restart
  through the one MutationAttempts recovery authority. Every proof runs against
  real PostgreSQL commits: each establishment runs in its own process and
  checkout, and assertions read only what an independent session can observe.
  Game requests are observed at the Req.Test boundary.
  """
  use ExUnit.Case, async: false
  import SpaceTraders.AgentFixtures
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Agent, FleetGeneration, OperatorConditions, Repo, RuntimeDeath}
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}

  setup do
    Sandbox.mode(Repo, :auto)
    Sandbox.checkout(Repo, sandbox: false)
    restart_capacity_governor()
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_SECRET")

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      agent_ids =
        Repo.all(from(a in Agent.Agent, where: a.operator_id == ^operator.id, select: a.id))

      attempt_ids =
        Repo.all(from(a in Attempt, where: a.operator_id == ^operator.id, select: a.id))

      Repo.delete_all(from(o in Outcome, where: o.mutation_attempt_id in ^attempt_ids))
      Repo.delete_all(from(a in Attempt, where: a.id in ^attempt_ids))

      Repo.delete_all(
        from(d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id in ^agent_ids)
      )

      Repo.delete_all(
        from(o in SpaceTraders.Evidence.Observation, where: o.agent_id in ^agent_ids)
      )

      topics = ["fleet_allocation:#{operator.id}" | Enum.map(agent_ids, &"fleet:#{&1}")]
      Repo.delete_all(from(n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics))
      Repo.delete_all(from(o in Agent.Operator, where: o.id == ^operator.id))
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()
      restart_capacity_governor()
      Sandbox.mode(Repo, :manual)
    end)

    %{operator: operator, scope: operator_scope_fixture(operator)}
  end

  describe "a lost registration response" do
    setup do
      game(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v2/register"} -> Req.Test.transport_error(conn, :timeout)
        end
      end)

      :ok
    end

    test "suppresses competing setup and the next candidate until its outcome is known",
         %{scope: scope} do
      assert {:error, :registration_unresolved} =
               in_session(fn ->
                 FleetGeneration.mint(scope, %{
                   symbol: "ORBITALIST",
                   faction: "COSMIC",
                   replacement_symbols: ["ORBITALIST", "PARALLAX"]
                 })
               end)

      # A possibly successful registration never falls through to PARALLAX.
      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}
      refute_received {:game_request, _, _, _}

      assert %{status: :unresolved, symbol: "ORBITALIST", summary: summary} =
               FleetGeneration.registration_recovery(scope)

      assert summary =~ "ORBITALIST"
      assert {:ok, %{state: :empty}} = FleetGeneration.current_fleet(scope)

      assert [%{key: "registration-recovery", kind: :intervention}] =
               OperatorConditions.unresolved(scope)

      # A restarted or competing setup sees the committed uncertainty.
      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)

      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.import_agent(scope, "UNRELATED_SECRET", true) end)

      refute_received {:game_request, _, _, _}
      assert agents(scope) == []
    end

    test "public symbol occupancy leaves it unresolved; absence proves it never happened",
         %{scope: scope} do
      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}

      game(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/agents/ORBITALIST"} -> Req.Test.json(conn, public_agent("ORBITALIST"))
        end
      end)

      # Somebody holds the symbol: that proves neither ownership nor failure.
      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.reconcile_registration(scope) end)

      assert_received {:game_request, "GET", "/v2/agents/ORBITALIST", nil}
      assert %{status: :unresolved} = FleetGeneration.registration_recovery(scope)
      assert agents(scope) == []

      game(fn conn ->
        case {conn.method, conn.request_path, conn.body_params["symbol"]} do
          {"GET", "/v2/agents/ORBITALIST", _} ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "Agent not found"}})

          {"POST", "/v2/register", "ORBITALIST"} ->
            Req.Test.json(conn, registration("ORBITALIST", "SECOND_SECRET"))
        end
      end)

      assert {:ok, :clear} = in_session(fn -> FleetGeneration.reconcile_registration(scope) end)
      assert_received {:game_request, "GET", "/v2/agents/ORBITALIST", nil}
      refute_received {:game_request, "POST", _, _}
      assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
      assert OperatorConditions.unresolved(scope) == []

      assert {:ok, %{agent: agent}} =
               in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}
      assert [%{symbol: "ORBITALIST", agent_token: "SECOND_SECRET"}] = agents(scope)
      assert agent.symbol == "ORBITALIST"
    end

    test "a confirmed AgentToken adopts only the intended identity", %{scope: scope} do
      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}

      game(fn conn ->
        token = conn |> Plug.Conn.get_req_header("authorization") |> List.first()

        case {conn.method, conn.request_path, token} do
          {"GET", "/v2/my/agent", "Bearer OTHER_SECRET"} ->
            Req.Test.json(conn, my_agent("SOMEONE"))

          {"GET", "/v2/my/agent", "Bearer LOST_SECRET"} ->
            Req.Test.json(conn, my_agent("ORBITALIST"))

          {"GET", "/v2/my/ships", "Bearer LOST_SECRET"} ->
            Req.Test.json(conn, %{
              "data" => [ship("ORBITALIST-1")],
              "meta" => %{"total" => 1, "page" => 1, "limit" => 20}
            })
        end
      end)

      # Recovery adoption is not a second-Agent import path.
      assert {:error, :registration_identity_mismatch} =
               in_session(fn ->
                 FleetGeneration.adopt_registered_agent(scope, "OTHER_SECRET", true)
               end)

      assert %{status: :unresolved} = FleetGeneration.registration_recovery(scope)
      assert agents(scope) == []

      assert {:ok, %{agent: adopted}} =
               in_session(fn ->
                 FleetGeneration.adopt_registered_agent(scope, "LOST_SECRET", true)
               end)

      assert adopted.symbol == "ORBITALIST"
      assert adopted.agent_token == nil
      refute_received {:game_request, "POST", _, _}
      assert [%{symbol: "ORBITALIST", agent_token: "LOST_SECRET"}] = agents(scope)

      assert {:ok, %{state: :current, agent: %{symbol: "ORBITALIST"}}} =
               FleetGeneration.current_fleet(scope)

      assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
      assert OperatorConditions.unresolved(scope) == []
      assert ["ORBITALIST-1"] = ship_symbols(adopted)

      # Once current, the recovery path cannot add another Agent.
      assert {:error, :current_fleet_exists} =
               in_session(fn ->
                 FleetGeneration.adopt_registered_agent(scope, "LOST_SECRET", true)
               end)
    end
  end

  describe "a successful registration" do
    setup %{operator: operator} do
      parent = self()

      game(fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v2/register"} ->
            send(parent, {:registering, self()})

            receive do
              :respond -> Req.Test.json(conn, registration("ORBITALIST", "FIRST_SECRET"))
            after
              5000 -> flunk("held registration was not released")
            end
        end
      end)

      %{operator: operator}
    end

    test "followed by interrupted local persistence recovers the same identity after restart",
         %{scope: scope, operator: operator} do
      minting = killable(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
      assert_receive {:registering, request}, 2000

      # Hold the establishment row so local adoption waits after the response.
      holder = hold_operator_row(operator)
      send(request, :respond)
      await_blocked_by(minting.backend, holder.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(minting.pid, minting.backend)
      release(holder)

      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}

      assert %{status: :awaiting_adoption, symbol: "ORBITALIST"} =
               FleetGeneration.registration_recovery(scope)

      assert agents(scope) == []
      assert {:ok, %{state: :empty}} = FleetGeneration.current_fleet(scope)
      assert_credential_secret("FIRST_SECRET")

      # Restarted setup resumes adoption instead of registering PARALLAX.
      assert {:ok, %{agent: recovered}} =
               in_session(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)

      refute_received {:game_request, _, _, _}
      assert recovered.symbol == "ORBITALIST"
      assert [%{symbol: "ORBITALIST", agent_token: "FIRST_SECRET"}] = agents(scope)
      assert ["ORBITALIST-1"] = ship_symbols(recovered)
      assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
      assert recovery_credentials() == []
    end

    test "followed by interrupted bootstrap recovers the same identity", %{scope: scope} do
      minting = killable(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
      assert_receive {:registering, request}, 2000

      # An uncommitted Ship with the same symbol stalls the bootstrap insert.
      holder = hold_ship_symbol("ORBITALIST-1")
      send(request, :respond)
      await_blocked_by(minting.backend, holder.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(minting.pid, minting.backend)
      release(holder)
      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}

      assert %{status: :awaiting_adoption, symbol: "ORBITALIST"} =
               FleetGeneration.registration_recovery(scope)

      assert agents(scope) == []

      assert {:ok, :adopted} = in_session(fn -> FleetGeneration.reconcile_registration(scope) end)
      refute_received {:game_request, "POST", _, _}

      assert {:ok, %{state: :current, agent: current}} = FleetGeneration.current_fleet(scope)
      assert current.symbol == "ORBITALIST"
      assert ["ORBITALIST-1"] = ship_symbols(current)
      assert [%{agent_token: "FIRST_SECRET"}] = agents(scope)
    end
  end

  defp mint(symbol), do: %{symbol: symbol, faction: "COSMIC"}

  defp agents(scope), do: Agent.list_agents(Agent.get_operator!(scope.operator.id))

  defp ship_symbols(agent) do
    Repo.all(
      from(s in SpaceTraders.Fleet.Ship,
        where: s.agent_id == ^agent.id,
        order_by: s.symbol,
        select: s.symbol
      )
    )
  end

  defp recovery_credentials do
    Repo.all(
      from(a in "mutation_attempts",
        where: not is_nil(a.recovery_credential_ciphertext),
        select: a.recovery_credential_ciphertext
      )
    )
  end

  # The pending AgentToken is durable, encrypted at rest and absent from evidence.
  defp assert_credential_secret(token) do
    assert [ciphertext] = recovery_credentials()
    refute ciphertext =~ token

    evidence =
      Repo.all(from(o in "mutation_attempt_outcomes", select: o.evidence)) ++
        Repo.all(from(a in "mutation_attempts", select: a.prepared_evidence))

    refute inspect(evidence) =~ token
  end

  # Records every game request, then answers with `respond`.
  defp game(respond) do
    parent = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(parent, {:game_request, conn.method, conn.request_path, conn.body_params["symbol"]})
      respond.(conn)
    end)
  end

  # A fresh process with its own PostgreSQL session, like a restarted request.
  defp in_session(fun) do
    task = Task.async(fn -> Repo.checkout(fun) end)
    Req.Test.allow(SpaceTraders.API, self(), task.pid)
    Task.await(task, 10_000)
  end

  # An unlinked establishment in its own session, so it can be killed mid-way.
  defp killable(fun) do
    parent = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        receive do
          :go -> :ok
        end

        Repo.checkout(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:backend, ref, backend})
          fun.()
        end)
      end)

    Req.Test.allow(SpaceTraders.API, self(), pid)
    send(pid, :go)
    assert_receive {:backend, ^ref, backend}
    %{pid: pid, backend: backend}
  end

  defp hold_operator_row(operator) do
    hold(fn ->
      Repo.query!("SELECT id FROM operators WHERE id = $1 FOR NO KEY UPDATE", [operator.id])
    end)
  end

  defp hold_ship_symbol(symbol) do
    hold(fn ->
      holder = legacy_operator_fixture()
      agent = agent_fixture(holder, %{symbol: "HOLDER#{System.unique_integer([:positive])}"})
      Repo.insert!(%SpaceTraders.Fleet.Ship{symbol: symbol, ship_type: "X", agent_id: agent.id})
    end)
  end

  # Holds `fun`'s locks in an uncommitted transaction until released.
  defp hold(fun) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        Repo.transaction(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          fun.()
          send(parent, {:held, ref, backend})

          receive do
            :release -> Repo.rollback(:released)
          after
            5000 -> flunk("holder was not released")
          end
        end)
      end)

    assert_receive {:held, ^ref, backend}
    %{task: task, backend: backend}
  end

  defp release(%{task: task}) do
    send(task.pid, :release)
    assert {:error, :released} = Task.await(task)
  end

  defp await_blocked_by(backend, holder, remaining \\ 500)
  defp await_blocked_by(_backend, _holder, 0), do: flunk("establishment did not wait on holder")

  defp await_blocked_by(backend, holder, remaining) do
    case Repo.query!("SELECT pg_blocking_pids($1)", [backend]).rows do
      [[[^holder]]] ->
        :ok

      _ ->
        Process.sleep(10)
        await_blocked_by(backend, holder, remaining - 1)
    end
  end

  defp restart_capacity_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _pid} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
  end

  defp registration(symbol, token) do
    %{
      "data" => %{
        "token" => token,
        "agent" => %{
          "symbol" => symbol,
          "headquarters" => "X1-UX81-A1",
          "credits" => 175_000,
          "startingFaction" => "COSMIC"
        },
        "ships" => [ship("#{symbol}-1")],
        "contract" => %{"id" => "c1"},
        "faction" => %{"symbol" => "COSMIC"}
      }
    }
  end

  defp ship(symbol), do: %{"symbol" => symbol, "registration" => %{"role" => "COMMAND"}}

  defp my_agent(symbol) do
    %{
      "data" => %{
        "symbol" => symbol,
        "headquarters" => "X1-UX81-A1",
        "credits" => 175_000,
        "startingFaction" => "COSMIC"
      }
    }
  end

  defp public_agent(symbol), do: my_agent(symbol)
end
