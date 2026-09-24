defmodule SpaceTradersWeb.HomeController do
  use SpaceTradersWeb, :controller

  alias SpaceTraders.Agent

  def index(conn, _params) do
    destination = if Agent.has_operators?(), do: ~p"/mission-control", else: ~p"/setup"
    redirect(conn, to: destination)
  end
end
