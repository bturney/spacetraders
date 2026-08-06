defmodule SpaceTradersWeb.PageController do
  use SpaceTradersWeb, :controller

  alias SpaceTraders.Agent

  def home(conn, _params) do
    case conn.assigns.current_scope do
      nil ->
        if Agent.has_operators?() do
          render(conn, :home, agents: [])
        else
          # No operators yet: send the visitor to first-run setup.
          redirect(conn, to: ~p"/setup")
        end

      %{operator: operator} ->
        render(conn, :home, agents: Agent.list_agents(operator))
    end
  end
end
