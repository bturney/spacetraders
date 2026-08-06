defmodule SpaceTradersWeb.OperatorSetupController do
  @moduledoc """
  First-run setup: creates the first operator account (email + password) and
  links their AccountToken, then logs them in.

  This screen only exists while no operators exist. Once an operator is present
  the routes redirect to log-in (or home if already signed in); additional
  operators register via the normal `/operators/register` page.
  """

  use SpaceTradersWeb, :controller

  alias SpaceTraders.Agent
  alias SpaceTradersWeb.OperatorAuth

  def new(conn, _params) do
    if setup_allowed?(conn) do
      render(conn, :new, changeset: Agent.change_registration())
    else
      redirect_unavailable(conn)
    end
  end

  def create(conn, %{"operator" => operator_params}) do
    if setup_allowed?(conn) do
      case Agent.register_operator(operator_params) do
        {:ok, operator} ->
          conn
          |> put_flash(:info, "Operator account created. Welcome!")
          |> OperatorAuth.log_in_operator(operator)

        {:error, changeset} ->
          render(conn, :new, changeset: changeset)
      end
    else
      redirect_unavailable(conn)
    end
  end

  defp setup_allowed?(conn) do
    not Agent.has_operators?() and is_nil(conn.assigns.current_scope)
  end

  defp redirect_unavailable(conn) do
    if conn.assigns.current_scope do
      redirect(conn, to: ~p"/")
    else
      redirect(conn, to: ~p"/operators/log-in")
    end
  end
end
