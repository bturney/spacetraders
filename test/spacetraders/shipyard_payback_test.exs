defmodule SpaceTraders.ShipyardPaybackTest do
  # Worked examples for the #837 conservative complete-cycle falsifier. The
  # expected values are hand-derived from the frozen contract, not runtime policy.
  use ExUnit.Case, async: true

  alias SpaceTraders.ShipyardPayback

  @base %{
    capital: 100_000,
    revenue: 60_000,
    operating_cost: 40_200,
    complete_seconds: 3200,
    enabled_rate: 44_944,
    lead_seconds: 0,
    horizon_seconds: 172_800,
    reset_seconds: 432_000,
    available_cash: 200_000,
    stock_units: 1600,
    incumbent_period_seconds: 3130
  }

  describe "stress/1" do
    test "covers capital and every stressed future outlay inside the capped horizon" do
      # 60k - 1.25 * 40.2k = 9,750 per cycle -> 11 cycles; each 3,200 s cycle
      # halved in throughput (6,400 s) plus one extra hour of lead.
      result = ShipyardPayback.stress(@base)

      assert result.cycles_needed == 11
      assert result.completion_seconds == 74_000
      assert result.future_outlays == 552_750
      assert result.future_receipts == 660_000
      assert result.capital_loaded_surplus == 7250
      assert result.classification == :supported
    end

    test "a favourable one-leg enabled rate cannot override the complete-cycle rate" do
      result = ShipyardPayback.stress(%{@base | enabled_rate: 100_000})

      assert result.achievable_rate == 22_275
      assert result.lower_rate == 22_275
    end

    test "unfunded inputs or unsustainable shared finite demand are inconclusive" do
      # 40/1000s incumbent + 40/6400s stressed hauler exceeds 40/1800s refill;
      # 400 units cannot cover 11 cycles once the incumbent drains them.
      for change <- [
            %{available_cash: 50_000},
            %{incumbent_period_seconds: 1000, stock_units: 400}
          ] do
        assert %{classification: :inconclusive} = ShipyardPayback.stress(Map.merge(@base, change))
      end
    end

    test "a low enabled rate or a near reset cannot borrow a longer horizon" do
      for change <- [%{enabled_rate: 5000}, %{reset_seconds: 1800}] do
        assert %{classification: :inconclusive} = ShipyardPayback.stress(Map.merge(@base, change))
      end
    end

    test "profitable unstressed sales do not excuse a nonpositive stressed cycle" do
      assert %{classification: :inconclusive, reason: :nonpositive_stressed_return} =
               ShipyardPayback.stress(%{@base | operating_cost: 50_000})
    end
  end

  describe "classify/2" do
    @v %{
      net_cash: -21_100,
      acquisitions: 1,
      new_ship_cycles: [20_000, 19_800],
      unknown_effects: [],
      payback: %{classification: :supported}
    }
    @b %{net_cash: 138_300, acquisitions: 0, new_ship_cycles: [], unknown_effects: []}

    test "reports N and an acquisition-loaded negative Delta without a superiority gate" do
      result = ShipyardPayback.classify(@b, @v)

      assert result.n_b == 138_300
      assert result.n_v == -21_100
      assert result.delta == -159_400
      assert result.productive_path == :pass
      assert result.payback == :supported
      assert result.p1 == :attributed_productive_acquisition
    end

    test "B already succeeding is current-policy success, not attributed improvement" do
      b = %{@v | net_cash: 1}
      assert ShipyardPayback.classify(b, @v).p1 == :current_policy_success
    end

    test "two profitable sales cannot justify unsupported payback" do
      v = %{@v | payback: %{classification: :inconclusive}}
      assert ShipyardPayback.classify(@b, v).p1 == :inconclusive
    end

    test "decisive unknown effects or a missing monetary fact are inconclusive" do
      assert ShipyardPayback.classify(@b, %{@v | unknown_effects: [%{bound: 25_000}]}).p1 ==
               :inconclusive

      assert ShipyardPayback.classify(@b, %{@v | new_ship_cycles: [20_000, nil]}).p1 ==
               :inconclusive
    end

    test "fewer than two profitable cycles or a nonpositive aggregate fails the productive path" do
      for cycles <- [[20_000], [20_000, -1], [30_000, -100]] do
        result = ShipyardPayback.classify(@b, %{@v | new_ship_cycles: cycles})
        assert result.productive_path == :fail
        assert result.p1 == :fail
      end
    end

    test "a recorded control contradiction keeps Delta arithmetic, not causal" do
      assert ShipyardPayback.classify(@b, @v).delta_attribution == :measured

      b = Map.put(@b, :contradictions, ["B send timestamps use wall clock"])
      assert ShipyardPayback.classify(b, @v).delta_attribution == :inconclusive
    end

    test "no acquisition in either arm is not a productive pass" do
      assert ShipyardPayback.classify(@b, @b).p1 == :no_acquisition
    end
  end
end
