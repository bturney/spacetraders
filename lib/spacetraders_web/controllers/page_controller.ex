defmodule SpaceTradersWeb.PageController do
  use SpaceTradersWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
