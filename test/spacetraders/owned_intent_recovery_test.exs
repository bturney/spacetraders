defmodule SpaceTraders.OwnedIntentRecoveryTest do
  # Recovery boots shared ShipServer runtime and switches Req.Test to shared mode.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.API.Model
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.Fleet.{Activity, Intent, Ship}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  test "scan recovery after restart keeps the cooldown's original retained source" do
    {agent, ship, portfolio, commitment} = claimed_ship("SCAN-SOURCE")

    {intent, attempt} =
      selected_intelligence(agent, ship, portfolio, commitment, "scan_waypoints")

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    expiration = DateTime.add(attempt.sent_or_unknown_at, 60) |> DateTime.to_iso8601()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" =>
          ship_body(ship.symbol, %{
            "cooldown" => %{
              "shipSymbol" => ship.symbol,
              "totalSeconds" => 60,
              "remainingSeconds" => 60,
              "expiration" => expiration
            }
          })
      })
    end)

    {:ok, original} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, newer} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    refute original.observation.id == newer.observation.id
    SpaceTraders.Quiesced.stop_ship(ship.symbol)

    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("recovery replaced retained cooldown facts") end)

    {:ok, restored} = SpaceTraders.Evidence.retained_ship_binding(agent, original.observation.id)

    _ =
      Intents.reconcile(
        agent.id,
        ship.symbol,
        SpaceTraders.Evidence.bound_ship(restored),
        :boot,
        intent.id
      )

    accepted = MutationAttempts.get!(attempt.id)
    assert accepted.state == "accepted"
    proof = List.last(accepted.outcomes).evidence["observations"] |> hd()
    assert proof["source"]["id"] == original.observation.id
    assert proof["observed_at"] == DateTime.to_iso8601(original.observation.observed_at)
    assert %Intent{status: "waiting", in_flight_action: nil} = Repo.get!(Intent, intent.id)
  end

  test "chart proof reuses its exact Waypoint acquisition across identical replacement and restart" do
    {agent, ship, portfolio, commitment} = claimed_ship("CHART-SOURCE")
    {_intent, attempt} = selected_intelligence(agent, ship, portfolio, commitment, "chart")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    chart_time = DateTime.to_iso8601(attempt.sent_or_unknown_at)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => "X1-UX81-A1",
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "traits" => [],
          "chart" => %{
            "waypointSymbol" => "X1-UX81-A1",
            "submittedBy" => agent.symbol,
            "submittedOn" => chart_time
          }
        }
      })
    end)

    {:ok, original} =
      SpaceTraders.Evidence.get_waypoint(agent, "X1-UX81", "X1-UX81-A1", bind: true)

    assert %SpaceTraders.Evidence.Binding{} = original
    {:ok, newer} = SpaceTraders.Evidence.get_waypoint(agent, "X1-UX81", "X1-UX81-A1", bind: true)
    refute original.observation.id == newer.observation.id
    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("binding restoration made a game read") end)

    {:ok, restored} =
      SpaceTraders.Evidence.retained_binding(agent, original.observation.id)

    assert {:ok, [proof]} =
             SpaceTraders.Evidence.recovery_proof(
               attempt,
               :accepted,
               "Chart is attributed to this Agent after dispatch",
               [restored]
             )

    assert proof.source.id == original.observation.id
    assert proof.observed_at == original.observation.observed_at

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, [%{proof | source: nil}])

    assert {:ok, accepted} = MutationAttempts.reconcile(attempt, :accepted, [proof])
    refute SpaceTraders.SafetyFence.active?(accepted)
  end

  test "coalesced chart recovery reads share one exact retained acquisition" do
    {agent, _ship, _portfolio, _commitment} = claimed_ship("CHART-COALESCED")
    parent = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(parent, {:chart_read_started, self()})
      receive do: (:release_chart_read -> :ok)

      Req.Test.json(conn, %{
        "data" => chart_waypoint(agent.symbol, DateTime.to_iso8601(DateTime.utc_now()))
      })
    end)

    first =
      Task.async(fn ->
        SpaceTraders.Evidence.get_waypoint(agent, "X1-UX81", "X1-UX81-A1", bind: true)
      end)

    assert_receive {:chart_read_started, reader}, 5_000

    second =
      Task.async(fn ->
        SpaceTraders.Evidence.get_waypoint(agent, "X1-UX81", "X1-UX81-A1", bind: true)
      end)

    wait_for_coalesced_read(second.pid)
    send(reader, :release_chart_read)
    {:ok, original} = Task.await(first)
    {:ok, shared} = Task.await(second)
    assert original.observation.id == shared.observation.id
    assert original.observation.observed_at == shared.observation.observed_at
    refute_receive {:chart_read_started, _}
  end

  test "scan without post-dispatch cooldown blocks as unprovable absence without sending" do
    {agent, ship, portfolio, commitment} = claimed_ship("SCAN-UNPROVABLE")

    {intent, attempt} =
      selected_intelligence(agent, ship, portfolio, commitment, "scan_waypoints")

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    current = Repo.get!(Intent, intent.id)
    assert current.status == "blocked"
    assert current.blocker.evidence =~ ~s({:absence_unprovable, "scan_waypoints"})
    assert current.in_flight_action["kind"] == "scan_waypoints"
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "prepared scan boot and live dispatch retain the same returned Intelligence exactly once" do
    for trigger <- [:boot, :live] do
      {agent, ship, portfolio, commitment} = claimed_ship("SCAN-PREPARED-#{trigger}")

      {intent, attempt} =
        selected_intelligence(
          agent,
          ship,
          portfolio,
          commitment,
          "scan_waypoints",
          trigger == :boot
        )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

          "POST" ->
            send(self(), {:scan_dispatch, trigger})

            Req.Test.json(conn, %{
              "data" => %{
                "waypoints" => [
                  %{
                    "symbol" => "X1-UX81-A1",
                    "systemSymbol" => "X1-UX81",
                    "type" => "PLANET",
                    "x" => 0,
                    "y" => 0,
                    "traits" => [],
                    "orbitals" => []
                  }
                ]
              }
            })
        end
      end)

      if trigger == :boot do
        _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      else
        {:ok, binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

        _ =
          Intents.execute_action(agent, intent, SpaceTraders.Evidence.bound_ship(binding), %{
            "kind" => "scan_waypoints",
            "waypoint" => intent.target_waypoint
          })
      end

      assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
      [completed_attempt] = MutationAttempts.list_for_agent(agent)
      assert completed_attempt.state == "succeeded"
      if attempt, do: assert(completed_attempt.id == attempt.id)
      assert_receive {:scan_dispatch, ^trigger}
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      refute_receive {:scan_dispatch, ^trigger}
    end
  end

  test "durably successful scan reentry does not require its expired cooldown or replay" do
    {agent, ship, portfolio, commitment} = claimed_ship("SCAN-COMMITTED")

    {intent, attempt} =
      selected_intelligence(agent, ship, portfolio, commitment, "scan_waypoints")

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, _} = MutationAttempts.record_outcome(attempt, :succeeded, %{status: 200})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    assert %Intent{
             status: "blocked",
             in_flight_action: nil,
             parameters: %{"scan_attempted" => true}
           } = Repo.get!(Intent, intent.id)

    assert MutationAttempts.get!(attempt.id).state == "succeeded"
  end

  test "chart callback lacking required provenance keeps its selection without a second chart" do
    {agent, ship, portfolio, commitment} = claimed_ship("CHART-INCOMPLETE")
    {intent, _} = selected_intelligence(agent, ship, portfolio, commitment, "chart", false)
    {:ok, binding} = retained_scan_ship(agent, ship)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "POST"
      send(self(), :chart_dispatch)

      Req.Test.json(conn, %{
        "data" => %{
          "chart" => %{"waypointSymbol" => intent.target_waypoint},
          "waypoint" => %{
            "symbol" => intent.target_waypoint,
            "systemSymbol" => "X1-UX81",
            "type" => "PLANET",
            "traits" => []
          }
        }
      })
    end)

    _ =
      Intents.execute_action(agent, intent, SpaceTraders.Evidence.bound_ship(binding), %{
        "kind" => "chart",
        "waypoint" => intent.target_waypoint
      })

    assert %Intent{status: "blocked", in_flight_action: %{"kind" => "chart"}} =
             Repo.get!(Intent, intent.id)

    assert_receive :chart_dispatch
    refute_receive :chart_dispatch
  end

  test "failed chart evidence retention preserves its attempt and fence even with satisfied Intelligence" do
    {agent, ship, portfolio, commitment} = claimed_ship("CHART-RETENTION")
    {intent, attempt} = selected_intelligence(agent, ship, portfolio, commitment, "chart")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    body = chart_waypoint(agent.symbol, DateTime.to_iso8601(attempt.sent_or_unknown_at))

    {:ok, _} =
      SpaceTraders.Intelligence.observe_waypoint(agent, Model.Waypoint.from_json(body),
        source: "get_waypoint",
        observing_ship_symbol: ship.symbol
      )

    Repo.query!(
      "ALTER TABLE authoritative_observations ADD CONSTRAINT chart_retention_gap CHECK (operation_id <> 'get-waypoint')"
    )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      data =
        if conn.request_path == "/v2/my/ships/#{ship.symbol}",
          do: ship_body(ship.symbol),
          else: body

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    assert %Intent{
             status: "blocked",
             mutation_attempt_id: id,
             in_flight_action: %{"kind" => "chart"}
           } = Repo.get!(Intent, intent.id)

    assert id == attempt.id
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  for chart_fact <- [:other_agent, :before_dispatch, :future, :missing] do
    test "chart recovery rejects #{chart_fact} provenance despite a fresh retained acquisition" do
      {agent, ship, portfolio, commitment} = claimed_ship("CHART-REJECT-#{unquote(chart_fact)}")
      {intent, attempt} = selected_intelligence(agent, ship, portfolio, commitment, "chart")
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      {by, time} =
        case unquote(chart_fact) do
          :other_agent -> {"OTHER-AGENT", attempt.sent_or_unknown_at}
          :before_dispatch -> {agent.symbol, DateTime.add(attempt.sent_or_unknown_at, -60)}
          :future -> {agent.symbol, DateTime.add(attempt.sent_or_unknown_at, 60)}
          :missing -> {nil, attempt.sent_or_unknown_at}
        end

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/ships/#{ship.symbol}",
            do: ship_body(ship.symbol),
            else: chart_waypoint(by, DateTime.to_iso8601(time))

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

      assert %Intent{
               status: "blocked",
               mutation_attempt_id: id,
               in_flight_action: %{"kind" => "chart"}
             } = Repo.get!(Intent, intent.id)

      assert id == attempt.id
      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    end
  end

  test "Contract recovery covers only retained Cargo and recipient facts with exact lineage" do
    {agent, ship, _portfolio, _commitment} = claimed_ship("DELIVERY-SOURCE")

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("deliver-contract"),
        "/my/contracts/ctr-source/deliver",
        agent_id: agent.id,
        json: %{"shipSymbol" => ship.symbol, "tradeSymbol" => "IRON_ORE", "units" => 1}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        if conn.request_path == "/v2/my/contracts",
          do: [delivery_contract_body()],
          else: ship_body(ship.symbol)

      Req.Test.json(conn, %{"data" => data})
    end)

    {:ok, cargo} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, recipient} = SpaceTraders.Evidence.get_contracts(agent, bind: true)
    {:ok, newer} = SpaceTraders.Evidence.get_contracts(agent, bind: true)
    refute newer.observation.id == recipient.observation.id

    assert {:incomplete, %{missing: [_]}} =
             SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "Delivery accepted", [cargo])

    assert {:incomplete, %{missing: [_]}} =
             SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "Delivery accepted", [
               recipient
             ])

    assert {:ok, proof} =
             SpaceTraders.Evidence.recovery_proof(
               attempt,
               :accepted,
               "Cargo and Contract progress agree",
               [cargo, recipient]
             )

    assert Enum.map(proof, & &1.source.id) == [cargo.observation.id, recipient.observation.id]

    assert Enum.map(proof, & &1.observed_at) == [
             cargo.observation.observed_at,
             recipient.observation.observed_at
           ]

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, Enum.map(proof, &%{&1 | source: nil}))

    assert {:ok, accepted} = MutationAttempts.reconcile(attempt, :accepted, proof)
    assert accepted.state == "accepted"
  end

  test "Construction binding survives restart without widening Cargo coverage" do
    {agent, ship, _portfolio, _commitment} = claimed_ship("CONSTRUCTION-SOURCE")

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("supply-construction"),
        "/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply",
        agent_id: agent.id,
        json: %{"shipSymbol" => ship.symbol, "tradeSymbol" => "IRON_ORE", "units" => 1}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        if String.ends_with?(conn.request_path, "/construction"),
          do: %{
            "symbol" => "X1-UX81-A1",
            "isComplete" => false,
            "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 5, "fulfilled" => 1}]
          },
          else: ship_body(ship.symbol)

      Req.Test.json(conn, %{"data" => data})
    end)

    {:ok, cargo} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    {:ok, %SpaceTraders.Evidence.Binding{} = recipient} =
      SpaceTraders.Evidence.get_construction(agent, "X1-UX81", "X1-UX81-A1", bind: true)

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("retained restart binding acquired evidence")
    end)

    assert {:ok, restored} =
             SpaceTraders.Evidence.retained_binding(agent, recipient.observation.id)

    assert restored == recipient

    assert {:incomplete, %{missing: [_]}} =
             SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "Supply accepted", [
               restored
             ])

    assert {:ok, proof} =
             SpaceTraders.Evidence.recovery_proof(
               attempt,
               :accepted,
               "Cargo and Construction agree",
               [cargo, restored]
             )

    assert {:ok, _} = MutationAttempts.reconcile(attempt, :accepted, proof)
  end

  defp delivery_contract_body do
    %{
      "id" => "ctr-source",
      "accepted" => true,
      "fulfilled" => false,
      "terms" => %{
        "deadline" => "2099-01-01T00:00:00Z",
        "payment" => %{},
        "deliver" => [
          %{
            "tradeSymbol" => "IRON_ORE",
            "destinationSymbol" => "X1-UX81-A1",
            "unitsRequired" => 5,
            "unitsFulfilled" => 1
          }
        ]
      }
    }
  end

  test "Construction recovery settles from exact retained Cargo and recipient sources" do
    {agent, ship, portfolio, commitment} = claimed_ship("SUPPLY-RECOVERY")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "construction")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_delivery(ship, "construction", 11, 5)
    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    accepted = MutationAttempts.get!(attempt.id)
    assert accepted.state == "accepted"
    assert Repo.get!(Intent, intent.id).last_action_result["units"] == 1
    observations = List.last(accepted.outcomes).evidence["observations"]
    assert Enum.all?(observations, &is_binary(get_in(&1, ["source", "id"])))
    assert Enum.map(observations, & &1["operation_id"]) == ["get-my-ship", "get-construction"]
  end

  test "delivery runtime keeps supplied Cargo lineage when identical newer Cargo replaces latest" do
    {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-EXACT-RUNTIME")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "contract")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_delivery(ship, "contract", 11, 5)
    {:ok, original} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, newer} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    refute original.observation.id == newer.observation.id

    assert {:ok, %{status: "completed"}} =
             Intents.advance(agent, intent, SpaceTraders.Evidence.bound_ship(original))

    observations = List.last(MutationAttempts.get!(attempt.id).outcomes).evidence["observations"]
    assert hd(observations)["source"]["id"] == original.observation.id

    assert hd(observations)["observed_at"] ==
             DateTime.to_iso8601(original.observation.observed_at)

    assert SpaceTraders.Evidence.latest_observation(agent, "ship:#{ship.symbol}").id ==
             newer.observation.id
  end

  for family <- ["contract", "construction"] do
    test "#{family} recipient progress completed externally retires absence without Fleet-earned quantity" do
      family = unquote(family)
      {agent, ship, portfolio, commitment} = claimed_ship("EXTERNAL-" <> family)
      {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, family)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      stub_delivery(ship, family, 12, 5)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      result = Repo.get!(Intent, intent.id)
      assert result.status == "completed"
      assert result.last_action_result["external_completion"]
      assert result.last_action_result["units"] == 0
      absent = MutationAttempts.get!(attempt.id)
      assert absent.state == "absent"
      refute absent.retry_authorized
      refute Enum.any?(absent.outcomes, &(&1.classification in ["accepted", "succeeded"]))
    end
  end

  defp selected_delivery(agent, ship, portfolio, commitment, family) do
    recipient =
      if family == "contract",
        do: %{"type" => "contract", "contract_id" => "ctr-source", "waypoint" => "X1-UX81-A1"},
        else: %{"type" => "construction", "system" => "X1-UX81", "waypoint" => "X1-UX81-A1"}

    intent =
      owned_intent(ship, portfolio, commitment,
        type: "deliver",
        target_waypoint: "X1-UX81-A1",
        parameters: %{"trade_symbol" => "IRON_ORE", "units" => 1, "recipient" => recipient}
      )

    {:ok, %{intent: intent, attempt: attempt}} =
      prepare_recorded(agent, intent, %{
        "kind" => "deliver",
        "trade_symbol" => "IRON_ORE",
        "units" => 1,
        "cargo_before" => 12,
        "fulfilled_before" => 4,
        "recipient" => recipient
      })

    {intent, attempt}
  end

  test "persisted delivery absence rechecks recipient completion before consuming a retry" do
    {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-RETRY-COMPLETED")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "construction")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_delivery(ship, "construction", 12, 4)
    {:ok, cargo} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    {:ok, recipient} =
      SpaceTraders.Evidence.get_construction(agent, "X1-UX81", "X1-UX81-A1", bind: true)

    {:ok, proof} =
      SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Unchanged Cargo and progress", [
        cargo,
        recipient
      ])

    {:ok, absent} = MutationAttempts.reconcile(attempt, :absent, proof)
    assert absent.retry_authorized
    stub_delivery(ship, "construction", 12, 5)
    _ = Intents.reconcile(agent.id, ship.symbol, nil, :intent_retry, intent.id)
    assert Repo.get!(Intent, intent.id).status == "completed"
    refute MutationAttempts.get!(attempt.id).retry_authorized
    assert MutationAttempts.get!(attempt.id).state == "absent"
  end

  test "prepared Construction delivery resumes its original attempt and completed response only once" do
    {agent, ship, portfolio, commitment} = claimed_ship("PREPARED-SUPPLY")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "construction")
    calls = start_supervised!({Elixir.Agent, fn -> 0 end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        case conn.method do
          "GET" ->
            ship_body(ship.symbol, %{"nav" => nav_body("DOCKED")})

          "POST" ->
            assert String.ends_with?(conn.request_path, "/construction/supply")
            Elixir.Agent.update(calls, &(&1 + 1))

            %{
              "cargo" => %{
                "capacity" => 40,
                "units" => 11,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 11}]
              },
              "construction" => %{
                "symbol" => "X1-UX81-A1",
                "isComplete" => false,
                "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 5, "fulfilled" => 5}]
              }
            }
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert Elixir.Agent.get(calls, & &1) == 1
    assert MutationAttempts.get!(attempt.id).state == "succeeded"
    assert [only] = MutationAttempts.list_for_agent(agent)
    assert only.id == attempt.id
    assert Repo.get!(Intent, intent.id).last_action_result["units"] == 1
  end

  test "a delivery callback cannot clear the newer retry of its same selected action" do
    {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-STALE-RETRY")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "contract")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    stub_delivery(ship, "contract", 12, 4)
    {:ok, cargo} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, recipient} = SpaceTraders.Evidence.get_contracts(agent, bind: true)

    {:ok, proof} =
      SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Unchanged Cargo and recipient", [
        cargo,
        recipient
      ])

    {:ok, absent} = MutationAttempts.reconcile(attempt, :absent, proof)
    {:ok, retry} = SpaceTraders.Fleet.Intents.RecordedAction.prepare_retry(agent, intent, absent)

    assert :intent_no_longer_owned =
             Intents.transition_intent(intent, status: "completed", in_flight_action: nil)

    current = Repo.get!(Intent, intent.id)
    assert current.in_flight_action == intent.in_flight_action
    assert current.mutation_attempt_id == retry.id
    assert MutationAttempts.get!(retry.id).state == "prepared"
  end

  test "missing Construction material progress cannot resolve supply or release its fence" do
    {agent, ship, portfolio, commitment} = claimed_ship("MISSING-MATERIAL")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "construction")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      data =
        if String.ends_with?(conn.request_path, "/construction"),
          do: %{"symbol" => "X1-UX81-A1", "isComplete" => true, "materials" => []},
          else: ship_body(ship.symbol, %{"nav" => nav_body("DOCKED")})

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
  end

  test "a durable successful response cannot advance delivery from malformed recovery facts" do
    {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-SUCCESS-GAP")
    {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, "construction")
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, _} = MutationAttempts.record_outcome(attempt, :succeeded, %{status: 200})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      data =
        if String.ends_with?(conn.request_path, "/construction"),
          do: %{
            "symbol" => "X1-UX81-A1",
            "isComplete" => nil,
            "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 5, "fulfilled" => 5}]
          },
          else:
            ship_body(ship.symbol, %{
              "nav" => nav_body("DOCKED"),
              "cargo" => %{
                "capacity" => 40,
                "units" => 11,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 11}]
              }
            })

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert Repo.get!(Intent, intent.id).status == "blocked"
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
    assert MutationAttempts.get!(attempt.id).state == "succeeded"
  end

  for family <- ["contract", "construction"] do
    test "#{family} partial acquisition expiry preserves exact usable recipient and never restamps Cargo" do
      family = unquote(family)
      {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-EXPIRY-#{family}")
      {_intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, family)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      previous = Application.fetch_env(:spacetraders, :clock)

      start_supervised!(
        {SpaceTraders.TestClock, DateTime.add(attempt.sent_or_unknown_at, 1, :second)}
      )

      Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
          :error -> Application.delete_env(:spacetraders, :clock)
        end
      end)

      stub_delivery(ship, family, 11, 5)
      {:ok, cargo} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      SpaceTraders.TestClock.advance(31)

      {:ok, recipient} =
        if family == "contract",
          do: SpaceTraders.Evidence.get_contracts(agent, bind: true),
          else: SpaceTraders.Evidence.get_construction(agent, "X1-UX81", "X1-UX81-A1", bind: true)

      assert {:incomplete, %{usable: [^recipient], unusable: [^cargo], missing: [_]}} =
               SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "Progress agrees", [
                 cargo,
                 recipient
               ])

      {:ok, replacement} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

      assert {:ok, restored} =
               SpaceTraders.Evidence.retained_binding(agent, recipient.observation.id)

      assert restored == recipient
      assert replacement.value == cargo.value
      refute replacement.observation.id == cargo.observation.id

      {:ok, observations} =
        SpaceTraders.Evidence.recovery_proof(
          attempt,
          :accepted,
          "Replacement Cargo and original recipient agree",
          [replacement, restored]
        )

      assert {:ok, _} = MutationAttempts.reconcile(attempt, :accepted, observations)

      assert SpaceTraders.Evidence.retained_ship_binding(agent, cargo.observation.id) ==
               {:ok, cargo}
    end
  end

  for family <- ["contract", "construction"],
      trigger <- [:boot, :arrival, :cooldown, :intent_retry] do
    test "#{family} accepted delivery reenters the selected action on #{trigger}" do
      family = unquote(family)
      trigger = unquote(trigger)
      {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-#{family}-#{trigger}")
      {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, family)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      stub_delivery(ship, family, 11, 5)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, trigger, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, trigger, intent.id)
      assert MutationAttempts.get!(attempt.id).state == "accepted"
      assert Repo.get!(Intent, intent.id).status == "completed"
      assert Repo.get!(Intent, intent.id).last_action_result["units"] == 1
      assert [only] = MutationAttempts.list_for_agent(agent)
      assert only.id == attempt.id
    end
  end

  for family <- ["contract", "construction"], gap <- [:cargo, :recipient] do
    operation =
      if gap == :cargo,
        do: "get-my-ship",
        else: if(family == "contract", do: "get-contracts", else: "get-construction")

    test "#{family} #{gap} retention failure retains the selected attempt and Safety Fence" do
      family = unquote(family)
      gap = unquote(gap)
      {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-GAP-#{family}-#{gap}")
      {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, family)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      operation = unquote(operation)

      Repo.query!(
        "ALTER TABLE authoritative_observations ADD CONSTRAINT delivery_retention_gap CHECK (operation_id <> '#{operation}')"
      )

      stub_delivery(ship, family, 11, 5)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
      assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
    end
  end

  for family <- ["contract", "construction"] do
    test "#{family} proven absence retries once through the same live response continuation" do
      family = unquote(family)
      {agent, ship, portfolio, commitment} = claimed_ship("DELIVERY-ABSENT-#{family}")
      {intent, attempt} = selected_delivery(agent, ship, portfolio, commitment, family)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      calls = start_supervised!({Elixir.Agent, fn -> 0 end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        cargo = %{
          "capacity" => 40,
          "units" => 11,
          "inventory" => [%{"symbol" => "IRON_ORE", "units" => 11}]
        }

        before =
          delivery_contract_body()
          |> put_in(["terms", "deliver", Access.at(0), "unitsFulfilled"], 4)

        construction = %{
          "symbol" => "X1-UX81-A1",
          "isComplete" => false,
          "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 5, "fulfilled" => 4}]
        }

        data =
          case {conn.method, conn.request_path} do
            {"GET", "/v2/my/ships/" <> _} ->
              ship_body(ship.symbol, %{"nav" => nav_body("DOCKED")})

            {"GET", "/v2/my/contracts"} ->
              [before]

            {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction"} ->
              construction

            {"POST", _} ->
              Elixir.Agent.update(calls, &(&1 + 1))

              if family == "contract",
                do: %{
                  "cargo" => cargo,
                  "contract" =>
                    put_in(before, ["terms", "deliver", Access.at(0), "unitsFulfilled"], 5)
                },
                else: %{
                  "cargo" => cargo,
                  "construction" =>
                    put_in(construction, ["materials", Access.at(0), "fulfilled"], 5)
                }
          end

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :intent_retry, intent.id)
      assert Elixir.Agent.get(calls, & &1) == 1
      assert Repo.get!(Intent, intent.id).status == "completed"
      assert Repo.get!(Intent, intent.id).last_action_result["units"] == 1
      assert [original, retry] = MutationAttempts.list_for_agent(agent)
      assert original.id == attempt.id
      assert original.state == "absent"
      refute original.retry_authorized
      assert retry.retry_of_id == original.id
      assert retry.state == "succeeded"
      assert :intent_no_longer_owned = Intents.transition_intent(intent, in_flight_action: nil)
    end
  end

  defp stub_delivery(ship, family, cargo, fulfilled, complete \\ false) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      data =
        case conn.request_path do
          "/v2/my/ships/" <> _ ->
            ship_body(ship.symbol, %{
              "nav" => nav_body("DOCKED"),
              "cargo" => %{
                "capacity" => 40,
                "units" => cargo,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => cargo}]
              }
            })

          "/v2/my/contracts" ->
            [
              delivery_contract_body()
              |> Map.put("fulfilled", complete)
              |> put_in(["terms", "deliver", Access.at(0), "unitsFulfilled"], fulfilled)
            ]

          "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction" ->
            assert family == "construction"

            %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => complete,
              "materials" => [
                %{"tradeSymbol" => "IRON_ORE", "required" => 5, "fulfilled" => fulfilled}
              ]
            }
        end

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  # #654 agrees this seam: real Ship Execution -> outcome telemetry -> Prometheus.
  test "confirmed purchases accumulate gross credits without a zero baseline or wake duplicates" do
    start_transaction_metrics()
    scrape = &transaction_metrics/0

    series =
      ~s(spacetraders_outcome_credits_transactions_total{intent_type="buy",operation="buy"})

    refute scrape.() =~ series
    refute scrape.() =~ ~s(spacetraders_outcome_observed_at_seconds{family="transactions"})

    for {suffix, total, at} <- [{"FIRST", 50, 1_893_456_000}, {"SECOND", 100, 1_893_456_060}] do
      {agent, ship, portfolio, commitment} = claimed_ship("OUTCOME-BUY-#{suffix}")
      {intent, action} = market_selection(ship, portfolio, commitment, "buy")
      {:ok, %{intent: selected}} = prepare_recorded(agent, intent, action)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        data =
          case {conn.method, conn.request_path} do
            {"GET", "/v2/my/agent"} -> %{"symbol" => agent.symbol, "credits" => 1000}
            {"GET", _} -> market_ship_body(ship, 0)
            {"POST", _} -> trade_response(agent, ship, "PURCHASE", 10, 950, 5)
          end

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, selected.id)
      assert Repo.get!(Intent, intent.id).status == "completed"
      assert scrape.() =~ "#{series} #{total}\n"
      assert scrape.() =~ "# TYPE spacetraders_outcome_credits_transactions_total counter\n"

      assert transaction_metric_value(
               ~s(spacetraders_outcome_observed_at_seconds{family="transactions"})
             ) == at

      assert_receive {:telemetry, [:spacetraders, :outcome, :transaction], %{credits: 50},
                      metadata}

      assert metadata == %{intent_type: "buy", operation: "buy"}

      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("completed purchase made another request") end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, selected.id)
      assert scrape.() =~ "#{series} #{total}\n"
      SpaceTraders.TestClock.advance(60)
    end

    SpaceTraders.TestClock.advance(600)

    assert transaction_metric_value(
             ~s(spacetraders_outcome_observed_at_seconds{family="transactions"})
           ) == 1_893_456_060
  end

  test "a confirmed sale records receipts rather than an event count or the quoted price" do
    start_transaction_metrics()
    {agent, ship, portfolio, commitment} = claimed_ship("OUTCOME-SELL")
    {intent, action} = market_selection(ship, portfolio, commitment, "sell")
    {:ok, %{intent: selected}} = prepare_recorded(agent, intent, action)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} -> %{"symbol" => agent.symbol, "credits" => 1000}
          {"GET", _} -> market_ship_body(ship, 5)
          {"POST", _} -> trade_response(agent, ship, "SELL", 17, 1085, 0)
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, selected.id)
    assert Repo.get!(Intent, intent.id).status == "completed"

    assert transaction_metrics() =~
             ~s(spacetraders_outcome_credits_transactions_total{intent_type="sell",operation="sell"} 85\n)

    assert_receive {:telemetry, [:spacetraders, :outcome, :transaction], %{credits: 85}, metadata}
    assert metadata == %{intent_type: "sell", operation: "sell"}
  end

  test "a confirmed supporting refuel records its existing total under the root Intent type" do
    start_transaction_metrics()
    {agent, ship, portfolio, commitment} = claimed_ship("OUTCOME-REFUEL")
    intent = owned_intent(ship, portfolio, commitment, [])

    action = %{
      "kind" => "refuel",
      "waypoint" => "X1-UX81-A1",
      "units" => 50,
      "fuel_before" => 150
    }

    live = Model.Ship.from_json(ship_body(ship.symbol))

    SpaceTraders.RecordedDispatchFixtures.retain_purchase_preflight(
      agent,
      intent.target_waypoint,
      action
    )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            %{"symbol" => agent.symbol, "credits" => 965}

          {"GET", _} ->
            ship_body(ship.symbol, %{"fuel" => %{"current" => 200, "capacity" => 200}})

          {"POST", _} ->
            %{
              "agent" => %{"symbol" => agent.symbol, "credits" => 965},
              "fuel" => %{"current" => 200, "capacity" => 200},
              "transaction" => %{
                "type" => "PURCHASE",
                "shipSymbol" => ship.symbol,
                "tradeSymbol" => "FUEL",
                "waypointSymbol" => "X1-UX81-A1",
                "units" => 50,
                "pricePerUnit" => 1,
                "totalPrice" => 35
              }
            }
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.execute_action(agent, intent, live, action)
    assert [attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.state == "succeeded"

    assert transaction_metrics() =~
             ~s(spacetraders_outcome_credits_transactions_total{intent_type="navigate",operation="refuel"} 35\n)

    assert_receive {:telemetry, [:spacetraders, :outcome, :transaction], %{credits: 35}, metadata}
    assert metadata == %{intent_type: "navigate", operation: "refuel"}
  end

  test "a module modification receipt remains counted after the root completes from a Ship read" do
    start_transaction_metrics()
    {agent, ship, portfolio, commitment} = claimed_ship("OUTCOME-MODULE")
    module = "MODULE_SURVEY_SUITE_I"

    intent =
      owned_intent(ship, portfolio, commitment,
        type: "install_module",
        parameters: %{"module_symbol" => module}
      )

    action = %{
      "kind" => "install_module",
      "module_symbol" => module,
      "quantity" => 1,
      "waypoint" => "X1-UX81-A1",
      "installed_before" => 0,
      "cargo_before" => 1
    }

    before =
      ship_body(ship.symbol, %{
        "cargo" => %{
          "capacity" => 40,
          "units" => 1,
          "inventory" => [%{"symbol" => module, "units" => 1}]
        }
      })

    after_body =
      ship_body(ship.symbol, %{
        "modules" => [%{"symbol" => module}],
        "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
      })

    SpaceTraders.RecordedDispatchFixtures.retain_modification_preflight(agent, "X1-UX81-A1")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            %{"symbol" => agent.symbol, "credits" => 999_875}

          {"GET", _} ->
            after_body

          {"POST", _} ->
            %{
              "agent" => %{"symbol" => agent.symbol, "credits" => 999_875},
              "modules" => after_body["modules"],
              "cargo" => after_body["cargo"],
              "transaction" => %{
                "shipSymbol" => ship.symbol,
                "tradeSymbol" => module,
                "waypointSymbol" => "X1-UX81-A1",
                "totalPrice" => 125
              }
            }
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.execute_action(agent, intent, Model.Ship.from_json(before), action)
    assert Repo.get!(Intent, intent.id).status == "completed"

    assert transaction_metrics() =~
             ~s(spacetraders_outcome_credits_transactions_total{intent_type="install_module",operation="install_module"} 125\n)

    assert_receive {:telemetry, [:spacetraders, :outcome, :transaction], %{credits: 125},
                    metadata}

    assert metadata == %{intent_type: "install_module", operation: "install_module"}

    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("completed modification acquired new facts") end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    assert transaction_metrics() =~
             ~s(spacetraders_outcome_credits_transactions_total{intent_type="install_module",operation="install_module"} 125\n)
  end

  test "rejected or unattributed receipts and price-unknown recovery create no transaction series" do
    start_transaction_metrics()

    for scenario <- [:rejected, :unattributed, :missing_total, :invalid_total, :recovered] do
      {agent, ship, portfolio, commitment} = claimed_ship("OUTCOME-UNKNOWN-#{scenario}")
      {intent, action} = market_selection(ship, portfolio, commitment, "buy")
      {:ok, %{intent: selected, attempt: attempt}} = prepare_recorded(agent, intent, action)
      if scenario == :recovered, do: MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 950}})

          {"GET", _} ->
            Req.Test.json(conn, %{
              "data" => market_ship_body(ship, if(scenario == :recovered, do: 5, else: 0))
            })

          {"POST", _} when scenario == :rejected ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error" => %{"code" => 403, "message" => "forbidden"}})

          {"POST", _} when scenario == :unattributed ->
            data =
              trade_response(agent, ship, "PURCHASE", 10, 950, 5)
              |> put_in(["transaction", "shipSymbol"], "OTHER-SHIP")

            Req.Test.json(conn, %{"data" => data})

          {"POST", _} when scenario in [:missing_total, :invalid_total] ->
            data =
              trade_response(agent, ship, "PURCHASE", 10, 950, 5)
              |> put_in(
                ["transaction", "totalPrice"],
                if(scenario == :missing_total, do: nil, else: -50)
              )

            Req.Test.json(conn, %{"data" => data})
        end
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, selected.id)
      if scenario == :recovered, do: assert(Repo.get!(Intent, intent.id).status == "completed")
      refute transaction_metrics() =~ "spacetraders_outcome_credits_transactions_total"

      refute transaction_metrics() =~
               ~s(spacetraders_outcome_observed_at_seconds{family="transactions"})

      refute_receive {:telemetry, [:spacetraders, :outcome, :transaction], _, _}
    end
  end

  test "a broken transaction subscriber cannot interrupt confirmed Ship execution" do
    start_transaction_metrics()
    handler = {__MODULE__, :broken_transaction, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :outcome, :transaction],
        &__MODULE__.broken_transaction_handler/4,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {agent, ship, portfolio, commitment} = claimed_ship("OUTCOME-FAIL-SOFT")
    {intent, action} = market_selection(ship, portfolio, commitment, "buy")
    {:ok, %{intent: selected}} = prepare_recorded(agent, intent, action)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} -> %{"symbol" => agent.symbol, "credits" => 1000}
          {"GET", _} -> market_ship_body(ship, 0)
          {"POST", _} -> trade_response(agent, ship, "PURCHASE", 10, 950, 5)
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, selected.id)
        assert Repo.get!(Intent, intent.id).status == "completed"

        assert transaction_metrics() =~
                 ~s(spacetraders_outcome_credits_transactions_total{intent_type="buy",operation="buy"} 50\n)
      end)

    assert log =~ "has failed and has been detached"
  end

  def broken_transaction_handler(_event, _measurements, _metadata, _config),
    do: raise("broken transaction subscriber")

  defp start_transaction_metrics do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    start_supervised!({SpaceTraders.TestClock, ~U[2030-01-01 00:00:00.000000Z]})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :outcome, :transaction],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn ->
      :telemetry.detach(handler)

      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)

      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Outcomes)
    end)

    start_supervised!(
      PromEx.Storage.Peep.child_spec(
        __MODULE__.OutcomeReporter,
        SpaceTraders.PromEx.Outcome.event_metrics([]).metrics
      )
    )
  end

  defp transaction_metrics do
    SpaceTraders.Outcomes.metrics(SpaceTraders.PromEx)
    PromEx.Storage.Peep.scrape(__MODULE__.OutcomeReporter) |> IO.iodata_to_binary()
  end

  defp transaction_metric_value(series) do
    line =
      transaction_metrics()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, series <> " "))

    assert line, "missing series #{series}"
    {value, ""} = line |> String.replace_prefix(series <> " ", "") |> Float.parse()
    value
  end

  for kind <- ["buy", "sell"] do
    @tag :market_recovery
    test "#{kind} recovery advances once with exact retained Cargo and credit sources" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-SOURCE-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
      after_units = if unquote(kind) == "buy", do: 5, else: 0
      after_credits = if unquote(kind) == "buy", do: 950, else: 1050

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => after_credits},
            else: market_ship_body(ship, after_units)

        Req.Test.json(conn, %{"data" => data})
      end)

      {:ok, original_ship} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, original_credits} = SpaceTraders.Evidence.get_agent_binding(agent)
      {:ok, newer_ship} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      refute original_ship.observation.id == newer_ship.observation.id
      SpaceTraders.Quiesced.stop_ship(ship.symbol)
      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("recovery must reuse retained evidence") end)

      {:ok, restored} =
        SpaceTraders.Evidence.retained_ship_binding(agent, original_ship.observation.id)

      live = SpaceTraders.Evidence.bound_ship(restored)
      _ = Intents.reconcile(agent.id, ship.symbol, live, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, live, :arrival, intent.id)
      accepted = MutationAttempts.get!(attempt.id)
      assert accepted.state == "accepted"
      proofs = List.last(accepted.outcomes).evidence["observations"]

      assert Enum.map(proofs, & &1["source"]["id"]) ==
               [original_ship.observation.id, original_credits.observation.id]

      assert Enum.map(proofs, & &1["observed_at"]) ==
               Enum.map(
                 [original_ship, original_credits],
                 &DateTime.to_iso8601(&1.observation.observed_at)
               )

      assert %Intent{status: "completed", in_flight_action: nil, last_action_result: result} =
               Repo.get!(Intent, intent.id)

      assert result["units"] == 5
      refute Map.has_key?(result, "price")
      assert length(MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :market_recovery
    test "#{kind} ledger rejects an unretained caller-built Market Cargo conclusion" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-FORGED-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      for verdict <- [:accepted, :absent] do
        forged =
          SpaceTraders.Evidence.reconciliation_observation(
            "get-my-ship",
            attempt,
            verdict,
            "Caller claims Market Cargo and credits without retained observations"
          )

        assert {:error, :authoritative_evidence_required} =
                 MutationAttempts.reconcile(attempt, verdict, [forged])
      end

      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    end

    @tag :market_recovery
    test "#{kind} proven absence consumes one retry through boot and live wakes" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-RETRY-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1000}})

          {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON_ORE",
                    "purchasePrice" => 10,
                    "sellPrice" => 10,
                    "tradeVolume" => 10,
                    "supply" => "HIGH",
                    "type" => "EXPORT"
                  }
                ]
              }
            })

          {"GET", _} ->
            Req.Test.json(conn, %{"data" => market_ship_body(ship, action["cargo_before"])})

          {"POST", _} ->
            send(self(), :market_retry_sent)
            type = if unquote(kind) == "buy", do: "PURCHASE", else: "SELL"
            units = if unquote(kind) == "buy", do: 5, else: 0
            Req.Test.json(conn, %{"data" => trade_response(agent, ship, type, 10, 1000, units)})
        end
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
      original = MutationAttempts.get!(attempt.id)
      assert original.state == "absent"
      refute original.retry_authorized

      assert Enum.count(MutationAttempts.list_for_agent(agent), &(&1.retry_of_id == attempt.id)) ==
               1

      assert_receive :market_retry_sent
      refute_receive :market_retry_sent
    end
  end

  for kind <- ["buy", "sell"] do
    @tag :market_recovery
    test "#{kind} satisfied Cargo before an unused retry withdraws permission without sending" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-WITHDRAW-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      previous_clock = Application.fetch_env(:spacetraders, :clock)
      start_supervised!({SpaceTraders.TestClock, DateTime.add(attempt.sent_or_unknown_at, 1)})
      Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

      on_exit(fn ->
        case previous_clock do
          {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
          :error -> Application.delete_env(:spacetraders, :clock)
        end
      end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 1000},
            else: market_ship_body(ship, action["cargo_before"])

        Req.Test.json(conn, %{"data" => data})
      end)

      {:ok, before_ship} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, before_credits} = SpaceTraders.Evidence.get_agent_binding(agent)

      {:ok, proof} =
        SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Unchanged Market effects", [
          before_ship,
          before_credits
        ])

      {:ok, _} = MutationAttempts.reconcile(attempt, :absent, proof)
      SpaceTraders.TestClock.advance(1)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        assert conn.request_path == "/v2/my/agent" or
                 conn.request_path == "/v2/my/ships/#{ship.symbol}"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{
              "symbol" => agent.symbol,
              "credits" => if(unquote(kind) == "buy", do: 950, else: 1050)
            },
            else: market_ship_body(ship, if(unquote(kind) == "buy", do: 5, else: 0))

        Req.Test.json(conn, %{"data" => data})
      end)

      # Retained unchanged credits are still usable evidence; replacement is a
      # genuinely new acquisition, not a restamp of that prior conclusion.
      {:ok, _} = SpaceTraders.Evidence.get_agent_binding(agent)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
      refute MutationAttempts.get!(attempt.id).retry_authorized
      assert length(MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :market_recovery
    test "#{kind} stopped absence retires without needing Market eligibility or sending" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-STOP-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
      strategy = Repo.get_by!(Strategy, operator_id: agent.operator_id)
      Repo.update!(Ecto.Changeset.change(strategy, emergency_stopped_at: DateTime.utc_now()))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path in ["/v2/my/agent", "/v2/my/ships/#{ship.symbol}"]

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 1000},
            else: market_ship_body(ship, action["cargo_before"])

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert Repo.get!(Intent, intent.id).in_flight_action == nil
      absent = MutationAttempts.get!(attempt.id)
      assert absent.state == "absent"
      refute absent.retry_authorized
      assert length(MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :market_recovery
    test "#{kind} live and prepared boot callbacks advance the same selection only once" do
      for trigger <- [:live, :boot] do
        {agent, ship, portfolio, commitment} =
          claimed_ship("MARKET-PREPARED-#{unquote(kind)}-#{trigger}")

        {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

        selected =
          if trigger == :boot do
            {:ok, %{intent: selected}} =
              prepare_recorded(agent, intent, action)

            selected
          else
            intent
          end

        Req.Test.stub(SpaceTraders.API, fn conn ->
          case conn.method do
            "GET" ->
              Req.Test.json(conn, %{"data" => market_ship_body(ship, action["cargo_before"])})

            "POST" ->
              send(self(), {:market_sent, trigger})
              type = if unquote(kind) == "buy", do: "PURCHASE", else: "SELL"
              units = if unquote(kind) == "buy", do: 5, else: 0
              Req.Test.json(conn, %{"data" => trade_response(agent, ship, type, 10, 1000, units)})
          end
        end)

        if trigger == :boot do
          _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
        else
          {:ok, binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

          _ =
            Intents.execute_action(
              agent,
              selected,
              SpaceTraders.Evidence.bound_ship(binding),
              action
            )

          # Obsolete callers cannot select another action after completion.
          _ =
            Intents.execute_action(
              agent,
              selected,
              SpaceTraders.Evidence.bound_ship(binding),
              action
            )
        end

        _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id)
        assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
        assert [attempt] = MutationAttempts.list_for_agent(agent)
        assert attempt.state == "succeeded"
        assert_receive {:market_sent, ^trigger}
        refute_receive {:market_sent, ^trigger}
      end
    end

    @tag :market_recovery
    test "#{kind} missing retained credit source leaves the narrow fence and selection effective" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-RETENTION-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Repo.query!(
        "ALTER TABLE authoritative_observations ADD CONSTRAINT market_credit_retention_gap CHECK (operation_id <> 'get-my-agent') NOT VALID"
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{
              "symbol" => agent.symbol,
              "credits" => if(unquote(kind) == "buy", do: 950, else: 1050)
            },
            else: market_ship_body(ship, if(unquote(kind) == "buy", do: 5, else: 0))

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id)

      assert %Intent{status: "blocked", mutation_attempt_id: id, in_flight_action: selected} =
               Repo.get!(Intent, intent.id)

      assert id == attempt.id
      assert selected == intent.in_flight_action
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
      assert length(MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :market_recovery
    test "#{kind} changed credits with unchanged Cargo cannot authorize replay" do
      {agent, ship, portfolio, commitment} = claimed_ship("MARKET-AMBIGUOUS-#{unquote(kind)}")
      {intent, action} = market_selection(ship, portfolio, commitment, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 999},
            else: market_ship_body(ship, action["cargo_before"])

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
      assert length(MutationAttempts.list_for_agent(agent)) == 1
    end
  end

  defp market_selection(ship, portfolio, commitment, kind) do
    intent =
      owned_intent(ship, portfolio, commitment,
        type: kind,
        parameters: %{"trade_symbol" => "IRON_ORE", "units" => 5}
      )

    {intent,
     %{
       "kind" => kind,
       "trade_symbol" => "IRON_ORE",
       "units" => 5,
       "listing_price" => 10,
       "cargo_before" => if(kind == "buy", do: 0, else: 5),
       "credits_before" => 1000
     }}
  end

  @tag :market_recovery
  # {intent attrs, selected action, unchanged Ship, contradictory Ship}
  for kind <- ["buy", "install_module", "refuel"] do
    test "#{kind} pending retry with contradictory evidence blocks without sending" do
      kind = unquote(kind)
      {agent, ship, portfolio, commitment} = claimed_ship("PENDING-CONTRADICTION-#{kind}")
      {attrs, action, unchanged, contradictory} = pending_contradiction(kind, ship)
      intent = owned_intent(ship, portfolio, commitment, attrs)

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      test_pid = self()

      stub = fn body ->
        Req.Test.stub(SpaceTraders.API, fn conn ->
          case {conn.method, conn.request_path} do
            {"GET", "/v2/my/agent"} ->
              Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1000}})

            {"GET", _path} ->
              Req.Test.json(conn, %{"data" => body})

            {"POST", path} ->
              send(test_pid, {:retry_sent, path})
              Req.Test.json(conn, %{"data" => %{}})
          end
        end)
      end

      stub.(unchanged)
      {:ok, ship_binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, credits} = SpaceTraders.Evidence.get_agent_binding(agent)

      {:ok, proof} =
        SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Unchanged selected effect", [
          ship_binding,
          credits
        ])

      {:ok, absent} = MutationAttempts.reconcile(attempt, :absent, proof)
      assert absent.retry_authorized

      stub.(contradictory)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

      current = Repo.get!(Intent, intent.id)
      assert current.status == "blocked"
      assert current.mutation_attempt_id == attempt.id
      refute_received {:retry_sent, _}
      assert [pending] = MutationAttempts.list_for_agent(agent)
      assert pending.state == "absent"
      assert pending.retry_authorized
    end
  end

  defp pending_contradiction("buy", ship) do
    {[type: "buy", parameters: %{"trade_symbol" => "IRON_ORE", "units" => 5}],
     %{
       "kind" => "buy",
       "trade_symbol" => "IRON_ORE",
       "units" => 5,
       "listing_price" => 10,
       "cargo_before" => 0,
       "credits_before" => 1000
     }, market_ship_body(ship, 0), market_ship_body(ship, 3)}
  end

  defp pending_contradiction("install_module", ship) do
    module = "MODULE_SURVEY_SUITE_I"

    body = fn installed, cargo ->
      ship_body(ship.symbol, %{
        "modules" => List.duplicate(%{"symbol" => module}, installed),
        "cargo" => %{
          "capacity" => 40,
          "units" => cargo,
          "inventory" => if(cargo > 0, do: [%{"symbol" => module, "units" => cargo}], else: [])
        }
      })
    end

    # Fitted without consuming the Cargo unit contradicts the selected install.
    {[type: "install_module", parameters: %{"module_symbol" => module}],
     %{
       "kind" => "install_module",
       "module_symbol" => module,
       "quantity" => 1,
       "installed_before" => 0,
       "cargo_before" => 1
     }, body.(0, 1), body.(1, 1)}
  end

  defp pending_contradiction("refuel", ship) do
    body = fn fuel ->
      ship_body(ship.symbol, %{"fuel" => %{"current" => fuel, "capacity" => 200}})
    end

    # Less fuel than before neither proves the refuel nor its absence.
    {[],
     %{
       "kind" => "refuel",
       "waypoint" => "X1-UX81-A1",
       "fuel_before" => 150,
       "credits_before" => 1000
     }, body.(150), body.(100)}
  end

  test "recovered partial buy records the effect without declaring the requested quantity complete" do
    {agent, ship, portfolio, commitment} = claimed_ship("MARKET-PARTIAL-BUY")
    {intent, action} = market_selection(ship, portfolio, commitment, "buy")
    action = Map.put(action, "units", 2)

    {:ok, %{intent: intent, attempt: attempt}} =
      prepare_recorded(agent, intent, action)

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      data =
        if conn.request_path == "/v2/my/agent",
          do: %{"symbol" => agent.symbol, "credits" => 980},
          else: market_ship_body(ship, 2)

      Req.Test.json(conn, %{"data" => data})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert Repo.get!(Intent, intent.id).status == "blocked"
    assert length(MutationAttempts.list_for_agent(agent)) == 1
  end

  @tag :market_recovery
  test "market cargo docks through the same recorded progression as its trade" do
    {agent, ship, portfolio, commitment} = claimed_ship("MARKET-DOCK-PROGRESSION")
    {intent, _action} = market_selection(ship, portfolio, commitment, "buy")
    game = start_supervised!({Elixir.Agent, fn -> %{status: "IN_ORBIT", posts: []} end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1000}})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "purchasePrice" => 10,
                  "sellPrice" => 10,
                  "tradeVolume" => 10,
                  "supply" => "HIGH",
                  "type" => "EXPORT"
                }
              ]
            }
          })

        {"GET", _} ->
          status = Elixir.Agent.get(game, & &1.status)
          body = put_in(market_ship_body(ship, 0)["nav"], nav_body(status))
          Req.Test.json(conn, %{"data" => body})

        {"POST", path} ->
          Elixir.Agent.update(game, &%{&1 | posts: &1.posts ++ [Path.basename(path)]})

          if String.ends_with?(path, "/dock") do
            Elixir.Agent.update(game, &%{&1 | status: "DOCKED"})
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("DOCKED")}})
          else
            Req.Test.json(conn, %{"data" => trade_response(agent, ship, "PURCHASE", 10, 950, 5)})
          end
      end
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    assert Elixir.Agent.get(game, & &1.posts) == ["dock", "purchase"]
    assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)

    attempts = MutationAttempts.list_for_agent(agent)

    assert Enum.map(attempts, & &1.prepared_evidence["selected_action"]["kind"]) |> Enum.sort() ==
             ["buy", "dock"]

    assert Enum.all?(attempts, &(&1.state in ["accepted", "succeeded"]))

    assert Enum.all?(
             attempts,
             &is_binary(&1.prepared_evidence["selected_action"]["selection_id"])
           )
  end

  @tag :market_recovery
  test "a game-rejected market cargo dock blocks its selection without trading or replay" do
    {agent, ship, portfolio, commitment} = claimed_ship("MARKET-DOCK-REJECTED")
    {intent, _action} = market_selection(ship, portfolio, commitment, "buy")
    game = start_supervised!({Elixir.Agent, fn -> [] end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.method do
        "GET" ->
          body = put_in(market_ship_body(ship, 0)["nav"], nav_body("IN_ORBIT"))
          Req.Test.json(conn, %{"data" => body})

        "POST" ->
          Elixir.Agent.update(game, &(&1 ++ [Path.basename(conn.request_path)]))

          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => %{"code" => 4214, "message" => "Ship is in transit"}})
      end
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    assert Elixir.Agent.get(game, & &1) == ["dock"]
    current = Repo.get!(Intent, intent.id)
    assert %Intent{status: "blocked", in_flight_action: nil} = current
    assert current.blocker.reason == "in_transit"

    assert [%{state: "rejected"} = attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.prepared_evidence["selected_action"]["kind"] == "dock"

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("obsolete callback replayed a rejected dock")
    end)

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id + 1)
    assert length(MutationAttempts.list_for_agent(agent)) == 1
  end

  defp market_ship_body(ship, units) do
    ship_body(ship.symbol, %{
      "nav" => nav_body("DOCKED"),
      "cargo" => %{
        "capacity" => 40,
        "units" => units,
        "inventory" => if(units == 0, do: [], else: [%{"symbol" => "IRON_ORE", "units" => units}])
      }
    })
  end

  test "composite refuel proof preserves exact Ship and credit sources across restart" do
    {agent, ship, portfolio, commitment} = claimed_ship("COMPOSITE-SOURCE")
    intent = owned_intent(ship, portfolio, commitment, [])

    {:ok, %{attempt: attempt}} =
      prepare_recorded(agent, intent, %{
        "kind" => "refuel",
        "waypoint" => "X1-UX81-A1",
        "fuel_before" => 150
      })

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      data =
        if conn.request_path == "/v2/my/agent",
          do: %{"symbol" => agent.symbol, "credits" => 1000},
          else: ship_body(ship.symbol, %{"fuel" => %{"current" => 200, "capacity" => 200}})

      Req.Test.json(conn, %{"data" => data})
    end)

    {:ok, ship_source} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, credit_source} = SpaceTraders.Evidence.get_agent(agent, bind: true)
    {:ok, _newer} = SpaceTraders.Evidence.get_agent_binding(agent)

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("exact-source restoration must not read the game")
    end)

    {:ok, ship_source} =
      SpaceTraders.Evidence.retained_ship_binding(agent, ship_source.observation.id)

    {:ok, restored_credits} =
      SpaceTraders.Evidence.retained_binding(agent, credit_source.observation.id)

    assert restored_credits == credit_source

    assert {:ok, proofs} =
             SpaceTraders.Evidence.recovery_proof(
               attempt,
               :accepted,
               "Fuel restored; authoritative credits retained",
               [ship_source, credit_source]
             )

    assert Enum.map(proofs, & &1.source.id) == [
             ship_source.observation.id,
             credit_source.observation.id
           ]

    assert Enum.map(proofs, & &1.observed_at) == [
             ship_source.observation.observed_at,
             credit_source.observation.observed_at
           ]

    assert {:ok, _} = MutationAttempts.reconcile(attempt, :accepted, proofs)
  end

  for kind <- ["refuel", "jump"] do
    test "#{kind} restart reuses usable credits when a newer retained acquisition is malformed" do
      {agent, ship, portfolio, commitment} = claimed_ship("REUSABLE-CREDIT-#{unquote(kind)}")
      intent = owned_intent(ship, portfolio, commitment, [])

      {:ok, %{attempt: attempt}} =
        prepare_recorded(agent, intent, %{
          "kind" => unquote(kind),
          "waypoint" => "X1-UX81-A1",
          "fuel_before" => 150,
          "credits_before" => 1000
        })

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 900}})
      end)

      {:ok, usable} = SpaceTraders.Evidence.get_agent_binding(agent)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol}})
      end)

      {:ok, malformed} = SpaceTraders.Evidence.get_agent_binding(agent)
      refute malformed.observation.id == usable.observation.id

      Req.Test.stub(SpaceTraders.API, fn _ ->
        flunk("usable retained credit facts must not be reacquired")
      end)

      assert {:ok, restored} = SpaceTraders.Evidence.recovery_agent_binding(agent, attempt)
      assert restored == usable
    end

    test "#{kind} Bounded Unknown retains exact composite proof and reconciles under Emergency Stop" do
      {agent, ship, portfolio, commitment} = claimed_ship("BOUNDED-CREDIT-#{unquote(kind)}")
      intent = owned_intent(ship, portfolio, commitment, [])

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, %{
          "kind" => unquote(kind),
          "waypoint" => "X1-UX81-A1",
          "fuel_before" => 150,
          "credits_before" => 1000
        })

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 900},
            else: ship_body(ship.symbol)

        Req.Test.json(conn, %{"data" => data})
      end)

      {:ok, ship_source} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, credits} = SpaceTraders.Evidence.get_agent_binding(agent)

      {:ok, proofs} =
        SpaceTraders.Evidence.recovery_proof(
          attempt,
          :bounded_unknown,
          "Controlled-game fixture bounds this historical request",
          [ship_source, credits]
        )

      # Ledger accounting fixture only: this is not a production worst-case price rule.
      {:ok, _} =
        MutationAttempts.reconcile(attempt, :bounded_unknown, proofs,
          constraint_accounting:
            SpaceTraders.Evidence.constraint_accounting(
              "fixture-only expenditure bound of 100 credits",
              []
            )
        )

      strategy = Repo.get_by!(Strategy, operator_id: agent.operator_id)
      Repo.update!(Ecto.Changeset.change(strategy, emergency_stopped_at: DateTime.utc_now()))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 900},
            else: ship_body(ship.symbol, %{"fuel" => %{"current" => 200, "capacity" => 200}})

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      accepted = MutationAttempts.get!(attempt.id)
      assert accepted.state == "accepted"
      assert Enum.map(accepted.outcomes, & &1.classification) == ["bounded_unknown", "accepted"]

      assert hd(accepted.outcomes).evidence["observations"] |> Enum.map(& &1["source"]["id"]) ==
               [ship_source.observation.id, credits.observation.id]

      assert length(MutationAttempts.list_for_agent(agent)) == 1
      refute accepted.retry_authorized
    end

    test "#{kind} composite proof reports partial expiry without acquiring or widening coverage" do
      {agent, ship, portfolio, commitment} = claimed_ship("PARTIAL-CREDIT-#{unquote(kind)}")
      intent = owned_intent(ship, portfolio, commitment, [])

      {:ok, %{attempt: attempt}} =
        prepare_recorded(agent, intent, %{
          "kind" => unquote(kind),
          "waypoint" => "X1-UX81-A1",
          "fuel_before" => 150,
          "credits_before" => 1000
        })

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      previous = Application.fetch_env(:spacetraders, :clock)
      start_supervised!({SpaceTraders.TestClock, DateTime.add(attempt.sent_or_unknown_at, 1)})
      Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
          :error -> Application.delete_env(:spacetraders, :clock)
        end
      end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 1000},
            else: ship_body(ship.symbol)

        Req.Test.json(conn, %{"data" => data})
      end)

      {:ok, old_ship} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      SpaceTraders.TestClock.advance(20)
      {:ok, credits} = SpaceTraders.Evidence.get_agent_binding(agent)
      SpaceTraders.TestClock.advance(11)

      Req.Test.stub(SpaceTraders.API, fn _ ->
        flunk("assembly must not acquire missing evidence")
      end)

      assert {:incomplete, %{usable: [^credits], unusable: [^old_ship], missing: [ship_key]}} =
               SpaceTraders.Evidence.recovery_proof(
                 attempt,
                 :absent,
                 "Fuel/navigation unchanged",
                 [old_ship, credits]
               )

      assert ship_key == SpaceTraders.SafetyFence.DependencyKey.ship(agent.id, ship.symbol)

      {:ok, restored} =
        SpaceTraders.Evidence.retained_binding(agent, credits.observation.id)

      assert restored.observation.observed_at == credits.observation.observed_at

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
      end)

      {:ok, fresh_ship} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

      {:ok, proofs} =
        SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Fuel/navigation unchanged", [
          fresh_ship,
          restored
        ])

      assert {:error, :authoritative_evidence_required} =
               MutationAttempts.reconcile(
                 attempt,
                 :absent,
                 Enum.map(proofs, &%{&1 | dependency_keys: attempt.dependency_keys})
               )

      assert {:error, :authoritative_evidence_required} =
               MutationAttempts.reconcile(
                 attempt,
                 :absent,
                 Enum.map(proofs, &%{&1 | source: nil})
               )

      assert {:ok, absent} = MutationAttempts.reconcile(attempt, :absent, proofs)
      assert absent.retry_authorized
    end

    test "#{kind} proven absence consumes only one retry through repeated boot and live wakes" do
      {agent, ship, portfolio, commitment} = claimed_ship("COMPOSITE-RETRY-#{unquote(kind)}")
      destination = if unquote(kind) == "jump", do: "X1-UX81-A2", else: "X1-UX81-A1"
      intent = owned_intent(ship, portfolio, commitment, target_waypoint: destination)

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, %{
          "kind" => unquote(kind),
          "waypoint" => destination,
          "fuel_before" => 150,
          "credits_before" => 1000
        })

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
      {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)
      on_exit(fn -> if Process.alive?(calls), do: Elixir.Agent.stop(calls) end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1000}})

          {"GET", _} ->
            sent = Elixir.Agent.get(calls, & &1) > 0
            nav = nav_body("DOCKED", destination: if(sent, do: destination, else: "X1-UX81-A1"))

            Req.Test.json(conn, %{
              "data" =>
                ship_body(ship.symbol, %{
                  "nav" => nav,
                  "fuel" => %{"current" => if(sent, do: 200, else: 150), "capacity" => 200}
                })
            })

          {"POST", _} ->
            Elixir.Agent.update(calls, &(&1 + 1))

            Req.Test.json(conn, %{
              "data" => %{
                "agent" => %{"symbol" => agent.symbol, "credits" => 900},
                "transaction" => %{
                  "type" => "PURCHASE",
                  "shipSymbol" => ship.symbol,
                  "tradeSymbol" => "FUEL",
                  "waypointSymbol" => "X1-UX81-A1",
                  "units" => 50,
                  "pricePerUnit" => 2,
                  "totalPrice" => 100
                },
                "cooldown" => %{
                  "shipSymbol" => ship.symbol,
                  "remainingSeconds" => 0,
                  "totalSeconds" => 0
                },
                "nav" => nav_body("DOCKED", destination: destination),
                "fuel" => %{"current" => 200, "capacity" => 200}
              }
            })
        end
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert Elixir.Agent.get(calls, & &1) == 1
      assert Repo.get!(Intent, intent.id).status == "completed"
      original = MutationAttempts.get!(attempt.id)
      assert original.state == "absent"
      refute original.retry_authorized

      assert Enum.count(MutationAttempts.list_for_agent(agent), &(&1.retry_of_id == attempt.id)) ==
               1

      proofs = List.last(original.outcomes).evidence["observations"]
      assert Enum.all?(proofs, &is_binary(&1["source"]["id"]))
    end

    test "#{kind} ledger rejects unretained composite conclusions for every recovery verdict" do
      {agent, ship, _portfolio, _commitment} = claimed_ship("UNBOUND-#{unquote(kind)}")
      operation = if unquote(kind) == "jump", do: "jump-ship", else: "refuel-ship"

      {:ok, attempt} =
        MutationAttempts.prepare(
          OperationInventory.fetch!(operation),
          "/my/ships/#{ship.symbol}/#{unquote(kind)}",
          agent_id: agent.id
        )

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      for verdict <- [:accepted, :absent, :bounded_unknown] do
        forged =
          SpaceTraders.Evidence.reconciliation_observation(
            "get-my-ship",
            attempt,
            verdict,
            "Caller claims fuel/navigation and credits without retained observations"
          )

        opts =
          if verdict == :bounded_unknown,
            do: [
              constraint_accounting:
                SpaceTraders.Evidence.constraint_accounting("one historical effect", [])
            ],
            else: []

        assert {:error, :authoritative_evidence_required} =
                 MutationAttempts.reconcile(attempt, verdict, [forged], opts)
      end

      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    end

    test "#{kind} recovery retains the supplied exact Ship source and retained credits" do
      {agent, ship, portfolio, commitment} = claimed_ship("COMPOSITE-#{unquote(kind)}")
      intent = owned_intent(ship, portfolio, commitment, [])

      action = %{
        "kind" => unquote(kind),
        "waypoint" => "X1-UX81-A1",
        "fuel_before" => 150,
        "credits_before" => 1000
      }

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, action)

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 900},
            else: ship_body(ship.symbol, %{"fuel" => %{"current" => 200, "capacity" => 200}})

        Req.Test.json(conn, %{"data" => data})
      end)

      {:ok, original} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, credits} = SpaceTraders.Evidence.get_agent(agent, bind: true)
      {:ok, _replacement} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

      Req.Test.stub(SpaceTraders.API, fn _ ->
        flunk("eligible retained components must be reused")
      end)

      _ =
        Intents.reconcile(
          agent.id,
          ship.symbol,
          SpaceTraders.Evidence.bound_ship(original),
          :boot,
          intent.id
        )

      accepted = MutationAttempts.get!(attempt.id)
      assert accepted.state == "accepted"
      proofs = List.last(accepted.outcomes).evidence["observations"]

      assert Enum.map(proofs, & &1["source"]["id"]) == [
               original.observation.id,
               credits.observation.id
             ]

      assert Repo.get!(Intent, intent.id).status == "completed"
    end

    test "#{kind} recovery cannot settle a retained Ship when credit retention fails" do
      {agent, ship, portfolio, commitment} = claimed_ship("CREDIT-GAP-#{unquote(kind)}")
      intent = owned_intent(ship, portfolio, commitment, [])

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(agent, intent, %{
          "kind" => unquote(kind),
          "waypoint" => "X1-UX81-A1",
          "fuel_before" => 150,
          "credits_before" => 1000
        })

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Repo.query!(
        "ALTER TABLE authoritative_observations ADD CONSTRAINT credit_retention_gap CHECK (operation_id <> 'get-my-agent') NOT VALID"
      )

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 900},
            else: ship_body(ship.symbol, %{"fuel" => %{"current" => 200, "capacity" => 200}})

        Req.Test.json(conn, %{"data" => data})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
      assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
    end
  end

  test "recovery keeps the exact retained Ship source when identical newer facts replace latest" do
    {agent, ship, portfolio, commitment} = claimed_ship("EXACT-SOURCE")
    {_intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    {:ok, binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    original = binding.observation
    {:ok, newer} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    refute newer.observation.id == original.id
    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("restart reuse acquired replacement facts") end)
    {:ok, binding} = SpaceTraders.Evidence.retained_ship_binding(agent, original.id)

    assert {:ok, [proof]} =
             SpaceTraders.Evidence.recovery_proof(
               attempt,
               :accepted,
               "Ship is in orbit",
               [binding]
             )

    assert proof.source.id == original.id
    assert proof.observed_at == original.observed_at
    assert {:ok, accepted} = MutationAttempts.reconcile(attempt, :accepted, [proof])

    assert List.last(accepted.outcomes).evidence["observations"]
           |> hd()
           |> Map.fetch!("source")
           |> Map.fetch!("id") == original.id
  end

  test "final ledger validation rejects stripped or falsely widened retained sources" do
    {agent, ship, portfolio, commitment} = claimed_ship("FALSE-SOURCE")
    {_intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    {:ok, binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    {:ok, [proof]} =
      SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "In orbit", [binding])

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, [%{proof | source: nil}])

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, [
               %{proof | dependency_keys: attempt.dependency_keys ++ ["fake"]}
             ])

    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "navigation ledger invariants require retained evidence even without selection metadata" do
    {agent, ship, _portfolio, _commitment} = claimed_ship("LEDGER-SOURCE")

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("orbit-ship"),
        "/my/ships/#{ship.symbol}/orbit",
        agent_id: agent.id
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    forged =
      SpaceTraders.Evidence.reconciliation_observation(
        "get-my-ship",
        attempt,
        :accepted,
        "Caller asserts orbit without retention"
      )

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, [forged])

    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "final validation uses durable dependency scope rather than a caller's attempt snapshot" do
    {agent, ship, portfolio, commitment} = claimed_ship("DURABLE-SCOPE")
    {_intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    other_symbol = "OTHER-SOURCE-SHIP"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => ship_body(other_symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    {:ok, other} = SpaceTraders.Evidence.get_ship_binding(agent, other_symbol)

    forged = %{
      attempt
      | dependency_keys: [SpaceTraders.SafetyFence.DependencyKey.ship(agent.id, other_symbol)]
    }

    {:ok, proof} =
      SpaceTraders.Evidence.recovery_proof(forged, :accepted, "Other Ship is in orbit", [other])

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(forged, :accepted, proof)

    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  test "unretained Ship facts cannot resolve recovery or release its Safety Fence" do
    {agent, ship, portfolio, commitment} = claimed_ship("RETENTION-GAP")
    {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    # Fail the real retention write, while the governed game read still succeeds.
    Repo.query!(
      "ALTER TABLE authoritative_observations ADD CONSTRAINT retention_gap CHECK (subject <> 'ship:#{ship.symbol}')"
    )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    assert {:error, :evidence_not_retained} =
             SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
  end

  test "partial expiry preserves usable exact bindings without reads and a newer source cannot restamp age" do
    {agent, ship, portfolio, commitment} = claimed_ship("PARTIAL-BINDING")
    {_intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    now = DateTime.add(attempt.sent_or_unknown_at, 1, :second)
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({SpaceTraders.TestClock, now})
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    {:ok, original} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    {:ok, original_proof} =
      SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "In orbit", [original])

    SpaceTraders.TestClock.advance(31)
    {:ok, replacement} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("proof assembly acquired hidden evidence") end)

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, original_proof)

    assert {:incomplete, %{usable: [^replacement], unusable: [^original]}} =
             SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "In orbit", [
               original,
               replacement
             ])

    assert {:incomplete, %{missing: missing}} =
             SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "In orbit", [original])

    assert missing == attempt.dependency_keys

    assert {:ok, [proof]} =
             SpaceTraders.Evidence.recovery_proof(attempt, :accepted, "In orbit", [replacement])

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :accepted, [
               %{proof | source: original.observation}
             ])

    assert {:ok, _} = MutationAttempts.reconcile(attempt, :accepted, [proof])
  end

  test "exact evidence rejects wrong Generation, pre-dispatch and future acquisitions" do
    {agent, ship, portfolio, commitment} = claimed_ship("SCOPED-BINDING")
    {_intent, prepared} = selected_orbit(agent, ship, portfolio, commitment)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
    end)

    {:ok, before_send} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    {:ok, before_send_proof} =
      SpaceTraders.Evidence.recovery_proof(prepared, :absent, "Still docked", [before_send])

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(prepared)

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :absent, before_send_proof)

    assert {:incomplete, _} =
             SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Still docked", [before_send])

    {:ok, binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

    {:ok, valid_proof} =
      SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Still docked", [binding])

    wrong_generation = %{attempt | fleet_generation_id: attempt.fleet_generation_id + 1}

    assert {:incomplete, _} =
             SpaceTraders.Evidence.recovery_proof(wrong_generation, :absent, "Still docked", [
               binding
             ])

    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({SpaceTraders.TestClock, DateTime.add(binding.observation.observed_at, -1)})
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    assert {:incomplete, _} =
             SpaceTraders.Evidence.recovery_proof(attempt, :absent, "Still docked", [binding])

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(attempt, :absent, valid_proof)

    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
  end

  for trigger <- [:boot, :arrival, :cooldown, :intent_retry] do
    test "#{trigger} preserves the original bound source through replacement and recovery re-entry" do
      {agent, ship, portfolio, commitment} = claimed_ship("BOUND-#{unquote(trigger)}")
      {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
      end)

      {:ok, original} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, _newer} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      _ = Intents.reconcile(agent.id, ship.symbol, original, unquote(trigger), intent.id)
      accepted = MutationAttempts.get!(attempt.id)
      assert accepted.state == "accepted"

      assert get_in(List.last(accepted.outcomes).evidence, [
               "observations",
               Access.at(0),
               "source",
               "id"
             ]) == original.observation.id

      assert Repo.get!(Intent, intent.id).status == "completed"
    end

    test "#{trigger} rejects a malformed owned read without resolving or clearing selected evidence" do
      {agent, ship, portfolio, commitment} = claimed_ship("INVALID-#{unquote(trigger)}")
      {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        Req.Test.json(conn, %{"data" => %{"symbol" => ship.symbol, "nav" => nav_body("IN_ORBIT")}})
      end)

      supplied =
        ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")}) |> Model.Ship.from_json()

      _ = Intents.reconcile(agent.id, ship.symbol, supplied, unquote(trigger), intent.id)

      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
      retained = Repo.get!(Intent, intent.id)
      assert retained.status == "blocked"
      assert retained.in_flight_action == intent.in_flight_action
      assert retained.mutation_attempt_id == attempt.id
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    end
  end

  test "prepared work resumes its original attempt; sent work is observed without duplicate dispatch" do
    {agent, ship, portfolio, commitment} = claimed_ship("PREPARED-RECOVERY")
    {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    game = start_supervised!({Elixir.Agent, fn -> %{status: "DOCKED", calls: 0} end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body(Elixir.Agent.get(game, & &1.status))
              })
          })

        "POST" ->
          Elixir.Agent.update(game, &%{status: "IN_ORBIT", calls: &1.calls + 1})
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
      end
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "succeeded"
    assert Repo.get!(Intent, intent.id).status == "completed"
    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert Elixir.Agent.get(game, & &1.calls) == 1
    assert [only] = MutationAttempts.list_for_agent(agent)
    assert only.id == attempt.id
  end

  test "a crash after absence classification consumes retry authority exactly once" do
    {agent, ship, portfolio, commitment} = claimed_ship("ABSENT-RECOVERY")
    {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    {:ok, _} =
      MutationAttempts.reconcile(attempt, :absent, [
        retained_ship_proof(agent, ship, attempt, :absent, "Authoritative Ship remains docked")
      ])

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.method do
        "GET" -> Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
        "POST" -> Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
      end
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert [original, retry] = MutationAttempts.list_for_agent(agent)
    assert original.id == attempt.id
    refute original.retry_authorized
    assert retry.retry_of_id == original.id
    assert retry.state == "succeeded"
  end

  test "an obsolete callback cannot clear a newer retry of the same selection" do
    {agent, ship, portfolio, commitment} = claimed_ship("STALE-RETRY-CALLBACK")
    {selected, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    proof = retained_ship_proof(agent, ship, attempt, :absent, "Ship remains docked")
    {:ok, absent} = MutationAttempts.reconcile(attempt, :absent, [proof])

    {:ok, retry} =
      SpaceTraders.Fleet.Intents.RecordedAction.prepare_retry(agent, selected, absent)

    assert :intent_no_longer_owned = Intents.transition_intent(selected, in_flight_action: nil)
    current = Repo.get!(Intent, selected.id)
    assert current.in_flight_action == selected.in_flight_action
    assert current.mutation_attempt_id == retry.id
    assert MutationAttempts.get!(retry.id).state == "prepared"
  end

  test "legacy refuel without an attempt retains historical evidence and shared credit protection" do
    {agent, ship, portfolio, commitment} = claimed_ship("LEGACY-RECOVERY")
    action = %{"kind" => "refuel", "waypoint" => "X1-UX81-A1", "fuel_before" => 150}
    intent = owned_intent(ship, portfolio, commitment, in_flight_action: action)
    original_result = %{"reason" => "response lost before upgrade"}
    intent = Repo.update!(Ecto.Changeset.change(intent, last_action_result: original_result))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1000}})

        _ ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
      end
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    retained = Repo.get!(Intent, intent.id)
    assert retained.status == "blocked"
    assert retained.in_flight_action == action
    assert retained.last_action_result == original_result
    attempt = MutationAttempts.get!(retained.mutation_attempt_id)
    assert attempt.state == "ambiguous"
    assert is_nil(attempt.sent_or_unknown_at)
    refute attempt.retry_authorized
    assert attempt.prepared_evidence["legacy_unknown"]["last_action_result"] == original_result

    assert [blocking] =
             SpaceTraders.SafetyFence.blocking_attempts([
               SpaceTraders.SafetyFence.DependencyKey.agent_credits(agent.id)
             ])

    assert blocking.id == attempt.id

    assert [] ==
             SpaceTraders.SafetyFence.blocking_attempts([
               SpaceTraders.SafetyFence.DependencyKey.ship(agent.id, "INDEPENDENT-SHIP")
             ])
  end

  test "accepted legacy posture resolves through authoritative facts without replay" do
    {agent, ship, portfolio, commitment} = claimed_ship("LEGACY-ACCEPTED")

    intent =
      owned_intent(ship, portfolio, commitment,
        in_flight_action: %{"kind" => "orbit", "waypoint" => "X1-UX81-A1"}
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert Repo.get!(Intent, intent.id).status == "completed"
    assert [%{state: "accepted"} = attempt] = MutationAttempts.list_for_agent(agent)
    assert Enum.map(attempt.outcomes, & &1.classification) == ["ambiguous", "accepted"]
  end

  test "a stale event identity cannot even adopt or read replacement work" do
    {agent, ship, portfolio, commitment} = claimed_ship("STALE-RECOVERY")

    intent =
      owned_intent(ship, portfolio, commitment,
        in_flight_action: %{"kind" => "orbit", "waypoint" => "X1-UX81-A1"}
      )

    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("stale event reached evidence acquisition") end)
    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id + 1)
    assert Repo.get!(Intent, intent.id) == intent
    assert [] == MutationAttempts.list_for_agent(agent)
  end

  test "legacy survey cooldown is not fabricated into historical send evidence" do
    {agent, ship, portfolio, commitment} = claimed_ship("LEGACY-SURVEY")

    intent =
      owned_intent(ship, portfolio, commitment,
        type: "acquire_resources",
        in_flight_action: %{"kind" => "survey"}
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" =>
          ship_body(ship.symbol, %{
            "cooldown" => %{
              "shipSymbol" => ship.symbol,
              "totalSeconds" => 60,
              "remainingSeconds" => 60,
              "expiration" => future_iso()
            }
          })
      })
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    retained = Repo.get!(Intent, intent.id)
    assert retained.status == "blocked"
    assert retained.in_flight_action == intent.in_flight_action
    attempt = MutationAttempts.get!(retained.mutation_attempt_id)
    assert attempt.state == "ambiguous"
    assert attempt.sent_or_unknown_at == nil
  end

  # Refuel and jump spending needs an explicit bound and a retained quote.
  defp prepare_recorded(agent, intent, %{"kind" => kind} = action)
       when kind in ["refuel", "jump"] do
    action =
      Map.merge(
        if(kind == "jump", do: %{"source_waypoint" => "X1-UX81-A1"}, else: %{"units" => 50}),
        action
      )

    SpaceTraders.RecordedDispatchFixtures.retain_purchase_preflight(
      agent,
      intent.target_waypoint,
      action
    )

    SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)
  end

  defp prepare_recorded(agent, intent, %{"kind" => kind} = action)
       when kind in ["install_module", "remove_module"] do
    action = Map.put_new(action, "waypoint", intent.target_waypoint)

    SpaceTraders.RecordedDispatchFixtures.retain_modification_preflight(
      agent,
      action["waypoint"]
    )

    SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)
  end

  defp prepare_recorded(agent, intent, action),
    do: SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)

  defp owned_intent(ship, portfolio, commitment, attrs) do
    intent =
      Repo.insert!(
        struct(
          Intent,
          [
            ship_id: ship.id,
            caller: "commitment",
            fleet_commitment_id: commitment.id,
            fleet_commitment_portfolio_id: portfolio.id,
            fleet_commitment_portfolio_version: portfolio.version,
            type: "navigate",
            target_waypoint: "X1-UX81-A1"
          ] ++ attrs
        )
      )

    if intent.type == "buy" do
      agent = Repo.get!(SpaceTraders.Agent.Agent, ship.agent_id)

      SpaceTraders.RecordedDispatchFixtures.retain_purchase_preflight(
        agent,
        intent.target_waypoint,
        %{
          "trade_symbol" => intent.parameters["trade_symbol"] || "IRON_ORE",
          "units" => intent.parameters["units"] || 5,
          "listing_price" => 10,
          "credits_before" => 1000
        }
      )
    end

    intent
  end

  test "a legacy action with missing recipient parameters protects dependencies before new admission" do
    {agent, ship, portfolio, commitment} = claimed_ship("LEGACY-INCOMPLETE")
    action = %{"kind" => "deliver", "trade_symbol" => "IRON_ORE", "units" => 1}
    intent = owned_intent(ship, portfolio, commitment, type: "deliver", in_flight_action: action)

    assert {:error, {:safety_fenced, [id]}} =
             MutationAttempts.prepare(
               OperationInventory.fetch!("purchase-cargo"),
               "/my/ships/OTHER-SHIP/purchase",
               agent_id: agent.id,
               json: %{"symbol" => "FUEL", "units" => 1}
             )

    attempt = MutationAttempts.get!(id)
    assert attempt.operation_id == "historical-ship-action"
    assert attempt.state == "ambiguous"
    assert attempt.prepared_evidence["selected_action"] == action
    assert Repo.get!(Intent, intent.id).in_flight_action == action
    assert attempt.sent_or_unknown_at == nil
  end

  for fuel <- [150, 200] do
    test "malformed credits cannot settle refuel with #{fuel} fuel or release its shared fence" do
      {agent, ship, portfolio, commitment} = claimed_ship("MALFORMED-CREDITS")
      intent = owned_intent(ship, portfolio, commitment, [])

      {:ok, %{intent: intent, attempt: attempt}} =
        prepare_recorded(
          agent,
          intent,
          %{"kind" => "refuel", "waypoint" => "X1-UX81-A1", "fuel_before" => 150}
        )

      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        if conn.request_path == "/v2/my/agent" do
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol}})
        else
          Req.Test.json(conn, %{
            "data" =>
              ship_body(
                ship.symbol,
                %{"fuel" => %{"current" => unquote(fuel), "capacity" => 200}}
              )
          })
        end
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      assert Repo.get!(Intent, intent.id).status == "blocked"
      assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
      assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    end
  end

  test "persisted absence does not dispatch a retry when restart evidence already satisfies the outcome" do
    {agent, ship, portfolio, commitment} = claimed_ship("SATISFIED-ABSENCE")
    {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    {:ok, _} =
      MutationAttempts.reconcile(attempt, :absent, [
        retained_ship_proof(agent, ship, attempt, :absent, "Ship remains docked")
      ])

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    original = MutationAttempts.get!(attempt.id)
    assert original.state == "absent"
    refute original.retry_authorized
    assert List.last(original.outcomes).classification == "absent"

    assert List.last(original.outcomes).evidence["retry_disposition"] ==
             "selected_outcome_satisfied"

    assert Repo.get!(Intent, intent.id).status == "completed"
    assert length(MutationAttempts.list_for_agent(agent)) == 1
  end

  test "a Ship observation expiring during dependent acquisition is not restamped fresh" do
    {agent, ship, portfolio, commitment} = claimed_ship("EXPIRED-DEPENDENCY")
    intent = owned_intent(ship, portfolio, commitment, [])

    {:ok, %{intent: intent, attempt: attempt}} =
      prepare_recorded(
        agent,
        intent,
        %{"kind" => "refuel", "fuel_before" => 150, "waypoint" => "X1-UX81-A1"}
      )

    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      if conn.request_path == "/v2/my/agent" do
        observation = SpaceTraders.Evidence.latest_observation(agent, "ship:#{ship.symbol}")

        Repo.update!(
          Ecto.Changeset.change(observation, observed_at: DateTime.add(DateTime.utc_now(), -31))
        )

        Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 1000}})
      else
        Req.Test.json(conn, %{
          "data" =>
            ship_body(
              ship.symbol,
              %{"fuel" => %{"current" => 200, "capacity" => 200}}
            )
        })
      end
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert Repo.get!(Intent, intent.id).status == "blocked"
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
  end

  test "changed authority suppresses prepared recovery durably before transport" do
    {agent, ship, portfolio, commitment} = claimed_ship("CHANGED-AUTHORITY")
    {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    strategy = Repo.get_by!(Strategy, operator_id: agent.operator_id)
    Repo.update!(Ecto.Changeset.change(strategy, emergency_stopped_at: DateTime.utc_now()))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(attempt.id)
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
  end

  test "runtime re-entry can resolve Bounded Unknown while retaining its original accounting" do
    {agent, ship, portfolio, commitment} = claimed_ship("BOUNDED-RUNTIME")
    {intent, attempt} = selected_orbit(agent, ship, portfolio, commitment)
    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    {:ok, _} =
      MutationAttempts.reconcile(
        attempt,
        :bounded_unknown,
        [
          retained_ship_proof(
            agent,
            ship,
            attempt,
            :bounded_unknown,
            "At most one posture change"
          )
        ],
        constraint_accounting:
          SpaceTraders.Evidence.constraint_accounting("at most one posture change", [])
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    accepted = MutationAttempts.get!(attempt.id)
    assert accepted.state == "accepted"
    assert Enum.map(accepted.outcomes, & &1.classification) == ["bounded_unknown", "accepted"]

    assert hd(accepted.outcomes).evidence["constraint_accounting"]["consequence_bound"] ==
             "at most one posture change"

    assert Repo.get!(Intent, intent.id).status == "completed"
  end

  defp selected_orbit(agent, ship, portfolio, commitment) do
    intent = owned_intent(ship, portfolio, commitment, [])

    {:ok, %{intent: intent, attempt: attempt}} =
      prepare_recorded(agent, intent, %{
        "kind" => "orbit",
        "waypoint" => "X1-UX81-A1"
      })

    {intent, attempt}
  end

  defp selected_intelligence(agent, ship, portfolio, commitment, kind, prepare? \\ true) do
    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "acquire_intelligence",
        target_waypoint: "X1-UX81-A1",
        parameters: %{
          "system" => "X1-UX81",
          "subject_type" => "waypoint",
          "required_facts" => [if(kind == "chart", do: "chart", else: "traits")],
          "freshness_seconds" => 300
        }
      })

    if prepare? do
      {:ok, %{intent: selected, attempt: attempt}} =
        prepare_recorded(agent, intent, %{
          "kind" => kind,
          "waypoint" => intent.target_waypoint
        })

      {selected, attempt}
    else
      {intent, nil}
    end
  end

  defp retained_scan_ship(agent, ship) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
  end

  defp chart_waypoint(submitted_by, submitted_on) do
    %{
      "symbol" => "X1-UX81-A1",
      "systemSymbol" => "X1-UX81",
      "type" => "PLANET",
      "traits" => [],
      "chart" => %{
        "waypointSymbol" => "X1-UX81-A1",
        "submittedBy" => submitted_by,
        "submittedOn" => submitted_on
      }
    }
  end

  # Synchronize the two callers before releasing transport; source identity and
  # time are asserted only through the public Evidence binding result.
  defp wait_for_coalesced_read(pid) do
    pending = :sys.get_state(SpaceTraders.Evidence.ReadCoordinator).pending

    if Enum.any?(pending, fn {_key, entry} -> pid in entry.waiters end) do
      :ok
    else
      receive do
      after
        1 -> wait_for_coalesced_read(pid)
      end
    end
  end

  defp retained_ship_proof(agent, ship, attempt, outcome, basis) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})
    end)

    {:ok, binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, [proof]} = SpaceTraders.Evidence.recovery_proof(attempt, outcome, basis, [binding])
    proof
  end

  test "Intent lifecycle transitions keep their correlation identifier" do
    {_agent, ship, _portfolio, _commitment} = claimed_ship("OWNED-TELEMETRY")

    intent =
      Repo.insert!(%Intent{ship_id: ship.id, caller: "commitment", target_waypoint: "X1-UX81-A2"})

    handler = "owned-transition-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :intent, :transition],
        &__MODULE__.handle_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, updated} = Intents.transition_intent(intent, status: "waiting")
    assert_receive {:telemetry, [:spacetraders, :intent, :transition], %{count: 1}, metadata}
    assert metadata.intent_id == intent.id
    assert metadata.ship_id == ship.id
    assert metadata.from_state == "active"
    assert metadata.to_state == "waiting"

    assert {:ok, _} = Intents.transition_intent(updated, recovery_attempts: 1)
    refute_receive {:telemetry, [:spacetraders, :intent, :transition], _, _}
  end

  test "current and historical Intents remain scoped to their Agent" do
    {first, ship, _portfolio, _commitment} = claimed_ship("OWNED-HISTORY")
    {other, other_ship, _other_portfolio, _other_commitment} = claimed_ship("OTHER-HISTORY")

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      target_waypoint: "X1-UX81-A1",
      status: "waiting"
    })

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      target_waypoint: "X1-UX81-A2",
      status: "completed"
    })

    Repo.insert!(%Intent{
      ship_id: other_ship.id,
      caller: "commitment",
      target_waypoint: "X1-UX81-A3",
      status: "active"
    })

    assert [%Intent{status: "waiting"}] = Intents.current(first)
    assert [%Intent{status: "completed"}] = Intents.history(first)
    assert [%Intent{status: "active"}] = Intents.current(other)
  end

  test "boot recovers a commitment wait without reading a Job or replaying navigation" do
    {agent, ship, portfolio, commitment} = claimed_ship("OWNED-BOOT")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"}
      })

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("navigate-ship"),
        "/my/ships/#{ship.symbol}/navigate",
        agent_id: agent.id,
        json: %{"waypointSymbol" => "X1-UX81-A2"}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    test_pid = self()
    Req.Test.set_req_test_to_shared(SpaceTraders.API)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/ships/#{ship.symbol}"}
      send(test_pid, :observed)

      Req.Test.json(conn, %{
        "data" =>
          ship_body(ship.symbol, %{
            "nav" =>
              nav_body("IN_TRANSIT",
                arrival: future_iso(),
                destination: "X1-UX81-A2"
              )
          })
      })
    end)

    handler = "owned-boot-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :repo, :query],
        &__MODULE__.handle_event/4,
        self()
      )

    assert [ship.symbol] == Intents.rearm_owned_intents_on_boot()
    :ok = :telemetry.detach(handler)
    assert_no_job_query()

    assert_receive :observed
    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)

    assert [%Event{payload: %{"intent_id" => intent_id}}] =
             Timeline.pending_events(:ship, ship.symbol)

    assert intent_id == intent.id
  end

  test "a commitment-owned recovery retries after an authoritative read failure" do
    {agent, ship, _portfolio, commitment} = claimed_ship("OWNED-RETRY")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"}
      })

    {:ok, calls} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/ships/#{ship.symbol}"}

      if Elixir.Agent.get_and_update(calls, &{&1, &1 + 1}) == 0 do
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{"code" => 4001, "message" => "temporary recovery failure"}
        })
      else
        Req.Test.json(conn, %{
          "data" =>
            ship_body(ship.symbol, %{
              "nav" => nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
            })
        })
      end
    end)

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert Elixir.Agent.get(calls, & &1) == 2
    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)

    assert [
             %Activity{
               kind: "owned_intent_recovery",
               message: "Authoritative recovery read failed; retrying"
             }
           ] =
             Enum.filter(Repo.all(Activity), &(&1.kind == "owned_intent_recovery"))
  end

  test "a late commitment wake cannot resume legacy Job execution" do
    {agent, ship, _portfolio, _commitment} = claimed_ship("OWNED-LATE")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "completed"
      })

    handler = "owned-late-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :repo, :query],
        &__MODULE__.handle_event/4,
        self()
      )

    assert :ok =
             Intents.reconcile(
               agent.id,
               ship.symbol,
               ship_body(ship.symbol) |> Model.Ship.from_json(),
               :arrival,
               intent.id
             )

    :ok = :telemetry.detach(handler)
    assert_no_job_query()
  end

  test "a claimed Ship completes a governed buy and sell without a Job" do
    {agent, ship, portfolio, commitment} = claimed_ship("OWNED-TRADE")
    {:ok, purchased} = Elixir.Agent.start_link(fn -> false end)
    ship_path = "/v2/my/ships/#{ship.symbol}"
    purchase_path = ship_path <> "/purchase"
    sell_path = ship_path <> "/sell"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          cargo =
            if Elixir.Agent.get(purchased, & &1),
              do: %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              else: %{"capacity" => 40, "units" => 0, "inventory" => []}

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav_body("DOCKED"), "cargo" => cargo})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "purchasePrice" => 10,
                  "sellPrice" => 20,
                  "tradeVolume" => 5
                }
              ]
            }
          })

        {"POST", ^purchase_path} ->
          Elixir.Agent.update(purchased, fn _ -> true end)
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "PURCHASE", 10, 50, 5)})

        {"POST", ^sell_path} ->
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "SELL", 20, 150, 0)})

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    candidate = %{
      trade_symbol: "IRON_ORE",
      units: 5,
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A1",
      purchase_price: 10,
      sell_price: 20
    }

    assert {:ok, %Intent{type: "buy", status: "completed"} = buy} =
             Intents.request_commitment_round_trip(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               candidate
             )

    assert {:ok, %Intent{type: "sell", status: "completed"} = sell} =
             SpaceTraders.FleetExecution.continue_after_intent(agent, commitment, portfolio, buy)

    assert sell.fleet_commitment_id == commitment.id
    assert [%Intent{type: "sell"}, %Intent{type: "buy"}] = Intents.history(agent)
  end

  test "boot and arrival continue an owned trade exactly once" do
    {agent, ship, portfolio, commitment} = claimed_ship("OWNED-RESTART")
    {:ok, calls} = Elixir.Agent.start_link(fn -> %{buy: 0, sell: 0, arrived: false} end)
    ship_path = "/v2/my/ships/#{ship.symbol}"
    purchase_path = ship_path <> "/purchase"
    sell_path = ship_path <> "/sell"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          state = Elixir.Agent.get(calls, & &1)

          nav =
            if state.arrived,
              do: nav_body("DOCKED"),
              else: nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A1")

          cargo =
            if state.buy > 0,
              do: %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              else: %{"capacity" => 40, "units" => 0, "inventory" => []}

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav, "cargo" => cargo})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "purchasePrice" => 10,
                  "sellPrice" => 20,
                  "tradeVolume" => 5
                }
              ]
            }
          })

        {"POST", ^purchase_path} ->
          Elixir.Agent.update(calls, &Map.update!(&1, :buy, fn count -> count + 1 end))
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "PURCHASE", 10, 50, 5)})

        {"POST", ^sell_path} ->
          Elixir.Agent.update(calls, &Map.update!(&1, :sell, fn count -> count + 1 end))
          Req.Test.json(conn, %{"data" => trade_response(agent, ship, "SELL", 20, 150, 0)})

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    candidate = %{
      trade_symbol: "IRON_ORE",
      units: 5,
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-A1",
      purchase_price: 10,
      sell_price: 20
    }

    buy =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "buy",
        target_waypoint: "X1-UX81-A1",
        status: "waiting",
        parameters: %{
          "trade_symbol" => "IRON_ORE",
          "units" => 5,
          "max_price" => 10,
          "reserve_credits" => 0,
          "market_trade" => candidate
        },
        in_flight_action: %{
          "kind" => "navigate",
          "waypoint" => "X1-UX81-A1",
          "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A1"}
        }
      })

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("navigate-ship"),
        "/my/ships/#{ship.symbol}/navigate",
        agent_id: agent.id,
        json: %{"waypointSymbol" => "X1-UX81-A1"}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    SpaceTraders.Quiesced.stop_ship(ship.symbol)

    assert :ok = Intents.rearm_on_boot()
    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert Repo.get!(Intent, buy.id).status == "waiting"
    assert Elixir.Agent.get(calls, &{&1.buy, &1.sell}) == {0, 0}

    Elixir.Agent.update(calls, &%{&1 | arrived: true})

    live_ship =
      ship_body(ship.symbol, %{
        "nav" => nav_body("DOCKED"),
        "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
      })
      |> Model.Ship.from_json()

    assert {:ok, %Intent{type: "sell", status: "completed"}} =
             Intents.reconcile(agent.id, ship.symbol, live_ship, :arrival, buy.id)

    assert %Intent{status: "completed"} = Repo.get!(Intent, buy.id)
    assert [%Intent{type: "sell", status: "completed"} = sell | _] = Intents.history(agent)
    assert Elixir.Agent.get(calls, &{&1.buy, &1.sell}) == {1, 1}

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, buy.id)
    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, buy.id)
    assert Repo.get!(Intent, sell.id).status == "completed"
    assert Elixir.Agent.get(calls, &{&1.buy, &1.sell}) == {1, 1}
  end

  defp trade_response(agent, ship, kind, price, credits, cargo_units) do
    %{
      "agent" => %{"symbol" => agent.symbol, "credits" => credits},
      "cargo" => %{
        "capacity" => 40,
        "units" => cargo_units,
        "inventory" =>
          if(cargo_units == 0, do: [], else: [%{"symbol" => "IRON_ORE", "units" => cargo_units}])
      },
      "transaction" => %{
        "type" => kind,
        "shipSymbol" => ship.symbol,
        "tradeSymbol" => "IRON_ORE",
        "waypointSymbol" => "X1-UX81-A1",
        "units" => 5,
        "pricePerUnit" => price,
        "totalPrice" => price * 5
      }
    }
  end

  def handle_event(event, measurements, metadata, pid),
    do: send(pid, {:telemetry, event, measurements, metadata})

  defp assert_no_job_query do
    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:telemetry, [:spacetraders, :repo, :query], _, %{query: query}} ->
               String.contains?(query, ~s("jobs"))

             _ ->
               false
           end)
  end

  defp future_iso, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

  defp claimed_ship(symbol) do
    operator = Repo.insert!(%Operator{email: "#{symbol}@example.com"})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: symbol,
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN",
        operator_id: operator.id
      })

    ship =
      Repo.insert!(%Ship{symbol: "#{symbol}-SHIP", ship_type: "SHIP_PROBE", agent_id: agent.id})

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => [%{"objective" => "Exercise Ship Execution"}]},
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

    candidate = %PortfolioCandidate{
      id: "ship-execution-#{symbol}",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: [ship.symbol],
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(operator),
        generation.id,
        selection,
        %{evidence_references: [], expectations: %{}, calibration_version: "owned-recovery-v1"}
      )

    [commitment] = portfolio.commitments
    {agent, ship, portfolio, commitment}
  end
end
