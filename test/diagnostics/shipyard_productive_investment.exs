# Opt-in #837 whole-window replay (T = t0 + 48h). Shares #834's lifecycle and
# finite World, entering the normal application's public reconciliation
# boundary in BOTH arms. Writes the full receipt plus a ShipyardPayback arm
# summary; compare B/V summaries with shipyard_productive_compare.exs.
# The unchanged B clock contradiction is retained, never repaired here.
#
#   SHIPYARD_PROOF_PRESET=steady_growth SHIPYARD_PROOF_RECEIPTS=dir \
#     MIX_ENV=test mix run --no-start test/diagnostics/shipyard_productive_investment.exs
defmodule SpaceTraders.ShipyardProductiveInvestment do
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

      {:ok, world} = Supervisor.start_child(supervisor, {ShipyardProofWorld, []})
      {:ok, context} = Supervisor.start_child(supervisor, {Agent, fn -> nil end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        fleet = Agent.get(context, & &1)

        if conn.method == "POST" and
             (conn.request_path == "/v2/my/ships" or
                String.ends_with?(conn.request_path, "/purchase") or
                String.ends_with?(conn.request_path, "/refuel")) do
          send(controller, {:investment_send, checkpoint(world, fleet, conn)})
        end

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

      seconds = System.get_env("SHIPYARD_PROOF_PREFIX_SECONDS", "172800") |> String.to_integer()
      assert seconds in 1..172_800
      cutoff = DateTime.add(~U[2026-10-22 00:00:00Z], seconds)

      result =
        ShipyardProofRuntime.finite_control(world, fleet, preset, cutoff, boundary: :application)

      result =
        Map.merge(result, %{
          ticket: 837,
          classification:
            "functional path and independent economic audit required; matched causal claim inconclusive",
          application_boundary: "Reconciler public evidence/demand entries in both arms",
          spending_checkpoints: checkpoints(),
          comparison_sources:
            Map.new(
              ~w(test/support/shipyard_proof_world.ex test/support/shipyard_proof_runtime.ex test/support/shipyard_payback.ex test/support/test_clock.ex test/diagnostics/shipyard_finite_control.exs test/diagnostics/shipyard_productive_investment.exs test/diagnostics/shipyard_productive_compare.exs),
              fn path ->
                {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
              end
            ),
          limits: [
            "Unchanged B mixes wall and world clocks; arithmetic Delta is not causal superiority.",
            "Productive cycles do not establish capital payback; audit complete-cycle funded finite demand separately.",
            "No live qualification, Gate 0, or full refusal/restart/reset matrix claim."
          ]
        })

      directory = System.fetch_env!("SHIPYARD_PROOF_RECEIPTS")
      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "837-#{preset}.json"),
        Jason.encode!(ShipyardProofRuntime.receipt_json(result), pretty: true)
      )

      arm =
        result
        |> SpaceTraders.ShipyardPayback.arm()
        |> Map.put(:comparison_sources, result.comparison_sources)
        |> Map.put(:manifest, result.manifest)

      File.write!(
        Path.join(directory, "837-#{preset}-summary.json"),
        Jason.encode!(ShipyardProofRuntime.receipt_json(arm), pretty: true)
      )

      assert result.account.unexplained_cash == 0
      assert result.account.credits == 400_000 + result.account.net_cash
      assert result.manifest.external_liability == false
      assert result.as_of == cutoff
      assert DateTime.compare(result.execution_stopped_at, result.as_of) != :lt
      refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))

      IO.inspect(
        %{
          preset: preset,
          payback: arm.payback,
          contradictions: length(arm.contradictions),
          requests: length(result.request_effects),
          cycles: Enum.frequencies_by(result.earnings, & &1.ship_symbol),
          account:
            Map.take(
              result.account,
              ~w(credits receipts all_outlays goods_outlays fuel_outlays acquisition_outlays net_cash low_credits unexplained_cash)a
            )
        },
        label: "#837 finite productive investment"
      )
    after
      for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
          do: SpaceTraders.Quiesced.stop_ship(symbol)

      Supervisor.stop(supervisor)

      case previous_clock do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      SpaceTraders.Test.Governor.restart()

      if fleet = Process.delete(:proof_fleet),
        do: ShipyardProofRuntime.cleanup_control_fixture(fleet)
    end
  end

  defp checkpoint(world, fleet, conn) do
    portfolio = SpaceTraders.FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

    %{
      at: Clock.utc_now(),
      path: conn.request_path,
      body: conn.body_params,
      credits: ShipyardProofWorld.snapshot(world).credits,
      commitments:
        Enum.map(
          portfolio.commitments,
          &Map.take(&1, ~w(id candidate_id claims reservations dependencies expected_value)a)
        ),
      attempts:
        SpaceTraders.MutationAttempts.list_for_agent(fleet.agent)
        |> Enum.filter(&(&1.state in ["sent_or_unknown", "ambiguous", "bounded_unknown"]))
        |> Enum.map(
          &Map.take(
            &1,
            ~w(id state operation_id prepared_at sent_or_unknown_at prepared_evidence provenance)a
          )
        ),
      acquisition_episodes:
        Enum.map(
          portfolio.commitments,
          &SpaceTraders.FleetAllocation.commitment_decision_episode/1
        )
        |> Enum.uniq_by(& &1.id)
        |> Enum.filter(&(&1.calibration_version == "ship-acquisition-v2"))
        |> Enum.map(&Map.take(&1, ~w(id expectations calibration_version evidence_references)a))
    }
  end

  defp checkpoints(acc \\ []) do
    receive do
      {:investment_send, checkpoint} -> checkpoints([checkpoint | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

SpaceTraders.ShipyardProductiveInvestment.run()
