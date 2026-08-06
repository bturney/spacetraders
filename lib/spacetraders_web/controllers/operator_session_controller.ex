defmodule SpaceTradersWeb.OperatorSessionController do
  use SpaceTradersWeb, :controller

  alias SpaceTraders.Agent
  alias SpaceTradersWeb.OperatorAuth

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # email + password login
  defp create(conn, %{"operator" => operator_params}, info) do
    %{"email" => email, "password" => password} = operator_params

    if operator = Agent.get_operator_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> OperatorAuth.log_in_operator(operator, operator_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/operators/log-in")
    end
  end

  def update_password(conn, %{"operator" => operator_params} = params) do
    operator = conn.assigns.current_scope.operator
    true = Agent.sudo_mode?(operator)
    {:ok, {_operator, expired_tokens}} = Agent.update_operator_password(operator, operator_params)

    # disconnect all existing LiveViews with old sessions
    OperatorAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:operator_return_to, ~p"/operators/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> OperatorAuth.log_out_operator()
  end
end
