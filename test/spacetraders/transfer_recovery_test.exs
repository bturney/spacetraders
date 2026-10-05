defmodule SpaceTraders.TransferRecoveryTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.{Evidence, Fleet, FleetAllocation, MutationAttempts, SafetyFence}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Intents}
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  # Approved #570 seams: root Intents, exact Evidence proof, existing admission,
  # sole mutation ledger, and Req.Test at the game boundary (same as #566).
  test "transfer ledger rejects an unretained conclusion covering both Ships" do
    %{agent: agent, intent: intent} = transfer_fixture()
    {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, prepared_action(agent))
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    forged = Evidence.reconciliation_observation("get-my-ship", attempt, :accepted, "asserted")

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, [forged])

    assert SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "absent transfer retries once through the selected live and boot progression" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, sends} = Elixir.Agent.start_link(fn -> 0 end)
    stub_transfer(sends)

    assert {:ok, %Intent{status: "completed"}} = Intents.advance(agent, selected, nil)
    assert Elixir.Agent.get(sends, & &1) == 1
    assert MutationAttempts.get!(attempt.id).state == "absent"
    refute MutationAttempts.get!(attempt.id).retry_authorized
    retry = Enum.find(MutationAttempts.list_for_agent(agent), &(&1.retry_of_id == attempt.id))
    assert retry.retry_of_id == attempt.id
    assert retry.state == "succeeded"

    assert :ok = Intents.reconcile(agent.id, "PRODUCER", nil, :boot, selected.id)
    assert Elixir.Agent.get(sends, & &1) == 1
  end

  test "lost receiver Claim retires proven absence without erasing the historical verdict" do
    %{agent: agent, intent: intent, portfolio: portfolio} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Repo.query!(
      "DELETE FROM fleet_commitment_claims WHERE resource = $1 AND fleet_commitment_portfolio_id = $2",
      ["HAULER", portfolio.id]
    )

    {:ok, sends} = Elixir.Agent.start_link(fn -> 0 end)
    stub_transfer(sends)

    assert {:ok, %Intent{status: "superseded", in_flight_action: nil}} =
             Intents.advance(agent, selected, nil)

    assert Elixir.Agent.get(sends, & &1) == 0
    historical = MutationAttempts.get!(attempt.id)
    assert historical.state == "absent"
    refute historical.retry_authorized
    assert Enum.any?(historical.outcomes, &(&1.classification == "absent"))
  end

  test "unattributable transfer retains Bounded Unknown only on its two Ship dependencies" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      symbol = List.last(String.split(conn.request_path, "/"))
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" => ship_body(symbol, %{"cargo" => cargo(if(symbol == "PRODUCER", do: 8, else: 0))})
      })
    end)

    assert {:ok, %Intent{status: "blocked"}} = Intents.advance(agent, selected, nil)
    bounded = MutationAttempts.get!(attempt.id)
    assert bounded.state == "bounded_unknown"
    assert bounded.dependency_keys == ["ship:#{agent.id}:PRODUCER", "ship:#{agent.id}:HAULER"]
    assert SafetyFence.active?(bounded)
    assert SafetyFence.blocking_attempts(["ship:#{agent.id}:UNRELATED"]) == []
    refute bounded.retry_authorized
  end

  test "successful response cannot complete with a Ship component expiring during the receiver read" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, _} = MutationAttempts.record_outcome(attempt, :succeeded, %{cargo: cargo(8)})
    use_clock(DateTime.add(attempt.sent_or_unknown_at, 1, :second))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      symbol = List.last(String.split(conn.request_path, "/"))
      if symbol == "HAULER", do: SpaceTraders.TestClock.advance(31)

      Req.Test.json(conn, %{
        "data" => ship_body(symbol, %{"cargo" => cargo(if(symbol == "PRODUCER", do: 8, else: 4))})
      })
    end)

    assert {:ok, %Intent{status: "blocked", in_flight_action: action}} =
             Intents.advance(agent, selected, nil)

    assert action == selected.in_flight_action
    assert MutationAttempts.get!(attempt.id).state == "succeeded"
  end

  test "losing retained receiving capacity after marker commit suppresses transfer at final admission" do
    %{agent: agent, intent: intent} = transfer_fixture()
    selected_action = prepared_action(agent)
    {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, intent, selected_action)
    {:ok, _} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("transfer sent after receiving evidence disappeared")
    end)

    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:spacetraders, :recorded_dispatch, :marker_committed],
      fn _, _, metadata, _ ->
        if metadata.attempt_id == attempt.id do
          Repo.delete!(Repo.get!(Evidence.Observation, selected_action["target_observation_id"]))
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :transfer_evidence_unavailable} = SpaceTraders.API.dispatch_recorded(attempt)
    historical = MutationAttempts.get!(attempt.id)
    assert historical.state == "ambiguous"
    assert historical.sent_or_unknown_at
    assert SafetyFence.active?(historical)
  end

  test "retry replaces expired preflight components with newly judged exact Ship evidence" do
    %{agent: agent, intent: intent} = transfer_fixture()
    selected_action = prepared_action(agent)

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, selected_action)

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    use_clock(DateTime.add(attempt.sent_or_unknown_at, 31, :second))
    {:ok, sends} = Elixir.Agent.start_link(fn -> 0 end)
    stub_transfer(sends)

    assert {:ok, %Intent{status: "completed"}} = Intents.advance(agent, selected, nil)
    assert Elixir.Agent.get(sends, & &1) == 1
    retry = Enum.find(MutationAttempts.list_for_agent(agent), &(&1.retry_of_id == attempt.id))

    assert retry.prepared_evidence["selected_action"]["selection_id"] ==
             selected.in_flight_action["selection_id"]

    refute retry.prepared_evidence["selected_action"]["target_observation_id"] ==
             selected_action["target_observation_id"]
  end

  for trigger <- [:boot, :arrival, :cooldown, :intent_retry] do
    @trigger trigger
    test "#{trigger} retains exact two-Ship acceptance after receiver authority is lost" do
      %{agent: agent, intent: intent, portfolio: portfolio} = transfer_fixture()

      {:ok, %{intent: selected, attempt: attempt}} =
        RecordedAction.prepare(agent, intent, prepared_action(agent))

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
      {:ok, sends} = Elixir.Agent.start_link(fn -> 1 end)
      stub_transfer(sends)
      {:ok, original} = Evidence.get_ship_binding(agent, "PRODUCER")
      {:ok, newer} = Evidence.get_ship_binding(agent, "PRODUCER")
      refute newer.observation.id == original.observation.id
      {:ok, original} = Evidence.retained_ship_binding(agent, original.observation.id)

      Repo.query!(
        "DELETE FROM fleet_commitment_claims WHERE resource = $1 AND fleet_commitment_portfolio_id = $2",
        ["HAULER", portfolio.id]
      )

      _ =
        Intents.reconcile(
          agent.id,
          "PRODUCER",
          Evidence.bound_ship(original),
          @trigger,
          selected.id
        )

      assert Repo.get!(Intent, selected.id).status == "completed"
      accepted = MutationAttempts.get!(attempt.id)
      assert accepted.state == "accepted"
      refute SafetyFence.active?(accepted)
      proofs = List.last(accepted.outcomes).evidence["observations"]
      source_proof = Enum.find(proofs, &(&1["source"]["subject"] == "ship:PRODUCER"))
      assert source_proof["source"]["id"] == original.observation.id
      assert source_proof["observed_at"] == DateTime.to_iso8601(original.observation.observed_at)

      assert Enum.map(proofs, & &1["dependency_keys"]) == [
               ["ship:#{agent.id}:PRODUCER"],
               ["ship:#{agent.id}:HAULER"]
             ]

      _ = Intents.reconcile(agent.id, "PRODUCER", nil, @trigger, selected.id)
      assert Elixir.Agent.get(sends, & &1) == 1
    end
  end

  test "an obsolete successful transfer callback cannot clear a newer selection" do
    %{agent: agent, intent: intent} = transfer_fixture()
    selected_action = prepared_action(agent)
    {:ok, sends} = Elixir.Agent.start_link(fn -> 0 end)
    stub_transfer(sends)
    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:spacetraders, :mutation_attempts, :outcome_committed],
      fn _, _, metadata, _ ->
        if metadata.operation_id == "transfer-cargo" do
          current = Repo.get!(Intent, intent.id)
          {:ok, clear} = Intents.transition_intent(current, in_flight_action: nil)
          {:ok, source} = Evidence.get_ship_binding(agent, "PRODUCER")
          {:ok, target} = Evidence.get_ship_binding(agent, "HAULER")

          replacement =
            selected_action
            |> Map.merge(%{
              "source_before" => 8,
              "target_before" => 4,
              "units" => 1,
              "source_observation_id" => source.observation.id,
              "target_observation_id" => target.observation.id
            })

          {:ok, next} = RecordedAction.prepare(agent, clear, replacement)
          send(test_pid, {:replacement, next})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok = Intents.execute_action(agent, intent, nil, selected_action)
    assert_received {:replacement, %{intent: replacement, attempt: next}}
    assert Repo.get!(Intent, intent.id).in_flight_action == replacement.in_flight_action
    assert Repo.get!(Intent, intent.id).mutation_attempt_id == next.id
    assert MutationAttempts.get!(next.id).state == "prepared"
    assert Elixir.Agent.get(sends, & &1) == 1
  end

  test "receiving read retention failure preserves the original attempt and both-Ship fence" do
    %{agent: agent, intent: intent} = transfer_fixture()

    {:ok, %{intent: selected, attempt: attempt}} =
      RecordedAction.prepare(agent, intent, prepared_action(agent))

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Repo.query!(
      "ALTER TABLE authoritative_observations ADD CONSTRAINT transfer_retention_gap CHECK (subject <> 'ship:HAULER') NOT VALID"
    )

    {:ok, sends} = Elixir.Agent.start_link(fn -> 1 end)
    stub_transfer(sends)

    assert {:ok, %Intent{status: "blocked"}} = Intents.advance(agent, selected, nil)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SafetyFence.active?(MutationAttempts.get!(attempt.id))
    assert Repo.get!(Intent, selected.id).mutation_attempt_id == attempt.id
    assert Elixir.Agent.get(sends, & &1) == 1
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

  defp use_clock(now) do
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({SpaceTraders.TestClock, now})
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)
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
