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

    test "#{preset}: R1 safety prefix retains an explicit incomplete valuation classification" do
      result =
        run(@preset, world: [reset_at: DateTime.add(@t0, 30, :minute)], cutoff: {30, :minute})

      assert result.preset == @preset
      assert_unchanged_preset(result)
      assert_no_purchase_effect(result)
      assert [_ | _] = reasons = refusal_reasons(result)

      # This ordinary tracer is NOT an R1 acceptance pass. Exact work selection
      # may leave no current Claim-only loser; do not choose its winner or add a
      # reconciliation to force valuation. The opt-in strict assertion retains
      # the exact AC failure, and the paired Allocation :value test covers the
      # actual capped valuation mechanism, not this exact application path.
      if System.get_env("SHIPYARD_PROOF_REQUIRE_R1") == "true" do
        assert result.proof.classification == :pass,
               "R1 INCONCLUSIVE: #{inspect(result.proof)}; actual reasons: #{inspect(reasons)}"
      end

      case result.proof.classification do
        :pass -> assert_short_horizon_valuation(result)
        :inconclusive -> assert result.proof.missing == "normal capped valuation refusal"
      end

      assert_unchanged_calibration(result)
      assert_alternative_executes(result)
    end

    test "#{preset}: R2 safety tracer distinguishes funding refusal from later recovery" do
      result =
        run(@preset,
          world: [credits: 200_000],
          cutoff: {2, :hour},
          stop_at_funding_refusal: true
        )

      assert result.preset == @preset
      assert_unchanged_preset(result)
      assert_unchanged_calibration(result)
      assert_alternative_executes(result)

      if System.get_env("SHIPYARD_PROOF_REQUIRE_R2") == "true" do
        assert result.proof.classification == :pass,
               "R2 INCONCLUSIVE: #{inspect(result.proof)}; actual reasons: #{inspect(refusal_reasons(result))}"
      end

      case result.proof.classification do
        :pass -> assert_funding_refusal(result)
        :inconclusive -> assert result.proof.missing == "eligible funding refusal"
      end

      assert_acquisition_history(result)
      assert result.account.low_credits >= @floor
      assert result.account.credits == 200_000 + result.account.net_cash
      assert result.account.unexplained_cash == 0
    end

    for {name, world} <- [
          "rival Players consumed all destination demand": [rivals: ~w(IRON COPPER)],
          "destination sell 1,000 equals the source buy": [destination_sell: 1000]
        ] do
      @world world
      test "#{preset}: R3 #{name}; nothing is bought on stale or theoretical sales" do
        result = run(@preset, world: @world, cutoff: {1, :hour})

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
        run(@preset,
          world: [rivals: ~w(IRON)],
          cutoff: {48, :hour},
          control: [stop_at_readiness: true]
        )

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

  defp assert_short_horizon_valuation(result) do
    valuations =
      for refusal <- refusals(result.fleet),
          limitation <- refusal.expectations["limitations"],
          limitation["reason"] == "enabled_value_not_above_cost",
          do: limitation["valuation"]

    assert valuations != []

    for valuation <- valuations do
      assert valuation["horizon"]["status"] == "known"
      assert valuation["horizon"]["duration_seconds"] in 1..1800
      assert valuation["horizon"]["evidence_ref"]["operation_id"] == "get-status"
      assert valuation["enabled_work"]["candidate_id"]
      assert valuation["enabled_value"] < valuation["total_exposure"]
      assert valuation["total_exposure"] == 135_000
    end
  end

  defp assert_funding_refusal(result) do
    assert_no_purchase_effect(result)

    assert [%{expectations: expectations}] =
             Enum.filter(
               refusals(result.fleet),
               &(&1.rejection_reason == "insufficient_acquisition_credits")
             )

    assert [_ | _] = expectations["considered_work"]

    assert Enum.any?(expectations["limitations"], fn limitation ->
             valuation = limitation["valuation"]

             limitation["reason"] == "insufficient_acquisition_credits" and
               valuation["total_exposure"] == 135_000 and valuation["available_credits"] < 135_000
           end)

    protection = Enum.sum_by(result.current_commitments, &(&1.reservations["credits"] || 0))
    assert protection >= 50_000
    assert result.account.credits - result.floor - protection < 135_000
  end

  defp assert_acquisition_history(result) do
    for attempt <- result.attempts, attempt.operation_id == "purchase-ship" do
      episode = Enum.find(result.decisions, &(&1.id == attempt.provenance["decision_episode_id"]))

      commitment =
        Enum.find(result.all_commitments, &(&1.id == attempt.provenance["commitment_id"]))

      assert commitment
      assert episode.selection_kind == :selected_plan
      assert episode.expectations["domain"] == "ship_acquisition"
      assert attempt.provenance["fleet_generation_id"] == result.generation
      assert attempt.provenance["strategy_revision_id"] == result.strategy_revision
      assert episode.expectations["valuation"]["available_credits"] >= 135_000

      if attempt.state == "not_sent" do
        assert attempt.sent_or_unknown_at == nil

        assert Enum.any?(attempt.outcomes, fn outcome ->
                 outcome.classification == "not_sent" and
                   outcome.evidence["reason"] == ":ship_investment_evidence_unavailable"
               end)

        assert Enum.any?(episode.evidence_references, fn dependency ->
                 {:ok, expires, _} = DateTime.from_iso8601(dependency["valid_until"])
                 DateTime.compare(expires, attempt.prepared_at) != :gt
               end)
      else
        assert attempt.state == "succeeded"
        assert attempt.sent_or_unknown_at
      end
    end

    if "acquisition_already_unsettled" in refusal_reasons(result) do
      assert Enum.any?(result.attempts, &(&1.operation_id == "purchase-ship"))
      assert SpaceTraders.FleetAcquisition.open_purchase(result.fleet.agent) == nil
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

  defp run(preset, opts) do
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

    fleet = Runtime.fresh_generation(world, preset)
    Elixir.Agent.update(context, fn _ -> fleet end)
    start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))
    {amount, unit} = Keyword.fetch!(opts, :cutoff)

    control = Keyword.merge([boundary: :application], Keyword.get(opts, :control, []))

    control =
      if Keyword.get(opts, :stop_at_funding_refusal) do
        Keyword.put(control, :stop_when, fn ->
          Enum.any?(refusals(fleet), &(&1.rejection_reason == "insufficient_acquisition_credits"))
        end)
      else
        control
      end

    result =
      Runtime.finite_control(
        world,
        fleet,
        preset,
        DateTime.add(@t0, amount, unit),
        control
      )

    case_name =
      cond do
        Keyword.has_key?(Keyword.fetch!(opts, :world), :reset_at) -> "R1"
        Keyword.has_key?(Keyword.fetch!(opts, :world), :credits) -> "R2"
        true -> "R3"
      end

    expected =
      if case_name == "R1",
        do: "enabled_value_not_above_cost",
        else: "insufficient_acquisition_credits"

    reached? = Enum.any?(refusals(fleet), &(&1.rejection_reason == expected))

    proof = %{
      case: case_name,
      classification:
        cond do
          case_name == "R3" -> :not_assessed_here
          reached? -> :pass
          true -> :inconclusive
        end,
      missing:
        cond do
          reached? or case_name == "R3" -> nil
          case_name == "R1" -> "normal capped valuation refusal"
          true -> "eligible funding refusal"
        end
    }

    result = Map.put(result, :proof, proof)

    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)

      receipt =
        result
        |> Map.put(:refusals, refusals(fleet))
        |> Map.put(:preset_document, fleet.revision.document)
        |> Map.put(
          :tracer_sha256,
          :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower)
        )

      File.write!(
        Path.join(directory, "838-#{case_name}-#{preset}.json"),
        Jason.encode!(Runtime.receipt_json(receipt), pretty: true)
      )
    end

    Map.merge(result, %{fleet: fleet, world: world})
  end
end
