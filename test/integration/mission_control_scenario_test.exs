defmodule SpaceTraders.MissionControlScenarioTest do
  @moduledoc """
  Proves the Operator-facing Mission Control briefing answers the four Fleet
  questions from one authenticated surface, and that collection gaps stay
  truthful rather than becoming zero measurements.

  The scenario drives production interfaces only: Operator setup, Fleet
  Strategy activation, Fleet Generation minting, Objective evidence recording,
  condition lifecycle, and the authenticated LiveView.
  """

  use SpaceTraders.ScenarioCase

  import Phoenix.LiveViewTest
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Evidence, FleetGeneration, FleetStrategy, OperatorConditions}

  @account_token "MISSION_CONTROL_SCENARIO_ACCOUNT_TOKEN"
  @email "mission-control-scenario@example.com"
  @symbol "MCCTRL"

  test "an authenticated Operator answers the Fleet's four questions from one briefing", %{
    conn: conn
  } do
    conn = register_operator(conn)
    operator = Agent.get_operator_by_email(@email)
    scope = Scope.for_operator(operator)

    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    stub_api(&mission_control_api/1)

    {:ok, %{agent: agent}} =
      FleetGeneration.mint(scope, %{
        symbol: @symbol,
        faction: "COSMIC",
        replacement_symbols: [@symbol]
      })

    [generation] = FleetGeneration.list_generations(scope)
    assert generation.fleet_strategy_revision_id == revision.id
    assert %DateTime{} = generation.strategy_capable_at

    {:ok, _generation} =
      FleetGeneration.record_objective_progress(scope, generation.id, 0, %{
        "change" => 120,
        "elapsed_seconds" => 60,
        "horizon_seconds" => 3600,
        "feasible?" => true,
        "evidence_id" => objective_evidence(agent, 175_120).id
      })

    {:ok, view, html} = live(conn, ~p"/mission-control")

    # Question 1: is the Fleet healthy?
    assert has_element?(view, "#operating-health", "Operating normally")

    # Question 2: are objectives succeeding?
    assert has_element?(view, "#objective-evaluations", "Objective status: Growing")

    # Question 3: what is the Fleet doing? Consequential milestones, not API noise.
    assert has_element?(view, "#notable-activity", "Generation 1 began with #{@symbol}")
    refute html =~ "API request retrying"

    # Question 4: am I needed? Attention and Intervention are distinct states.
    {:ok, attention} =
      OperatorConditions.raise(
        scope,
        "credit-floor",
        :attention,
        "Protected credit floor is at risk"
      )

    {:ok, _intervention} =
      OperatorConditions.raise(
        scope,
        "external-authority",
        :intervention,
        "AccountToken is needed to replace the Agent"
      )

    assert render(view) =~ "Needs Operator attention"
    assert has_element?(view, "#needs-attention", "Attention")
    assert has_element?(view, "#needs-attention", "Intervention")
    assert has_element?(view, "#needs-attention", "Protected credit floor is at risk")
    assert has_element?(view, "#needs-attention", "AccountToken is needed to replace the Agent")

    # Acknowledgement is an explicit action, not resolution.
    refute has_element?(view, "#needs-attention", "Acknowledged · unresolved")

    view
    |> element("#needs-attention button[phx-value-id='#{attention.id}']")
    |> render_click()

    assert has_element?(view, "#needs-attention", "Acknowledged · unresolved")
    assert has_element?(view, "#needs-attention", "Protected credit floor is at risk")

    assert [%{id: id, acknowledged_at: %DateTime{}}] =
             Enum.filter(OperatorConditions.unresolved(scope), &(&1.id == attention.id))
             |> Enum.take(1)

    assert id == attention.id
  end

  test "a collection gap renders as unknown, never as a zero measurement", %{conn: conn} do
    conn = register_operator(conn)
    operator = Agent.get_operator_by_email(@email)
    scope = Scope.for_operator(operator)

    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _revision} = FleetStrategy.activate(scope, strategy.draft_version)

    stub_api(&mission_control_api/1)

    {:ok, _agent} =
      FleetGeneration.mint(scope, %{
        symbol: @symbol,
        faction: "COSMIC",
        replacement_symbols: [@symbol]
      })

    stub_api(fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"message" => "Game API unavailable"}})
    end)

    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#operating-health", "Fleet health unknown")
    assert has_element?(view, "#operating-health", "this is not a zero measurement")
    refute has_element?(view, "#operating-health", "Operating normally")
  end

  test "a Stale Agent stays distinct from an unknown Fleet and never a zero measurement", %{
    conn: conn
  } do
    conn = register_operator(conn)
    operator = Agent.get_operator_by_email(@email)
    scope = Scope.for_operator(operator)

    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _revision} = FleetStrategy.activate(scope, strategy.draft_version)

    stub_api(&mission_control_api/1)

    {:ok, _agent} =
      FleetGeneration.mint(scope, %{
        symbol: @symbol,
        faction: "COSMIC",
        replacement_symbols: [@symbol]
      })

    stub_api(fn conn ->
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
    refute has_element?(view, "#operating-health", "Operating normally")
  end

  defp register_operator(conn) do
    conn =
      post(conn, ~p"/setup", %{
        "operator" => %{
          "email" => @email,
          "password" => "a long scenario password",
          "password_confirmation" => "a long scenario password",
          "account_token" => @account_token
        }
      })

    assert get_session(conn, :operator_token)
    conn
  end

  defp mission_control_api(conn) do
    case {conn.method, conn.request_path} do
      {"POST", "/v2/register"} ->
        Req.Test.json(conn, %{
          "data" => %{
            "token" => "MISSION_CONTROL_AGENT_TOKEN",
            "agent" => %{
              "symbol" => @symbol,
              "credits" => 175_000,
              "headquarters" => "X1-TEST-A1",
              "startingFaction" => "COSMIC"
            },
            "contract" => %{"id" => "scenario-contract", "type" => "PROCUREMENT"},
            "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
            "ships" => []
          }
        })

      {"GET", "/v2/my/agent"} ->
        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "SCENARIO_ACCOUNT",
            "symbol" => @symbol,
            "headquarters" => "X1-TEST-A1",
            "credits" => 175_120,
            "startingFaction" => "COSMIC",
            "shipCount" => 1
          }
        })

      {"GET", "/v2/my/ships"} ->
        Req.Test.json(conn, %{"data" => [ship_body("#{@symbol}-1")]})

      {"GET", "/v2/my/contracts"} ->
        Req.Test.json(conn, %{"data" => []})

      request ->
        flunk("unexpected Mission Control scenario request: #{inspect(request)}")
    end
  end

  defp objective_evidence(agent, credits) do
    observation =
      Evidence.authoritative_observation(
        "get-my-agent",
        ["agent:#{agent.id}"],
        %{"response" => %{"credits" => credits}}
      )

    %Evidence.Observation{
      agent_id: agent.id,
      subject: "agent:#{agent.id}",
      operation_id: observation.operation_id,
      dependency_keys: observation.dependency_keys,
      facts: observation.facts,
      response_fingerprint: observation.response_fingerprint,
      observed_at: observation.observed_at
    }
    |> Repo.insert!()
  end
end
