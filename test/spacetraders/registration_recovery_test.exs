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
  alias SpaceTraders.{Agent, FleetGeneration, Repo, RuntimeDeath}
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}

  setup do
    Sandbox.mode(Repo, :auto)
    Sandbox.checkout(Repo, sandbox: false)
    restart_capacity_governor()
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator_scope_fixture(operator), "ACCOUNT_SECRET")

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
      SpaceTraders.AgentFixtures.cleanup_operator_fixture(operator.id)
      SpaceTraders.FleetGenerationAdmission.clear()
      restart_capacity_governor()
      Sandbox.mode(Repo, :manual)
    end)

    %{operator: operator, scope: operator_scope_fixture(operator)}
  end

  test "independently committed activation and adoption publish one coherent Revision", %{
    scope: scope,
    operator: operator
  } do
    alias SpaceTraders.FleetStrategy
    agent = agent_fixture(operator, %{symbol: "ORBITALIST", agent_token: "PREDECESSOR_TOKEN"})
    {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, first} = FleetStrategy.activate(scope, draft.draft_version)
    {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
    parent = self()
    handler = "694-adoption-strategy-binding"

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _, _, metadata, _ ->
        if Process.get(:pause_adoption_revision) == true and
             String.starts_with?(metadata.query, "SELECT") and
             String.contains?(metadata.query, "fleet_strategies") and
             String.contains?(metadata.query, "fleet_strategy_revisions") do
          Process.delete(:pause_adoption_revision)
          send(parent, {:adoption_revision_read, self()})

          receive do
            :continue -> :ok
          after
            5000 -> raise "Adoption response was not released"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Process.put(:pause_adoption_revision, true)
      Req.Test.json(conn, registration("ORBITALIST", "SUCCESSOR_TOKEN"))
    end)

    replacing =
      Task.async(fn ->
        Repo.checkout(fn ->
          error = %SpaceTraders.API.GameplayError{
            code: 4113,
            type: :other,
            message:
              "Failed to parse token. Token reset_date does not match the server. Server resets happen weekly. After a reset, you should re-register your agent. Expected: 2026-10-14, Actual: 2026-10-01"
          }

          FleetGeneration.handle_game_result(agent, {:error, error})
        end)
      end)

    Req.Test.allow(SpaceTraders.API, self(), replacing.pid)
    assert_receive {:adoption_revision_read, adopting}, 5000
    assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)

    activating =
      Task.async(fn ->
        Repo.checkout(fn ->
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(parent, {:activation_backend, backend})
          result = FleetStrategy.activate(scope, draft.draft_version)
          send(parent, :activation_committed)
          result
        end)
      end)

    assert_receive {:activation_backend, backend}, 5000
    await_activation_boundary(backend, System.monotonic_time(:millisecond) + 4000)
    send(adopting, :continue)
    assert {:error, :stale_agent} = Task.await(replacing)
    assert {:ok, second} = Task.await(activating)
    assert first.id != second.id
    assert FleetStrategy.get(scope).active_revision.id == second.id

    assert {:ok, %{state: :current, agent: successor, generation: current}} =
             FleetGeneration.current_fleet(scope)

    assert current.fleet_strategy_revision_id == second.id

    assert {:ok, allocation} =
             SpaceTraders.FleetAllocation.authorize_current(scope, successor, second)

    assert allocation.id == current.id
    assert :ok = FleetGeneration.gameplay_authority(successor.id)

    assert List.last(FleetGeneration.list_generations(scope)).fleet_strategy_revision_id ==
             first.id
  end

  defp await_activation_boundary(backend, deadline) do
    receive do
      :activation_committed -> :ok
    after
      0 ->
        case Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend]).rows do
          [["Lock"]] ->
            :ok

          _ ->
            if System.monotonic_time(:millisecond) >= deadline,
              do: flunk("Activation neither committed nor waited on adoption")

            Process.sleep(10)
            await_activation_boundary(backend, deadline)
        end
    end
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
      assert ["ORBITALIST-1"] = ship_symbols(adopted)

      # Once current, the recovery path cannot add another Agent.
      assert {:error, :current_fleet_exists} =
               in_session(fn ->
                 FleetGeneration.adopt_registered_agent(scope, "LOST_SECRET", true)
               end)
    end

    test "missing capacity or runtime authority leaves the same unresolved attempt", %{
      scope: scope
    } do
      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}
      recovery = FleetGeneration.registration_recovery(scope)

      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      try do
        assert {:error, :registration_unresolved} =
                 in_session(fn -> FleetGeneration.reconcile_registration(scope) end)

        assert FleetGeneration.registration_recovery(scope) == recovery
        refute_received {:game_request, _, _, _}
      after
        {:ok, _} =
          Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
      end

      previous = Application.get_env(:spacetraders, SpaceTraders.RuntimeAuthority)
      Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, enabled: true)

      try do
        assert {:error, :runtime_authority_unavailable} =
                 in_session(fn -> FleetGeneration.reconcile_registration(scope) end)

        assert {:error, :runtime_authority_unavailable} =
                 in_session(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)

        assert FleetGeneration.registration_recovery(scope) == recovery
        refute_received {:game_request, _, _, _}
      after
        if previous,
          do: Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, previous),
          else: Application.delete_env(:spacetraders, SpaceTraders.RuntimeAuthority)
      end
    end
  end

  test "a success response without its AgentToken remains unresolved across sessions", %{
    scope: scope
  } do
    game(fn conn ->
      response = registration("ORBITALIST", "UNRETAINED_SECRET")
      Req.Test.json(conn, update_in(response, ["data"], &Map.delete(&1, "token")))
    end)

    assert {:error, :registration_unresolved} =
             in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

    assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}

    assert %{status: :unresolved, symbol: "ORBITALIST"} =
             FleetGeneration.registration_recovery(scope)

    assert {:error, :registration_unresolved} =
             in_session(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)

    refute_received {:game_request, _, _, _}
    assert agents(scope) == []
  end

  test "registration credentials stay out of debug SQL logs as well as public recovery", %{
    scope: scope
  } do
    game(fn conn -> Req.Test.json(conn, registration("ORBITALIST", "DEBUG_AGENT_SECRET")) end)
    previous_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          assert {:ok, %{agent: %{symbol: "ORBITALIST"}}} =
                   in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
        end)

      refute log =~ "DEBUG_AGENT_SECRET"
      refute log =~ "ACCOUNT_SECRET"
      refute inspect(FleetGeneration.registration_recovery(scope)) =~ "DEBUG_AGENT_SECRET"
    after
      Logger.configure(level: previous_level)
    end
  end

  test "a caller transaction cannot dispatch registration with rollbackable recovery evidence", %{
    scope: scope
  } do
    game(fn conn -> Req.Test.json(conn, registration("ORBITALIST", "FIRST_SECRET")) end)

    assert {:error, :caller_interrupted} =
             in_session(fn ->
               Repo.transaction(fn ->
                 assert {:error, :registration_commit_boundary_required} =
                          FleetGeneration.mint(scope, mint("ORBITALIST"))

                 Repo.rollback(:caller_interrupted)
               end)
             end)

    refute_received {:game_request, _, _, _}
    assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
    assert agents(scope) == []

    assert {:ok, %{agent: %{symbol: "ORBITALIST"}}} =
             in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

    assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}
    refute_received {:game_request, _, _, _}
  end

  test "only proven rejection advances a candidate and retains the exact rejection evidence", %{
    scope: scope
  } do
    game(fn conn ->
      case conn.body_params["symbol"] do
        "ORBITALIST" ->
          conn
          |> Plug.Conn.put_status(409)
          |> Req.Test.json(%{
            "error" => %{"code" => 4103, "message" => "Symbol is taken"}
          })

        "PARALLAX" ->
          Req.Test.json(conn, registration("PARALLAX", "SECOND_SECRET"))
      end
    end)

    assert {:ok, %{agent: %{symbol: "PARALLAX"}}} =
             in_session(fn ->
               FleetGeneration.mint(scope, %{
                 symbol: "ORBITALIST",
                 faction: "COSMIC",
                 replacement_symbols: ["ORBITALIST", "PARALLAX"]
               })
             end)

    assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}
    assert_received {:game_request, "POST", "/v2/register", "PARALLAX"}
    refute_received {:game_request, _, _, _}

    [rejection] =
      Repo.all(
        from o in Outcome,
          join: a in Attempt,
          on: a.id == o.mutation_attempt_id,
          where: a.operator_id == ^scope.operator.id and o.classification == "rejected",
          select: o.evidence
      )

    assert rejection == %{
             "status" => 409,
             "response" => %{
               "error" => %{"code" => 4103, "message" => "Symbol is taken"}
             }
           }

    assert [generation] = FleetGeneration.list_generations(scope)
    assert generation.replacement_symbols == %{"symbols" => ["ORBITALIST", "PARALLAX"]}
  end

  test "death before dispatch preserves preparation and permits exactly one later registration",
       %{scope: scope} do
    game(fn conn -> Req.Test.json(conn, registration("ORBITALIST", "FIRST_SECRET")) end)

    dependency =
      SpaceTraders.SafetyFence.DependencyKey.agent_symbol(scope.operator.id, "ORBITALIST")

    holder =
      hold(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dependency])
      end)

    minting = killable(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
    await_blocked_by(minting.backend, holder.backend)

    assert %{status: :in_progress, attempt_id: attempt_id, symbol: "ORBITALIST"} =
             FleetGeneration.registration_recovery(scope)

    refute_received {:game_request, _, _, _}
    assert {:disconnected, _log} = RuntimeDeath.kill(minting.pid, minting.backend)
    release(holder)

    assert {:ok, %{agent: %{symbol: "ORBITALIST"}}} =
             in_session(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)

    assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}
    refute_received {:game_request, _, _, _}

    assert %{
             state: "not_sent",
             prepared_evidence: %{"request" => %{"body" => %{"symbol" => "ORBITALIST"}}}
           } =
             Repo.get!(Attempt, attempt_id)
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

    test "death after dispatch releases establishment authority but preserves uncertainty for a queued mint",
         %{scope: scope} do
      minting = killable(fn -> FleetGeneration.mint(scope, mint("ORBITALIST")) end)
      assert_receive {:registering, _request}, 2000
      assert_received {:game_request, "POST", "/v2/register", "ORBITALIST"}

      # The independent observer sees committed sent-or-unknown while the
      # response is still held at the game boundary.
      assert %{status: :unresolved, attempt_id: attempt_id, symbol: "ORBITALIST"} =
               FleetGeneration.registration_recovery(scope)

      contender = contender(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)
      await_blocked_by(contender.backend, minting.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(minting.pid, minting.backend)
      assert {:error, :registration_unresolved} = Task.await(contender.task, 10_000)

      # Application reconstruction and a new request reuse PostgreSQL truth;
      # no admission queue, cached response or surviving sender is required.
      restart_capacity_governor()
      assert {:ok, %{state: :empty}} = FleetGeneration.preflight_current_fleet()

      assert %{status: :unresolved, attempt_id: ^attempt_id, symbol: "ORBITALIST"} =
               FleetGeneration.registration_recovery(scope)

      assert %{status: :unresolved, attempt_id: ^attempt_id} =
               SpaceTraders.MissionControl.overview(scope).registration_recovery

      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.import_agent(scope, "OTHER_SECRET", true) end)

      refute_received {:game_request, _, _, _}
      assert agents(scope) == []
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

      assert %{status: :awaiting_adoption, symbol: "ORBITALIST"} =
               SpaceTraders.MissionControl.overview(scope).registration_recovery

      assert agents(scope) == []
      assert {:ok, %{state: :empty}} = FleetGeneration.current_fleet(scope)
      assert_credential_secret(scope, "FIRST_SECRET")

      # Restarted setup resumes adoption instead of registering PARALLAX.
      assert {:ok, %{agent: recovered}} =
               in_session(fn -> FleetGeneration.mint(scope, mint("PARALLAX")) end)

      refute_received {:game_request, _, _, _}
      assert recovered.symbol == "ORBITALIST"
      assert [%{symbol: "ORBITALIST", agent_token: "FIRST_SECRET"}] = agents(scope)
      assert ["ORBITALIST-1"] = ship_symbols(recovered)
      assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
      assert recovery_credentials(scope) == []
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

  describe "Server Reset replacement" do
    setup %{scope: scope} do
      game(fn conn -> Req.Test.json(conn, registration("RESETME", "FIRST_SECRET")) end)

      {:ok, %{agent: minted}} =
        in_session(fn -> FleetGeneration.mint(scope, mint("RESETME")) end)

      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      parent = self()

      # Reads prove the reset; each registration is held until released.
      game(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            reset_mismatch(conn)

          {"POST", "/v2/register"} ->
            send(parent, {:registering, self()})

            receive do
              :respond -> Req.Test.json(conn, registration("RESETME", "SECOND_SECRET"))
            after
              5000 -> flunk("held registration was not released")
            end
        end
      end)

      %{predecessor: Repo.get!(Agent.Agent, minted.id)}
    end

    test "a competing Operator retry waits in PostgreSQL and never dispatches a second registration",
         %{scope: scope, predecessor: predecessor} do
      detecting = contender(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:registering, request}, 2000

      retry = contender(fn -> FleetGeneration.replace_after_reset(scope) end)
      await_blocked_by(retry.backend, detecting.backend)
      restart = contender(fn -> FleetGeneration.resume_reset_replacement() end)
      await_queued_behind(restart.backend, detecting.backend)

      send(request, :respond)
      assert {:error, :stale_agent} = Task.await(detecting.task, 10_000)
      assert {:error, :current_fleet_exists} = Task.await(retry.task, 10_000)
      assert {:error, :current_fleet_exists} = Task.await(restart.task, 10_000)

      assert_received {:game_request, "GET", "/v2/my/agent", nil}
      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert_sole_successor(scope, predecessor)
    end

    test "a late predecessor balance retains its original Evidence and cannot update the same-name successor",
         %{scope: scope, predecessor: predecessor} do
      {:ok, draft} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
      {:ok, _} = SpaceTraders.FleetStrategy.activate(scope, draft.draft_version)
      parent = self()

      game(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            send(parent, {:balance_read, self()})
            assert_receive :respond, 5000
            Req.Test.json(conn, put_in(my_agent("RESETME"), ["data", "credits"], 999_999))

          {"GET", "/v2/my/ships"} ->
            reset_mismatch(conn)

          {"POST", "/v2/register"} ->
            Req.Test.json(conn, registration("RESETME", "SECOND_SECRET"))
        end
      end)

      late = contender(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:balance_read, read}, 2000

      assert {:error, :stale_agent} =
               in_session(fn -> SpaceTraders.Fleet.list_ships(predecessor) end)

      assert_sole_successor(scope, predecessor)
      send(read, :respond)
      assert {:ok, %{credits: 999_999}} = Task.await(late.task, 10_000)

      [successor, retired] = FleetGeneration.list_generations(scope)
      assert successor.starting_credits == 175_000
      assert successor.last_observed_credits == nil
      assert successor.last_observed_evidence_id == nil
      observation = SpaceTraders.Evidence.latest_observation(predecessor, "agent:RESETME")
      assert observation.agent_id == predecessor.id
      assert observation.fleet_generation_id == retired.id
      assert get_in(observation.facts, ["response", "credits"]) == 999_999
    end

    test "capacity admission lost after reset evidence suppresses replacement until an explicit retry",
         %{scope: scope, predecessor: predecessor} do
      parent = self()

      game(fn conn ->
        send(parent, {:reset_read, self()})
        assert conn.method == "GET"
        assert_receive :respond, 5000
        reset_mismatch(conn)
      end)

      detecting = contender(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:reset_read, read}, 2000
      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      try do
        send(read, :respond)
        assert {:error, :stale_agent} = Task.await(detecting.task, 10_000)
        assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)
        assert_received {:game_request, "GET", "/v2/my/agent", nil}
        refute_received {:game_request, _, _, _}
        assert FleetGeneration.registration_recovery(scope).status == :clear
        assert {:error, :stale_agent} = FleetGeneration.gameplay_authority(predecessor.id)
      after
        {:ok, _} =
          Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
      end

      game(fn conn -> Req.Test.json(conn, registration("RESETME", "SECOND_SECRET")) end)
      assert {:ok, _} = in_session(fn -> FleetGeneration.replace_after_reset(scope) end)
      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert_sole_successor(scope, predecessor)
    end

    test "runtime authority lost after reset evidence suppresses replacement and survives reconstruction",
         %{scope: scope, predecessor: predecessor} do
      parent = self()

      game(fn conn ->
        send(parent, {:reset_read, self()})
        assert conn.method == "GET"
        assert_receive :respond, 5000
        reset_mismatch(conn)
      end)

      detecting = contender(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:reset_read, read}, 2000
      previous = Application.get_env(:spacetraders, SpaceTraders.RuntimeAuthority)
      Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, enabled: true)

      try do
        send(read, :respond)
        assert {:error, :stale_agent} = Task.await(detecting.task, 10_000)
        assert {:ok, %{state: :transition}} = FleetGeneration.preflight_current_fleet()

        assert {:error, :runtime_authority_unavailable} =
                 in_session(fn -> FleetGeneration.resume_reset_replacement() end)

        assert_received {:game_request, "GET", "/v2/my/agent", nil}
        refute_received {:game_request, _, _, _}
      after
        if previous,
          do: Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, previous),
          else: Application.delete_env(:spacetraders, SpaceTraders.RuntimeAuthority)
      end

      game(fn conn -> Req.Test.json(conn, registration("RESETME", "SECOND_SECRET")) end)
      assert {:ok, _} = in_session(fn -> FleetGeneration.resume_reset_replacement() end)
      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert_sole_successor(scope, predecessor)
    end

    test "death before dispatch leaves the predecessor fenced; restart replaces it exactly once",
         %{scope: scope, predecessor: predecessor} do
      dependency =
        SpaceTraders.SafetyFence.DependencyKey.agent_symbol(scope.operator.id, "RESETME")

      holder =
        hold(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dependency])
        end)

      detecting = killable(fn -> FleetGeneration.agent_overview(predecessor) end)
      await_blocked_by(detecting.backend, holder.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(detecting.pid, detecting.backend)
      release(holder)

      # The committed fence survives: no gameplay authority, no current Fleet.
      restart_capacity_governor()
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)

      assert {:error, :stale_agent} =
               FleetGeneration.gameplay_authority(predecessor.id)

      assert_received {:game_request, "GET", "/v2/my/agent", nil}
      refute_received {:game_request, _, _, _}

      resumed = contender(fn -> FleetGeneration.resume_reset_replacement() end)
      assert_receive {:registering, request}, 2000
      send(request, :respond)
      assert {:ok, %{agent: %{symbol: "RESETME"}}} = Task.await(resumed.task, 10_000)

      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert_sole_successor(scope, predecessor)
    end

    test "death after dispatch preserves replacement uncertainty for a queued restart",
         %{scope: scope, predecessor: predecessor} do
      detecting = killable(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:registering, _request}, 2000

      assert %{status: :unresolved, attempt_id: attempt_id, symbol: "RESETME"} =
               FleetGeneration.registration_recovery(scope)

      restart = contender(fn -> FleetGeneration.resume_reset_replacement() end)
      await_blocked_by(restart.backend, detecting.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(detecting.pid, detecting.backend)
      assert {:error, :registration_unresolved} = Task.await(restart.task, 10_000)

      restart_capacity_governor()
      assert {:ok, %{state: :transition}} = FleetGeneration.preflight_current_fleet()

      assert %{status: :unresolved, attempt_id: ^attempt_id} =
               FleetGeneration.registration_recovery(scope)

      assert {:error, :registration_unresolved} =
               in_session(fn -> FleetGeneration.resume_reset_replacement() end)

      assert_received {:game_request, "GET", "/v2/my/agent", nil}
      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert [%{id: id, agent_token: "FIRST_SECRET"}] = agents(scope)
      assert id == predecessor.id
      assert {:error, :stale_agent} = FleetGeneration.gameplay_authority(id)
    end

    test "a proven success interrupted before adoption is adopted on restart without mint authority",
         %{scope: scope, operator: operator, predecessor: predecessor} do
      detecting = killable(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:registering, request}, 2000

      holder = hold_operator_row(operator)
      send(request, :respond)
      await_blocked_by(detecting.backend, holder.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(detecting.pid, detecting.backend)
      release(holder)

      assert %{status: :awaiting_adoption, symbol: "RESETME"} =
               FleetGeneration.registration_recovery(scope)

      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)
      restart_capacity_governor()

      # Registration already succeeded. Its encrypted AgentToken, not renewed
      # AccountToken mint authority, is enough to finish local adoption.
      operator |> Ecto.Changeset.change(account_token: nil) |> Repo.update!()

      assert {:ok, %{agent: %{symbol: "RESETME"}}} =
               in_session(fn -> FleetGeneration.resume_reset_replacement() end)

      assert_received {:game_request, "GET", "/v2/my/agent", nil}
      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
      assert_sole_successor(scope, predecessor)
    end

    test "interrupted replacement bootstrap rolls back retirement and recovers the same successful identity",
         %{scope: scope, predecessor: predecessor} do
      parent = self()

      game(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            reset_mismatch(conn)

          {"POST", "/v2/register"} ->
            send(parent, {:registering, self()})
            assert_receive :respond, 5000
            body = registration("RESETME", "SECOND_SECRET")

            Req.Test.json(
              conn,
              put_in(body, ["data", "ships"], [ship("RESETME-1"), ship("RESETME-2")])
            )
        end
      end)

      detecting = killable(fn -> FleetGeneration.agent_overview(predecessor) end)
      assert_receive {:registering, request}, 2000
      holder = hold_ship_symbol("RESETME-2")
      send(request, :respond)
      await_blocked_by(detecting.backend, holder.backend)
      assert {:disconnected, _log} = RuntimeDeath.kill(detecting.pid, detecting.backend)
      release(holder)

      assert {:ok, %{state: :transition, agent: %{id: id}}} = FleetGeneration.current_fleet(scope)
      assert id == predecessor.id
      assert ship_symbols(predecessor) == ["RESETME-1"]

      assert %{status: :awaiting_adoption, symbol: "RESETME"} =
               FleetGeneration.registration_recovery(scope)

      assert_credential_secret(scope, "SECOND_SECRET")

      restart_capacity_governor()
      assert {:ok, :adopted} = in_session(fn -> FleetGeneration.reconcile_registration(scope) end)
      assert_received {:game_request, "GET", "/v2/my/agent", nil}
      assert_received {:game_request, "POST", "/v2/register", "RESETME"}
      refute_received {:game_request, _, _, _}
      assert_sole_successor(scope, predecessor, ["RESETME-1", "RESETME-2"])
      assert FleetGeneration.registration_recovery(scope).status == :clear
    end
  end

  # One commanded Agent: the successor is current with its own credential; the
  # predecessor is retained, stale, and its Generation retired.
  defp assert_sole_successor(scope, predecessor, expected_ships \\ ["RESETME-1"]) do
    assert {:ok, %{state: :current, agent: successor, generation: generation}} =
             FleetGeneration.current_fleet(scope)

    assert successor.symbol == "RESETME"
    assert successor.id != predecessor.id
    assert generation.number == 2
    assert Repo.get!(Agent.Agent, successor.id).agent_token == "SECOND_SECRET"
    assert ship_symbols(successor) == expected_ships

    assert [%{id: predecessor_id, agent_token: "FIRST_SECRET", stale_at: %DateTime{}}, _] =
             agents(scope)

    assert predecessor_id == predecessor.id
    assert {:error, :stale_agent} = FleetGeneration.gameplay_authority(predecessor.id)

    assert [_current, %{retired_at: %DateTime{}, agent_id: ^predecessor_id}] =
             FleetGeneration.list_generations(scope)
  end

  defp reset_mismatch(conn) do
    conn
    |> Plug.Conn.put_status(401)
    |> Req.Test.json(%{
      "error" => %{
        "code" => 4113,
        "message" =>
          "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
      }
    })
  end

  defp mint(symbol), do: %{symbol: symbol, faction: "COSMIC"}

  defp agents(_scope), do: Repo.all(from a in SpaceTraders.Agent.Agent, order_by: a.id)

  defp ship_symbols(agent) do
    Repo.all(
      from(s in SpaceTraders.Fleet.Ship,
        where: s.agent_id == ^agent.id,
        order_by: s.symbol,
        select: s.symbol
      )
    )
  end

  defp recovery_credentials(scope) do
    Repo.all(
      from(a in "mutation_attempts",
        where:
          a.operator_id == ^scope.operator.id and not is_nil(a.recovery_credential_ciphertext),
        select: a.recovery_credential_ciphertext
      )
    )
  end

  # The pending AgentToken is durable, encrypted at rest and absent from evidence.
  defp assert_credential_secret(scope, token) do
    assert [ciphertext] = recovery_credentials(scope)
    refute ciphertext =~ token

    evidence =
      Repo.all(
        from(o in Outcome,
          join: a in Attempt,
          on: a.id == o.mutation_attempt_id,
          where: a.operator_id == ^scope.operator.id,
          select: o.evidence
        )
      ) ++
        Repo.all(
          from(a in Attempt,
            where: a.operator_id == ^scope.operator.id,
            select: a.prepared_evidence
          )
        )

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
    assert_receive {:backend, ^ref, backend}, 2000

    on_exit(fn ->
      if Process.alive?(pid), do: RuntimeDeath.kill(pid, backend)
    end)

    %{pid: pid, backend: backend}
  end

  defp contender(fun) do
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
          fun.()
        end)
      end)

    Req.Test.allow(SpaceTraders.API, self(), task.pid)
    send(task.pid, :go)
    assert_receive {:backend, ^ref, backend}, 2000
    %{task: task, backend: backend}
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

  # A later waiter is blocked by the holder and every waiter queued ahead of it.
  defp await_queued_behind(backend, holder, remaining \\ 500)
  defp await_queued_behind(_backend, _holder, 0), do: flunk("contender did not queue on holder")

  defp await_queued_behind(backend, holder, remaining) do
    [[blockers]] = Repo.query!("SELECT pg_blocking_pids($1)", [backend]).rows

    if holder in blockers do
      :ok
    else
      Process.sleep(10)
      await_queued_behind(backend, holder, remaining - 1)
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
