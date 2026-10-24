defmodule SpaceTraders.ShipyardProductiveInvestmentTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.{Clock, FleetAllocation, MutationAttempts}
  alias SpaceTraders.ShipyardPayback
  alias SpaceTraders.ShipyardProofRuntime, as: Runtime
  alias SpaceTraders.ShipyardProofWorld, as: World

  @t0 ~U[2026-10-22 00:00:00Z]

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    previous_repo = Application.fetch_env!(:spacetraders, SpaceTraders.Repo)
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Repo)

    # Newly allocated Ships start their own timer process. Do not hold a
    # caller's Sandbox connection while that process initializes from the DB.
    Application.put_env(
      :spacetraders,
      SpaceTraders.Repo,
      Keyword.put(previous_repo, :pool, DBConnection.ConnectionPool)
    )

    {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Repo)

    on_exit(fn ->
      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.Repo)
      Application.put_env(:spacetraders, SpaceTraders.Repo, previous_repo)
      {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.Repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :manual)
      SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true)
    end)

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

      SpaceTraders.Test.Governor.restart()
    end)

    :ok
  end

  # Bounded tracer: run the unchanged credit-growth preset only until the
  # acquired Ship has two completed cycles (cap t0 + 4h; purchase timing varies
  # 00:26-02:15). Both presets' 48h B/V evidence is recorded in
  # docs/autonomy/shipyard-evidence-821.md.
  @preset "steady_growth"
  test "steady_growth: the normally acquired Ship trades under ordinary authority and passes the stressed payback check" do
    world = start_supervised!({World, []})
    controller = self()
    context = start_supervised!({Elixir.Agent, fn -> nil end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      fleet = Elixir.Agent.get(context, & &1)

      if conn.method == "POST" and
           conn.request_path == "/v2/my/ships/PROOF824-3/purchase" do
        send(
          controller,
          {:productive_send, Clock.utc_now(),
           FleetAllocation.current_ship_claim(fleet.agent, "PROOF824-3"),
           MutationAttempts.list_for_agent(fleet.agent)}
        )
      end

      World.reply(world, conn, controller)
    end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
    end)

    fleet = Runtime.fresh_generation(world, @preset)

    on_exit(fn ->
      for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
          do: SpaceTraders.Quiesced.stop_ship(symbol)

      Runtime.cleanup_control_fixture(fleet)
    end)

    Elixir.Agent.update(context, fn _ -> fleet end)
    assert SpaceTraders.Outcomes.Earnings.list(fleet.generation.id) == []
    start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))

    result =
      Runtime.finite_control(world, fleet, @preset, DateTime.add(@t0, 4, :hour),
        boundary: :application,
        stop_after_cycles: {"PROOF824-3", 2}
      )

    arm = ShipyardPayback.arm(result)

    # Exactly one acquisition; two profitable cycles; no decisive unknowns.
    assert arm.acquisitions == 1
    assert result.account.acquisition_outlays == 100_000
    assert length(arm.new_ship_cycles) == 2
    assert Enum.all?(arm.new_ship_cycles, &(is_integer(&1) and &1 > 0))
    assert arm.unknown_effects == []
    assert arm.contradictions == []
    assert result.account.unexplained_cash == 0
    assert result.account.low_credits >= result.floor
    refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))

    # Unchanged incumbent valuation admitted it; the independent stressed
    # complete-cycle check (capital + all future outlays, capped horizon,
    # before reset, funded, finite demand) supports it.
    assert arm.valuation.rate_basis in ~w(minimum_planned_realized discounted_planned)
    assert arm.valuation.horizon_seconds == 172_800
    assert arm.payback.classification == :supported
    assert arm.payback.capital_loaded_surplus > 0

    # Ordinary trade authority: the goods buy is sent under the new Ship's
    # own Claim with a durable MutationAttempt marked before send.
    assert_received {:productive_send, at, {:ok, authority}, attempts}
    assert is_integer(authority.commitment_id)

    assert Enum.any?(attempts, fn attempt ->
             attempt.operation_id == "purchase-cargo" and attempt.state == "sent_or_unknown" and
               attempt.sent_or_unknown_at == at and
               attempt.provenance["commitment_id"] == authority.commitment_id
           end)
  end
end
