defmodule SpaceTraders.AutonomousRuntimeScenarioTest do
  use SpaceTraders.ScenarioCase

  import Phoenix.LiveViewTest
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: GameAgent
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  @account_token "SCENARIO_ACCOUNT_TOKEN"
  @agent_token "SCENARIO_AGENT_TOKEN"
  @ship_symbol "SCENARIO-1"

  test "authenticated commands and autonomous recovery remain durable and observable", %{
    conn: conn
  } do
    conn =
      post(conn, ~p"/setup", %{
        "operator" => %{
          "email" => "scenario@example.com",
          "password" => "a long scenario password",
          "password_confirmation" => "a long scenario password",
          "account_token" => @account_token
        }
      })

    assert get_session(conn, :operator_token)

    stub_api(fn conn ->
      assert get_req_header(conn, "authorization") == ["Bearer #{@account_token}"]

      Req.Test.json(conn, %{
        "data" => %{
          "token" => @agent_token,
          "agent" => %{
            "symbol" => "SCENARIO",
            "credits" => 175_000,
            "headquarters" => "X1-TEST-A1",
            "startingFaction" => "COSMIC"
          },
          "contract" => %{"id" => "scenario-contract", "type" => "PROCUREMENT"},
          "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
          "ships" => [ship_body(@ship_symbol)]
        }
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/agents/new")

    assert {:error, {:redirect, %{to: "/", status: 302}}} =
             view
             |> form("#mint_form", %{"agent" => %{"symbol" => "SCENARIO", "faction" => "COSMIC"}})
             |> render_submit()

    assert_receive {:scenario_telemetry, [:spacetraders, :api, :request], %{count: 1}, minted}
    assert minted.endpoint == "/register"
    refute inspect(minted) =~ @account_token
    refute inspect(minted) =~ @agent_token

    game_agent = Repo.get_by!(GameAgent, symbol: "SCENARIO")

    Repo.insert!(%Ship{
      symbol: @ship_symbol,
      ship_type: "SHIP_COMMAND_FRIGATE",
      agent_id: game_agent.id
    })

    subscribe_to_notifications(game_agent)

    due_at = DateTime.add(SpaceTraders.Clock.utc_now(), 5, :minute)

    {:ok, event} = Timeline.schedule_event(:ship, @ship_symbol, :arrival, due_at)

    assert :ok = ShipServer.arm(game_agent, @ship_symbol, event)
    assert ShipServer.ensure_ready(@ship_symbol) == {:error, :ship_in_transit}

    stub_api(fn conn ->
      assert conn.request_path == "/v2/my/ships/#{@ship_symbol}"
      Req.Test.transport_error(conn, :timeout)
    end)

    allow_runtime_api()

    assert advance_time(5, :minute) == due_at

    assert_receive failed_signal =
                     {:scenario_telemetry, [:spacetraders, :api, :request], %{count: 1}, failed}

    assert failed.agent_id == game_agent.id
    assert failed.ship_symbol == @ship_symbol
    assert failed.outcome == "unknown"
    refute inspect(failed_signal) =~ @agent_token
    assert Repo.get!(Event, event.id).status == "pending"

    stub_api(fn conn -> Req.Test.json(conn, %{"data" => ship_body(@ship_symbol)}) end)
    restart_runtime_processes()

    assert_receive notification = {:ship_updated, agent_id, @ship_symbol}
    assert agent_id == game_agent.id
    assert_eventually(fn -> Repo.get!(Event, event.id).status == "done" end)

    captured = [notification | drain_external_signals()]
    inspected = inspect(captured)

    assert Enum.any?(captured, fn
             {:scenario_telemetry, [:spacetraders, :api, :request], _, metadata} ->
               metadata.agent_id == game_agent.id and metadata.ship_symbol == @ship_symbol

             _ ->
               false
           end)

    refute inspected =~ @account_token
    refute inspected =~ @agent_token
    assert Agent.get_operator_by_email("scenario@example.com").account_token == @account_token
  end
end
