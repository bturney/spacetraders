# Real fresh-VM application boot, against the isolated adopted-installation DB
# owned by CurrentFleetMigrationTest. Only known synthetic test credentials.
defmodule SoleOperatorAuthProbe do
  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Plug.Conn

  alias SpaceTraders.{Agent, FleetGeneration}
  @endpoint SpaceTradersWeb.Endpoint

  def run do
    {:ok, _} = Application.ensure_all_started(:spacetraders)
    session = System.fetch_env!("ADOPTED_SESSION_TOKEN") |> Base.decode64!()

    operator =
      Agent.get_operator_by_email_and_password("adopted@example.com", "adopted durable password")

    assert operator
    assert operator.confirmed_at
    assert operator.account_token == "ADOPTED_ACCOUNT_SECRET"
    assert {authenticated, _} = Agent.get_operator_by_session_token(session)
    assert authenticated.id == operator.id
    assert {:ok, %{operator: canonical, state: :current}} = FleetGeneration.current_fleet()
    assert canonical.id == operator.id
    assert canonical.account_token == nil

    old_session = build_conn() |> init_test_session(operator_token: session)
    settings = get(old_session, "/operators/settings")
    html = html_response(settings, 200)
    assert settings.assigns.current_scope.operator.id == operator.id
    assert html =~ "An AccountToken is linked"
    refute html =~ "ADOPTED_ACCOUNT_SECRET"
    refute html =~ "AGENT_SECRET"
    refute html =~ "/operators/register"

    setup = get(build_conn(), "/setup")
    assert redirected_to(setup) == "/operators/log-in"

    login =
      post(build_conn(), "/operators/log-in", %{
        "operator" => %{
          "email" => operator.email,
          "password" => "adopted durable password"
        }
      })

    assert redirected_to(login) == "/mission-control"
    assert get_session(login, :operator_token)
    logout = delete(login, "/operators/log-out")
    refute get_session(logout, :operator_token)
    assert Agent.get_operator_by_session_token(session)
    IO.puts("adopted authentication passed")
  end
end

SoleOperatorAuthProbe.run()
