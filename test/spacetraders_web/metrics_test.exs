defmodule SpaceTradersWeb.MetricsTest do
  use SpaceTradersWeb.ConnCase

  alias SpaceTraders.API

  test "GET /metrics is public and serves Prometheus metrics", %{conn: conn} do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => %{}})
    end)

    assert {:ok, _agent} = API.get_agent("TOKEN")
    conn = get(conn, "/metrics")

    body = response(conn, 200)
    assert body =~ "# HELP"
    assert body =~ "spacetraders_api_requests_total"
    assert body =~ ~s(endpoint="/my/agent")
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
