defmodule SpaceTradersWeb.OperatorLive.RegistrationTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/operators/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_operator(operator_fixture())
        |> live(~p"/operators/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(operator: %{"email" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register operator" do
    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/register")

      email = unique_operator_email()

      form =
        form(lv, "#registration_form",
          operator:
            valid_operator_attributes(email: email)
            |> Map.put(:password_confirmation, valid_operator_password())
        )

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/operators/log-in")

      assert html =~ "Account created. Log in to continue."

      assert %SpaceTraders.Agent.Operator{confirmed_at: %DateTime{}} =
               SpaceTraders.Agent.get_operator_by_email(email)
    end

    test "renders errors for duplicated email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/register")

      operator = operator_fixture(%{email: "test@email.com"})

      result =
        lv
        |> form("#registration_form",
          operator: %{"email" => operator.email}
        )
        |> render_submit()

      assert result =~ "has already been taken"
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/operators/log-in")

      assert login_html =~ "Log in"
    end
  end
end
