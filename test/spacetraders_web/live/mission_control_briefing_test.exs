defmodule SpaceTradersWeb.MissionControlBriefingTest do
  # Admission caches are cleared when ConnCase closes the shared sandbox.
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent
  alias SpaceTraders.{Evidence, Fleet, FleetGeneration, FleetStrategy, OperatorConditions}

  @symbol "MCCTRL"

  setup :register_and_log_in_operator

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

    {:ok, activity, _html} = live(conn, ~p"/activity")
    assert has_element?(activity, "#activity-history #condition-#{attention.id}", "Resolved")

    assert has_element?(
             activity,
             "#activity-history #condition-#{recurrence.id}",
             "Still unresolved"
           )

    assert has_element?(
             activity,
             "#condition-#{attention.id} a[href='/world/systems/X1/waypoints/X1-A1/construction']",
             "Construction"
           )
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
    assert has_element?(view, "#operating-health", "this is not a zero measurement")
    refute has_element?(view, "#operating-health", "Fleet health unknown")
    refute has_element?(view, "#operating-health", "Operating normally")
    refute has_element?(view, "#fleet-health", "0 Ships in this Fleet Generation")
  end

  defp mint_fleet(scope) do
    {:ok, _operator} = Agent.link_account_token(scope.operator, "MISSION_CONTROL_ACCOUNT_TOKEN")
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
    {Agent.get_agent(scope, minted.id), generation}
  end

  defp briefing_api(conn) do
    case {conn.method, conn.request_path} do
      {"POST", "/v2/register"} ->
        Req.Test.json(conn, %{
          "data" => %{
            "token" => "MISSION_CONTROL_AGENT_TOKEN",
            "agent" => %{
              "symbol" => @symbol,
              "credits" => 175_000,
              "headquarters" => "X1-UX81-A1",
              "startingFaction" => "COSMIC"
            },
            "contract" => %{"id" => "briefing-contract", "type" => "PROCUREMENT"},
            "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
            "ships" => [ship_body("#{@symbol}-1")]
          }
        })

      {"GET", "/v2/my/agent"} ->
        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "BRIEFING_ACCOUNT",
            "symbol" => @symbol,
            "headquarters" => "X1-UX81-A1",
            "credits" => 175_120,
            "startingFaction" => "COSMIC",
            "shipCount" => 1
          }
        })

      {"GET", "/v2/my/ships"} ->
        Req.Test.json(conn, %{"data" => [ship_body("#{@symbol}-1")]})

      {"GET", "/v2/my/contracts"} ->
        Req.Test.json(conn, %{"data" => []})
    end
  end
end
