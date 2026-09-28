defmodule SpaceTradersWeb.GrafanaLinkTest do
  use ExUnit.Case, async: false

  alias SpaceTradersWeb.GrafanaLink

  test "carries only durable identities and the relevant time range" do
    url =
      GrafanaLink.url(:strategy_outcomes,
        fleet_generation: 11,
        strategy_revision: 22,
        decision_episode: 33,
        commitment: 44,
        intent: 55,
        attempt: 66,
        from: ~U[2030-01-01 12:00:00Z],
        to: :now,
        token: "must-not-appear"
      )

    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "observability-host.taila148e9.ts.net"
    assert is_nil(uri.userinfo)
    assert uri.path == "/d/spacetraders-strategy-outcomes/strategy-outcomes"

    assert query == %{
             "from" => "1893499200000",
             "timezone" => "utc",
             "to" => "now",
             "var-attempt" => "66",
             "var-commitment" => "44",
             "var-decision_episode" => "33",
             "var-fleet_generation" => "11",
             "var-intent" => "55",
             "var-strategy_revision" => "22"
           }

    refute url =~ "must-not-appear"
    refute Map.has_key?(query, "token")
  end

  test "routes calibration evidence to the family that answers its question" do
    assert GrafanaLink.family_for_calibration("market-v2") == :economics_capital
    assert GrafanaLink.family_for_calibration("ship-acquisition-v1") == :economics_capital
    assert GrafanaLink.family_for_calibration("construction-v1") == :fleet_logistics
    assert GrafanaLink.family_for_calibration("intelligence-v1") == :intelligence_api_capacity
    assert GrafanaLink.family_for_calibration("owned-recovery-v1") == :reliability_recovery
    assert GrafanaLink.family_for_calibration("unclassified-v1") == :strategy_outcomes
  end

  test "rejects a configured base URL that could put credentials in a link" do
    previous = Application.fetch_env!(:spacetraders, GrafanaLink)
    on_exit(fn -> Application.put_env(:spacetraders, GrafanaLink, previous) end)

    Application.put_env(:spacetraders, GrafanaLink,
      base_url: "https://operator:secret@observability.example.test"
    )

    assert_raise ArgumentError, ~r/must not contain credentials/, fn ->
      GrafanaLink.url(:strategy_outcomes, from: "now-1h", to: :now)
    end
  end
end
