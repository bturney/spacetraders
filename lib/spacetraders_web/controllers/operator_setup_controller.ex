defmodule SpaceTradersWeb.OperatorSetupController do
  @moduledoc """
  First-run setup: creates the first operator account (email + password) and
  links their AccountToken, then logs them in.

  This screen only exists while no Operator exists. Once the sole Operator is
  established the routes redirect to log-in (or home if already signed in).
  The context serializes creation and canonical identity publication durably.
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

        {:error, :setup_unavailable} ->
          redirect_unavailable(conn)

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
      redirect(conn, to: ~p"/mission-control")
    else
      redirect(conn, to: ~p"/operators/log-in")
    end
  end
end
