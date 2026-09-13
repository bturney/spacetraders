defmodule SpaceTradersWeb.MetricsTest do
  use SpaceTradersWeb.ConnCase

  alias SpaceTraders.API

  test "GET /metrics is public and serves Prometheus metrics", %{conn: conn} do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{"data" => %{}})
    end)

    assert {:ok, _ship} = API.get_ship("TOKEN", "ORBITALIST-1")
    assert response(get(conn, "/health"), 200)
    SpaceTraders.Repo.query!("SELECT 1")
    conn = get(conn, "/metrics")

    body = response(conn, 200)
    assert body =~ "# HELP"
    assert body =~ "spacetraders_api_requests_total"
    assert body =~ ~s(endpoint="/my/ships/{shipSymbol}")
    assert body =~ ~s(outcome="ok")
    refute body =~ "ORBITALIST-1"
    assert body =~ "spacetraders_prom_ex_ecto_repo_query_total_time_milliseconds"
    assert body =~ "spacetraders_prom_ex_beam_system_version_info"
    assert body =~ ~s(controller="SpaceTradersWeb.HealthController")
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
