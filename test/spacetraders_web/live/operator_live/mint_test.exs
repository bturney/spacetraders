defmodule SpaceTradersWeb.OperatorLive.MintTest do
  # Minting tests mutate application-wide RuntimeAuthority configuration.
  use SpaceTradersWeb.ConnCase, async: false

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

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

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

    test "mints an agent and redirects to Mission Control", %{conn: conn} do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      register_stub(minted_agent_body("MINER1"))

      conn = log_in_operator(conn, operator)
      {:ok, lv, _html} = live(conn, ~p"/agents/new")

      {:ok, conn} =
        lv
        |> form("#mint_form", @mint_form)
        |> render_submit()
        |> follow_redirect(conn, ~p"/mission-control")

      agent = Repo.get_by!(SpaceTraders.Agent.Agent, symbol: "MINER1")
      assert agent.operator_id == operator.id
      assert agent.agent_token == "AGENT_TOKEN"
      assert agent.headquarters == "X1-UX81-A2"

      assert conn.resp_body =~ "MINER1"
      assert conn.resp_body =~ "Mission Control"
    end

    test "a Server Reset transition is not an ordinary mint path; a late submit sends nothing",
         %{conn: conn} do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      Req.Test.stub(SpaceTraders.API, fn _conn ->
        flunk("a fenced transition forbids ordinary registration")
      end)

      conn = log_in_operator(conn, operator)
      {:ok, lv, _html} = live(conn, ~p"/agents/new")

      stale =
        agent_fixture(operator, %{
          symbol: "ORBITALIST",
          stale_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      result = lv |> form("#mint_form", @mint_form) |> render_submit()
      assert result =~ "A Server Reset replacement is pending. No Agent was minted"
      assert has_element?(lv, "#server-reset-transition", "ORBITALIST")
      refute has_element?(lv, "#mint_form")
      assert [%{id: id}] = SpaceTraders.Repo.all(SpaceTraders.Agent.Agent)
      assert id == stale.id

      {:ok, lv, _html} = live(conn, ~p"/agents/new")
      refute has_element?(lv, "#mint_form")
      assert has_element?(lv, "a[href='/mission-control']", "Review replacement")
    end

    test "a current Fleet replaces the mint form; it is not an add-another Agent path", %{
      conn: conn
    } do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      agent_fixture(operator, %{symbol: "ORBITALIST"})

      {:ok, lv, html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      assert html =~ "This deployment already has a current Agent"
      assert html =~ "ORBITALIST"
      refute has_element?(lv, "#mint_form")
      assert has_element?(lv, "a[href='/mission-control']")
    end

    test "a mint submitted after another request established the Fleet is refused before registration",
         %{conn: conn} do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      Req.Test.stub(SpaceTraders.API, fn _conn ->
        flunk("an established Fleet forbids registration")
      end)

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")
      agent_fixture(operator, %{symbol: "ORBITALIST"})

      result = lv |> form("#mint_form", @mint_form) |> render_submit()

      assert result =~ "This deployment already has a current Agent"
      assert [%{symbol: "ORBITALIST"}] = SpaceTraders.Repo.all(SpaceTraders.Agent.Agent)
    end

    test "shows a flash error when the game rejects the mint", %{conn: conn} do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      register_stub(%{"error" => %{"code" => 4103, "message" => "Symbol is already in use"}}, 400)

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      result =
        lv
        |> form("#mint_form", %{"agent" => %{"symbol" => "DUPLICATE", "faction" => "COSMIC"}})
        |> render_submit()

      assert result =~ "Symbol is already in use"
    end

    test "reports when mutation authority is unavailable", %{conn: conn} do
      previous = Application.get_env(:spacetraders, SpaceTraders.RuntimeAuthority)
      Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, enabled: true)

      on_exit(fn ->
        Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, previous)
      end)

      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      result =
        lv
        |> form("#mint_form", @mint_form)
        |> render_submit()

      assert result =~ "Minting is temporarily unavailable. Please try again shortly."
    end

    test "explains when an AgentToken is linked instead of an AccountToken", %{conn: conn} do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "AGENT_TOKEN")

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

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      {:ok, lv, _html} = conn |> log_in_operator(operator) |> live(~p"/agents/new")

      result =
        lv
        |> form("#mint_form", %{"agent" => %{"symbol" => "bad symbol", "faction" => "COSMIC"}})
        |> render_submit()

      assert result =~ "must be 1-20 uppercase letters, digits, dashes or underscores"
    end
  end

  describe "registration recovery" do
    test "a lost response replaces the mint form with truthful reconciliation", %{conn: conn} do
      operator = operator_fixture()

      {:ok, operator} =
        Agent.link_account_token(SpaceTraders.Agent.Scope.for_operator(operator), "ACCOUNT_TOKEN")

      parent = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(parent, {:game_request, conn.method, conn.request_path})
        Req.Test.transport_error(conn, :timeout)
      end)

      conn = log_in_operator(conn, operator)
      {:ok, lv, _html} = live(conn, ~p"/agents/new")
      result = lv |> form("#mint_form", @mint_form) |> render_submit()

      assert result =~ "The registration outcome is still unknown"
      refute result =~ "No Agent was registered."
      assert result =~ "Registration of MINER1 may have succeeded"
      refute has_element?(lv, "#mint_form")
      assert has_element?(lv, "#reconcile-registration")
      assert has_element?(lv, "#adopt_registered_form")
      assert_received {:game_request, "POST", "/v2/register"}

      # A reload renders the same durable state; Glance can't tell, and asks nothing.
      {:ok, reloaded, _html} = live(conn, ~p"/agents/new")
      refute has_element?(reloaded, "#mint_form")
      assert render(reloaded) =~ "Registration of MINER1 may have succeeded"
      {:ok, _mission_control, html} = live(conn, ~p"/mission-control")
      assert html =~ "No current Fleet yet."
      refute html =~ "Reconcile registration"

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(parent, {:game_request, conn.method, conn.request_path})

        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "MINER1",
                "headquarters" => "X1-UX81-A2",
                "credits" => 175_000,
                "startingFaction" => "COSMIC"
              }
            })

          "/v2/my/ships" ->
            Req.Test.json(conn, %{
              "data" => [],
              "meta" => %{"total" => 0, "page" => 1, "limit" => 20}
            })

          _other ->
            Req.Test.json(conn, %{"data" => []})
        end
      end)

      {:ok, _conn} =
        reloaded
        |> form("#adopt_registered_form", %{
          "adopt" => %{"agent_token" => "RECOVERED_TOKEN", "confirmed" => "true"}
        })
        |> render_submit()
        |> follow_redirect(conn, ~p"/mission-control")

      refute_received {:game_request, "POST", _}

      assert [%{symbol: "MINER1", agent_token: "RECOVERED_TOKEN"}] =
               SpaceTraders.Repo.all(SpaceTraders.Agent.Agent)
    end
  end
end
