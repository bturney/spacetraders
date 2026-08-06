defmodule SpaceTradersWeb.HealthController do
  use SpaceTradersWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
