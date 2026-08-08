defmodule SpaceTradersWeb.OperatorLive.MintTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Repo

  @mint_form %{"agent" => %{"symbol" => "MINER1", "faction" => "COSMIC"}}

  defp register_stub(body, status \\ 200) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v2/register"} ->
          conn
          |> Map.put(:status, status)
          |> Req.Test.json(body)

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "MINER1",
              "headquarters" => "X1-UX81-A2",
              "credits" => 175_000,
              "startingFaction" => "COSMIC",
              "shipCount" => 0
            }
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => []})

        {"GET", "/v2/my/contracts"} ->
          Req.Test.json(conn, %{"data" => []})

        {"GET", "/v2/systems/X1-UX81/waypoints"} ->
          Req.Test.json(conn, %{"data" => []})
      end
    end)
  end

  defp minted_agent_body(symbol) do
    %{
      "data" => %{
        "token" => "AGENT_TOKEN",
        "agent" => %{
          "symbol" => symbol,
          "credits" => 175_000,
          "headquarters" => "X1-UX81-A2",
          "startingFaction" => "COSMIC"
        },
        "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
        "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
        "ships" => []
      }
    }
  end

  describe "Mint page" do
    test "requires authentication", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/agents/new")
      assert {:redirect, %{to: path}} = redirect
      assert path == ~p"/operators/log-in"
    end

    test "shows the mint form when an AccountToken is linked", %{conn: conn} do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN")

      {:ok, _lv, html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      assert html =~ "Mint an agent"
      assert html =~ "COSMIC"
      assert html =~ ~s(<input type="text" name="agent[symbol]")
    end

    test "prompts to link an AccountToken when none is linked", %{conn: conn} do
      operator = operator_fixture()

      {:ok, _lv, html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      assert html =~ "Link your AccountToken in"
      refute html =~ ~s(<input type="text" name="agent[symbol]")
    end

    test "mints an agent and redirects home", %{conn: conn} do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN")
      register_stub(minted_agent_body("MINER1"))

      conn = log_in_operator(conn, operator)
      {:ok, lv, _html} = live(conn, ~p"/agents/new")

      {:ok, conn} =
        lv
        |> form("#mint_form", @mint_form)
        |> render_submit()
        |> follow_redirect(conn, ~p"/")

      agent = Repo.get_by!(SpaceTraders.Agent.Agent, symbol: "MINER1")
      assert agent.operator_id == operator.id
      assert agent.agent_token == "AGENT_TOKEN"
      assert agent.headquarters == "X1-UX81-A2"

      assert conn.resp_body =~ "MINER1"
      assert conn.resp_body =~ "Fleet command"
    end

    test "shows a flash error when the game rejects the mint", %{conn: conn} do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN")
      register_stub(%{"error" => %{"code" => 4103, "message" => "Symbol is already in use"}}, 400)

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      result =
        lv
        |> form("#mint_form", %{"agent" => %{"symbol" => "DUPLICATE", "faction" => "COSMIC"}})
        |> render_submit()

      assert result =~ "Symbol is already in use"
    end

    test "explains when an AgentToken is linked instead of an AccountToken", %{conn: conn} do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "AGENT_TOKEN")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{
          "error" => %{
            "code" => 4101,
            "message" =>
              "Token has an invalid subject claim. Expected \"account-token\" but received agent-token."
          }
        })
      end)

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      result =
        lv
        |> form("#mint_form", @mint_form)
        |> render_submit()

      assert result =~ "Use an AccountToken to mint agents"
      assert result =~ "AgentToken belongs in the existing-agent import form"
    end

    test "renders validation errors for an invalid symbol", %{conn: conn} do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN")

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      result =
        lv
        |> form("#mint_form", %{"agent" => %{"symbol" => "bad symbol", "faction" => "COSMIC"}})
        |> render_submit()

      assert result =~ "must be 1-20 uppercase letters, digits, dashes or underscores"
    end
  end
end
