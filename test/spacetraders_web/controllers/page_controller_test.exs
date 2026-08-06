defmodule SpaceTradersWeb.PageControllerTest do
  use SpaceTradersWeb.ConnCase

  test "GET / with no operators redirects to first-run setup", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET / when signed in lists the operator's agents", %{conn: conn} do
    operator = SpaceTraders.AgentFixtures.operator_fixture()
    agent = SpaceTraders.AgentFixtures.agent_fixture(operator)

    conn =
      conn
      |> SpaceTradersWeb.ConnCase.log_in_operator(operator)
      |> get(~p"/")

    assert html_response(conn, 200) =~ agent.symbol
    assert html_response(conn, 200) =~ agent.faction
  end
end
