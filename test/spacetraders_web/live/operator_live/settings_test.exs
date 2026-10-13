defmodule SpaceTradersWeb.OperatorLive.SettingsTest do
  # Settings resolves the current Fleet, which may adopt deployment-wide; async
  # fixtures holding Agent writes would deadlock with adoption's table locks.
  use SpaceTradersWeb.ConnCase, async: false

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_operator(operator_fixture())
        |> live(~p"/operators/settings")

      assert html =~ "Change Email"
      assert html =~ "Save Password"
    end

    test "keeps account and application boundaries without planner controls", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_operator(operator_fixture())
        |> live(~p"/operators/settings")

      refute html =~ "Fleet Strategy"
      refute html =~ "Strategic Objective"
      refute html =~ "Hard Constraint"
      refute html =~ "Emergency Stop"
      refute html =~ "draft"
    end

    test "redirects if operator is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/operators/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/operators/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if operator is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_operator(operator_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/operators/settings")
        |> follow_redirect(conn, ~p"/operators/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      operator = operator_fixture()
      %{conn: log_in_operator(conn, operator), operator: operator}
    end

    test "updates the operator email", %{conn: conn, operator: operator} do
      new_email = unique_operator_email()

      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> form("#email_form", %{
          "operator" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Agent.get_operator_by_email(operator.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "operator" => %{"email" => "with spaces"}
        })

      assert result =~ "Change Email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, operator: operator} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> form("#email_form", %{
          "operator" => %{"email" => operator.email}
        })
        |> render_submit()

      assert result =~ "Change Email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      operator = operator_fixture()
      %{conn: log_in_operator(conn, operator), operator: operator}
    end

    test "updates the operator password", %{conn: conn, operator: operator} do
      new_password = valid_operator_password()

      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      form =
        form(lv, "#password_form", %{
          "operator" => %{
            "email" => operator.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/operators/settings"

      assert get_session(new_password_conn, :operator_token) != get_session(conn, :operator_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Agent.get_operator_by_email_and_password(operator.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "operator" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> form("#password_form", %{
          "operator" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save Password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      operator = operator_fixture()
      email = unique_operator_email()

      token =
        extract_operator_token(fn url ->
          Agent.deliver_operator_update_email_instructions(
            %{operator | email: email},
            operator.email,
            url
          )
        end)

      %{conn: log_in_operator(conn, operator), token: token, email: email, operator: operator}
    end

    test "updates the operator email once", %{
      conn: conn,
      operator: operator,
      token: token,
      email: email
    } do
      {:error, redirect} = live(conn, ~p"/operators/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/operators/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Agent.get_operator_by_email(operator.email)
      assert Agent.get_operator_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/operators/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/operators/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, operator: operator} do
      {:error, redirect} = live(conn, ~p"/operators/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/operators/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Agent.get_operator_by_email(operator.email)
    end

    test "redirects if operator is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/operators/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/operators/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end

  describe "AccountToken linking" do
    setup %{conn: conn} do
      operator = operator_fixture()
      %{conn: log_in_operator(conn, operator), operator: operator}
    end

    test "shows the link form with unlinked status", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/operators/settings")

      assert html =~ "AccountToken"
      assert html =~ "Link your my.spacetraders.io AccountToken to mint agents in-app"
      refute html =~ "can't be blank"
    end

    test "never pre-fills the linked token into the form", %{conn: conn, operator: operator} do
      {:ok, operator} = Agent.link_account_token(operator, "LINKED_TOKEN")

      {:ok, _lv, html} = conn |> log_in_operator(operator) |> live(~p"/operators/settings")

      refute html =~ "LINKED_TOKEN"
      refute html =~ "can't be blank"
    end

    test "keeps the typed token while live-validating", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> live(~p"/operators/settings")

      result =
        lv
        |> element("#account_token_form")
        |> render_change(%{"operator" => %{"account_token" => "NEW_TOKEN"}})

      refute result =~ "can't be blank"
      assert result =~ ~s(value="NEW_TOKEN")
    end

    test "links the AccountToken", %{conn: conn, operator: operator} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> form("#account_token_form", %{"operator" => %{"account_token" => "ACCOUNT_TOKEN"}})
        |> render_submit()

      assert result =~ "AccountToken linked."
      assert Agent.get_operator!(operator.id).account_token == "ACCOUNT_TOKEN"

      {:ok, _mint_lv, mint_html} =
        lv
        |> element("#import-agent a", "Mint an Agent")
        |> render_click()
        |> follow_redirect(conn, ~p"/agents/new")

      assert mint_html =~ ~s(<input type="text" name="agent[symbol]")
    end

    test "rejects a blank AccountToken", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> form("#account_token_form", %{"operator" => %{"account_token" => ""}})
        |> render_submit()

      assert result =~ "can&#39;t be blank"
    end
  end

  describe "existing agent import" do
    setup %{conn: conn} do
      operator = operator_fixture()
      %{conn: log_in_operator(conn, operator), operator: operator}
    end

    test "requires explicit confirmation", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/operators/settings")

      assert html =~ "Import an existing agent"
      assert html =~ "I confirm this AgentToken belongs to my agent"

      result =
        lv
        |> form("#import_agent_form", %{
          "import" => %{"agent_token" => "AGENT_TOKEN", "confirmed" => "false"}
        })
        |> render_submit()

      assert result =~ "Confirm that the AgentToken belongs to your agent"
      refute result =~ "AGENT_TOKEN"
    end

    test "validates and imports an existing agent without exposing its token", %{
      conn: conn,
      operator: operator
    } do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "ORBITALIST",
                "credits" => 42_000,
                "headquarters" => "X1-UX81-A1",
                "startingFaction" => "COSMIC",
                "shipCount" => 0
              }
            })

          "/v2/my/ships" ->
            Req.Test.json(conn, %{
              "data" => [],
              "meta" => %{"total" => 0, "page" => 1, "limit" => 20}
            })
        end
      end)

      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      result =
        lv
        |> form("#import_agent_form", %{
          "import" => %{"agent_token" => "AGENT_TOKEN", "confirmed" => "true"}
        })
        |> render_submit()

      assert result =~ "Agent ORBITALIST imported."
      refute result =~ "AGENT_TOKEN"
      assert [agent] = Agent.list_agents(Agent.get_operator!(operator.id))
      assert agent.symbol == "ORBITALIST"

      assert {:ok, %{state: :current, agent: %{id: current_id}}} =
               SpaceTraders.FleetGeneration.current_fleet(Scope.for_operator(operator))

      assert current_id == agent.id
      refute has_element?(lv, "#import_agent_form")
    end

    test "import is initial setup only; a current Fleet has no import path", %{
      conn: conn,
      operator: operator
    } do
      agent_fixture(operator, %{symbol: "ORBITALIST"})

      {:ok, lv, html} = live(conn, ~p"/operators/settings")

      refute has_element?(lv, "#import_agent_form")
      assert html =~ "This deployment already has a current Agent"
    end

    test "an import submitted after another request established the Fleet is refused", %{
      conn: conn,
      operator: operator
    } do
      Req.Test.stub(SpaceTraders.API, fn _conn ->
        flunk("an established Fleet forbids import reads")
      end)

      {:ok, lv, _html} = live(conn, ~p"/operators/settings")
      agent_fixture(operator, %{symbol: "ORBITALIST"})

      result =
        lv
        |> form("#import_agent_form", %{
          "import" => %{"agent_token" => "AGENT_TOKEN", "confirmed" => "true"}
        })
        |> render_submit()

      assert result =~ "This deployment already has a current Agent"
      refute result =~ "AGENT_TOKEN"
      assert [%{symbol: "ORBITALIST"}] = Agent.list_agents(operator)
    end
  end

  describe "Agent Name Bank" do
    setup %{conn: conn} do
      operator = operator_fixture()
      %{conn: log_in_operator(conn, operator)}
    end

    test "shows the stored candidates in order", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")
      assert lv |> element("#name_bank_form textarea") |> render() =~ "ORBITALIST\nPARALLAX"
    end

    test "saves an edited, reordered bank for Fleet Generation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      html =
        lv
        |> form("#name_bank_form", %{"name_bank" => %{"names" => "zenith\nNADIR"}})
        |> render_submit()

      assert html =~ "Agent Name Bank saved"
      assert SpaceTraders.AgentNameBank.list() == ["ZENITH", "NADIR"]
    end

    test "invalid submission explains the error, keeps the draft and the stored bank", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      html =
        lv
        |> form("#name_bank_form", %{"name_bank" => %{"names" => "ab\nNADIR\nnadir"}})
        |> render_submit()

      assert html =~ "AB"
      assert html =~ "at least 3"
      assert html =~ "NADIR"
      assert lv |> element("#name_bank_form textarea") |> render() =~ "ab\nNADIR\nnadir"

      assert SpaceTraders.AgentNameBank.list() ==
               ~w(ORBITALIST PARALLAX APHELION SIDEREAL LIMINAL)
    end

    test "unsaved edits survive recurring patches and sibling form events", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/settings")

      lv
      |> element("#name_bank_form")
      |> render_change(%{"name_bank" => %{"names" => "DRAFTY\nONE"}})

      send(lv.pid, :refresh_name_bank)

      lv
      |> element("#account_token_form")
      |> render_change(%{"operator" => %{"account_token" => "X"}})

      assert lv |> element("#name_bank_form textarea") |> render() =~ "DRAFTY\nONE"
    end
  end
end
