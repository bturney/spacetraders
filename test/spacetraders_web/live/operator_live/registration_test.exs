defmodule SpaceTradersWeb.OperatorLive.RegistrationTest do
  use SpaceTradersWeb.ConnCase, async: true

  import SpaceTraders.AgentFixtures
  alias SpaceTraders.Agent

  test "the former registration URL cannot bypass empty setup", %{conn: conn} do
    assert conn |> get("/operators/register") |> html_response(404)

    assert conn
           |> post("/operators/register", %{"operator" => valid_operator_attributes()})
           |> html_response(404)

    refute Agent.has_operators?()
  end

  test "the former registration URL cannot create another Operator", %{conn: conn} do
    operator = operator_fixture()

    assert conn |> get("/operators/register") |> html_response(404)

    assert conn
           |> post("/operators/register", %{
             "operator" => valid_operator_attributes(email: "intruder@example.com")
           })
           |> html_response(404)

    refute Agent.get_operator_by_email("intruder@example.com")
    assert Agent.get_operator_by_email_and_password(operator.email, valid_operator_password())
  end

  test "signed-in requests cannot reach the former registration surface", %{conn: conn} do
    conn = log_in_operator(conn, operator_fixture())
    assert conn |> get("/operators/register") |> html_response(404)
  end
end
