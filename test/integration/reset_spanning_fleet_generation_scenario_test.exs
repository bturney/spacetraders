defmodule SpaceTraders.ResetSpanningFleetGenerationScenarioTest do
  use SpaceTraders.ScenarioCase

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.FleetStrategy

  @account_token "RESET_SCENARIO_ACCOUNT_TOKEN"

  test "Fleet Strategy survives replacement and Emergency Stop suppresses the next replacement",
       %{conn: conn} do
    conn =
      post(conn, ~p"/setup", %{
        "operator" => %{
          "email" => "reset-scenario@example.com",
          "password" => "a long scenario password",
          "password_confirmation" => "a long scenario password",
          "account_token" => @account_token
        }
      })

    assert get_session(conn, :operator_token)

    operator = Agent.get_operator_by_email("reset-scenario@example.com")
    scope = Scope.for_operator(operator)

    assert {:ok, strategy} = FleetStrategy.select_preset(scope, "charted_expansion")
    assert {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    stub_api(fn conn ->
      Req.Test.json(conn, registration_body("RESETME", "FIRST_TOKEN"))
    end)

    assert {:ok, %{agent: minted}} =
             FleetGeneration.mint(scope, %{
               symbol: "RESETME",
               faction: "COSMIC",
               replacement_symbols: ["RESETME", "FALLBACK"]
             })

    stale_agent = Repo.get!(SpaceTraders.Agent.Agent, minted.id)

    stub_api(fn conn ->
      case {conn.method, conn.request_path, conn.body_params["symbol"]} do
        {"GET", "/v2/my/agent", nil} ->
          reset_mismatch(conn)

        {"POST", "/v2/register", "RESETME"} ->
          assert %DateTime{} = Repo.get!(SpaceTraders.Agent.Agent, stale_agent.id).stale_at

          conn
          |> put_status(400)
          |> Req.Test.json(%{
            "error" => %{"code" => 4103, "message" => "Symbol is already in use"}
          })

        {"POST", "/v2/register", "FALLBACK"} ->
          assert Repo.get(SpaceTraders.Agent.Agent, stale_agent.id)
          Req.Test.json(conn, registration_body("FALLBACK", "SECOND_TOKEN"))
      end
    end)

    assert {:error, :stale_agent} = FleetGeneration.agent_overview(stale_agent)
    assert FleetStrategy.get(scope).active_revision.id == revision.id

    assert [replacement, retired] = FleetGeneration.list_generations(scope)
    assert replacement.symbol == "FALLBACK"
    assert replacement.fleet_strategy_revision_id == revision.id
    assert %DateTime{} = replacement.strategy_capable_at
    assert %DateTime{} = retired.fenced_at
    assert %DateTime{} = retired.retired_at

    replacement_agent = Repo.get!(SpaceTraders.Agent.Agent, replacement.agent_id)
    assert {:ok, _stopped} = FleetStrategy.engage_emergency_stop(scope)

    stub_api(fn conn ->
      assert conn.method == "GET"
      reset_mismatch(conn)
    end)

    assert {:error, :stale_agent} = FleetGeneration.agent_overview(replacement_agent)
    assert Repo.get(SpaceTraders.Agent.Agent, replacement_agent.id)
    assert [still_active, _retired] = FleetGeneration.list_generations(scope)
    assert still_active.id == replacement.id
    assert %DateTime{} = still_active.fenced_at
    assert is_nil(still_active.retired_at)
    assert FleetStrategy.get(scope).active_revision.id == revision.id
  end

  defp reset_mismatch(conn) do
    conn
    |> put_status(401)
    |> Req.Test.json(%{
      "error" => %{
        "code" => 4113,
        "message" =>
          "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
      }
    })
  end

  defp registration_body(symbol, token) do
    %{
      "data" => %{
        "token" => token,
        "agent" => %{
          "symbol" => symbol,
          "credits" => 175_000,
          "headquarters" => "X1-TEST-A1",
          "startingFaction" => "COSMIC"
        },
        "contract" => %{"id" => "scenario-contract", "type" => "PROCUREMENT"},
        "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
        "ships" => []
      }
    }
  end
end
