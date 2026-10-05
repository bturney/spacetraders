defmodule SpaceTraders.ResourceRecoveryTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RecordedDispatchFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.{Intent, Intents, ShipServer}
  alias SpaceTraders.MutationAttempts

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  test "failed resource observation retention leaves the selected mutation and narrow fence unresolved" do
    {agent, ship, intent, attempt} = selected_resource("extract")
    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Repo.query!(
      "ALTER TABLE authoritative_observations ADD CONSTRAINT resource_retention_gap CHECK (subject <> 'ship:#{ship.symbol}')"
    )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => resource_ship(ship.symbol, "extract")})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :cooldown, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
    assert Repo.get!(Intent, intent.id).blocker.evidence =~ "evidence_not_retained"
  end

  test "unchanged resource Cargo never manufactures absence or blind retry" do
    {agent, ship, intent, attempt} = selected_resource("extract")
    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"

      Req.Test.json(conn, %{
        "data" => ship_body(ship.symbol, %{"cargo" => intent.in_flight_action["cargo_before"]})
      })
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "sent_or_unknown"
    assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    assert Repo.get!(Intent, intent.id).in_flight_action == intent.in_flight_action
  end

  for kind <- ["extract", "survey"] do
    test "#{kind} unchanged Ship blocks as unprovable absence without sending" do
      {agent, ship, intent, attempt} = selected_resource(unquote(kind))
      {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        Req.Test.json(conn, %{
          "data" => ship_body(ship.symbol, %{"cargo" => intent.in_flight_action["cargo_before"]})
        })
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      current = Repo.get!(Intent, intent.id)
      assert current.status == "blocked"
      assert current.blocker.evidence =~ ~s({:absence_unprovable, "#{unquote(kind)}"})
      assert current.in_flight_action == intent.in_flight_action
      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
      assert [_only] = MutationAttempts.list_for_agent(agent)
    end
  end

  test "legacy jettison without a send marker cannot turn a Cargo decrement into attribution" do
    {agent, ship, intent, attempt} = selected_resource("jettison")
    {:ok, _} = MutationAttempts.record_not_sent(attempt, "Unused fixture preparation")

    legacy =
      Repo.update!(
        Ecto.Changeset.change(intent,
          mutation_attempt_id: nil,
          in_flight_action: Map.delete(intent.in_flight_action, "selection_id")
        )
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, %{"data" => resource_ship(ship.symbol, "jettison")})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, legacy.id)
    current = Repo.get!(Intent, legacy.id)
    assert current.status == "blocked"
    assert current.in_flight_action == legacy.in_flight_action
    assert MutationAttempts.get!(current.mutation_attempt_id).state == "ambiguous"
  end

  test "resource rejection clears only its rejected selection even for a navigation-typed error" do
    {agent, ship, intent, attempt} = selected_resource("extract")

    Req.Test.stub(
      SpaceTraders.API,
      &Req.Test.json(&1, %{
        "data" => ship_body(ship.symbol, %{"cargo" => intent.in_flight_action["cargo_before"]})
      })
    )

    {:ok, binding} = Evidence.get_ship_binding(agent, ship.symbol)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "POST"

      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"code" => 4203, "message" => "Rejected by game"}})
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, binding, :boot, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "rejected"
    assert Repo.get!(Intent, intent.id).in_flight_action == nil
    assert Repo.get!(Intent, intent.id).blocker.reason == "insufficient_fuel"
  end

  for trigger <- [:boot, :cooldown] do
    test "#{trigger} resource retry applies the same rejection continuation as first dispatch" do
      {agent, ship, intent, attempt} = selected_resource("extract")
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      before = ship_body(ship.symbol, %{"cargo" => intent.in_flight_action["cargo_before"]})
      Req.Test.stub(SpaceTraders.API, &Req.Test.json(&1, %{"data" => before}))
      {:ok, binding} = Evidence.get_ship_binding(agent, ship.symbol)

      {:ok, proof} =
        Evidence.recovery_proof(attempt, :absent, "Controlled owner absence proof", [binding])

      {:ok, _} = MutationAttempts.reconcile(attempt, :absent, proof)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"

        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"code" => 4203, "message" => "Rejected by game"}})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, binding, unquote(trigger), intent.id)
      current = Repo.get!(Intent, intent.id)
      assert current.in_flight_action == nil
      assert current.blocker.reason == "insufficient_fuel"
      attempts = MutationAttempts.list_for_agent(agent)
      assert length(attempts) == 2
      original = Enum.find(attempts, &(&1.id == attempt.id))
      retry = Enum.find(attempts, &(&1.retry_of_id == attempt.id))
      assert original.id == attempt.id
      assert original.state == "absent"
      refute original.retry_authorized
      assert retry.retry_of_id == original.id
      assert retry.state == "rejected"

      Req.Test.stub(SpaceTraders.API, fn _ ->
        flunk("obsolete callback replayed a rejected retry")
      end)

      assert :ok =
               Intents.reconcile(agent.id, ship.symbol, binding, unquote(trigger), intent.id + 1)
    end
  end

  for stopped? <- [false, true] do
    test "persisted resource absence #{if stopped?, do: "retires under Stop", else: "consumes exactly one retry"}" do
      {agent, ship, intent, attempt} = selected_resource("extract")
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
      before = ship_body(ship.symbol, %{"cargo" => intent.in_flight_action["cargo_before"]})
      Req.Test.stub(SpaceTraders.API, &Req.Test.json(&1, %{"data" => before}))
      {:ok, binding} = Evidence.get_ship_binding(agent, ship.symbol)

      {:ok, proof} =
        Evidence.recovery_proof(attempt, :absent, "Controlled owner absence proof", [binding])

      {:ok, _} = MutationAttempts.reconcile(attempt, :absent, proof)

      if unquote(stopped?) do
        operator = Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id)

        assert {:ok, _} =
                 SpaceTraders.FleetStrategy.engage_emergency_stop(
                   SpaceTraders.Agent.Scope.for_operator(operator)
                 )

        on_exit(fn ->
          SpaceTraders.EmergencyStopAdmission.resume(agent.operator_id, :infinity)
        end)

        Req.Test.stub(SpaceTraders.API, fn _ -> flunk("stopped resource absence sent a retry") end)
      else
        Req.Test.stub(SpaceTraders.API, fn conn ->
          assert conn.method == "POST"
          Req.Test.json(conn, %{"data" => resource_response(ship.symbol, "extract")})
        end)
      end

      _ = Intents.reconcile(agent.id, ship.symbol, binding, :boot, intent.id)
      assert Repo.get!(Intent, intent.id).in_flight_action == nil
      refute MutationAttempts.get!(attempt.id).retry_authorized

      assert_retry_retired(unquote(stopped?), agent, ship, intent)
    end
  end

  defp assert_retry_retired(true, _agent, _ship, _intent), do: :ok

  defp assert_retry_retired(false, agent, ship, intent) do
    assert Repo.get!(Intent, intent.id).status == "completed"
    Req.Test.stub(SpaceTraders.API, fn _ -> flunk("retired resource selection replayed") end)
    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
  end

  for operation <-
        ~w(extract-resources extract-resources-with-survey siphon-resources create-survey ship-refine jettison) do
    test "#{operation} ledger recovery refuses unretained conclusions even without selection metadata" do
      agent = operator_fixture() |> agent_fixture()

      {:ok, attempt} =
        MutationAttempts.prepare(
          SpaceTraders.API.OperationInventory.fetch!(unquote(operation)),
          "/my/ships/RESOURCE-RECOVERY/action",
          agent_id: agent.id
        )

      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      proof =
        Evidence.reconciliation_observation(
          "get-my-ship",
          attempt,
          :accepted,
          "Unretained caller assertion"
        )

      assert {:error, :authoritative_evidence_required} =
               MutationAttempts.reconcile(attempt, :accepted, [proof])

      assert SpaceTraders.SafetyFence.active?(MutationAttempts.get!(attempt.id))
    end
  end

  test "resource recovery uses the exact retained Cargo and cooldown acquisition after replacement" do
    {agent, ship, intent, attempt} = selected_resource("extract")
    {:ok, _} = MutationAttempts.mark_sent_or_unknown(attempt)
    body = resource_ship(ship.symbol, "extract")
    Req.Test.stub(SpaceTraders.API, &Req.Test.json(&1, %{"data" => body}))
    {:ok, original} = Evidence.get_ship_binding(agent, ship.symbol)
    {:ok, replacement} = Evidence.get_ship_binding(agent, ship.symbol)
    refute original.observation.id == replacement.observation.id

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("retained recovery must not send or read again")
    end)

    _ = Intents.reconcile(agent.id, ship.symbol, original, :cooldown, intent.id)
    assert Repo.get!(Intent, intent.id).status == "completed"
    accepted = MutationAttempts.get!(attempt.id)
    assert accepted.state == "accepted"
    [proof] = List.last(accepted.outcomes).evidence["observations"]
    assert proof["source"]["id"] == original.observation.id
    assert proof["observed_at"] == DateTime.to_iso8601(original.observation.observed_at)
  end

  for kind <- ~w(extract siphon refine survey jettison) do
    test "prepared #{kind} boot dispatch keeps the same response continuation without a second read" do
      kind = unquote(kind)
      {agent, ship, intent, attempt} = selected_resource(kind)

      before =
        ship_body(ship.symbol, %{
          "nav" => nav_body("IN_ORBIT"),
          "cargo" => intent.in_flight_action["cargo_before"]
        })

      Req.Test.stub(SpaceTraders.API, &Req.Test.json(&1, %{"data" => before}))
      {:ok, binding} = Evidence.get_ship_binding(agent, ship.symbol)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST", "prepared response continuation acquired a second Ship read"
        Req.Test.json(conn, %{"data" => resource_response(ship.symbol, kind)})
      end)

      _ = Intents.reconcile(agent.id, ship.symbol, binding, :boot, intent.id)
      current = Repo.get!(Intent, intent.id)
      assert current.in_flight_action == nil
      assert MutationAttempts.get!(attempt.id).state == "succeeded"

      if kind == "survey" do
        assert current.status == "waiting"
        assert current.parameters["survey"]["signature"] == "RECOVERY-SURVEY"
      else
        assert current.status == "completed"
        assert current.last_action_result["kind"] == kind
      end
    end
  end

  for kind <- ~w(extract siphon refine survey jettison) do
    test "#{kind} resumes after accepted outcome commit without replay or a second verdict" do
      kind = unquote(kind)
      {agent, ship, intent, attempt} = selected_resource(kind)
      {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(
        SpaceTraders.API,
        &Req.Test.json(&1, %{"data" => resource_ship(ship.symbol, kind)})
      )

      {:ok, binding} = Evidence.get_ship_binding(agent, ship.symbol)

      {:ok, proof} =
        Evidence.recovery_proof(
          attempt,
          :accepted,
          "Owner already established the resource effect",
          [binding]
        )

      {:ok, accepted} = MutationAttempts.reconcile(attempt, :accepted, proof)
      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("committed accepted effect was replayed") end)

      _ = Intents.reconcile(agent.id, ship.symbol, binding, :boot, intent.id)
      current = Repo.get!(Intent, intent.id)
      assert current.in_flight_action == nil
      assert current.status == if(kind == "survey", do: "waiting", else: "completed")
      assert length(MutationAttempts.get!(attempt.id).outcomes) == length(accepted.outcomes)
    end
  end

  defp resource_response(symbol, kind) do
    body = resource_ship(symbol, kind)
    base = Map.take(body, ["cargo", "cooldown"])

    case kind do
      "survey" ->
        Map.put(base, "surveys", [
          %{
            "symbol" => "X1-UX81-A1",
            "signature" => "RECOVERY-SURVEY",
            "expiration" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
            "size" => "SMALL",
            "deposits" => [%{"symbol" => "IRON_ORE"}]
          }
        ])

      "refine" ->
        Map.merge(base, %{
          "produced" => [%{"tradeSymbol" => "IRON", "units" => 10}],
          "consumed" => [%{"tradeSymbol" => "IRON_ORE", "units" => 100}]
        })

      _ ->
        Map.put(base, if(kind == "extract", do: "extraction", else: "siphon"), %{
          "shipSymbol" => symbol,
          "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
        })
    end
  end

  defp selected_resource(kind) do
    agent = operator_fixture() |> agent_fixture()

    before = %{
      "capacity" => 200,
      "units" => 100,
      "inventory" => [%{"symbol" => "IRON_ORE", "units" => 100}]
    }

    action = %{
      "kind" => kind,
      "waypoint" => "X1-UX81-A1",
      "cargo_before" => before,
      "produce" => "IRON",
      "trade_symbol" => "IRON_ORE",
      "units" => 5
    }

    %{ship: ship, intent: intent, attempt: attempt} =
      prepare_action(agent, "RESOURCE-RECOVERY", action)

    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          type: "acquire_resources",
          parameters: %{"mode" => kind, "produce" => "IRON"}
        )
      )

    {agent, ship, intent, attempt}
  end

  defp resource_ship(symbol, kind) do
    {units, inventory} =
      case kind do
        "refine" -> {10, [%{"symbol" => "IRON", "units" => 10}]}
        "jettison" -> {95, [%{"symbol" => "IRON_ORE", "units" => 95}]}
        _ -> {105, [%{"symbol" => "IRON_ORE", "units" => 105}]}
      end

    ship_body(symbol, %{
      "nav" => nav_body("IN_ORBIT"),
      "cargo" => %{"capacity" => 200, "units" => units, "inventory" => inventory},
      "cooldown" => %{
        "shipSymbol" => symbol,
        "totalSeconds" => 60,
        "remainingSeconds" => 60,
        "expiration" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
      }
    })
  end
end
