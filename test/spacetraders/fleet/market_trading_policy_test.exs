defmodule SpaceTraders.Fleet.MarketTradingPolicyTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Fleet.MarketTradingPolicy

  defp candidate(overrides) do
    Map.merge(
      %{
        trade_symbol: "IRON_ORE",
        source_waypoint: "X1-UX81-A1",
        destination_waypoint: "X1-UX81-A2",
        units: 10,
        purchase_price: 10,
        sell_price: 20,
        transit_seconds: 100,
        destination_age: 10
      },
      overrides
    )
  end

  test "selects highest expected net profit" do
    {selected, rejected} =
      MarketTradingPolicy.select(
        [candidate(%{sell_price: 20}), candidate(%{trade_symbol: "COPPER", sell_price: 30})],
        %{credits: 1_000, reserve_credits: 0}
      )

    assert selected.trade_symbol == "COPPER"
    assert rejected == []
  end

  test "uses transit and destination freshness as tie breakers" do
    {selected, _rejected} =
      MarketTradingPolicy.select(
        [
          candidate(%{transit_seconds: 20, destination_age: 2}),
          candidate(%{transit_seconds: 10, destination_age: 8})
        ],
        %{credits: 1_000, reserve_credits: 0}
      )

    assert selected.transit_seconds == 10
  end

  test "returns rejected candidates when constraints eliminate every trade" do
    {selected, rejected} =
      MarketTradingPolicy.select([candidate(%{sell_price: 11})], %{minimum_profit: 20})

    assert selected == nil
    assert [%{reason: :candidate_constraints}] = rejected
  end
end
