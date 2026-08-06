defmodule SpaceTradersWeb.OperatorLive.LoginTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  import SpaceTraders.AgentFixtures

  describe "login page" do
    test "renders login page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/operators/log-in")

      assert html =~ "Log in"
      assert html =~ "Sign up"
      assert html =~ "Password"
    end
  end

  describe "operator login - password" do
    test "redirects if operator logs in with valid credentials", %{conn: conn} do
      operator = operator_fixture()

      {:ok, lv, _html} = live(conn, ~p"/operators/log-in")

      form =
        form(lv, "#login_form_password",
          operator: %{
            email: operator.email,
            password: valid_operator_password(),
            remember_me: true
          }
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/operators/log-in")

      form =
        form(lv, "#login_form_password", operator: %{email: "test@email.com", password: "123456"})

      render_submit(form, %{user: %{remember_me: true}})

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/operators/log-in"
    end
  end

  describe "login navigation" do
    test "redirects to registration page when the Register button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/operators/log-in")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Sign up")
        |> render_click()
        |> follow_redirect(conn, ~p"/operators/register")

      assert login_html =~ "Register"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      operator = operator_fixture()
      %{operator: operator, conn: log_in_operator(conn, operator)}
    end

    test "shows login page with email filled in", %{conn: conn, operator: operator} do
      {:ok, _lv, html} = live(conn, ~p"/operators/log-in")

      assert html =~ "You need to reauthenticate"
      refute html =~ "Register"

      assert html =~
               ~s(<input type="email" name="operator[email]" id="login_form_password_email" value="#{operator.email}")
    end
  end
end
