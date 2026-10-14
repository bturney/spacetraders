defmodule SpaceTraders.CurrentFleetDurabilityTest do
  use ExUnit.Case, async: false
  import SpaceTraders.AgentFixtures
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Agent, FleetGeneration, Repo}
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}

  setup tags do
    Sandbox.mode(Repo, :auto)
    Sandbox.checkout(Repo, sandbox: false)
    restart_capacity_governor()
    operator = operator_fixture()

    agent =
      unless tags[:mint_proof],
        do: agent_fixture(operator, %{symbol: "ORBITALIST", agent_token: "DURABLE_SECRET"})

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)

      # Real-commit proofs own their retained evidence too. Production deletion
      # deliberately nilifies provenance rather than deleting observations.
      agent_ids =
        Repo.all(
          from(a in SpaceTraders.Agent.Agent, where: a.operator_id == ^operator.id, select: a.id)
        )

      attempt_ids =
        Repo.all(from a in Attempt, where: a.operator_id == ^operator.id, select: a.id)

      Repo.delete_all(from o in Outcome, where: o.mutation_attempt_id in ^attempt_ids)
      Repo.delete_all(from a in Attempt, where: a.id in ^attempt_ids)

      Repo.delete_all(
        from(d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id in ^agent_ids)
      )

      Repo.delete_all(
        from(o in SpaceTraders.Evidence.Observation, where: o.agent_id in ^agent_ids)
      )

      topics = ["fleet_allocation" | Enum.map(agent_ids, &"fleet:#{&1}")]
      Repo.delete_all(from(n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics))
      SpaceTraders.AgentFixtures.cleanup_operator_fixture(operator.id)
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()
      restart_capacity_governor()
      Sandbox.mode(Repo, :manual)
    end)

    %{operator: operator, agent: agent}
  end

  defp restart_capacity_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _pid} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
  end

  @tag mint_proof: true
  test "successful mint and same-symbol reset publish committed identity before any observer can repair it",
       %{operator: operator} do
    {:ok, operator} = Agent.link_account_token(operator_scope_fixture(operator), "ACCOUNT_SECRET")
    scope = operator_scope_fixture(operator)
    {:ok, draft} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = SpaceTraders.FleetStrategy.activate(scope, draft.draft_version)
    parent = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "POST"
      Req.Test.json(conn, registration("FIRST_SECRET"))
    end)

    sender =
      Task.async(fn ->
        receive do
          :mint ->
            Repo.checkout(fn ->
              [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
              send(parent, {:sender_backend, backend})
              FleetGeneration.mint(scope, %{symbol: "ORBITALIST", faction: "COSMIC"})
            end)
        end
      end)

    Req.Test.allow(SpaceTraders.API, self(), sender.pid)
    send(sender.pid, :mint)
    assert_receive {:sender_backend, backend}
    assert {:ok, %{agent: first}} = Task.await(sender)
    [[observer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    assert backend != observer_backend
    # Observe the committed PostgreSQL publication before a lazy compatibility
    # read. Removing lifecycle publication must fail this proof.
    assert [[first_generation_id]] =
             Repo.query!(
               "SELECT fleet_generation_id FROM current_fleet_identity WHERE operator_id = $1",
               [operator.id]
             ).rows

    assert is_integer(first_generation_id)

    assert {:ok, %{state: :current, agent: first_ref, generation: first_generation}} =
             FleetGeneration.current_fleet(scope)

    assert first_ref.id == first.id
    assert first_generation.id == first_generation_id

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "POST"
      assert conn.body_params["symbol"] == "ORBITALIST"

      assert {:ok, %{state: :transition, generation: fenced}} =
               FleetGeneration.current_fleet(scope)

      assert fenced.id == first_generation_id
      Req.Test.json(conn, registration("SECOND_SECRET"))
    end)

    error = %SpaceTraders.API.GameplayError{
      code: 4113,
      type: :other,
      message:
        "Failed to parse token. Token reset_date does not match the server. Server resets happen weekly. After a reset, you should re-register your agent. Expected: 2026-10-11, Actual: 2026-10-01"
    }

    assert {:error, :stale_agent} =
             SpaceTraders.Observability.with_context(
               [
                 agent_id: first.id,
                 fleet_generation_id: first_generation_id,
                 strategy_revision_id: revision.id
               ],
               fn ->
                 FleetGeneration.handle_game_result(
                   Repo.get!(SpaceTraders.Agent.Agent, first.id),
                   {:error, error}
                 )
               end
             )

    assert [[second_generation_id]] =
             Repo.query!(
               "SELECT fleet_generation_id FROM current_fleet_identity WHERE operator_id = $1",
               [operator.id]
             ).rows

    assert second_generation_id != first_generation_id

    assert {:ok, %{state: :current, agent: second_ref, generation: second_generation}} =
             FleetGeneration.current_fleet(scope)

    assert second_ref.id != first.id
    assert second_generation.id == second_generation_id
    assert second_generation.fleet_strategy_revision_id == revision.id
    assert second_generation.symbol == first_generation.symbol
    assert Repo.get!(SpaceTraders.Agent.Agent, second_ref.id).agent_token == "SECOND_SECRET"
    assert [current, historical] = FleetGeneration.list_generations(scope)
    assert current.id == second_generation_id
    assert historical.id == first_generation_id
    assert historical.retired_at

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer SECOND_SECRET"]

      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "ORBITALIST",
              "headquarters" => "X1-UX81-A1",
              "credits" => 456_000,
              "startingFaction" => "COSMIC"
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{
            "data" => [],
            "meta" => %{"total" => 0, "page" => 1, "limit" => 20}
          })

        "/v2/my/contracts" ->
          Req.Test.json(conn, %{
            "data" => [],
            "meta" => %{"total" => 0, "page" => 1, "limit" => 20}
          })
      end
    end)

    briefing = SpaceTraders.MissionControl.overview(scope)
    assert briefing.current_fleet.generation.id == second_generation_id

    assert [%{agent: %{id: id}, overview: {:ok, %{credits: 456_000}}, ships: {:ok, []}}] =
             briefing.fleets

    assert id == second_ref.id
  end

  defp registration(token) do
    %{
      "data" => %{
        "token" => token,
        "agent" => %{
          "symbol" => "ORBITALIST",
          "headquarters" => "X1-UX81-A1",
          "credits" => 175_000,
          "startingFaction" => "COSMIC"
        },
        "ships" => [],
        "contract" => %{"id" => "c1"},
        "faction" => %{"symbol" => "COSMIC"}
      }
    }
  end

  test "competing initialization serializes on PostgreSQL and independent readers see one committed Generation",
       %{operator: operator, agent: agent} do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE operators IN SHARE ROW EXCLUSIVE MODE")
          send(parent, :held)

          receive do
            :release -> :ok
          after
            5000 -> flunk("lock holder was not released")
          end
        end)
      end)

    assert_receive :held

    adopters =
      for _ <- 1..2 do
        Task.async(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(parent, {:initializing, self(), backend})
            FleetGeneration.preflight_current_fleet()
          end)
        end)
      end

    assert_receive {:initializing, first, first_backend}
    assert_receive {:initializing, second, second_backend}
    assert first != second
    assert first_backend != second_backend
    [[observer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    refute observer_backend in [first_backend, second_backend]

    identities =
      Enum.map(adopters, fn task ->
        assert {:ok, identity} = Task.await(task)
        identity
      end)

    [identity, second_identity] = identities
    assert identity == second_identity
    assert identity.agent.id == agent.id
    assert identity.operator.id == operator.id
    assert identity.agent.agent_token == nil
    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder)

    # Both senders exited; this independent checkout observes only committed
    # state and rerun reuses the same meaningful Generation identity.
    assert {:ok, ^identity} = FleetGeneration.current_fleet()
    assert {:ok, ^identity} = FleetGeneration.preflight_current_fleet()
    assert [generation] = FleetGeneration.list_generations(operator_scope_fixture(operator))
    assert generation.id == identity.generation.id
    assert Repo.get!(SpaceTraders.Agent.Agent, agent.id).agent_token == "DURABLE_SECRET"
  end

  test "an aborted preflight transaction cannot unpublish established authority; rerun preserves secrets",
       %{operator: operator, agent: agent} do
    before = FleetGeneration.list_generations(operator_scope_fixture(operator))

    sender =
      Task.async(fn ->
        Repo.transaction(fn ->
          assert {:ok, %{generation: generation}} = FleetGeneration.preflight_current_fleet()
          assert generation.agent_id == agent.id
          Repo.rollback(:interrupted_before_commit)
        end)
      end)

    assert {:error, :interrupted_before_commit} = Task.await(sender)
    assert FleetGeneration.list_generations(operator_scope_fixture(operator)) == before
    assert Repo.get!(SpaceTraders.Agent.Agent, agent.id).agent_token == "DURABLE_SECRET"
    assert {:ok, %{state: :current, agent: current}} = FleetGeneration.preflight_current_fleet()
    assert current.id == agent.id
    assert [generation] = FleetGeneration.list_generations(operator_scope_fixture(operator))
    assert generation.agent_id == agent.id
  end

  describe "competing establishment" do
    setup %{operator: operator} do
      {:ok, operator} =
        Agent.link_account_token(operator_scope_fixture(operator), "ACCOUNT_SECRET")

      parent = self()

      # Every game request is observed and held in flight until released.
      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(parent, {:game_request, self(), conn.method, conn.request_path})

        receive do
          :respond -> :ok
        after
          5000 -> flunk("held game request was not released")
        end

        case conn.request_path do
          "/v2/register" ->
            Req.Test.json(conn, registration("FIRST_SECRET"))

          "/v2/my/agent" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "ORBITALIST",
                "headquarters" => "X1-UX81-A1",
                "credits" => 42_000,
                "startingFaction" => "COSMIC"
              }
            })

          "/v2/my/ships" ->
            Req.Test.json(conn, %{
              "data" => [],
              "meta" => %{"total" => 0, "page" => 1, "limit" => 20}
            })
        end
      end)

      %{operator: operator, scope: operator_scope_fixture(operator)}
    end

    @tag mint_proof: true
    test "a second mint waits in PostgreSQL during registration and never dispatches its own",
         %{scope: scope} do
      first = contender(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
      assert_receive {:game_request, sender, "POST", "/v2/register"}, 2000

      second = contender(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)
      await_blocked_by(second.backend, first.backend)
      refute_received {:game_request, _, _, _}

      send(sender, :respond)
      assert {:ok, %{agent: established}} = Task.await(first.task)
      assert {:error, :current_fleet_exists} = Task.await(second.task)
      refute_received {:game_request, _, _, _}
      assert_sole_current(scope, established, "FIRST_SECRET")
    end

    @tag mint_proof: true
    test "an import competing with registration waits and cannot add a second Agent",
         %{scope: scope} do
      minting = contender(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
      assert_receive {:game_request, sender, "POST", "/v2/register"}, 2000

      importing =
        contender(fn -> FleetGeneration.import_agent(scope, "IMPORTED_SECRET", true) end)

      await_blocked_by(importing.backend, minting.backend)

      send(sender, :respond)
      assert {:ok, %{agent: established}} = Task.await(minting.task)
      assert {:error, :current_fleet_exists} = Task.await(importing.task)
      refute_received {:game_request, _, _, _}
      assert_sole_current(scope, established, "FIRST_SECRET")
    end

    @tag mint_proof: true
    test "a mint competing with an in-flight import waits and dispatches no registration",
         %{scope: scope} do
      importing =
        contender(fn -> FleetGeneration.import_agent(scope, "IMPORTED_SECRET", true) end)

      assert_receive {:game_request, reader, "GET", "/v2/my/agent"}, 2000

      minting = contender(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)
      await_blocked_by(minting.backend, importing.backend)

      send(reader, :respond)
      assert_receive {:game_request, ships_reader, "GET", "/v2/my/ships"}, 2000
      send(ships_reader, :respond)
      assert {:ok, established} = Task.await(importing.task)
      assert {:error, :current_fleet_exists} = Task.await(minting.task)
      refute_received {:game_request, _, _, _}
      assert_sole_current(scope, established, "IMPORTED_SECRET")
    end
  end

  defp mint(symbol), do: %{symbol: symbol, faction: "COSMIC"}

  # An independent PostgreSQL session: its own checkout, committed results only.
  defp contender(establish) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        receive do
          :go -> :ok
        end

        Repo.checkout(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:backend, ref, backend})
          establish.()
        end)
      end)

    Req.Test.allow(SpaceTraders.API, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:backend, ^ref, backend}
    [[observer]] = Repo.query!("SELECT pg_backend_pid()").rows
    assert backend != observer
    %{task: task, backend: backend}
  end

  defp assert_sole_current(scope, established, token) do
    assert {:ok, %{state: :current, agent: current, generation: generation}} =
             FleetGeneration.current_fleet(scope)

    assert current.id == established.id
    assert generation.agent_id == established.id
    assert [only] = Repo.all(SpaceTraders.Agent.Agent)
    assert only.id == established.id
    assert only.agent_token == token
    assert [^generation] = FleetGeneration.list_generations(scope)
  end

  defp await_blocked_by(backend, holder, remaining \\ 500)

  defp await_blocked_by(_backend, _holder, 0),
    do: flunk("contender did not wait on the establishment holder in PostgreSQL")

  defp await_blocked_by(backend, holder, remaining) do
    case Repo.query!("SELECT pg_blocking_pids($1)", [backend]).rows do
      [[[^holder]]] ->
        :ok

      _ ->
        Process.sleep(10)
        await_blocked_by(backend, holder, remaining - 1)
    end
  end
end
