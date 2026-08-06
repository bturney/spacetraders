defmodule SpaceTradersWeb.OperatorSetupControllerTest do
  use SpaceTradersWeb.ConnCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Operator

  @valid_params %{
    "operator" => %{
      "email" => "first@example.com",
      "password" => "a long password",
      "password_confirmation" => "a long password"
    }
  }

  describe "GET /setup" do
    test "renders the setup form when no operators exist", %{conn: conn} do
      conn = get(conn, ~p"/setup")
      assert html_response(conn, 200) =~ "Set up your SpaceTraders dashboard"
    end

    test "redirects to log-in when an operator already exists", %{conn: conn} do
      operator_fixture()
      conn = get(conn, ~p"/setup")
      assert redirected_to(conn) == ~p"/operators/log-in"
    end

    test "redirects home when already signed in", %{conn: conn} do
      conn = conn |> log_in_operator(operator_fixture()) |> get(~p"/setup")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "POST /setup" do
    test "creates the first operator, confirms, and logs them in", %{conn: conn} do
      conn = post(conn, ~p"/setup", @valid_params)

      assert get_session(conn, :operator_token)
      assert redirected_to(conn) == ~p"/"

      assert %Operator{confirmed_at: %DateTime{}} =
               Agent.get_operator_by_email("first@example.com")
    end

    test "links an AccountToken when provided", %{conn: conn} do
      params = put_in(@valid_params, ["operator", "account_token"], "ACCOUNT_TOKEN")
      post(conn, ~p"/setup", params)

      assert Agent.get_operator_by_email("first@example.com").account_token == "ACCOUNT_TOKEN"
    end

    test "re-renders with errors on invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/setup", %{
          "operator" => %{
            "email" => "invalid",
            "password" => "short",
            "password_confirmation" => "different"
          }
        })

      assert html_response(conn, 200) =~ "must have the @ sign and no spaces"
      assert html_response(conn, 200) =~ "should be at least 12 character(s)"
    end

    test "is refused once an operator exists", %{conn: conn} do
      operator_fixture()
      conn = post(conn, ~p"/setup", @valid_params)
      assert redirected_to(conn) == ~p"/operators/log-in"
    end
  end
end
