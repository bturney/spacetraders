# Opt-in, finite application replay; intentionally not an ordinary discovered
# ExUnit test. A 48-game-hour demand/recovery trace can take several real minutes.
# No sleeps, timeout overrides, extra policy owner, or admission bypass.
defmodule SpaceTraders.ShipyardFiniteControl do
  import ExUnit.Assertions
  alias SpaceTraders.{Clock, Repo, ShipyardProofRuntime, ShipyardProofWorld, TestClock}

  def run do
    if Process.whereis(Repo), do: raise("run this diagnostic with mix run --no-start")
    previous_repo = Application.fetch_env!(:spacetraders, Repo)
    leak_baseline = SpaceTraders.FixtureLeakProbe.baseline()
    # A committed diagnostic is not a long-lived Sandbox owner. The default
    # Sandbox :auto mode still owns connections until its processes exit.
    Application.put_env(
      :spacetraders,
      Repo,
      Keyword.put(previous_repo, :pool, DBConnection.ConnectionPool)
    )

    try do
      {:ok, _} = Application.ensure_all_started(:spacetraders)
      replay()
    after
      :ok = Application.stop(:spacetraders)
      Application.put_env(:spacetraders, Repo, previous_repo)
      {:ok, _} = Application.ensure_all_started(:spacetraders)
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

      Req.Test.stub(SpaceTraders.API, fn conn ->
        ShipyardProofWorld.reply(world, conn, controller)
      end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      fleet = ShipyardProofRuntime.fresh_generation(world, preset)
      Process.put(:proof_fleet, fleet)

      {:ok, _} =
        Supervisor.start_child(
          supervisor,
          SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler)
        )

      result = ShipyardProofRuntime.finite_control(world, fleet, preset)
      ShipyardProofRuntime.write_control_receipt(result, preset)
      assert result.account.unexplained_cash == 0
      assert result.account.credits == 400_000 + result.account.net_cash
      assert result.account.debit_outlays == 20_000
      assert result.as_of == ~U[2026-10-24 00:00:00Z]
      assert DateTime.compare(result.execution_stopped_at, result.as_of) != :lt
      refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))

      IO.inspect(
        %{
          preset: preset,
          classification: result.classification,
          requests: length(result.request_effects),
          cycles: length(result.earnings),
          account:
            Map.take(
              result.account,
              ~w(credits receipts all_outlays goods_outlays fuel_outlays acquisition_outlays debit_outlays net_cash low_credits unexplained_cash)a
            )
        },
        label: "#834 finite control"
      )
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

      if fleet = Process.delete(:proof_fleet) do
        ShipyardProofRuntime.cleanup_control_fixture(fleet)
      end
    end
  end
end

SpaceTraders.ShipyardFiniteControl.run()
