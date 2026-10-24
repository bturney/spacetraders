defmodule SpaceTraders.ShipyardPurchaseRecoveryTest do
  # Independently committed state must survive the owned runtime restart.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox

  alias SpaceTraders.{
    Clock,
    Evidence,
    Fleet,
    FleetAcquisition,
    FleetAllocation,
    MutationAttempts,
    Repo
  }

  alias SpaceTraders.ShipyardProofRuntime, as: Runtime
  alias SpaceTraders.ShipyardProofWorld, as: World

  @t0 ~U[2026-10-22 00:00:00Z]
  @symbols ~w(PROOF824-1 PROOF824-2 PROOF824-3)

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline, capacity: true) end)
  end

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
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
      for symbol <- @symbols, do: SpaceTraders.Quiesced.stop_ship(symbol)

      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      SpaceTraders.Test.Governor.restart()

      :ok = Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "committed fixture teardown removes its causal notifications and preserves unrelated rows" do
    topic = "unrelated:shipyard-fixture:#{System.unique_integer([:positive])}"

    assert {:ok, :unrelated} =
             SpaceTraders.Outbox.publish(
               %{topic: topic, event: "unrelated_fixture", payload: %{"portfolio_id" => -1}},
               fn -> :unrelated end
             )

    sentinel = Repo.one!(from n in SpaceTraders.Outbox.Notification, where: n.topic == ^topic)
    on_exit(fn -> Repo.delete!(sentinel) end)
    baseline = notification_snapshot()
    world = start_supervised!({World, []})
    controller = self()
    Req.Test.stub(SpaceTraders.API, fn conn -> World.reply(world, conn, controller) end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
    end)

    fleet = Runtime.fresh_generation(world, "steady_growth")

    on_exit(fn ->
      for symbol <- @symbols, do: SpaceTraders.Quiesced.stop_ship(symbol)
      assert {:ok, _} = Runtime.cleanup_control_fixture(fleet)
    end)

    assert {:ok, %{action: :published}} = Runtime.run(fn -> Runtime.reconcile(fleet) end)
    for symbol <- @symbols, do: SpaceTraders.Quiesced.stop_ship(symbol)

    portfolios =
      Repo.all(
        from p in FleetAllocation.Portfolio,
          where: p.fleet_generation_id == ^fleet.generation.id,
          select: p.id
      )

    episodes =
      Repo.all(
        from e in FleetAllocation.StrategyDecisionEpisode,
          where: e.fleet_generation_id == ^fleet.generation.id,
          select: e.id
      )

    before_cleanup = notification_snapshot()
    created = Map.drop(before_cleanup, Map.keys(baseline))

    assert Enum.any?(created, fn {_id, row} ->
             row.event == "fleet_commitment_portfolio_published" and
               row.payload["portfolio_id"] in portfolios and
               row.payload["decision_episode_id"] in episodes and
               not Map.has_key?(row.payload, "agent_id") and
               not Map.has_key?(row.payload, "fleet_generation_id")
           end)

    assert {:ok, _} = Runtime.cleanup_control_fixture(fleet)
    after_cleanup = notification_snapshot()
    write_outbox_receipt(fleet, portfolios, episodes, baseline, before_cleanup, after_cleanup)
    assert Map.keys(Map.drop(after_cleanup, Map.keys(baseline))) == []
    assert Map.take(after_cleanup, Map.keys(baseline)) == baseline

    # The next ordinary publication/rollback must add only its own causal row,
    # even when unrelated persisted baseline notifications already exist.
    assert {:ok, :next} =
             SpaceTraders.Outbox.publish(
               %{topic: topic, event: "after_fixture", payload: %{}},
               fn -> :next end
             )

    [next] = notification_snapshot() |> Map.drop(Map.keys(baseline)) |> Map.values()
    assert next.event == "after_fixture"
    Repo.delete!(next)

    assert {:error, :forced_failure} =
             SpaceTraders.Outbox.publish(
               %{topic: topic, event: "rolled_back", payload: %{}},
               fn -> Repo.rollback(:forced_failure) end
             )

    assert notification_snapshot() == baseline
  end

  for preset <- ~w(steady_growth charted_expansion) do
    @preset preset
    test "#{preset}: a normally admitted lost purchase recovers its original Attempt after restart" do
      world = start_supervised!({World, []})
      controller = self()
      context = start_supervised!({Elixir.Agent, fn -> nil end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        fleet = Elixir.Agent.get(context, & &1)

        if conn.method == "POST" and conn.request_path == "/v2/my/ships",
          do: send(controller, {:purchase_send, checkpoint(fleet, world)})

        if conn.method == "GET" and conn.request_path == "/v2/my/ships/PROOF824-3",
          do: send(controller, {:readiness_read, checkpoint(fleet, world)})

        delivery =
          if conn.method == "POST" and conn.request_path == "/v2/my/ships",
            do: :lost_response,
            else: :delivered

        World.reply(world, conn, controller, delivery)
      end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      notification_baseline = notification_snapshot()
      fleet = Runtime.fresh_generation(world, @preset)
      Elixir.Agent.update(context, fn _ -> fleet end)

      on_exit(fn ->
        assert_fixture_notification_cleanup(fleet, notification_baseline)
      end)

      refute Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1")
      start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))

      prefix =
        Runtime.finite_control(world, fleet, @preset, DateTime.add(@t0, 48, :hour),
          boundary: :application,
          stop_at_unsettled_purchase: true
        )

      assert [original] = Enum.reject(purchase_attempts(fleet), &(&1.state == "not_sent"))
      assert original.state == "ambiguous"
      assert {:error, :ship_not_owned} = Fleet.owned_ship(fleet.agent, "PROOF824-3")
      assert prefix.account.acquisition_outlays == 100_000
      assert {commitment, ^original} = FleetAcquisition.open_purchase(fleet.agent)
      assert commitment.reservations["credits"] == 135_000
      assert_received {:purchase_send, send_check}
      assert_send(prefix, send_check, original)

      before_restart = checkpoint(fleet, world)
      assert World.advertise_second_offer(world) == :ok
      observe_offer(fleet)

      assert [offer] =
               Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1").facts[
                 "ships"
               ]

      assert offer["purchase_price"] == 100_000

      old_servers =
        for symbol <- @symbols,
            {pid, _} <- Registry.lookup(SpaceTraders.Fleet.ShipRegistry, symbol),
            do: {symbol, pid}

      old_scheduler = Process.whereis(SpaceTraders.Evidence.DemandScheduler)
      assert :ok = stop_supervised(SpaceTraders.Evidence.DemandScheduler)
      refute Process.alive?(old_scheduler)
      for {symbol, _pid} <- old_servers, do: SpaceTraders.Quiesced.stop_ship(symbol)
      for {_, pid} <- old_servers, do: refute(Process.alive?(pid))
      assert before_restart.attempts == checkpoint(fleet, world).attempts
      assert {:error, :ship_not_owned} = Fleet.owned_ship(fleet.agent, "PROOF824-3")
      assert Runtime.run(fn -> SpaceTraders.Fleet.ShipServerBoot.start_link([]) end) == :ignore
      start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))
      new_scheduler = Process.whereis(SpaceTraders.Evidence.DemandScheduler)
      refute new_scheduler == old_scheduler
      restarted = checkpoint(fleet, world)
      assert restarted.attempts == before_restart.attempts
      assert restarted.generation == before_restart.generation

      assert Enum.map(restarted.registered, & &1.symbol) ==
               Enum.map(before_restart.registered, & &1.symbol)

      for {symbol, old_pid} <- old_servers do
        # Boot rearms unfinished owned work, not an idle Ship just to satisfy
        # the fixture. Every server it does reconstruct must be a new process.
        for {new_pid, _} <- Registry.lookup(SpaceTraders.Fleet.ShipRegistry, symbol),
            do: refute(new_pid == old_pid)
      end

      assert [{_, _}] = Registry.lookup(SpaceTraders.Fleet.ShipRegistry, "PROOF824-1")

      runtime_restart = %{
        old_scheduler: inspect(old_scheduler),
        new_scheduler: inspect(new_scheduler),
        stopped_ships: Map.new(old_servers, fn {symbol, pid} -> {symbol, inspect(pid)} end),
        rearmed_ships:
          Map.new(
            for symbol <- @symbols,
                {pid, _} <- Registry.lookup(SpaceTraders.Fleet.ShipRegistry, symbol),
                do: {symbol, inspect(pid)}
          )
      }

      # Allocation sees a second obtainable offer while the ORIGINAL purchase is
      # unresolved. Its existing recovery owner settles that Attempt, and the
      # open-at-entry guard refuses another investment at this same boundary.
      blocked = Runtime.run(fn -> acquisition(fleet) end)
      assert blocked.rejection_reason == "acquisition_already_unsettled"
      assert [accepted] = Enum.reject(purchase_attempts(fleet), &(&1.state == "not_sent"))
      assert accepted.id == original.id
      assert accepted.state == "accepted"
      assert accepted.prepared_evidence == original.prepared_evidence
      assert accepted.provenance == original.provenance
      assert Enum.map(accepted.outcomes, & &1.classification) == ["ambiguous", "accepted"]
      assert {:ok, ship} = Fleet.owned_ship(fleet.agent, "PROOF824-3")
      assert ship.ship_type == "SHIP_LIGHT_HAULER"
      assert length(Fleet.current_ships(fleet.agent.id)) == 3

      assert {:error, :no_current_ship_claim} =
               FleetAllocation.current_ship_claim(fleet.agent, ship.symbol)

      assert FleetAcquisition.open_purchase(fleet.agent) == nil
      after_restart = checkpoint(fleet, world)
      assert_received {:readiness_read, readiness_check}
      refute Enum.any?(readiness_check.registered, &(&1.symbol == ship.symbol))

      assert Enum.any?(
               readiness_check.attempts,
               &(&1.id == original.id and &1.state == "accepted")
             )

      assert_recovery_reads(accepted, before_restart, after_restart)

      # A later offer is not prohibited forever: this one loses on actual
      # remaining time. Change only the announced horizon, then acquire the
      # fresh authoritative status/offer through governed reads.
      assert :ok = World.shorten_horizon(world)
      assert {:ok, _} = Runtime.run(fn -> Evidence.get_status_binding(fleet.agent) end)
      observe_offer(fleet)
      refused = Runtime.run(fn -> acquisition(fleet) end)
      assert refused.rejection_reason == "enabled_value_not_above_cost"
      assert refused.expectations["calibration"]["horizon_window_seconds"] == 172_800

      assert SpaceTraders.GenerationHorizon.current(fleet.agent, Clock.utc_now()).duration_seconds <=
               1800

      refute refused.rejection_reason == "acquisition_already_unsettled"
      assert purchase_attempts(fleet) == after_restart.attempts

      for _ <- 1..2 do
        assert Runtime.run(fn -> SpaceTraders.Fleet.ShipServerBoot.start_link([]) end) == :ignore

        assert Runtime.run(fn -> FleetAcquisition.reconcile(fleet.scope, fleet.agent) end) ==
                 {:error, :no_purchase_attempt}
      end

      final = checkpoint(fleet, world)

      assert length(
               Enum.filter(
                 final.world.requests,
                 &(&1.method == "POST" and &1.path == "/v2/my/ships")
               )
             ) == 1

      assert final.account.acquisition_outlays == 100_000
      assert final.account.unexplained_cash == 0
      assert final.account.credits == 400_000 + final.account.net_cash
      assert final.world.offer_stock == 1
      assert final.generation.id == fleet.generation.id
      assert final.generation.fleet_strategy_revision_id == fleet.revision.id
      assert Repo.get!(SpaceTraders.FleetStrategy.Revision, fleet.revision.id) == fleet.revision

      for check <- [send_check, before_restart, restarted, after_restart, final] do
        # Count the original possibly effective send once, not once for the
        # Reservation and again for its overlapping Attempt or recovery reads.
        possible = Enum.reject(check.attempts, &(&1.state == "not_sent"))
        assert Enum.map(possible, & &1.id) == [original.id]

        assert Enum.sum_by(possible, & &1.prepared_evidence["spending"]["worst_case_exposure"]) +
                 10_000 <= 135_000
      end

      refute Enum.any?(final.world.requests, &Map.has_key?(&1, :failure))

      assert Enum.all?(
               final.world.requests,
               &(DateTime.diff(&1.completed_at, &1.started_at, :millisecond) == 1000)
             )

      refute_received {:purchase_send, _}
      refute_received {:readiness_read, _}

      write_receipt(
        Map.merge(prefix, %{
          send_check: send_check,
          restarted: restarted,
          runtime_restart: runtime_restart,
          readiness_check: readiness_check
        }),
        before_restart,
        after_restart,
        final,
        blocked,
        refused
      )
    end
  end

  defp purchase_attempts(fleet),
    do:
      Enum.filter(
        MutationAttempts.list_for_agent(fleet.agent),
        &(&1.operation_id == "purchase-ship")
      )

  defp notification_snapshot do
    Map.new(Repo.all(SpaceTraders.Outbox.Notification), &{&1.id, &1})
  end

  defp assert_fixture_notification_cleanup(fleet, baseline) do
    for symbol <- @symbols, do: SpaceTraders.Quiesced.stop_ship(symbol)

    portfolios =
      Repo.all(
        from p in FleetAllocation.Portfolio,
          where: p.fleet_generation_id == ^fleet.generation.id,
          select: p.id
      )

    episodes =
      Repo.all(
        from e in FleetAllocation.StrategyDecisionEpisode,
          where: e.fleet_generation_id == ^fleet.generation.id,
          select: e.id
      )

    before_cleanup = notification_snapshot()
    assert {:ok, _} = Runtime.cleanup_control_fixture(fleet)
    after_cleanup = notification_snapshot()
    write_outbox_receipt(fleet, portfolios, episodes, baseline, before_cleanup, after_cleanup)
    assert Map.keys(Map.drop(after_cleanup, Map.keys(baseline))) == []
    assert Map.take(after_cleanup, Map.keys(baseline)) == baseline
  end

  defp write_outbox_receipt(fleet, portfolios, episodes, baseline, before_cleanup, after_cleanup) do
    if directory = System.get_env("SHIPYARD_OUTBOX_EVIDENCE") do
      File.mkdir_p!(directory)

      summarize = fn rows ->
        Map.new(rows, fn {id, row} ->
          {id,
           %{
             topic: row.topic,
             event: row.event,
             payload_owner_keys:
               Map.take(
                 row.payload,
                 ~w(agent_id fleet_generation_id portfolio_id decision_episode_id)
               ),
             payload_fingerprint: Evidence.fingerprint(row.payload),
             delivered_at: row.delivered_at
           }}
        end)
      end

      data = %{
        operator: fleet.scope.operator.id,
        agent: fleet.agent.id,
        generation: fleet.generation.id,
        portfolio_ids: portfolios,
        episode_ids: episodes,
        baseline: summarize.(baseline),
        before_cleanup: summarize.(before_cleanup),
        after_cleanup: summarize.(after_cleanup)
      }

      File.write!(
        Path.join(directory, "fixture-outbox-#{fleet.generation.id}.json"),
        Jason.encode!(Runtime.receipt_json(data), pretty: true)
      )
    end
  end

  defp acquisition(fleet),
    do:
      SpaceTraders.FleetAllocation.Acquisition.reconcile(
        fleet.scope,
        fleet.agent,
        fleet.revision,
        "X1-UX81",
        nil
      )

  defp observe_offer(fleet) do
    assert {:ok, yard} =
             Runtime.run(fn -> Evidence.get_shipyard(fleet.agent, "X1-UX81", "X1-UX81-A1") end)

    source = Evidence.latest_observation(fleet.agent, "shipyard:X1-UX81:X1-UX81-A1")

    assert {:ok, _} =
             SpaceTraders.Intelligence.observe_shipyard(fleet.agent, "X1-UX81", yard,
               source: "api",
               observed_at: source.observed_at,
               offers_visible: true,
               evidence: source
             )
  end

  defp checkpoint(fleet, world) do
    %{
      at: Clock.utc_now(),
      attempts: purchase_attempts(fleet),
      portfolio: FleetAllocation.current_portfolio(fleet.scope, fleet.agent),
      generation: FleetAllocation.current_generation(),
      registered: Fleet.current_ships(fleet.agent.id),
      world: World.snapshot(world),
      account: World.account(world, Clock.utc_now())
    }
  end

  defp assert_send(prefix, check, original) do
    assert [sending] = Enum.reject(check.attempts, &(&1.state == "not_sent"))
    assert sending.id == original.id
    assert sending.state == "sent_or_unknown"
    assert sending.sent_or_unknown_at == check.at
    assert DateTime.compare(sending.prepared_at, sending.sent_or_unknown_at) != :gt
    assert sending.fleet_generation_id == prefix.generation
    assert sending.strategy_revision_id == prefix.strategy_revision
    assert sending.prepared_evidence["spending"]["worst_case_exposure"] == 125_000

    purchase =
      Enum.find(check.portfolio.commitments, &(&1.id == sending.provenance["commitment_id"]))

    assert purchase.claims == []
    assert purchase.reservations["credits"] == 135_000

    assert sending.provenance["decision_episode_id"] ==
             FleetAllocation.commitment_decision_episode(purchase).id

    retained = Enum.reject(check.portfolio.commitments, &(&1.id == purchase.id))
    protected = Enum.sum_by(retained, &(&1.reservations["credits"] || 0))
    assert protected >= 50_000
    assert SpaceTraders.CreditCalibration.active().margin_percent == 25
    assert check.world.credits - prefix.floor - protected - 135_000 >= 60_000
    assert map_size(check.world.ships) == 2
    assert length(check.registered) == 2
    assert Enum.all?(check.attempts, &(&1.id == original.id or &1.state == "not_sent"))
    episode = FleetAllocation.commitment_decision_episode(purchase)
    assert episode.calibration_version == "ship-acquisition-v2"
    assert episode.expectations["valuation"]["horizon"]["duration_seconds"] == 172_800
  end

  defp assert_recovery_reads(accepted, before_restart, after_restart) do
    outcome = List.last(accepted.outcomes)
    observations = outcome.evidence["observations"]

    assert Enum.sort(Enum.map(observations, & &1["operation_id"])) == [
             "get-my-agent",
             "get-my-ships"
           ]

    for observation <- observations do
      source = Repo.get!(Evidence.Observation, observation["source"]["id"])
      assert source.agent_id == accepted.agent_id
      assert source.fleet_generation_id == accepted.fleet_generation_id
      assert DateTime.compare(source.observed_at, accepted.sent_or_unknown_at) == :gt
      assert DateTime.compare(source.observed_at, before_restart.at) != :lt

      assert Enum.any?(
               after_restart.world.requests,
               &(&1.completed_at == source.observed_at and &1.method == "GET")
             )
    end

    ready = Enum.find(after_restart.world.requests, &(&1.path == "/v2/my/ships/PROOF824-3"))

    observed =
      before_restart.world.requests
      |> Enum.filter(&String.ends_with?(&1.path, "/shipyard"))
      |> List.last()

    offer = SpaceTraders.API.Model.ShipyardShip.from_json(hd(observed.response["ships"]))
    ship = SpaceTraders.API.Model.Ship.from_json(ready.response)

    for field <- ~w(frame reactor engine modules mounts)a,
        do: assert(Map.fetch!(ship, field) == Map.fetch!(offer, field))

    assert {ship.cargo.capacity, ship.cargo.units, ship.fuel.current, ship.fuel.capacity} ==
             {40, 0, 100, 100}

    assert ship.crew.current >= ship.crew.required
    assert ship.cooldown.remaining_seconds == 0
    assert DateTime.compare(ready.completed_at, outcome.recorded_at) != :lt
  end

  defp write_receipt(prefix, before_restart, after_restart, final, blocked, refused) do
    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)

      data = %{
        ticket: 840,
        classification: "purchase S2/acquisition S4 only; not full P1/payback/live qualification",
        prefix: prefix,
        before_restart: before_restart,
        after_restart: after_restart,
        final: final,
        blocked: blocked,
        refused: refused,
        variations: [
          "lose the single accepted purchase response",
          "advertise a second obtainable offer while unsettled",
          "after settlement announce thirty minutes remaining"
        ],
        limits: [
          "Owned ShipServers and DemandScheduler restarted; not a whole BEAM/database restart.",
          "No full P1/productive-cycle/payback or live qualification claim; #837 remains separate.",
          "Purchase S2 and acquisition S4 only; #842 owns remaining payment/cutoff/reset matrix.",
          "Baseline B retained separately with mixed wall/application clocks; no B production patch or causal Delta claim."
        ],
        test_source_sha256:
          :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower)
      }

      File.write!(
        Path.join(directory, "840-#{prefix.preset}.json"),
        Jason.encode!(Runtime.receipt_json(data), pretty: true)
      )
    end
  end
end
