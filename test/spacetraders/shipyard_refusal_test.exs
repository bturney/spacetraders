defmodule SpaceTraders.ShipyardRefusalTest do
  @moduledoc """
  #838: adverse time, funding and opportunity inputs. Each case changes only its
  named World input from the matched positive fixture and runs the unchanged
  preset through ordinary Allocation. Refusals are whatever the existing
  acquisition mechanism decides; no case injects a refusal.
  """
  use SpaceTraders.DataCase, async: false

  import Ecto.Query
  alias SpaceTraders.Repo

  alias SpaceTraders.{Clock, Fleet}
  alias SpaceTraders.ShipyardProofRuntime, as: Runtime
  alias SpaceTraders.ShipyardProofWorld, as: World

  @t0 ~U[2026-10-22 00:00:00Z]

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
    :ok
  end

  setup do
    start_supervised!({SpaceTraders.TestClock, @t0})
    previous = Application.fetch_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, SpaceTraders.TestClock)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    start_supervised!(
      {SpaceTraders.API.CapacityGovernor, now: &Clock.utc_now/0, probe_base_ms: 1000}
    )

    controller = self()

    start_supervised!(
      {SpaceTraders.API.RateLimiter,
       clock: %{
         now: fn -> DateTime.diff(Clock.utc_now(), @t0, :millisecond) end,
         sleep: fn ms -> Runtime.wait(controller, :protocol, ms) end
       }}
    )

    on_exit(fn ->
      for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
          do: SpaceTraders.Quiesced.stop_ship(symbol)

      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      {:ok, _} =
        Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)
    end)

    :ok
  end

  for {preset, floor} <- [{"steady_growth", 50_000}, {"charted_expansion", 75_000}] do
    @preset preset
    @floor floor

    test "#{preset}: R1 a thirty-minute horizon refuses with no purchase effect and keeps trading (valuation step reached nondeterministically)" do
      result = run(world: [reset_at: DateTime.add(@t0, 30, :minute)], cutoff: {30, :minute})

      assert_unchanged_preset(result)
      assert_no_purchase_effect(result)
      assert [_ | _] = reasons = refusal_reasons(result)

      # PARTIAL for valuation: inside the 30-minute window the Claim-only loser
      # appears only near its end, and whether a run reaches the capped
      # valuation (enabled_value_not_above_cost) varies between runs for either
      # preset. This test proves refusal + no effect + executing alternative;
      # the deterministic horizon-valuation refusal is covered by
      # market_domain_allocation_test.exs ("horizon" refusal). Running past the
      # announced reset reaches valuation only nondeterministically too.
      assert List.last(reasons) in ~w(no_claim_only_loser enabled_value_not_above_cost)

      assert_unchanged_calibration(result)
      assert_alternative_executes(result)
    end

    test "#{preset}: R2 200,000 credits refuses unaffordable exposure without touching the floor" do
      result = run(world: [credits: 200_000], cutoff: {2, :hour})

      assert_unchanged_preset(result)
      assert_no_purchase_effect(result)
      # Funding refusal is explicit in most runs; a run may instead refuse
      # earlier as acquisition_already_unsettled (seen once in B/V receipts,
      # with no purchase Attempt sent). Either way nothing is bought.
      assert Enum.any?(
               refusal_reasons(result),
               &(&1 in ~w(insufficient_acquisition_credits acquisition_already_unsettled))
             )

      assert_unchanged_calibration(result)
      assert_alternative_executes(result)

      # The 135,000 exposure was never reserved against the floor or against
      # the selected work's protection, nor anticipated from future sales.
      assert result.account.low_credits >= @floor
      assert result.account.credits == 200_000 + result.account.net_cash
    end

    for {name, world} <- [
          "rival Players consumed all destination demand": [rivals: ~w(IRON COPPER)],
          "destination sell 1,000 equals the source buy": [destination_sell: 1000]
        ] do
      @world world
      test "#{preset}: R3 #{name}; nothing is bought on stale or theoretical sales" do
        result = run(world: @world, cutoff: {1, :hour})

        assert_unchanged_preset(result)
        assert_no_purchase_effect(result)
        assert refusal_reasons(result) == ["no_claim_only_loser"]

        # No goods bought, no sales: executable economics, not stale quotes.
        assert Enum.reject(result.request_effects, &(&1.method == "GET")) |> Enum.map(& &1.path) ==
                 []

        assert result.account.net_cash == 0
        assert result.earnings == []
      end
    end

    test "#{preset}: R3 rivals on IRON only leave independent COPPER work admissible" do
      result =
        run(world: [rivals: ~w(IRON)], cutoff: {48, :hour}, control: [stop_at_readiness: true])

      assert_unchanged_preset(result)

      # The observed IRON depth is the rivals' actual residue, not the
      # theoretical 1,600 units.
      iron = latest_good(result, "X1-UX81-A2", "IRON")
      assert iron["trade_volume"] == 0
      assert iron["sell_price"] == 1100

      # Justified independent COPPER work was selected and traded ...
      sells = Enum.filter(result.request_effects, &String.ends_with?(&1.path, "/sell"))
      assert sells != []
      assert Enum.all?(sells, &(&1.body["symbol"] == "COPPER"))

      # ... and it, not IRON, is the work that justified the acquisition.
      assert [purchase] =
               Enum.filter(
                 result.request_effects,
                 &(&1.method == "POST" and &1.path == "/v2/my/ships")
               )

      assert purchase.signed_cash == -100_000

      valuation =
        Enum.find_value(result.decisions, fn d ->
          get_in(d.expectations, ["valuation", "enabled_work", "trade_symbol"])
        end)

      assert valuation == "COPPER"
    end
  end

  defp assert_unchanged_preset(result) do
    assert result.floor == if(result.preset == "steady_growth", do: 50_000, else: 75_000)
    assert result.account.low_credits >= result.floor
    refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))
  end

  defp assert_no_purchase_effect(result) do
    refute Enum.any?(
             result.request_effects,
             &(&1.method == "POST" and &1.path == "/v2/my/ships")
           )

    assert result.account.acquisition_outlays == 0
    assert result.account.unexplained_cash == 0

    assert Enum.reject(
             result.attempts,
             &(&1.operation_id != "purchase-ship" or &1.state == "not_sent")
           ) ==
             []

    assert length(Fleet.current_ships(result.fleet.agent.id)) == 2
  end

  defp assert_unchanged_calibration(result) do
    refused = Enum.filter(result.decisions, &(&1.selection_kind == :acquisition_refused))
    assert refused != []

    for d <- refused do
      assert d.expectations["calibration"] == %{
               "version" => "ship-acquisition-v2",
               "horizon_window_seconds" => 172_800,
               "no_history_discount" => 0.5
             }
    end
  end

  # The feasible alternative is the Fleet's ordinary selected trade, executed.
  defp assert_alternative_executes(result) do
    assert Enum.any?(result.decisions, fn d ->
             d.selection_kind == :selected_plan and d.expectations["commitment_count"] >= 1
           end)

    assert Enum.any?(result.request_effects, &String.ends_with?(&1.path, "/purchase"))
  end

  defp latest_good(result, waypoint, symbol) do
    result.observations
    |> Enum.filter(&(&1.subject == "market:X1-UX81:#{waypoint}"))
    |> List.last()
    |> then(& &1.facts["trade_goods"])
    |> Enum.find(&(&1["symbol"] == symbol))
  end

  defp refusal_reasons(result),
    do: refusals(result.fleet) |> Enum.map(& &1.rejection_reason) |> Enum.dedup()

  defp refusals(fleet) do
    Repo.all(
      from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
        where:
          e.fleet_generation_id == ^fleet.generation.id and
            e.selection_kind == :acquisition_refused,
        order_by: e.id
    )
  end

  defp run(opts) do
    world = start_supervised!({World, Keyword.fetch!(opts, :world)})
    controller = self()
    context = start_supervised!({Elixir.Agent, fn -> nil end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      World.reply(world, conn, controller)
    end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
    end)

    fleet = Runtime.fresh_generation(world, @preset)
    Elixir.Agent.update(context, fn _ -> fleet end)
    start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))
    {amount, unit} = Keyword.fetch!(opts, :cutoff)

    result =
      Runtime.finite_control(
        world,
        fleet,
        @preset,
        DateTime.add(@t0, amount, unit),
        Keyword.merge([boundary: :application], Keyword.get(opts, :control, []))
      )

    Map.merge(result, %{fleet: fleet, world: world})
  end
end
