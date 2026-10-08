defmodule SpaceTraders.FleetRefitTest do
  # These cases share ShipServer lifecycle and the application-wide test clock.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model
  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Fleet.{Intent, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetRefit
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo

  @module "MODULE_SURVEY_SUITE_I"
  @system "X1-UX81"
  @home "X1-UX81-A1"
  @supply "X1-UX81-A2"
  @shipyard_path "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/shipyard"

  for kind <- ["install_module", "remove_module"] do
    @tag :refit_progression
    test "#{kind} live, prepared boot, and absent boot share one effect and continuation" do
      for entry <- [:live, :prepared, :absent] do
        {_scope, agent, _revision, ship} = generation("REFIT-#{entry}")
        {intent, action} = selected_refit(agent, ship, unquote(kind))

        {:ok, game} =
          start_supervised({Elixir.Agent, fn -> false end}, id: {unquote(kind), entry})

        test_pid = self()

        Req.Test.stub(SpaceTraders.API, fn conn ->
          case {conn.method, conn.request_path} do
            {"GET", "/v2/my/agent"} ->
              Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 18_000}})

            {"GET", @shipyard_path} ->
              Req.Test.json(conn, %{"data" => shipyard_body()})

            {"GET", _} ->
              body =
                if Elixir.Agent.get(game, & &1),
                  do: refit_after_body(ship.symbol, unquote(kind)),
                  else: refit_before_body(ship.symbol, unquote(kind))

              Req.Test.json(conn, %{"data" => body})

            {"POST", path} ->
              assert path ==
                       "/v2/my/ships/#{ship.symbol}/modules/#{if unquote(kind) == "install_module", do: "install", else: "remove"}"

              refute Elixir.Agent.get_and_update(game, &{&1, true})
              send(test_pid, {:refit_sent, entry})

              response =
                if unquote(kind) == "install_module",
                  do: install_response(),
                  else: removal_response()

              Req.Test.json(conn, %{"data" => response})
          end
        end)

        attempt =
          if entry == :live do
            {:ok, before} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)

            _ =
              Intents.execute_action(
                agent,
                intent,
                SpaceTraders.Evidence.bound_ship(before),
                action
              )

            nil
          else
            {:ok, %{attempt: attempt}} =
              SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)

            if entry == :absent, do: SpaceTraders.MutationAttempts.mark_sent_or_unknown(attempt)
            _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
            attempt
          end

        assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
        _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
        assert_receive {:refit_sent, ^entry}
        refute_receive {:refit_sent, ^entry}
        attempts = SpaceTraders.MutationAttempts.list_for_agent(agent)

        if entry == :absent do
          original = SpaceTraders.MutationAttempts.get!(attempt.id)
          assert original.state == "absent"
          refute original.retry_authorized
          assert Enum.count(attempts, &(&1.retry_of_id == attempt.id)) == 1
        else
          assert [%{state: "succeeded"} = succeeded] = attempts
          if attempt, do: assert(succeeded.id == attempt.id)
        end
      end
    end

    @tag :refit_progression
    test "#{kind} bounded historical effect reconciles during Stop without restoring authority" do
      {scope, agent, _revision, ship} = generation()
      {intent, action} = selected_refit(agent, ship, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)

      {:ok, attempt} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(attempt)
      stub_refit_facts(agent, ship, refit_before_body(ship.symbol, unquote(kind)))
      {:ok, before} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, credits} = SpaceTraders.Evidence.get_agent_binding(agent)

      {:ok, proof} =
        SpaceTraders.Evidence.recovery_proof(
          attempt,
          :bounded_unknown,
          "Controlled fixture accounting, not a production spending bound",
          [before, credits]
        )

      {:ok, _} =
        SpaceTraders.MutationAttempts.reconcile(attempt, :bounded_unknown, proof,
          constraint_accounting:
            SpaceTraders.Evidence.constraint_accounting(
              "fixture accounts for one historical refit",
              [
                %{
                  constraint: "Keep at least 1,000 credits available",
                  satisfied: true,
                  evidence:
                    "Controlled game charges zero for this historical module mutation; 18,000 credits retained"
                }
              ]
            )
        )

      {:ok, _} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)
      stub_refit_facts(agent, ship, refit_after_body(ship.symbol, unquote(kind)))
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :arrival, intent.id)
      assert SpaceTraders.MutationAttempts.get!(attempt.id).state == "accepted"
      assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
      assert length(SpaceTraders.MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :refit_progression
    test "#{kind} absence during Stop retires retry and leaves resume unblocked" do
      {scope, agent, _revision, ship} = generation()
      {intent, action} = selected_refit(agent, ship, unquote(kind))

      {:ok, %{attempt: attempt}} =
        SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)

      {:ok, _} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(attempt)
      {:ok, _} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)
      stub_refit_facts(agent, ship, refit_before_body(ship.symbol, unquote(kind)))
      _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
      original = SpaceTraders.MutationAttempts.get!(attempt.id)
      assert original.state == "absent"
      refute original.retry_authorized
      assert Repo.get!(Intent, intent.id).in_flight_action == nil
      refute SpaceTraders.SafetyFence.active?(original)

      assert :ok =
               SpaceTraders.Fleet.prepare_emergency_stop_resume(
                 agent.operator_id,
                 DateTime.utc_now()
               )

      assert length(SpaceTraders.MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :refit_withdraw
    test "#{kind} newly observed effect withdraws unused absence permission without replay" do
      {_scope, agent, _revision, ship} = generation()
      {intent, action} = selected_refit(agent, ship, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)

      {:ok, attempt} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(attempt)
      stub_refit_facts(agent, ship, refit_before_body(ship.symbol, unquote(kind)))
      {:ok, before} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, credits} = SpaceTraders.Evidence.get_agent_binding(agent)

      {:ok, proof} =
        SpaceTraders.Evidence.recovery_proof(
          attempt,
          :absent,
          "Modules and inventory unchanged",
          [before, credits]
        )

      {:ok, _} = SpaceTraders.MutationAttempts.reconcile(attempt, :absent, proof)
      stub_refit_facts(agent, ship, refit_after_body(ship.symbol, unquote(kind)))
      {:ok, after_binding} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("satisfied refit must not replay") end)

      _ =
        Intents.reconcile(
          agent.id,
          ship.symbol,
          SpaceTraders.Evidence.bound_ship(after_binding),
          :boot,
          intent.id
        )

      assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
      original = SpaceTraders.MutationAttempts.get!(attempt.id)
      assert original.state == "absent"
      refute original.retry_authorized
      assert length(SpaceTraders.MutationAttempts.list_for_agent(agent)) == 1
    end

    @tag :refit_source
    test "#{kind} ledger rejects unretained conclusions even without selected metadata" do
      {_scope, agent, _revision, ship} = generation()

      operation =
        if unquote(kind) == "install_module",
          do: "install-ship-module",
          else: "remove-ship-module"

      {:ok, attempt} =
        SpaceTraders.MutationAttempts.prepare(
          SpaceTraders.API.OperationInventory.fetch!(operation),
          "/my/ships/#{ship.symbol}/modules/#{if unquote(kind) == "install_module", do: "install", else: "remove"}",
          agent_id: agent.id,
          json: %{"symbol" => @module}
        )

      {:ok, attempt} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(attempt)

      for verdict <- [:accepted, :absent, :bounded_unknown] do
        forged =
          SpaceTraders.Evidence.reconciliation_observation(
            "get-my-ship",
            attempt,
            verdict,
            "Caller claims refit and credits without retained sources"
          )

        opts =
          if verdict == :bounded_unknown,
            do: [
              constraint_accounting:
                SpaceTraders.Evidence.constraint_accounting("fixture accounting only", [])
            ],
            else: []

        assert {:error, :authoritative_evidence_required} =
                 SpaceTraders.MutationAttempts.reconcile(attempt, verdict, [forged], opts)
      end

      assert SpaceTraders.SafetyFence.active?(SpaceTraders.MutationAttempts.get!(attempt.id))
    end

    @tag :refit_recovery
    test "#{kind} boot recovery retains exact Ship and credit sources across replacement" do
      {_scope, agent, _revision, ship} = generation()
      {intent, action} = selected_refit(agent, ship, unquote(kind))

      {:ok, %{intent: intent, attempt: attempt}} =
        SpaceTraders.Fleet.Intents.RecordedAction.prepare(agent, intent, action)

      {:ok, _} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(attempt)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"

        data =
          if conn.request_path == "/v2/my/agent",
            do: %{"symbol" => agent.symbol, "credits" => 18_000},
            else: refit_after_body(ship.symbol, unquote(kind))

        Req.Test.json(conn, %{"data" => data})
      end)

      {:ok, original} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      {:ok, credits} = SpaceTraders.Evidence.get_agent_binding(agent)
      {:ok, newer} = SpaceTraders.Evidence.get_ship_binding(agent, ship.symbol)
      refute original.observation.id == newer.observation.id
      :ok = SpaceTraders.Quiesced.stop_ship(ship.symbol)
      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("recovery replaced exact retained facts") end)

      {:ok, restored} =
        SpaceTraders.Evidence.retained_ship_binding(agent, original.observation.id)

      live = SpaceTraders.Evidence.bound_ship(restored)
      _ = Intents.reconcile(agent.id, ship.symbol, live, :boot, intent.id)
      _ = Intents.reconcile(agent.id, ship.symbol, live, :arrival, intent.id)

      accepted = SpaceTraders.MutationAttempts.get!(attempt.id)
      assert accepted.state == "accepted"
      proofs = List.last(accepted.outcomes).evidence["observations"]

      assert Enum.map(proofs, & &1["source"]["id"]) ==
               [original.observation.id, credits.observation.id]

      assert Enum.map(proofs, & &1["observed_at"]) ==
               Enum.map([original, credits], &DateTime.to_iso8601(&1.observation.observed_at))

      assert %Intent{status: "completed", in_flight_action: nil} = Repo.get!(Intent, intent.id)
      assert length(SpaceTraders.MutationAttempts.list_for_agent(agent)) == 1
    end
  end

  defp selected_refit(agent, ship, kind) do
    {_scope, _agent, _ship, portfolio, commitment} = claimed_refit_ship(agent, ship, "remove")

    {:ok, intent} =
      Intents.insert_commitment_intent(commitment, portfolio, ship, %{
        type: kind,
        target_waypoint: @supply,
        parameters: %{"module_symbol" => @module}
      })

    action = %{
      "kind" => kind,
      "module_symbol" => @module,
      "quantity" => 1,
      "waypoint" => @supply,
      "installed_before" => if(kind == "install_module", do: 0, else: 3),
      "cargo_before" => if(kind == "install_module", do: 1, else: 0)
    }

    stub_modification_quote(agent)
    {intent, action}
  end

  # Module preparation quotes the Shipyard fee and reads authoritative credits.
  defp stub_modification_quote(agent) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 18_000}})

        {"GET", @shipyard_path} ->
          Req.Test.json(conn, %{"data" => shipyard_body()})
      end
    end)
  end

  defp shipyard_body,
    do: %{"symbol" => @supply, "shipTypes" => [], "modificationsFee" => 100}

  defp refit_after_body(symbol, "install_module"), do: fitted_ship_body(symbol)
  defp refit_after_body(symbol, "remove_module"), do: removed_ship_body(symbol)

  defp refit_before_body(symbol, "install_module"), do: purchased_docked_body(symbol)
  defp refit_before_body(symbol, "remove_module"), do: fitted_ship_body(symbol, installed: 3)

  defp stub_refit_facts(agent, ship, body) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path in ["/v2/my/agent", "/v2/my/ships/#{ship.symbol}"]

      data =
        if conn.request_path == "/v2/my/agent",
          do: %{"symbol" => agent.symbol, "credits" => 18_000},
          else: body

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  test "a purchase-sourced refit claims its Ship, buys the module, installs, and reconciles" do
    {scope, agent, revision, ship} = generation()
    seed_intelligence(agent)

    test_pid = self()
    ship_symbol = ship.symbol
    ship_path = "/v2/my/ships/#{ship_symbol}"
    navigate_path = ship_path <> "/navigate"
    purchase_path = ship_path <> "/purchase"
    install_path = ship_path <> "/modules/install"
    market_path = "/v2/systems/#{@system}/waypoints/#{@supply}/market"

    stub_api(test_pid, %{
      "GET /v2/my/ships" => fn -> %{"data" => [outbound_ship_body(ship_symbol)]} end,
      "GET /v2/my/agent" => fn ->
        %{"data" => %{"symbol" => agent.symbol, "credits" => 50_000}}
      end,
      ("GET " <> ship_path) => fn ->
        count = ship_read_count()

        case count do
          0 -> %{"data" => outbound_ship_body(ship_symbol)}
          1 -> %{"data" => purchased_docked_body(ship_symbol)}
          _ -> %{"data" => fitted_ship_body(ship_symbol)}
        end
      end,
      ("POST " <> navigate_path) => fn -> %{"data" => %{"nav" => nav_in_transit()}} end,
      ("POST " <> purchase_path) => fn -> %{"data" => purchase_response()} end,
      ("POST " <> install_path) => fn -> %{"data" => install_response()} end,
      ("GET " <> market_path) => fn -> %{"data" => market_body()} end,
      ("GET " <> @shipyard_path) => fn -> %{"data" => shipyard_body()} end
    })

    assert {:ok, %Intent{type: "install_module", status: "waiting", target_waypoint: @supply}} =
             FleetRefit.reconcile(scope, agent, revision, @system)

    assert [%Intent{status: "waiting"} = intent] = Intents.current(agent)

    live_ship = Model.Ship.from_json(docked_awaiting_purchase_body(ship_symbol))

    assert {:ok, %Intent{status: "completed", last_action_result: result}} =
             Intents.advance(agent, intent, live_ship)

    assert result["kind"] == "install_module"

    assert {:ok, %{ship_symbol: ^ship_symbol, module_symbol: @module, portfolio: portfolio}} =
             FleetRefit.reconcile(scope, agent, revision, @system)

    assert FleetAllocation.current_portfolio(scope, agent) == nil

    assert %StrategyDecisionEpisode{classification: :realized, actual_outcomes: outcomes} =
             Repo.get!(StrategyDecisionEpisode, portfolio.strategy_decision_episode_id)

    assert outcomes["installed_after"] == 1
    assert outcomes["expected_cost"] == 32_000
    assert outcomes["reconciliation"]["state"] == "succeeded"
    assert outcomes["reconciliation"]["basis"] == "reconciled_mutation_attempt"
  end

  test "a removal affecting duplicate matching modules terminates on the authoritative read" do
    {scope, agent, revision, ship} = generation()
    seed_intelligence(agent)

    test_pid = self()
    ship_symbol = ship.symbol
    ship_path = "/v2/my/ships/#{ship_symbol}"
    remove_path = ship_path <> "/modules/remove"

    {_scope, agent, _ship, portfolio, commitment} = claimed_refit_ship(agent, ship, "remove")

    stub_api(test_pid, %{
      ("GET " <> ship_path) => fn ->
        if Keyword.get(removed_state(), :removed, false) do
          %{"data" => removed_ship_body(ship_symbol)}
        else
          %{"data" => fitted_ship_body(ship_symbol, installed: 3)}
        end
      end,
      ("POST " <> remove_path) => fn ->
        :persistent_term.put({__MODULE__, :removed}, removed: true)
        %{"data" => removal_response()}
      end,
      "GET /v2/my/agent" => fn ->
        %{"data" => %{"symbol" => agent.symbol, "credits" => 50_000}}
      end,
      ("GET " <> @shipyard_path) => fn -> %{"data" => shipyard_body()} end
    })

    candidate = removal_candidate(ship_symbol)

    ship_symbol = ship.symbol

    assert {:ok, %Intent{type: "remove_module", status: "completed", last_action_result: result}} =
             Intents.request_commitment_refit(
               agent,
               commitment,
               portfolio,
               ship_symbol,
               candidate
             )

    assert result["kind"] == "remove_module"
    assert result["quantity"] == 1

    assert {:ok, %{ship_symbol: ^ship_symbol, module_symbol: @module}} =
             FleetRefit.reconcile(scope, agent, revision, @system)
  end

  test "planning never assumes a module is in Cargo without purchase evidence" do
    {scope, agent, revision, ship} = generation()
    seed_intelligence(agent, supply: false)

    stub_api(self(), %{
      "GET /v2/my/ships" => fn -> %{"data" => [outbound_ship_body(ship.symbol)]} end,
      "GET /v2/my/agent" => fn ->
        %{"data" => %{"symbol" => agent.symbol, "credits" => 50_000}}
      end
    })

    assert {:error, :ship_refit_unavailable} =
             FleetRefit.reconcile(scope, agent, revision, @system)

    assert Intents.current(agent) == []
  end

  # -- stubbing ----------------------------------------------------------------

  for rejection <- [:purchase, :purchase_observation] do
    @rejection rejection
    test "a refit #{@rejection} 429 resumes from its durable wake after ShipServer restart" do
      install_test_clock()
      {scope, agent, revision, ship} = generation()
      seed_intelligence(agent)
      state = stub_refit_rejection(agent, ship, @rejection)
      purchase_path = "/v2/my/ships/#{ship.symbol}/purchase"

      assert {:ok, %Intent{status: "waiting", blocker: blocker} = intent} =
               FleetRefit.reconcile(scope, agent, revision, @system)

      assert blocker.reason == "api_capacity_deferred"
      assert_received {"POST", ^purchase_path}
      refute_received {"POST", ^purchase_path}

      [event] = SpaceTraders.Timeline.pending_events(:ship, ship.symbol)
      assert event.event_type == "intent_retry"
      assert event.payload["intent_id"] == intent.id

      [first] = SpaceTraders.MutationAttempts.list_for_agent(agent)

      if @rejection == :purchase do
        assert first.state == "rejected"
        assert intent.in_flight_action == nil
        assert intent.mutation_attempt_id == nil
      else
        assert first.state == "succeeded"
        assert intent.in_flight_action["kind"] == "buy"
        assert intent.mutation_attempt_id == first.id
      end

      :ok = SpaceTraders.Quiesced.stop_ship(ship.symbol)

      assert eventually(fn ->
               Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship.symbol) == []
             end)

      {:ok, pid} = ShipServer.ensure_started(agent, ship.symbol)
      :sys.get_state(pid)
      SpaceTraders.TestClock.advance(1)

      install_path = "/v2/my/ships/#{ship.symbol}/modules/install"
      assert_receive {"POST", ^install_path}, 1_000
      :sys.get_state(pid)
      assert Repo.get!(Intent, intent.id).status == "completed"
      assert SpaceTraders.Timeline.pending_events(:ship, ship.symbol) == []

      expected_purchases = if @rejection == :purchase, do: 2, else: 1
      assert Elixir.Agent.get(state, & &1.purchases) == expected_purchases

      attempts = SpaceTraders.MutationAttempts.list_for_agent(agent)
      assert length(attempts) == expected_purchases + 1
      assert List.last(attempts).state == "succeeded"
      assert List.last(attempts).operation_id == "install-ship-module"
      assert Enum.all?(attempts, &(&1.provenance["intent_id"] == intent.id))
    end
  end

  test "a deferred refit wake cannot send after its Claim is withdrawn" do
    install_test_clock()
    {scope, agent, revision, ship} = generation()
    seed_intelligence(agent)
    state = stub_refit_rejection(agent, ship, :purchase)

    assert {:ok, %Intent{status: "waiting"} = intent} =
             FleetRefit.reconcile(scope, agent, revision, @system)

    portfolio = FleetAllocation.current_portfolio(scope, agent)
    [commitment] = portfolio.commitments
    Repo.update!(Ecto.Changeset.change(commitment, unwind_state: :released))

    {:ok, pid} = ShipServer.ensure_started(agent, ship.symbol)
    :sys.get_state(pid)
    SpaceTraders.TestClock.advance(1)
    assert_receive {:retry_ship_read, _}, 1_000
    :sys.get_state(pid)

    assert Elixir.Agent.get(state, & &1.purchases) == 1
    assert Repo.get!(Intent, intent.id).status == "superseded"
    assert [%{state: "rejected"}] = SpaceTraders.MutationAttempts.list_for_agent(agent)
  end

  test "protocol backpressure defers a module removal instead of proving it infeasible" do
    {_scope, agent, _revision, ship} = generation()
    {_scope, _agent, _ship, portfolio, commitment} = claimed_refit_ship(agent, ship, "remove")
    remove_path = "/v2/my/ships/#{ship.symbol}/modules/remove"
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships/" <> _} ->
          Req.Test.json(conn, %{"data" => fitted_ship_body(ship.symbol, installed: 3)})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 50_000}})

        {"GET", @shipyard_path} ->
          Req.Test.json(conn, %{"data" => shipyard_body()})

        {"POST", ^remove_path} ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
      end
    end)

    assert {:ok, %Intent{status: "waiting", blocker: blocker}} =
             Intents.request_commitment_refit(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               removal_candidate(ship.symbol)
             )

    assert blocker.reason == "api_capacity_deferred"
    assert blocker.summary =~ "rejected before it applied"

    assert [%{state: "rejected", operation_id: "remove-ship-module"}] =
             SpaceTraders.MutationAttempts.list_for_agent(agent)

    assert FleetAllocation.failed_candidate_ids(portfolio.fleet_generation_id) == MapSet.new()
    assert_received {"POST", ^remove_path}
    refute_received {"POST", ^remove_path}
  end

  for refusal <- [:safety_fence, :emergency_stop] do
    @refusal refusal
    test "module preparation #{@refusal} after Readiness observation refuses safely" do
      {scope, agent, _revision, ship} = generation()
      {_scope, _agent, _ship, portfolio, commitment} = claimed_refit_ship(agent, ship, "remove")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v2/my/ships/#{ship.symbol}"

        case @refusal do
          :emergency_stop ->
            assert {:ok, _} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)

          :safety_fence ->
            {:ok, pending} =
              SpaceTraders.MutationAttempts.prepare(
                SpaceTraders.API.OperationInventory.fetch!("purchase-cargo"),
                "/my/ships/#{ship.symbol}/purchase",
                agent_id: agent.id,
                json: %{"symbol" => @module, "units" => 1}
              )

            {:ok, pending} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(pending)

            {:ok, _} =
              SpaceTraders.MutationAttempts.record_outcome(pending, :ambiguous, %{
                reason: "old unresolved purchase"
              })
        end

        Req.Test.json(conn, %{"data" => fitted_ship_body(ship.symbol, installed: 3)})
      end)

      assert {:ok, %Intent{status: "blocked", in_flight_action: nil, mutation_attempt_id: nil}} =
               Intents.request_commitment_refit(
                 agent,
                 commitment,
                 portfolio,
                 ship.symbol,
                 removal_candidate(ship.symbol)
               )

      attempts = SpaceTraders.MutationAttempts.list_for_agent(agent)

      if @refusal == :safety_fence do
        assert [%{state: "ambiguous", operation_id: "purchase-cargo"}] = attempts
      else
        assert attempts == []
      end
    end
  end

  defp stub_api(test_pid, handlers) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})
      key = conn.method <> " " <> conn.request_path

      case Map.fetch(handlers, key) do
        {:ok, handler} ->
          Req.Test.json(conn, handler.())

        :error ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"message" => "unstubbed " <> key}})
      end
    end)
  end

  defp install_test_clock do
    start_supervised!({SpaceTraders.TestClock, DateTime.utc_now()})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)
  end

  defp stub_refit_rejection(agent, ship, rejection) do
    test_pid = self()

    {:ok, state} =
      Elixir.Agent.start_link(fn ->
        %{purchases: 0, purchased: false, installed: false, read_rejections: 0}
      end)

    ship_path = "/v2/my/ships/#{ship.symbol}"
    purchase_path = ship_path <> "/purchase"
    install_path = ship_path <> "/modules/install"
    market_path = "/v2/systems/#{@system}/waypoints/#{@supply}/market"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [docked_awaiting_purchase_body(ship.symbol)]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 50_000}})

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{"data" => market_body()})

        {"GET", @shipyard_path} ->
          Req.Test.json(conn, %{"data" => shipyard_body()})

        {"GET", ^ship_path} ->
          game = Elixir.Agent.get(state, & &1)

          cond do
            rejection == :purchase_observation and game.purchased and game.read_rejections < 4 ->
              Elixir.Agent.update(state, &%{&1 | read_rejections: &1.read_rejections + 1})
              protocol_rejection(conn)

            game.installed ->
              Req.Test.json(conn, %{"data" => fitted_ship_body(ship.symbol)})

            game.purchased ->
              Req.Test.json(conn, %{"data" => purchased_docked_body(ship.symbol)})

            true ->
              if game.purchases > 0, do: send(test_pid, {:retry_ship_read, ship.symbol})
              Req.Test.json(conn, %{"data" => docked_awaiting_purchase_body(ship.symbol)})
          end

        {"POST", ^purchase_path} ->
          count =
            Elixir.Agent.get_and_update(
              state,
              &{&1.purchases, %{&1 | purchases: &1.purchases + 1}}
            )

          if rejection == :purchase and count == 0 do
            protocol_rejection(conn)
          else
            Elixir.Agent.update(state, &%{&1 | purchased: true})
            Req.Test.json(conn, %{"data" => purchase_response()})
          end

        {"POST", ^install_path} ->
          Elixir.Agent.update(state, &%{&1 | installed: true})
          Req.Test.json(conn, %{"data" => install_response()})

        request ->
          flunk("unexpected refit request: #{inspect(request)}")
      end
    end)

    Req.Test.set_req_test_to_shared(SpaceTraders.API)
    state
  end

  defp protocol_rejection(conn) do
    conn
    |> Plug.Conn.put_resp_header("retry-after", "0")
    |> Plug.Conn.put_status(429)
    |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
  end

  defp eventually(fun, attempts \\ 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp ship_read_count do
    key = {__MODULE__, :ship_reads}
    count = :persistent_term.get(key, 0)
    :persistent_term.put(key, count + 1)
    count
  end

  defp removed_state do
    :persistent_term.get({__MODULE__, :removed}, [])
  end

  # -- fixtures ----------------------------------------------------------------

  defp generation(symbol \\ "REFIT") do
    operator = Repo.insert!(%Operator{email: "refit-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%Agent{
        operator_id: operator.id,
        symbol: symbol,
        faction: "COSMIC",
        headquarters: @home,
        agent_token: "TOKEN"
      })

    ship = Repo.insert!(%Ship{agent_id: agent.id, symbol: "#{symbol}-1", ship_type: "SHIP_PROBE"})

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: %{
          "objectives" => [
            %{
              "objective" => "Refit the Fleet with a Survey module",
              "kind" => "attain",
              "evaluation" => "Operate a Survey-capable Ship",
              "capability" => "survey",
              "target_modules" => [@module]
            }
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"],
          "releases" => [
            %{"ship" => "REFIT-1", "module_symbol" => @module, "scope" => "all_matching"}
          ]
        }
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

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

    {Scope.for_operator(operator), agent, revision, ship}
  end

  defp claimed_refit_ship(agent, ship, action) do
    operator = Repo.get!(Operator, agent.operator_id)
    revision = Repo.one!(from r in Revision, order_by: [desc: r.id], limit: 1)

    generation =
      Repo.one!(
        from generation in Generation,
          where: generation.agent_id == ^agent.id and is_nil(generation.retired_at)
      )

    candidate = %PortfolioCandidate{
      id: "refit-#{action}",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [
        %{
          outcome: {:strategic_objective, 0},
          amount: 1,
          backing: {:claim, ship.symbol}
        }
      ],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        claims: [ship.symbol],
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{
          module_symbol: @module,
          action: :remove,
          capability: :survey,
          expected_cost: 0,
          installed_before: 3
        },
        calibration_version: "ship-refit-v1"
      })

    [commitment] = portfolio.commitments
    {Scope.for_operator(operator), agent, ship, portfolio, commitment}
  end

  defp seed_intelligence(agent, opts \\ []) do
    waypoints = [
      %{
        "symbol" => @supply,
        "systemSymbol" => @system,
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      },
      %{
        "symbol" => @home,
        "systemSymbol" => @system,
        "type" => "PLANET",
        "x" => 0,
        "y" => 0,
        "traits" => []
      }
    ]

    Enum.each(waypoints, fn waypoint ->
      Intelligence.observe_waypoint(agent, Model.Waypoint.from_json(waypoint), source: "test")
    end)

    if Keyword.get(opts, :supply, true) do
      Intelligence.observe_market(
        agent,
        @system,
        Model.Market.from_json(market_body()),
        source: "get_market",
        observing_ship_symbol: "REFIT-1"
      )
    end

    :ok
  end

  # -- ship bodies -------------------------------------------------------------

  defp outbound_ship_body(symbol) do
    ship_body(symbol, %{
      "nav" => nav_body("IN_ORBIT"),
      "modules" => [],
      "cargo" => %{
        "capacity" => 40,
        "units" => 12,
        "inventory" => [%{"symbol" => "IRON_ORE", "units" => 12}]
      }
    })
  end

  defp docked_awaiting_purchase_body(symbol) do
    ship_body(symbol, %{
      "nav" => nav_body("DOCKED", destination: @supply),
      "modules" => [],
      "cargo" => %{
        "capacity" => 40,
        "units" => 12,
        "inventory" => [%{"symbol" => "IRON_ORE", "units" => 12}]
      }
    })
  end

  defp purchased_docked_body(symbol) do
    ship_body(symbol, %{
      "nav" => nav_body("DOCKED", destination: @supply),
      "modules" => [],
      "cargo" => %{
        "capacity" => 40,
        "units" => 13,
        "inventory" => [
          %{"symbol" => "IRON_ORE", "units" => 12},
          %{"symbol" => @module, "units" => 1}
        ]
      }
    })
  end

  defp fitted_ship_body(symbol, opts \\ []) do
    installed = Keyword.get(opts, :installed, 1)

    modules = List.duplicate(%{"symbol" => @module}, installed)

    ship_body(symbol, %{
      "nav" => nav_body("DOCKED", destination: @supply),
      "modules" => modules,
      "cargo" => %{
        "capacity" => 40,
        "units" => 12,
        "inventory" => [%{"symbol" => "IRON_ORE", "units" => 12}]
      }
    })
  end

  defp removed_ship_body(symbol) do
    ship_body(symbol, %{
      "nav" => nav_body("DOCKED", destination: @supply),
      "modules" => [],
      "cargo" => %{
        "capacity" => 40,
        "units" => 13,
        "inventory" => [
          %{"symbol" => "IRON_ORE", "units" => 12},
          %{"symbol" => @module, "units" => 1}
        ]
      }
    })
  end

  defp nav_in_transit do
    nav_body("IN_TRANSIT",
      destination: @supply,
      arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    )
  end

  defp market_body do
    %{
      "symbol" => @supply,
      "imports" => [],
      "exports" => [],
      "exchange" => [],
      "transactions" => [],
      "tradeGoods" => [
        %{
          "symbol" => @module,
          "name" => "Survey Suite",
          "description" => "Survey module",
          "purchasePrice" => 32_000,
          "sellPrice" => 24_000,
          "tradeVolume" => 5,
          "supply" => "MODERATE",
          "activity" => "STATIC"
        }
      ]
    }
  end

  defp purchase_response do
    %{
      "agent" => %{"symbol" => "REFIT", "credits" => 18_000, "headquarters" => @home},
      "cargo" => %{
        "capacity" => 40,
        "units" => 13,
        "inventory" => [
          %{"symbol" => "IRON_ORE", "units" => 12},
          %{"symbol" => @module, "units" => 1}
        ]
      },
      "transaction" => %{
        "waypointSymbol" => @supply,
        "shipSymbol" => "REFIT-1",
        "tradeSymbol" => @module,
        "type" => "PURCHASE",
        "units" => 1,
        "perUnit" => 32_000,
        "totalPrice" => 32_000,
        "timestamp" => "2030-01-01T12:00:00.000Z"
      }
    }
  end

  defp install_response do
    %{
      "agent" => %{"symbol" => "REFIT", "credits" => 18_000, "headquarters" => @home},
      "modules" => [%{"symbol" => @module, "name" => "Survey Suite", "capacity" => 30}],
      "cargo" => %{
        "capacity" => 40,
        "units" => 12,
        "inventory" => [%{"symbol" => "IRON_ORE", "units" => 12}]
      },
      "transaction" => %{
        "waypointSymbol" => @supply,
        "shipSymbol" => "REFIT-1",
        "tradeSymbol" => @module,
        "type" => "INSTALL",
        "units" => 1,
        "perUnit" => 0,
        "totalPrice" => 0,
        "timestamp" => "2030-01-01T12:00:00.000Z"
      }
    }
  end

  defp removal_response do
    # The hazard response: every matching module left the Ship while the
    # response counts only one Cargo unit.
    %{
      "agent" => %{"symbol" => "REFIT", "credits" => 18_000, "headquarters" => @home},
      "modules" => [],
      "cargo" => %{
        "capacity" => 40,
        "units" => 13,
        "inventory" => [
          %{"symbol" => "IRON_ORE", "units" => 12},
          %{"symbol" => @module, "units" => 1}
        ]
      },
      "transaction" => %{
        "waypointSymbol" => @supply,
        "shipSymbol" => "REFIT-1",
        "tradeSymbol" => @module,
        "type" => "REMOVE",
        "units" => 1,
        "perUnit" => 0,
        "totalPrice" => 0,
        "timestamp" => "2030-01-01T12:00:00.000Z"
      }
    }
  end

  defp removal_candidate(ship_symbol) do
    %SpaceTraders.FleetPlanning.CandidateContribution{
      id: "refit-remove-#{ship_symbol}",
      strategy_revision_id: 0,
      objective_index: 0,
      objective: %{},
      kind: :ship_refit,
      trade_symbol: @module,
      source_waypoint: ship_symbol,
      destination_waypoint: ship_symbol,
      expected_outcomes: %{decision_value: 1, expected_cost: 0},
      uncertainty: %{removed_units: :all_matching},
      required_roles: [%{role: :fleet_refit, count: 1}],
      required_capabilities: [%{capability: :refit_ship, value: ship_symbol}],
      required_resources: %{credits: 0, cargo_capacity: 1, ship_count: 1},
      dependencies: [],
      validity: %{},
      alternatives: [],
      refit: %{
        action: :remove,
        module_symbol: @module,
        capability: :survey,
        sourcing: nil,
        market: nil,
        purchase_price: 0,
        expected_cost: 0,
        removal_scope: :all_matching,
        installed_before: 3
      }
    }
  end
end
