defmodule SpaceTradersWeb.HealthControllerTest do
  use SpaceTradersWeb.ConnCase

  test "GET /health responds 200 with status ok", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
