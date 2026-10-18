defmodule SpaceTradersWeb.MissionControlBriefingTest do
  # Admission caches are cleared when ConnCase closes the shared sandbox.
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.ShipBody
  import SpaceTraders.RealizedEconomicsFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Repo
  alias SpaceTraders.{Evidence, Fleet, FleetGeneration, FleetStrategy, OperatorConditions}

  @symbol "MCCTRL"

  setup :register_and_log_in_operator

  test "deferred voluntary replacement exposes no control and reset retry cannot abandon a healthy Fleet",
       %{conn: conn, scope: scope} do
    {agent, generation} = mint_fleet(scope)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      if conn.method != "GET",
        do: flunk("a healthy Fleet must not dispatch replacement mutations")

      briefing_api(conn)
    end)

    {:ok, view, _} = live(conn, ~p"/mission-control")
    refute has_element?(view, "[phx-click*='replacement']")
    refute has_element?(view, "[phx-click*='abandon']")
    refute has_element?(view, "a[href='/agents/new']")

    assert render_click(view, "retry_replacement", %{}) =~
             "No Server Reset replacement is pending."

    assert {:error, :no_server_reset} = FleetGeneration.replace_after_reset(scope)
    assert {:error, :no_server_reset} = FleetGeneration.resume_reset_replacement()
    assert %{status: :clear} = FleetGeneration.registration_recovery(scope)
    assert :ok = FleetGeneration.execution_allowed?(agent)

    assert {:ok, %{state: :current, agent: %{id: agent_id}, generation: current}} =
             FleetGeneration.current_fleet(scope)

    assert agent_id == agent.id
    assert current.id == generation.id
    assert is_nil(current.fenced_at)
    assert is_nil(current.retired_at)
    assert [^current] = FleetGeneration.list_generations(scope)

    {:ok, reopened, _} = live(conn, ~p"/mission-control")
    assert has_element?(reopened, "#strategy-context", "Generation 1")
    assert has_element?(reopened, "#strategy-context", agent.symbol)
    refute has_element?(reopened, "#server-reset-replacement")
    refute has_element?(reopened, "#mission-registration-recovery")
  end

  test "the briefing adopts one current identity and never projects a retained historical Agent",
       %{conn: conn, scope: scope} do
    historical =
      SpaceTraders.AgentFixtures.agent_fixture(scope.operator, %{
        symbol: "HISTORICAL",
        agent_token: nil
      })

    SpaceTraders.AgentFixtures.generation_fixture(%FleetGeneration.Generation{
      operator_id: scope.operator.id,
      agent_id: historical.id,
      number: 1,
      symbol: "HISTORICAL",
      faction: "COSMIC",
      retired_at: DateTime.add(DateTime.utc_now(), -3600)
    })

    current =
      SpaceTraders.AgentFixtures.agent_fixture(scope.operator, %{
        symbol: "ORBITALIST",
        agent_token: nil
      })

    {:ok, view, _} = live(conn, ~p"/mission-control")
    assert has_element?(view, "#strategy-context", "Generation 2")
    assert has_element?(view, "#strategy-context", "ORBITALIST")
    assert has_element?(view, "#fleet-health", current.symbol)
    refute has_element?(view, "#fleet-health", historical.symbol)
  end

  test "ambiguous legacy identity is actionable and does not query either Fleet", %{
    conn: conn,
    scope: scope
  } do
    SpaceTraders.AgentFixtures.agent_fixture(scope.operator, %{symbol: "FIRST"})

    second =
      SpaceTraders.AgentFixtures.agent_fixture(scope.operator, %{symbol: "SECOND", publish: false})

    Repo.insert!(%FleetGeneration.Generation{
      agent_id: second.id,
      operator_id: scope.operator.id,
      number: 2,
      symbol: second.symbol,
      faction: second.faction
    })

    Req.Test.stub(SpaceTraders.API, fn _ ->
      flunk("ambiguous identity must not dispatch game reads")
    end)

    {:ok, view, _} = live(conn, ~p"/mission-control")
    assert has_element?(view, "#current-fleet-state", "multiple plausible current Agents")
    assert has_element?(view, "#current-fleet-state", "Retire competing Generations explicitly")
    refute has_element?(view, "#fleet-health", "FIRST")
    refute has_element?(view, "#fleet-health", "SECOND")
    refute has_element?(view, "a[href='/agents/new']", "Mint an Agent")
  end

  test "an authenticated Operator answers the Fleet's four questions from one briefing", %{
    conn: conn,
    scope: scope
  } do
    {agent, generation} = mint_fleet(scope)
    {:ok, _overview} = Evidence.get_agent(agent)
    evidence = Evidence.latest_observation(agent, "agent:#{agent.symbol}")

    {:ok, _generation} =
      FleetGeneration.record_objective_progress(scope, generation.id, 0, %{
        "change" => 120,
        "elapsed_seconds" => 60,
        "horizon_seconds" => 10,
        "feasible?" => true,
        "evidence_id" => evidence.id
      })

    {:ok, ship} = Fleet.owned_ship(agent, "#{@symbol}-1")
    :ok = Fleet.record_activity(agent, ship, "retry", "API request retrying")

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#strategy-context", @symbol)
    assert has_element?(view, "#strategy-context", "Generation 1")
    assert has_element?(view, "#strategy-context", "Strategy-capable")
    assert has_element?(view, "#operating-health", "Operating normally")
    assert has_element?(view, "#objective-evaluations", "Grow credits")
    assert has_element?(view, "#objective-evaluations", "Objective status: Growing")

    assert has_element?(
             view,
             "#objective-evaluations",
             "Measured outcome rate: 20.0 per horizon."
           )

    assert has_element?(view, "#notable-activity", "Generation 1 began with #{@symbol}")
    refute has_element?(view, "#notable-activity", "API request retrying")
    assert has_element?(view, "#needs-attention", "No unresolved Attention or Intervention.")
  end

  test "Attention and Intervention update the briefing and acknowledgement does not resolve them",
       %{conn: conn, scope: scope} do
    mint_fleet(scope)
    {:ok, view, _html} = live(conn, ~p"/mission-control")

    attention_summary = "Protected credit floor cannot be maintained"
    intervention_summary = "AccountToken is needed to replace the Agent"

    {:ok, attention} =
      OperatorConditions.raise(scope, "credit-floor", :attention, attention_summary,
        entity_ref: "construction:X1:X1-A1"
      )

    {:ok, intervention} =
      OperatorConditions.raise(scope, "external-authority", :intervention, intervention_summary)

    assert has_element?(view, "#operating-health", "Needs Operator attention")

    assert view |> element("#needs-attention li", attention_summary) |> render() =~
             "<strong>Attention</strong>"

    assert view |> element("#needs-attention li", intervention_summary) |> render() =~
             "<strong>Intervention</strong>"

    assert has_element?(
             view,
             "#needs-attention a[href='/world/systems/X1/waypoints/X1-A1/construction']",
             "Construction"
           )

    refute has_element?(view, "#needs-attention", "Acknowledged · unresolved")

    view |> element("#needs-attention button[phx-value-id='#{attention.id}']") |> render_click()

    view
    |> element("#needs-attention button[phx-value-id='#{intervention.id}']")
    |> render_click()

    {:ok, reopened_view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(reopened_view, "#operating-health", "Needs Operator attention")

    assert reopened_view |> element("#needs-attention li", attention_summary) |> render() =~
             "Acknowledged · unresolved"

    assert reopened_view |> element("#needs-attention li", intervention_summary) |> render() =~
             "Acknowledged · unresolved"

    attention_id = attention.id
    intervention_id = intervention.id

    assert [
             %{id: ^attention_id, kind: :attention, acknowledged_at: %DateTime{}},
             %{id: ^intervention_id, kind: :intervention, acknowledged_at: %DateTime{}}
           ] = OperatorConditions.unresolved(scope)

    :ok = OperatorConditions.resolve(scope, "credit-floor")
    refute has_element?(reopened_view, "#needs-attention", attention_summary)
    assert has_element?(reopened_view, "#needs-attention", intervention_summary)
    assert has_element?(reopened_view, "#operating-health", "Needs Operator attention")

    {:ok, recurrence} =
      OperatorConditions.raise(scope, "credit-floor", :attention, attention_summary)

    assert recurrence.id != attention.id

    assert has_element?(
             reopened_view,
             "#needs-attention button[phx-value-id='#{recurrence.id}']",
             "Acknowledge"
           )

    refute reopened_view |> element("#needs-attention li", attention_summary) |> render() =~
             "Acknowledged · unresolved"
  end

  test "collection gaps render unknown Fleet health and outcomes rather than zero measurements",
       %{
         conn: conn,
         scope: scope
       } do
    mint_fleet(scope)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(403)
      |> Req.Test.json(%{"error" => %{"code" => 4031, "message" => "Access denied"}})
    end)

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#operating-health", "Fleet health unknown")
    assert has_element?(view, "#operating-health", "this is not a zero measurement")
    assert has_element?(view, "#fleet-health", "Fleet contribution is unknown")
    assert has_element?(view, "#objective-evaluations", "Objective status: Unknown")
    refute has_element?(view, "#operating-health", "Operating normally")
    refute has_element?(view, "#fleet-health", "0 Ships in this Fleet Generation")
    refute has_element?(view, "#objective-evaluations", "Measured outcome rate:")
    refute has_element?(view, "#objective-evaluations", "Observed net change:")
  end

  test "a Stale Agent renders a Server Reset transition distinct from an unknown Fleet", %{
    conn: conn,
    scope: scope
  } do
    mint_fleet(scope)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 4113,
          "message" =>
            "Failed to parse token. Token reset_date does not match the server. " <>
              "Server resets happen on a weekly to bi-weekly frequency during alpha. " <>
              "After a reset, you should re-register your agent. " <>
              "Expected: 2026-09-15, Actual: 2026-09-01"
        }
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#fleet-health", "Stale Agent")
    assert has_element?(view, "#operating-health", "Server Reset transition")
    assert has_element?(view, "#operating-health", "A Server Reset fenced #{@symbol}")
    assert has_element?(view, "#operating-health", "Nothing it reported is counted")
    refute has_element?(view, "#operating-health", "Fleet health unknown")
    refute has_element?(view, "#operating-health", "Operating normally")
    refute has_element?(view, "#fleet-health", "0 Ships in this Fleet Generation")
  end

  test "a recorded structural stall is Degraded Operation with its cause, release and Episode link",
       %{conn: conn, scope: scope} do
    {agent, generation} = mint_fleet(scope)
    episode = stall_episode(scope, generation, :overdue_demands_without_coverage)

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#operating-health", "Fleet allocation stalled")
    refute has_element?(view, "#operating-health", "Operating normally")
    section = "#allocation-disposition-#{agent.symbol}"
    assert has_element?(view, section, "Degraded Operation")
    assert has_element?(view, section, "Overdue Market Demands with no coverage")
    assert has_element?(view, section, "Releases when")
    assert has_element?(view, section, "No Operator action is needed")
    assert has_element?(view, "#{section} a[href='/decision-episodes/#{episode.id}']")
    assert has_element?(view, "#needs-attention", "No unresolved Attention or Intervention.")

    # Normal recovery closes the Episode and the representation clears.
    episode |> Ecto.Changeset.change(resolved_at: DateTime.utc_now()) |> Repo.update!()
    {:ok, view, _html} = live(conn, ~p"/mission-control")
    refute has_element?(view, "#allocation-disposition-#{agent.symbol}", "Degraded Operation")
    refute has_element?(view, "#operating-health", "Fleet allocation stalled")
  end

  test "an open Shortfall shows the floor and release predicate, not a stall or Neutral Wait",
       %{conn: conn, scope: scope} do
    {agent, _generation} = mint_fleet(scope)

    Repo.insert!(%SpaceTraders.CreditCalibration.Shortfall{
      agent_id: agent.id,
      kind: "revision_floor",
      credits: 900,
      credit_floor: 50_000,
      detected_at: DateTime.add(DateTime.utc_now(), -5, :second)
    })

    # A balance below the floor keeps the pause open (a higher one releases it).
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "accountId" => "BRIEFING_ACCOUNT",
              "symbol" => @symbol,
              "headquarters" => "X1-UX81-A1",
              "credits" => 900,
              "startingFaction" => "COSMIC",
              "shipCount" => 1
            }
          })

        _ ->
          briefing_api(conn)
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    section = "#allocation-disposition-#{agent.symbol}"

    assert has_element?(view, section, "Shortfall at the credit floor")
    assert has_element?(view, section, "SHORTFALL")
    assert has_element?(view, section, "not a Neutral Wait")
    assert has_element?(view, section, "50000 credit floor")
    assert has_element?(view, section, "Releases when")
    refute has_element?(view, section, "STALLED")
    refute has_element?(view, section, "Degraded Operation")
  end

  test "a Completed Round Trip shows its Earnings record's Net Earnings", %{
    conn: conn,
    scope: scope
  } do
    {_agent, generation} = mint_fleet(scope)
    portfolio = publish_market!(scope, generation)
    [commitment] = portfolio.commitments
    ship = [ship: "#{@symbol}-1"]

    buy = trade_intent!(portfolio, commitment, "buy", 400, 40, ship)
    refuel!(buy, 144)
    trade_intent!(portfolio, commitment, "sell", 1_200, 40, ship)
    # A coverage root Intent's refuel is observation-only spending, never the
    # trade's cost, even on the same Ship.
    scouting = intent!(portfolio, commitment, "acquire_intelligence", ship)
    refuel!(scouting, 300)
    SpaceTraders.FleetAllocation.record_trade_outcome(portfolio)

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#realized-trade-margin", "800 credits")
    assert has_element?(view, "#realized-net-earnings", "656 credits")
  end

  test "a trip still under way renders Net Earnings unknown, never zero", %{
    conn: conn,
    scope: scope
  } do
    {_agent, generation} = mint_fleet(scope)
    portfolio = publish_market!(scope, generation)
    [commitment] = portfolio.commitments
    ship = [ship: "#{@symbol}-1"]

    buy = trade_intent!(portfolio, commitment, "buy", 400, 40, ship)
    refuel!(buy, 144)
    SpaceTraders.FleetAllocation.record_trade_outcome(portfolio)

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#realized-trade-margin", "Unknown")
    assert has_element?(view, "#realized-net-earnings", "Unknown")
    refute has_element?(view, "#realized-net-earnings", "0 credits")
  end

  test "a Neutral Wait shows exactly its five summary facts; identity is click-through only",
       %{conn: conn, scope: scope} do
    {agent, generation} = mint_fleet(scope)
    episode = neutral_wait_episode(scope, generation)

    {:ok, view, _html} = live(conn, ~p"/mission-control")
    section = "#allocation-disposition-#{agent.symbol}"
    wait = "#{section} #neutral-wait-#{agent.symbol}"

    assert has_element?(view, wait, "no worthwhile admissible contribution")
    assert has_element?(view, wait, "incomplete coverage")
    assert has_element?(view, wait, "3 of 5 Marketplaces covered")
    assert has_element?(view, wait, "Last evaluated 2026-10-11 09:30:00 UTC")
    assert has_element?(view, wait, "Next due 2026-10-11 10:00:00 UTC")
    assert has_element?(view, "#{wait} a[href='/decision-episodes/#{episode.id}']")
    refute has_element?(view, section, "Decision Episode #{episode.id}")
    refute has_element?(view, section, "Waiting deliberately")
    assert has_element?(view, "#needs-attention", "No unresolved Attention or Intervention.")
    refute has_element?(view, "#operating-health", "Needs Operator attention")

    # The Unallocated Ship's link is causal: the wait's Decision Episode.
    assert has_element?(
             view,
             "#{section} #unallocated-ships-#{agent.symbol} a[href='/decision-episodes/#{episode.id}']",
             "#{@symbol}-1"
           )
  end

  defp neutral_wait_episode(scope, generation) do
    revision = FleetStrategy.get(scope).active_revision

    episode =
      Repo.insert!(%SpaceTraders.FleetAllocation.StrategyDecisionEpisode{
        operator_id: scope.operator.id,
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 1,
        calibration_version: "market-v1",
        selection_kind: :neutral_wait,
        binding_limitation_kind: :incomplete_coverage,
        next_observation_at: ~U[2026-10-11 10:00:00.000000Z],
        expectations: %{
          "binding_limitation" => %{
            "reason" => "incomplete_market_coverage",
            "coverage" => %{"completed" => 3, "required" => 5}
          }
        },
        actual_outcomes: %{"re_evaluations" => [%{"observed_at" => "2026-10-11T09:30:00Z"}]}
      })

    Repo.insert!(%SpaceTraders.FleetAllocation.AllocationResultPointer{
      fleet_generation_id: generation.id,
      operator_id: scope.operator.id,
      fleet_strategy_revision_id: revision.id,
      selection_kind: :neutral_wait,
      strategy_decision_episode_id: episode.id
    })

    episode
  end

  defp publish_market!(scope, generation) do
    revision = FleetStrategy.get(scope).active_revision
    generation = Repo.get!(SpaceTraders.FleetGeneration.Generation, generation.id)

    candidate = %SpaceTraders.FleetAllocation.PortfolioCandidate{
      id: "market-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["#{@symbol}-1"],
      reservations: %{},
      pledges: [],
      dependencies: [%{evidence_id: "market:X1-UX81-A1", state: :satisfied}],
      expected_value: 100,
      unwind_cost: 0
    }

    {:ok, selection} =
      SpaceTraders.FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: generation.allocation_version,
        claims: ["#{@symbol}-1"],
        reservations: %{}
      })

    {:ok, portfolio} =
      SpaceTraders.FleetAllocation.publish_portfolio(scope, generation.id, selection, %{
        evidence_references: [],
        expectations: %{"credit_change" => 100},
        calibration_version: "market-v1"
      })

    portfolio
  end

  defp stall_episode(scope, generation, reason) do
    revision = FleetStrategy.get(scope).active_revision

    Repo.insert!(%SpaceTraders.FleetAllocation.StrategyDecisionEpisode{
      operator_id: scope.operator.id,
      fleet_generation_id: generation.id,
      fleet_strategy_revision_id: revision.id,
      source_version: 1,
      calibration_version: "market-v1",
      selection_kind: :structural_stall,
      stall_reason: reason,
      evidence_references: [%{"kind" => "observation_demand", "subject" => "market:X1-A1"}],
      last_observed_at: DateTime.utc_now(),
      observation_count: 2
    })
  end

  describe "Server Reset replacement" do
    test "exhausted names show the fenced transition until an Operator retry succeeds",
         %{conn: conn, scope: scope} do
      mint_fleet(scope)
      {:ok, _} = SpaceTraders.AgentNameBank.save(["ORBITALIST"])
      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v2/register"} ->
            send(parent, {:register, conn.body_params["symbol"]})
            symbol_taken(conn)

          _ ->
            reset_mismatch(conn)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/mission-control")

      assert_received {:register, @symbol}
      assert_received {:register, "ORBITALIST"}
      refute_received {:register, _}
      assert has_element?(view, "#operating-health", "Server Reset transition")
      assert has_element?(view, "#server-reset-replacement", "A Server Reset fenced #{@symbol}")
      assert has_element?(view, "#needs-attention", "Edit the Agent Name Bank")
      assert has_element?(view, "#retry-reset-replacement")
      refute has_element?(view, "#generation-replacement")

      {:ok, _} = SpaceTraders.AgentNameBank.save(["PARALLAX"])

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path, conn.body_params["symbol"]} do
          {"POST", "/v2/register", "PARALLAX"} ->
            send(parent, {:register, "PARALLAX"})
            fleet_api(conn, "PARALLAX")

          {"POST", "/v2/register", symbol} ->
            send(parent, {:register, symbol})
            symbol_taken(conn)

          _ ->
            fleet_api(conn, "PARALLAX")
        end
      end)

      html = view |> element("#retry-reset-replacement") |> render_click()

      assert html =~ "Replaced after the Server Reset: PARALLAX is current."
      assert_received {:register, @symbol}
      assert_received {:register, "PARALLAX"}

      assert has_element?(
               view,
               "#generation-replacement",
               "Replaced Generation 1 (#{@symbol}) after a Server Reset."
             )

      assert has_element?(view, "#strategy-context", "Generation 2")
      refute has_element?(view, "#server-reset-replacement")
      refute has_element?(view, "#needs-attention", "Edit the Agent Name Bank")
    end

    test "same-name replacement presents the distinct successor Generation",
         %{conn: conn, scope: scope} do
      {predecessor, _} = mint_fleet(scope)

      old_waypoint =
        SpaceTraders.API.Model.Waypoint.from_json(%{
          "symbol" => "X1-UX81-OLD",
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => 0,
          "y" => 0
        })

      {:ok, _} =
        SpaceTraders.Intelligence.observe_waypoint(predecessor, old_waypoint,
          source: "get_waypoint"
        )

      Req.Test.stub(SpaceTraders.API, &reset_then_same_name/1)

      {:ok, view, _html} = live(conn, ~p"/mission-control")

      assert {:ok, %{state: :current, generation: %{number: 2, symbol: @symbol}}} =
               FleetGeneration.current_fleet(scope)

      # The projection read during reset detection never pairs the predecessor's
      # reads with the successor; the next projection shows the successor.
      send(view.pid, :fleet_strategy_updated)
      assert has_element?(view, "#strategy-context", "Generation 2")

      assert has_element?(
               view,
               "#generation-replacement",
               "Replaced Generation 1 (#{@symbol}) after a Server Reset."
             )

      {:ok, %{agent: successor}} = FleetGeneration.current_fleet(scope)

      new_waypoint =
        SpaceTraders.API.Model.Waypoint.from_json(%{
          "symbol" => "X1-UX81-NEW",
          "systemSymbol" => "X1-UX81",
          "type" => "JUMP_GATE",
          "x" => 1,
          "y" => 2
        })

      {:ok, _} =
        SpaceTraders.Intelligence.observe_waypoint(successor, new_waypoint,
          source: "get_waypoint"
        )

      # World resolves the same new identity, even though its symbol was reused.
      {:ok, world, _} = live(conn, ~p"/world")
      assert has_element?(world, "#world-waypoint-X1-UX81-NEW")
      refute has_element?(world, "#world-waypoint-X1-UX81-OLD")
    end

    test "a lost replacement response exposes authenticated reconciliation rather than another mint",
         %{conn: conn, scope: scope} do
      {predecessor, _} = mint_fleet(scope)
      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.method do
          "POST" ->
            send(parent, {:register, conn.body_params["symbol"]})
            Req.Test.transport_error(conn, :timeout)

          "GET" ->
            reset_mismatch(conn)
        end
      end)

      {:ok, view, _} = live(conn, ~p"/mission-control")
      assert_received {:register, @symbol}
      refute_received {:register, _}

      assert has_element?(
               view,
               "#mission-registration-recovery",
               "Registration of #{@symbol} may have succeeded"
             )

      assert has_element?(
               view,
               "#mission-registration-recovery a[href='/agents/new']",
               "Reconcile registration"
             )

      refute has_element?(view, "#retry-reset-replacement")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "GET"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer RECOVERED_TOKEN"]
        fleet_api(conn, @symbol)
      end)

      {:ok, recovery, _} = live(conn, ~p"/agents/new")
      refute has_element?(recovery, "#mint_form")
      assert has_element?(recovery, "#adopt_registered_form")

      assert {:ok, _conn} =
               recovery
               |> form("#adopt_registered_form", %{
                 "adopt" => %{"agent_token" => "RECOVERED_TOKEN", "confirmed" => "true"}
               })
               |> render_submit()
               |> follow_redirect(conn, ~p"/mission-control")

      {:ok, recovered, _} = live(conn, ~p"/mission-control")
      assert has_element?(recovered, "#strategy-context", "Generation 2")
      refute has_element?(recovered, "#mission-registration-recovery")

      assert has_element?(
               recovered,
               "#needs-attention",
               "No unresolved Attention or Intervention."
             )

      assert {:ok, %{state: :current, agent: successor}} = FleetGeneration.current_fleet(scope)
      assert successor.id != predecessor.id
      assert {:error, :stale_agent} = FleetGeneration.gameplay_authority(predecessor.id)
      refute_received {:register, _}
    end

    test "Emergency Stop suppresses automatic and Operator-requested replacement",
         %{conn: conn, scope: scope} do
      mint_fleet(scope)
      {:ok, _stop} = FleetStrategy.engage_emergency_stop(scope)
      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        if conn.method == "POST", do: send(parent, {:register, conn.body_params["symbol"]})
        reset_mismatch(conn)
      end)

      {:ok, view, _html} = live(conn, ~p"/mission-control")
      html = view |> element("#retry-reset-replacement") |> render_click()

      assert html =~ "Emergency Stop is engaged. Replacement minting is suppressed"
      assert has_element?(view, "#operating-health", "STOPPED")
      refute_received {:register, _}
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)
    end

    test "missing AccountToken authority is a pinned Intervention, not a retry loop",
         %{conn: conn, scope: scope} do
      mint_fleet(scope)

      scope.operator.id
      |> Agent.get_operator!()
      |> Ecto.Changeset.change(account_token: nil)
      |> Repo.update!()

      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        if conn.method == "POST", do: send(parent, {:register, conn.body_params["symbol"]})
        reset_mismatch(conn)
      end)

      {:ok, view, _html} = live(conn, ~p"/mission-control")
      assert has_element?(view, "#needs-attention", "AccountToken authority is unavailable")

      html = view |> element("#retry-reset-replacement") |> render_click()
      assert html =~ "Link an AccountToken in Settings before replacement can mint."
      refute_received {:register, _}
    end

    test "an ordinary authentication failure is not presented as a Server Reset",
         %{conn: conn, scope: scope} do
      mint_fleet(scope)
      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        if conn.method == "POST", do: send(parent, {:register, conn.body_params["symbol"]})

        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => 4104, "message" => "Token is invalid"}})
      end)

      {:ok, view, _html} = live(conn, ~p"/mission-control")

      refute has_element?(view, "#server-reset-replacement")
      refute has_element?(view, "#operating-health", "Server Reset transition")
      refute_received {:register, _}
      assert {:ok, %{state: :current}} = FleetGeneration.current_fleet(scope)
    end
  end

  defp reset_then_same_name(conn) do
    if conn.method == "POST" do
      fleet_api(conn, @symbol, "SUCCESSOR_AGENT_TOKEN")
    else
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer SUCCESSOR_AGENT_TOKEN"] -> fleet_api(conn, @symbol)
        _ -> reset_mismatch(conn)
      end
    end
  end

  defp reset_mismatch(conn) do
    conn
    |> Plug.Conn.put_status(401)
    |> Req.Test.json(%{
      "error" => %{
        "code" => 4113,
        "message" =>
          "Failed to parse token. Token reset_date does not match the server. " <>
            "Server resets happen on a weekly to bi-weekly frequency during alpha. " <>
            "After a reset, you should re-register your agent. " <>
            "Expected: 2026-09-15, Actual: 2026-09-01"
      }
    })
  end

  defp symbol_taken(conn) do
    conn
    |> Plug.Conn.put_status(400)
    |> Req.Test.json(%{"error" => %{"code" => 4103, "message" => "Symbol is already in use"}})
  end

  defp mint_fleet(scope) do
    {:ok, _operator} = Agent.link_account_token(scope, "MISSION_CONTROL_ACCOUNT_TOKEN")
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _revision} = FleetStrategy.activate(scope, strategy.draft_version)

    Req.Test.stub(SpaceTraders.API, &briefing_api/1)

    {:ok, %{agent: minted}} =
      FleetGeneration.mint(scope, %{
        symbol: @symbol,
        faction: "COSMIC",
        replacement_symbols: [@symbol]
      })

    [generation] = FleetGeneration.list_generations(scope)
    {SpaceTraders.Repo.get!(SpaceTraders.Agent.Agent, minted.id), generation}
  end

  defp briefing_api(conn), do: fleet_api(conn, @symbol)

  defp fleet_api(conn, symbol, token \\ nil) do
    case {conn.method, conn.request_path} do
      {"POST", "/v2/register"} ->
        Req.Test.json(conn, %{
          "data" => %{
            "token" => token || "#{symbol}_AGENT_TOKEN",
            "agent" => %{
              "symbol" => symbol,
              "credits" => 175_000,
              "headquarters" => "X1-UX81-A1",
              "startingFaction" => "COSMIC"
            },
            "contract" => %{"id" => "briefing-contract", "type" => "PROCUREMENT"},
            "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
            "ships" => [ship_body("#{symbol}-1")]
          }
        })

      {"GET", "/v2/my/agent"} ->
        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "BRIEFING_ACCOUNT",
            "symbol" => symbol,
            "headquarters" => "X1-UX81-A1",
            "credits" => 175_120,
            "startingFaction" => "COSMIC",
            "shipCount" => 1
          }
        })

      {"GET", "/v2/my/ships"} ->
        Req.Test.json(conn, %{"data" => [ship_body("#{symbol}-1")]})

      {"GET", "/v2/my/contracts"} ->
        Req.Test.json(conn, %{"data" => []})
    end
  end
end
