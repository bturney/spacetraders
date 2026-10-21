defmodule SpaceTraders.CurrentGenerationAuthorityTest do
  # Adoption takes deployment-wide table locks and admission caches are shared.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.{Agent, Evidence, Fleet, FleetGeneration, Repo}
  alias SpaceTraders.FleetGeneration.Generation

  # A predecessor whose Generation is history keeps its Agent row and a
  # syntactically usable AgentToken; only the published Generation is current.
  defp retained_predecessor_and_current_fleet do
    operator = operator_fixture()
    scope = operator_scope_fixture(operator)

    predecessor =
      agent_fixture(operator, %{symbol: "PARALLAX", agent_token: "PREDECESSOR_SECRET"})

    retired =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
        operator_id: operator.id,
        agent_id: predecessor.id,
        number: 1,
        symbol: "PARALLAX",
        faction: "COSMIC",
        fenced_at: DateTime.add(DateTime.utc_now(), -7200),
        retired_at: DateTime.add(DateTime.utc_now(), -3600)
      })

    current = agent_fixture(operator, %{symbol: "ORBITALIST", agent_token: "CURRENT_SECRET"})

    {:ok, %{state: :current, generation: generation}} = FleetGeneration.preflight_current_fleet()
    true = generation.agent_id == current.id

    %{
      scope: scope,
      operator: operator,
      predecessor: predecessor,
      retired: retired,
      current: current,
      generation: generation
    }
  end

  # The governor is application-wide and nothing else resets it: a 429, 5xx or
  # leaked admission from an earlier case would make the capacity fill below
  # wait unbounded (#819). Each case starts and leaves a fresh governor.
  setup do
    restart_capacity_governor()
    on_exit(&restart_capacity_governor/0)
  end

  # Safe only because this module is `async: false`: ExUnit runs every async
  # module first, then sync modules one at a time, so no other test can hold an
  # admission or call the governor while it restarts. Restarting instead of
  # capturing and restoring its state also drops earlier cases' 429/5xx
  # pressure and leaked admissions, which restoring would put back. Keep any
  # other test that uses the app-wide governor `async: false` too.
  defp restart_capacity_governor do
    governor = SpaceTraders.API.CapacityGovernor
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, governor)
    {:ok, _pid} = Supervisor.restart_child(SpaceTraders.Supervisor, governor)
    :ok
  end

  # Fills every admitted slot. Only a governor with nothing in flight admits
  # without waiting, so a polluted one fails here instead of timing out.
  defp fill_admitted_capacity(governor, operation) do
    diagnostics = governor.diagnostics()

    assert %{in_flight: 0, deferred: deferred, retry_after_until: nil, outage: nil} = diagnostics
    assert deferred == %{}

    for _ <- 1..diagnostics.admitted_capacity do
      {:ok, admission} = governor.admit(operation)
      admission
    end
  end

  defp observe_game_requests do
    test = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(
        test,
        {:game_request, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      Req.Test.json(conn, %{"data" => ship_body(List.last(String.split(conn.request_path, "/")))})
    end)
  end

  describe "new observations and gameplay dispatch" do
    test "an unpublished Agent cannot bootstrap its own gameplay authority through a read" do
      operator = operator_fixture()
      raw = agent_fixture(operator, %{publish: false, agent_token: "UNPUBLISHED_SECRET"})
      observe_game_requests()

      assert {:error, :generation_not_current} = Evidence.get_ships(AgentTokenReference.new(raw))

      assert {:error, %{reason: :ambiguous_current_fleet, summary: summary}} =
               FleetGeneration.current_fleet()

      assert summary =~ "provenance"
      assert Repo.get_by(Generation, agent_id: raw.id) == nil
      assert Repo.get!(SpaceTraders.Agent.Agent, raw.id).agent_token == "UNPUBLISHED_SECRET"
      refute_received {:game_request, _, _, _}
    end

    test "Strategy review captures only the published Fleet, retaining predecessor evidence as history" do
      %{scope: scope, current: current, predecessor: predecessor} =
        retained_predecessor_and_current_fleet()

      capture = SpaceTraders.MissionControl.capture_market_decision(scope)
      assert [%{agent: %{id: id, agent_token: nil}}] = capture.agents
      assert id == current.id
      refute Enum.any?(capture.agents, &(&1.agent.id == predecessor.id))

      assert Repo.get!(SpaceTraders.Agent.Agent, predecessor.id).agent_token ==
               "PREDECESSOR_SECRET"
    end

    test "an observation queued for API capacity rechecks current Generation authority before transport" do
      %{current: current, generation: generation} = retained_predecessor_and_current_fleet()
      observe_game_requests()
      governor = SpaceTraders.API.CapacityGovernor
      operation = SpaceTraders.API.OperationInventory.fetch!("get-my-ship")

      held =
        fill_admitted_capacity(governor, operation)

      on_exit(fn -> Enum.each(held, &governor.complete(&1, :not_dispatched)) end)
      observer = Task.async(fn -> Evidence.get_ship(current, "ORBITALIST-1") end)
      Req.Test.allow(SpaceTraders.API, self(), observer.pid)
      await_queued_read(governor)

      generation |> Ecto.Changeset.change(fenced_at: DateTime.utc_now()) |> Repo.update!()
      Enum.each(held, &governor.complete(&1, :not_dispatched))

      assert {:error, :generation_not_current} = Task.await(observer)
      refute_received {:game_request, _, _, _}
    end

    test "a gameplay mutation queued for capacity is durably not sent after its Generation is fenced" do
      %{current: current, generation: generation} = retained_predecessor_and_current_fleet()
      observe_game_requests()
      governor = SpaceTraders.API.CapacityGovernor
      operation = SpaceTraders.API.OperationInventory.fetch!("accept-contract")

      held =
        fill_admitted_capacity(governor, operation)

      on_exit(fn -> Enum.each(held, &governor.complete(&1, :not_dispatched)) end)

      sender =
        Task.async(fn ->
          SpaceTraders.API.accept_contract(AgentTokenReference.new(current), "CONTRACT-1")
        end)

      Req.Test.allow(SpaceTraders.API, self(), sender.pid)
      await_queued_read(governor)
      generation |> Ecto.Changeset.change(fenced_at: DateTime.utc_now()) |> Repo.update!()
      Enum.each(held, &governor.complete(&1, :not_dispatched))

      assert {:error, :generation_not_current} = Task.await(sender)
      refute_received {:game_request, _, _, _}

      assert [%{state: "not_sent", sent_or_unknown_at: nil} = attempt] =
               SpaceTraders.MutationAttempts.list_for_agent(current)

      assert attempt.fleet_generation_id == generation.id
      refute attempt.retry_authorized
    end

    test "use only the current Generation's credential; a cached predecessor reference gains no authority" do
      %{predecessor: predecessor, current: current} = retained_predecessor_and_current_fleet()
      observe_game_requests()

      cached = AgentTokenReference.new(predecessor)

      assert {:error, :generation_not_current} = Evidence.get_ship(cached, "PARALLAX-1")
      assert {:error, :generation_not_current} = Evidence.get_ship(predecessor, "PARALLAX-1")

      assert {:error, :generation_not_current} =
               SpaceTraders.API.accept_contract(cached, "CONTRACT-1")

      refute_received {:game_request, _, _, _}

      assert {:ok, _ship} = Evidence.get_ship(current, "ORBITALIST-1")

      assert_received {:game_request, "GET", "/v2/my/ships/ORBITALIST-1",
                       ["Bearer CURRENT_SECRET"]}

      assert Repo.get!(SpaceTraders.Agent.Agent, predecessor.id).agent_token ==
               "PREDECESSOR_SECRET"
    end

    test "Ship lookup and execution grant a retained predecessor no new authority" do
      %{predecessor: predecessor, current: current} = retained_predecessor_and_current_fleet()
      {:ok, _} = Fleet.record_ship(predecessor, "PARALLAX-1", "SHIP_COMMAND_FRIGATE")
      observe_game_requests()

      # Ship lookup still finds the historical owner; that confers nothing.
      assert {:ok, %{id: predecessor_id}} = Fleet.ship_agent("PARALLAX-1")
      assert predecessor_id == predecessor.id
      assert {:error, :generation_not_current} = Agent.execution_allowed?(predecessor)
      assert {:error, :generation_not_current} = Fleet.list_ships(predecessor)
      refute_received {:game_request, _, _, _}

      assert :ok = Agent.execution_allowed?(current)
    end

    test "a fenced transition dispatches nothing for the fenced Generation" do
      %{current: current, scope: scope} = retained_predecessor_and_current_fleet()

      reset = %SpaceTraders.API.GameplayError{
        code: 4113,
        type: :other,
        message:
          "Failed to parse token. Token reset_date does not match the server. Server resets happen weekly. After a reset, you should re-register your agent. Expected: 2026-10-11, Actual: 2026-10-01"
      }

      assert {:error, :stale_agent} = FleetGeneration.handle_game_result(current, {:error, reset})
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)
      observe_game_requests()

      assert {:error, :stale_agent} = Evidence.get_agent(current)
      assert {:error, :stale_agent} = Evidence.get_ship(current, "ORBITALIST-1")
      refute_received {:game_request, _, _, _}
    end
  end

  describe "capacity isolation" do
    test "each case starts with a governor free of earlier cases' pressure" do
      governor = SpaceTraders.API.CapacityGovernor
      operation = SpaceTraders.API.OperationInventory.fetch!("get-my-ship")

      # What an earlier case's 429 leaves behind, then the per-case reset.
      governor.protocol_rejected(30)
      assert %{retry_after_until: %DateTime{}} = governor.diagnostics()
      restart_capacity_governor()

      held = fill_admitted_capacity(governor, operation)
      assert length(held) == governor.diagnostics().admitted_capacity
      Enum.each(held, &governor.complete(&1, :not_dispatched))
    end
  end

  describe "late results" do
    test "a predecessor's late observation keeps its Generation and cannot update replacement credits" do
      %{predecessor: predecessor, retired: retired, current: current, generation: generation} =
        retained_predecessor_and_current_fleet()

      scope = operator_scope_fixture(Agent.get_operator!(current.operator_id))
      {:ok, draft} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
      {:ok, revision} = SpaceTraders.FleetStrategy.activate(scope, draft.draft_version)

      generation =
        generation
        |> Ecto.Changeset.change(
          starting_credits: 175_000,
          fleet_strategy_revision_id: revision.id
        )
        |> Repo.update!()

      late = credits_observation(999_999)

      assert {:ok, %{observation: late_evidence}} =
               Evidence.fulfil_demands(predecessor, "agent:PARALLAX", late)

      assert late_evidence.agent_id == predecessor.id
      assert late_evidence.fleet_generation_id == retired.id
      assert Repo.reload!(generation).last_observed_credits == nil
      assert Evidence.latest_observation(current, "agent:PARALLAX") == nil

      assert {:ok, %{observation: current_evidence}} =
               Evidence.fulfil_demands(current, "agent:ORBITALIST", credits_observation(180_000))

      assert current_evidence.fleet_generation_id == generation.id
      assert Repo.reload!(generation).last_observed_credits == 180_000
    end
  end

  defp credits_observation(credits) do
    Evidence.authoritative_observation(
      "get-my-agent",
      ["agent:PARALLAX", "agent:ORBITALIST"],
      %{response: %{"credits" => credits}},
      DateTime.utc_now()
    )
  end

  defp await_queued_read(governor, tries \\ 1000)
  defp await_queued_read(_governor, 0), do: flunk("observation never queued for capacity")

  defp await_queued_read(governor, tries) do
    if Enum.any?(governor.diagnostics().deferred, fn {_lane, queued} -> queued.count > 0 end) do
      :ok
    else
      receive do
      after
        1 -> await_queued_read(governor, tries - 1)
      end
    end
  end
end
