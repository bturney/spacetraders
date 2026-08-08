defmodule SpaceTradersWeb.OperatorLive.SettingsTest do
  use SpaceTradersWeb.ConnCase

  alias SpaceTraders.Agent
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

    test "never pre-fills the linked token into the form", %{conn: conn} do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "LINKED_TOKEN")

      {:ok, _lv, html} = conn |> log_in_operator(operator) |> live(~p"/operators/settings")

      refute html =~ "LINKED_TOKEN"
      refute html =~ "can't be blank"
    end

    test "keeps the typed token while live-validating", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> log_in_operator(operator_fixture())
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
        assert conn.request_path == "/v2/my/agent"

        Req.Test.json(conn, %{
          "data" => %{
            "symbol" => "ORBITALIST",
            "credits" => 42_000,
            "headquarters" => "X1-UX81-A1",
            "startingFaction" => "COSMIC",
            "shipCount" => 1
          }
        })
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
    end
  end
end
