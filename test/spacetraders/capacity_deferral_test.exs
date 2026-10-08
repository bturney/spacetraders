defmodule SpaceTraders.CapacityDeferralTest do
  # Root Intent recovery under API Capacity Deferral (#586). Seams: root
  # Intents progression (advance/reconcile/boot rearm), the durable Timeline
  # wakeup, the MutationAttempts ledger, and Req.Test at the game boundary.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.{Evidence, Fleet, FleetAllocation, MutationAttempts, Timeline}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Intents}
  alias SpaceTraders.API.CapacityGovernor
  alias SpaceTraders.Fleet.Intents.{CapacityDeferral, RecordedAction}
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  test "a 429 on the acting Ship's recovery read defers durably and keeps the unresolved attempt" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_throttled_reads()

    _ = Intents.advance(agent, selected, nil)

    assert_capacity_deferred(selected, attempt)
  end

  test "boot recovery meeting a 429 defers instead of spending recovery retries" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_throttled_reads()

    _ = Intents.reconcile(agent.id, "PRODUCER", nil, :boot, nil)

    current = assert_capacity_deferred(selected, attempt)
    assert current.recovery_attempts == 0
  end

  test "a wakeup with capacity resumes MutationAttempts recovery of the same attempt" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_throttled_reads()
    _ = Intents.advance(agent, selected, nil)
    event = wakeup_event()

    # The lost transfer did land: both Ships' Cargo now proves it.
    {:ok, sends} = Elixir.Agent.start_link(fn -> 1 end)
    stub_transfer(sends)
    :ok = Timeline.fire_event(event)
    _ = Intents.reconcile(agent.id, "PRODUCER", nil, :intent_retry, selected.id)

    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert Elixir.Agent.get(sends, & &1) == 1
    refute Repo.get!(Intent, selected.id).blocker
  end

  test "a stale wakeup for superseded work makes no request" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_throttled_reads()
    _ = Intents.advance(agent, selected, nil)
    event = wakeup_event()

    Repo.get!(Intent, selected.id)
    |> Ecto.Changeset.change(status: "superseded")
    |> Repo.update!()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk("stale wakeup made a request: #{conn.method} #{conn.request_path}")
    end)

    :ok = Timeline.fire_event(event)
    assert :ok = Intents.reconcile(agent.id, "PRODUCER", nil, :intent_retry, selected.id)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
  end

  describe "mutation-response Evidence reuse" do
    test "a response's Agent facts satisfy the credit recovery need and open Demand without a read" do
      %{agent: agent, intent: intent} = transfer_fixture()
      {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, prepared_action(agent))
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      {:ok, attempt} = MutationAttempts.record_outcome(attempt, :succeeded, %{status: 200})
      demand = open_demand(agent, "agent:#{agent.symbol}")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        flunk("reused Evidence made a read: #{conn.method} #{conn.request_path}")
      end)

      assert {:ok, %{retained: [subject], gaps: ["ship:PRODUCER"]}} =
               Evidence.retain_mutation_response(agent, attempt, sell_response(agent, 870))

      assert subject == "agent:#{agent.symbol}"
      assert {:ok, binding} = Evidence.recovery_agent_binding(agent, attempt)
      assert binding.value.credits == 870

      assert binding.observation.facts["mutation_response"] == %{
               "mutation_attempt_id" => attempt.id,
               "operation_id" => attempt.operation_id
             }

      assert Repo.reload!(demand).fulfilled_observation_id == binding.observation.id
      # Usable proof source, yet the Ships the response did not wholly prove stay missing.
      assert {:incomplete, %{usable: [^binding], unusable: [], missing: missing}} =
               Evidence.recovery_proof(attempt, :accepted, "credits", [binding])

      assert Enum.sort(missing) == ["ship:#{agent.id}:HAULER", "ship:#{agent.id}:PRODUCER"]
    end

    test "a partial response proves only its facts and leaves the Ship an explicit gap" do
      %{agent: agent, intent: intent} = transfer_fixture()
      {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, prepared_action(agent))
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      {:ok, attempt} = MutationAttempts.record_outcome(attempt, :succeeded, %{status: 200})

      assert {:ok, %{retained: [], gaps: ["ship:PRODUCER"]}} =
               Evidence.retain_mutation_response(agent, attempt, %{cargo: cargo(8)})

      {:ok, reads} = Elixir.Agent.start_link(fn -> 0 end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {conn.method, conn.request_path} == {"GET", "/v2/my/agent"}
        Elixir.Agent.update(reads, &(&1 + 1))
        Req.Test.json(conn, %{"data" => agent_body(agent, 900)})
      end)

      assert {:ok, binding} = Evidence.recovery_agent_binding(agent, attempt)
      assert binding.value.credits == 900
      assert Elixir.Agent.get(reads, & &1) == 1
    end

    test "facts for another Agent or an unresolved send are not attributable" do
      %{agent: agent, intent: intent} = transfer_fixture()
      {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, prepared_action(agent))
      {:ok, sent} = MutationAttempts.mark_sent_or_unknown(attempt)

      assert {:ok, %{retained: []}} =
               Evidence.retain_mutation_response(agent, sent, sell_response(agent, 870))

      {:ok, succeeded} = MutationAttempts.record_outcome(sent, :succeeded, %{status: 200})
      other = %{sell_response(agent, 870) | agent: %{agent_model(agent, 870) | symbol: "OTHER"}}

      assert {:ok, %{retained: []}} = Evidence.retain_mutation_response(agent, succeeded, other)
      assert is_nil(Evidence.latest_observation(agent, "agent:#{agent.symbol}"))
    end
  end

  defp open_demand(agent, subject) do
    revision = Repo.one!(from(r in Revision, order_by: [desc: r.id], limit: 1))

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: subject,
        required_facts: ["response"],
        freshness_seconds: 30,
        due_at: DateTime.utc_now(),
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second),
        owner: "capacity_deferral_test"
      })

    demand
  end

  defp sell_response(agent, credits) do
    %{agent: agent_model(agent, credits), cargo: cargo(8)}
  end

  defp agent_model(agent, credits),
    do: SpaceTraders.API.Model.Agent.from_json(agent_body(agent, credits))

  defp agent_body(agent, credits) do
    %{
      "accountId" => "account-1",
      "symbol" => agent.symbol,
      "headquarters" => "X1-UX81-A1",
      "credits" => credits,
      "startingFaction" => "COSMIC",
      "shipCount" => 2
    }
  end

  describe "governor-guided wakeup" do
    setup do
      governor = :"capacity_deferral_governor_#{System.unique_integer([:positive])}"
      start_supervised!({CapacityGovernor, name: governor})
      previous = Application.fetch_env(:spacetraders, SpaceTraders.FleetCapacity)
      Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, governor: governor)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, value)
          :error -> Application.delete_env(:spacetraders, SpaceTraders.FleetCapacity)
        end
      end)

      %{governor: governor}
    end

    test "ordinary work resumes when the governor's Retry-After guidance allows", %{
      governor: governor
    } do
      %{agent: agent, intent: intent} = transfer_fixture()

      # Prepared but never sent: resuming means dispatching ordinary work.
      {:ok, %{intent: selected, attempt: attempt}} =
        RecordedAction.prepare(agent, intent, prepared_action(agent))

      CapacityGovernor.protocol_rejected(30, governor)
      stub_throttled_reads()
      before = DateTime.utc_now()

      _ = Intents.advance(agent, selected, nil)
      deferred = DateTime.utc_now()

      current = Repo.get!(Intent, selected.id)
      assert current.status == "waiting"
      assert current.blocker.reason == "api_capacity_deferred"
      assert MutationAttempts.get!(attempt.id).state == "prepared"
      assert_in_delay(wakeup_event().due_at, before, deferred, 30)
    end

    test "unresolved mutation recovery waits out the account-wide Retry-After too", %{
      governor: governor
    } do
      %{agent: agent, intent: intent} = transfer_fixture()

      {:ok, %{intent: selected, attempt: attempt}} =
        RecordedAction.prepare(agent, intent, prepared_action(agent))

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
      CapacityGovernor.protocol_rejected(30, governor)
      stub_throttled_reads()
      before = DateTime.utc_now()

      _ = Intents.advance(agent, selected, nil)
      deferred = DateTime.utc_now()

      assert_capacity_deferred(selected, attempt)
      assert_in_delay(wakeup_event().due_at, before, deferred, 30)
    end

    test "deferred work survives runtime and governor restart on its durable wakeup", %{
      governor: governor
    } do
      %{agent: agent, intent: intent} = transfer_fixture()

      {:ok, %{intent: selected, attempt: attempt}} =
        RecordedAction.prepare(agent, intent, prepared_action(agent))

      CapacityGovernor.protocol_rejected(30, governor)
      stub_throttled_reads()
      _ = Intents.advance(agent, selected, nil)
      event = wakeup_event()

      # Restart: Ship runtime and the governor's process-local Retry-After are gone.
      SpaceTraders.Quiesced.stop_ship("PRODUCER")
      stop_supervised!(CapacityGovernor)
      start_supervised!({CapacityGovernor, name: governor})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        flunk("boot re-armed deferred work with a request: #{conn.method} #{conn.request_path}")
      end)

      Intents.rearm_on_boot()

      assert wakeup_event().id == event.id
      assert Repo.get!(Intent, selected.id).blocker.reason == "api_capacity_deferred"
      assert MutationAttempts.get!(attempt.id).state == "prepared"
      SpaceTraders.Quiesced.stop_ship("PRODUCER")

      # The durable wakeup, not a governor notification, resumes the work.
      {:ok, sends} = Elixir.Agent.start_link(fn -> 0 end)
      stub_transfer(sends)
      :ok = Timeline.fire_event(event)
      _ = Intents.reconcile(agent.id, "PRODUCER", nil, :intent_retry, selected.id)

      refute MutationAttempts.get!(attempt.id).state == "prepared"
      refute Repo.get!(Intent, selected.id).blocker
    end

    test "a wakeup still under Retry-After re-defers without reading or sending", %{
      governor: governor
    } do
      %{agent: agent, intent: intent} = transfer_fixture()

      {:ok, %{intent: selected, attempt: attempt}} =
        RecordedAction.prepare(agent, intent, prepared_action(agent))

      CapacityGovernor.protocol_rejected(30, governor)
      stub_throttled_reads()
      _ = Intents.advance(agent, selected, nil)
      first = wakeup_event()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        flunk("capacity-deferred wakeup made a request: #{conn.method} #{conn.request_path}")
      end)

      :ok = Timeline.fire_event(first)
      _ = Intents.reconcile(agent.id, "PRODUCER", nil, :intent_retry, selected.id)

      current = Repo.get!(Intent, selected.id)
      assert current.status == "waiting"
      assert current.blocker.reason == "api_capacity_deferred"
      assert MutationAttempts.get!(attempt.id).state == "prepared"
      second = wakeup_event()
      refute second.id == first.id
      # Same Retry-After window: the governor's guidance, not a fresh 30 seconds.
      assert abs(DateTime.diff(second.due_at, first.due_at, :millisecond)) <= 1000
    end
  end

  describe "prolonged deferral observability" do
    setup do
      governor = :"capacity_deferral_observed_#{System.unique_integer([:positive])}"
      start_supervised!({CapacityGovernor, name: governor})
      previous = Application.fetch_env(:spacetraders, SpaceTraders.FleetCapacity)
      Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, governor: governor)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, value)
          :error -> Application.delete_env(:spacetraders, SpaceTraders.FleetCapacity)
        end
      end)

      handler = "capacity-deferral-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler,
          [:spacetraders, :intent, :capacity_deferral],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:capacity_deferral, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      %{governor: governor}
    end

    test "each re-deferral reports how long the work has waited, with bounded labels only", %{
      governor: governor
    } do
      %{agent: agent, intent: intent} = transfer_fixture()

      {:ok, %{intent: selected}} = RecordedAction.prepare(agent, intent, prepared_action(agent))

      CapacityGovernor.protocol_rejected(30, governor)
      stub_throttled_reads()
      _ = Intents.advance(agent, selected, nil)

      assert_receive {:capacity_deferral, %{count: 1, deferred_seconds: first}, metadata}
      assert first < 5
      assert metadata == %{reason: :retry_after, work: :ordinary}

      # The work has already been waiting for two minutes when it is re-deferred.
      current = Repo.get!(Intent, selected.id)
      waited_since = DateTime.add(current.blocker.observed_at, -120, :second)

      current
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_embed(:blocker, %{current.blocker | observed_at: waited_since})
      |> Repo.update!()

      :ok = Timeline.fire_event(wakeup_event())
      _ = Intents.reconcile(agent.id, "PRODUCER", nil, :intent_retry, selected.id)

      assert_receive {:capacity_deferral, %{deferred_seconds: prolonged}, %{work: :ordinary}}
      assert prolonged >= 120
      assert Repo.get!(Intent, selected.id).blocker.observed_at == waited_since
      SpaceTraders.Quiesced.stop_ship("PRODUCER")
    end
  end

  describe "Ship runtime wakeup" do
    setup do
      governor = :"capacity_deferral_runtime_#{System.unique_integer([:positive])}"
      start_supervised!({CapacityGovernor, name: governor})
      previous = Application.fetch_env(:spacetraders, SpaceTraders.FleetCapacity)
      Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, governor: governor)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, value)
          :error -> Application.delete_env(:spacetraders, SpaceTraders.FleetCapacity)
        end
      end)

      %{governor: governor}
    end

    test "a deferred wakeup asks capacity before the Ship runtime spends any read", %{
      governor: governor
    } do
      %{agent: agent, intent: intent} = transfer_fixture()

      {:ok, %{intent: selected, attempt: attempt}} =
        RecordedAction.prepare(agent, intent, prepared_action(agent))

      CapacityGovernor.protocol_rejected(30, governor)
      stub_throttled_reads()
      _ = Intents.advance(agent, selected, nil)
      first = wakeup_event()

      {:ok, requests} = Elixir.Agent.start_link(fn -> [] end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Elixir.Agent.update(requests, &[conn.request_path | &1])
        Req.Test.json(conn, %{"data" => ship_body("PRODUCER")})
      end)

      ship_server =
        GenServer.whereis({:via, Registry, {SpaceTraders.Fleet.ShipRegistry, "PRODUCER"}})

      Req.Test.allow(SpaceTraders.API, self(), ship_server)
      {:ok, due} = Timeline.reschedule_event(first, SpaceTraders.Clock.utc_now())
      :ok = SpaceTraders.Fleet.ShipServer.arm(agent, "PRODUCER", due)

      assert eventually(fn ->
               Elixir.Agent.get(requests, & &1) != [] or
                 Enum.any?(pending_wakeups(), &(&1.id != first.id))
             end)

      assert Elixir.Agent.get(requests, & &1) == []
      assert Repo.get!(Intent, selected.id).blocker.reason == "api_capacity_deferred"
      assert MutationAttempts.get!(attempt.id).state == "prepared"
      SpaceTraders.Quiesced.stop_ship("PRODUCER")
    end
  end

  defp pending_wakeups do
    Timeline.pending_events(:ship, "PRODUCER")
    |> Enum.filter(&(&1.event_type == "intent_retry"))
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(10) && eventually(fun, attempts - 1)
    end
  end

  defp wakeup_event do
    assert [event] =
             Timeline.pending_events(:ship, "PRODUCER")
             |> Enum.filter(&(&1.event_type == "intent_retry"))

    event
  end

  # The wakeup lands `seconds` after the deferral, which happened in [before, deferred].
  defp assert_in_delay(due_at, before, deferred, seconds) do
    earliest = DateTime.add(before, seconds - 1, :second)
    latest = DateTime.add(deferred, seconds + 1, :second)

    assert DateTime.compare(due_at, earliest) != :lt and DateTime.compare(due_at, latest) != :gt,
           "wakeup at #{due_at}, expected #{seconds}s after deferral in #{before}..#{deferred}"
  end

  describe "wakeup guidance" do
    @now ~U[2026-10-07 12:00:00.000000Z]
    # The governor reasons on its own clock; guidance is carried as an offset.
    @governor_now ~U[2026-10-07 09:00:00.000000Z]

    test "follows the governor's reconsideration offset on the runtime clock" do
      disposition = disposition(:defer, :retry_after, DateTime.add(@governor_now, 10, :second))
      assert CapacityDeferral.wake_at(disposition, @now) == DateTime.add(@now, 10, :second)
    end

    test "bounds far guidance so a missed notification cannot strand the work" do
      disposition = disposition(:defer, :retry_after, DateTime.add(@governor_now, 3600, :second))
      assert CapacityDeferral.wake_at(disposition, @now) == DateTime.add(@now, 60, :second)
    end

    test "never wakes sooner than one second, even when capacity is available" do
      assert CapacityDeferral.wake_at(disposition(:proceed, :capacity_available, nil), @now) ==
               DateTime.add(@now, 1, :second)

      unavailable = disposition(:unavailable, :authority_unavailable, @governor_now)
      assert CapacityDeferral.wake_at(unavailable, @now) == DateTime.add(@now, 1, :second)
    end

    defp disposition(status, reason, retry_at) do
      %CapacityGovernor.Disposition{
        status: status,
        reason: reason,
        observed_at: @governor_now,
        retry_at: retry_at
      }
    end
  end

  defp stub_throttled_reads do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      conn
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
    end)
  end

  # Capacity Deferral: durable waiting work, unchanged mutation truth, and one
  # pending wakeup naming the Intent. Never blocked (Attention) or infeasible.
  defp assert_capacity_deferred(selected, attempt) do
    current = Repo.get!(Intent, selected.id)
    assert current.status == "waiting"
    assert current.blocker.reason == "api_capacity_deferred"
    assert current.in_flight_action == selected.in_flight_action
    assert current.mutation_attempt_id == attempt.id
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"

    assert [%{payload: %{"intent_id" => intent_id}}] =
             Timeline.pending_events(:ship, "PRODUCER")
             |> Enum.filter(&(&1.event_type == "intent_retry"))

    assert intent_id == selected.id
    current
  end

  defp prepared_action(agent) do
    {:ok, sends} = Elixir.Agent.start_link(fn -> 0 end)
    stub_transfer(sends)
    {:ok, source} = Evidence.get_ship_binding(agent, "PRODUCER")
    {:ok, target} = Evidence.get_ship_binding(agent, "HAULER")

    action()
    |> Map.put("source_observation_id", source.observation.id)
    |> Map.put("target_observation_id", target.observation.id)
  end

  defp stub_transfer(sends) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      sent? = Elixir.Agent.get(sends, & &1) > 0

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships/PRODUCER"} ->
          Req.Test.json(conn, %{
            "data" => ship_body("PRODUCER", %{"cargo" => cargo(if(sent?, do: 8, else: 12))})
          })

        {"GET", "/v2/my/ships/HAULER"} ->
          Req.Test.json(conn, %{
            "data" => ship_body("HAULER", %{"cargo" => cargo(if(sent?, do: 4, else: 0))})
          })

        {"POST", "/v2/my/ships/PRODUCER/transfer"} ->
          assert Jason.decode!(Jason.encode!(conn.body_params)) == %{
                   "shipSymbol" => "HAULER",
                   "tradeSymbol" => "IRON_ORE",
                   "units" => 4
                 }

          Elixir.Agent.update(sends, &(&1 + 1))
          Req.Test.json(conn, %{"data" => %{"cargo" => cargo(8)}})

        other ->
          flunk("unexpected transfer request: #{inspect(other)}")
      end
    end)
  end

  defp cargo(units) do
    %{
      "capacity" => 40,
      "units" => units,
      "inventory" => if(units > 0, do: [%{"symbol" => "IRON_ORE", "units" => units}], else: [])
    }
  end

  defp transfer_fixture do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, source_ship} = Fleet.record_ship(agent, "PRODUCER", "SHIP_COMMAND_FRIGATE")
    {:ok, _} = Fleet.record_ship(agent, "HAULER", "SHIP_COMMAND_FRIGATE")
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Complete construction"}],
          "hard_constraints" => []
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    producer = %PortfolioCandidate{
      id: "producer",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["PRODUCER"],
      reservations: %{},
      pledges: [
        %{
          outcome: {:cargo_transfer, "PRODUCER", "HAULER", "IRON_ORE"},
          amount: 4,
          backing: {:claim, "PRODUCER"}
        }
      ],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    receiver = %PortfolioCandidate{
      id: "receiver",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["HAULER"],
      reservations: %{"cargo_capacity:HAULER" => 4},
      pledges: [
        %{
          outcome: {:construction, "X1-UX81-A1", "IRON_ORE"},
          amount: 4,
          backing: {:dependency, "cargo"}
        }
      ],
      dependencies: [%{id: "cargo", kind: :acquisition, candidate_id: "producer", amount: 4}],
      expected_value: 2,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [producer, receiver], %{
        as_of: DateTime.utc_now(),
        claims: ["PRODUCER", "HAULER"],
        reservations: %{"cargo_capacity:HAULER" => 40},
        outcome_remaining: %{{:construction, "X1-UX81-A1", "IRON_ORE"} => 4}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "transfer-test"
      })

    producer = Enum.find(portfolio.commitments, &(&1.candidate_id == "producer"))
    receiver = Enum.find(portfolio.commitments, &(&1.candidate_id == "receiver"))

    intent =
      Repo.insert!(%Intent{
        ship_id: source_ship.id,
        caller: "commitment",
        type: "transfer",
        status: "active",
        fleet_commitment_id: producer.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        target_waypoint: "X1-UX81-A1",
        parameters: %{"target_ship" => "HAULER", "trade_symbol" => "IRON_ORE", "units" => 4}
      })

    %{agent: agent, intent: intent, receiver: receiver, producer: producer, portfolio: portfolio}
  end

  defp action do
    %{
      "kind" => "transfer",
      "target_ship" => "HAULER",
      "trade_symbol" => "IRON_ORE",
      "units" => 4,
      "source_before" => 12,
      "target_before" => 0
    }
  end
end
