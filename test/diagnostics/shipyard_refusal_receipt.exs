# Opt-in #838 R2 (200,000 initial credits) receipt, run unchanged in B and V. Shares #834's lifecycle and
# finite World, entering the normal application's public reconciliation
# boundary in BOTH arms. Writes the full receipt plus a ShipyardPayback arm
# summary; compare B/V summaries with shipyard_productive_compare.exs.
# The unchanged B clock contradiction is retained, never repaired here.
#
#   SHIPYARD_PROOF_PRESET=steady_growth SHIPYARD_PROOF_RECEIPTS=dir \
#     MIX_ENV=test mix run --no-start test/diagnostics/shipyard_refusal_receipt.exs
defmodule SpaceTraders.ShipyardRefusalReceipt do
  import ExUnit.Assertions
  alias SpaceTraders.{Clock, Repo, ShipyardProofRuntime, ShipyardProofWorld, TestClock}

  def run do
    if Process.whereis(Repo), do: raise("run this diagnostic with mix run --no-start")
    Logger.configure(level: Application.get_env(:logger, :level, :error))
    previous_repo = Application.fetch_env!(:spacetraders, Repo)
    leak_baseline = SpaceTraders.FixtureLeakProbe.baseline()

    Application.put_env(
      :spacetraders,
      Repo,
      Keyword.put(previous_repo, :pool, DBConnection.ConnectionPool)
    )

    try do
      {:ok, _} = Application.ensure_all_started(:spacetraders)
      replay()
    after
      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, Repo)
      Application.put_env(:spacetraders, Repo, previous_repo)
      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
      SpaceTraders.FixtureLeakProbe.assert_clean!(leak_baseline, capacity: true)
    end
  end

  defp replay do
    preset = System.fetch_env!("SHIPYARD_PROOF_PRESET")
    assert preset in ~w(steady_growth charted_expansion)
    assert is_nil(System.get_env("DATABASE_URL")), "use the checkout's isolated database"
    previous_clock = Application.fetch_env(:spacetraders, :clock)
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    try do
      {:ok, _} = Supervisor.start_child(supervisor, {TestClock, ~U[2026-10-22 00:00:00Z]})
      Application.put_env(:spacetraders, :clock, TestClock)

      {:ok, _} =
        Supervisor.start_child(
          supervisor,
          {SpaceTraders.API.CapacityGovernor, now: &Clock.utc_now/0, probe_base_ms: 1000}
        )

      controller = self()

      {:ok, _} =
        Supervisor.start_child(
          supervisor,
          {SpaceTraders.API.RateLimiter,
           clock: %{
             now: fn -> DateTime.diff(Clock.utc_now(), ~U[2026-10-22 00:00:00Z], :millisecond) end,
             sleep: fn ms -> ShipyardProofRuntime.wait(controller, :protocol, ms) end
           }}
        )

      {:ok, world} = Supervisor.start_child(supervisor, {ShipyardProofWorld, [credits: 200_000]})
      {:ok, context} = Supervisor.start_child(supervisor, {Agent, fn -> nil end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        ShipyardProofWorld.reply(world, conn, controller)
      end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      fleet = ShipyardProofRuntime.fresh_generation(world, preset)
      Agent.update(context, fn _ -> fleet end)
      Process.put(:proof_fleet, fleet)

      {:ok, _} =
        Supervisor.start_child(
          supervisor,
          SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler)
        )

      cutoff = DateTime.add(~U[2026-10-22 00:00:00Z], 2, :hour)

      result =
        ShipyardProofRuntime.finite_control(world, fleet, preset, cutoff, boundary: :application)

      import Ecto.Query

      refusals =
        SpaceTraders.Repo.all(
          from e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
            where:
              e.fleet_generation_id == ^fleet.generation.id and
                e.selection_kind == :acquisition_refused,
            order_by: e.id,
            select: %{
              id: e.id,
              reason: e.rejection_reason,
              count: e.observation_count,
              expectations: e.expectations,
              last_observed_at: e.last_observed_at
            }
        )

      # A two-hour no-purchase result is not necessarily a funding refusal.
      # Preserve every original Attempt, including not_sent, and distinguish
      # later purchases funded by actual earned receipts. This is read-only
      # proof accounting, not a new runtime productive-funding policy.
      funding_refusals = Enum.filter(refusals, &(&1.reason == "insufficient_acquisition_credits"))

      purchases =
        for attempt <- result.attempts,
            attempt.operation_id == "purchase-ship" do
          episode =
            Enum.find(result.decisions, &(&1.id == attempt.provenance["decision_episode_id"]))

          valuation = episode.expectations["valuation"]

          %{
            attempt: attempt,
            episode_id: episode.id,
            available_credits: valuation["available_credits"],
            total_exposure: valuation["total_exposure"],
            productive_envelope: 60_000,
            remainder_after_exposure:
              valuation["available_credits"] - valuation["total_exposure"],
            evidence_references: episode.evidence_references
          }
        end

      summary = %{
        ticket: 838,
        case: "R2_200000_credits",
        preset: preset,
        floor: result.floor,
        code_revision: result.code_revision,
        refusals: refusals,
        eligible_funding_refusal_episode_ids: Enum.map(funding_refusals, & &1.id),
        funding_classification:
          if(funding_refusals == [], do: "inconclusive", else: "eligible_boundary_proven"),
        purchase_history: purchases,
        productive_funding_gap:
          Enum.any?(purchases, fn purchase ->
            purchase.attempt.sent_or_unknown_at != nil and
              purchase.remainder_after_exposure < purchase.productive_envelope
          end),
        acquisition_outlays: result.account.acquisition_outlays,
        low_credits: result.account.low_credits,
        net_cash: result.account.net_cash,
        unexplained_cash: result.account.unexplained_cash,
        purchase_requests:
          Enum.count(result.request_effects, &(&1.method == "POST" and &1.path == "/v2/my/ships")),
        cycles: length(result.earnings)
      }

      assert result.account.unexplained_cash == 0
      assert result.account.credits == 200_000 + result.account.net_cash
      assert result.account.low_credits >= result.floor
      refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))

      directory = System.fetch_env!("SHIPYARD_PROOF_RECEIPTS")
      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "838-R2-#{preset}.json"),
        Jason.encode!(ShipyardProofRuntime.receipt_json(Map.put(result, :r2_summary, summary)),
          pretty: true
        )
      )

      File.write!(
        Path.join(directory, "838-R2-#{preset}-summary.json"),
        Jason.encode!(summary, pretty: true)
      )

      IO.inspect(summary, label: "#838 R2")
    after
      for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
          do: SpaceTraders.Quiesced.stop_ship(symbol)

      Supervisor.stop(supervisor)

      case previous_clock do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      {:ok, _} =
        Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      if fleet = Process.delete(:proof_fleet),
        do: ShipyardProofRuntime.cleanup_control_fixture(fleet)
    end
  end
end

SpaceTraders.ShipyardRefusalReceipt.run()
