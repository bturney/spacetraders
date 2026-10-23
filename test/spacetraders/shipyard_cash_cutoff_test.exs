defmodule SpaceTraders.ShipyardCashCutoffTest do
  # The restart must observe independently committed state, not a shared rollback.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Clock, Evidence, Fleet, FleetAllocation, MutationAttempts, Repo}
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
    admission_baseline = :sys.get_state(SpaceTraders.FleetGenerationAdmission)
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

      :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      {:ok, _} =
        Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

      :ok = Sandbox.mode(Repo, :manual)
      # Restore precisely the pre-test volatile credential fences. Do not clear
      # another test's fences or let this synthetic reset poison reused tokens.
      assert :sys.replace_state(SpaceTraders.FleetGenerationAdmission, fn _ ->
               admission_baseline
             end) == admission_baseline
    end)
  end

  for preset <- ~w(steady_growth charted_expansion) do
    @preset preset
    test "#{preset}: the real 25k-bound payment settles once across committed runtime restart" do
      {world, fleet} = fixture(@preset, scenario: :payment_safety, lose: "/purchase")
      start_supervised!(SpaceTraders.Quiesced.child_spec(Evidence.DemandScheduler))

      assert {:ok, %{action: :published, commitments: commitments}} =
               Runtime.run(fn -> Runtime.reconcile(fleet) end)

      trade = Enum.find(commitments, &(&1.claims == ["PROOF824-1"]))
      assert trade.reservations["credits"] == 25_000
      [original] = cargo_attempts(fleet, "purchase-cargo")
      assert original.state == "ambiguous"
      assert original.prepared_evidence["request"]["body"]["units"] == 20
      assert original.prepared_evidence["spending"]["worst_case_exposure"] == 25_000
      assert original.provenance["commitment_id"] == trade.id
      assert original.fleet_generation_id == fleet.generation.id
      assert original.strategy_revision_id == fleet.revision.id
      assert credit_fences(fleet) == [original.id]

      unknown_at = Clock.utc_now()
      unknown = Runtime.cash_evidence(fleet, unknown_at)
      assert unknown.net_cash == nil
      assert unknown.net_cash_bounds == %{minimum: -25_000, maximum: 0}
      assert [%{attempt_id: id, amount: nil, effect_at: nil}] = unknown.unknown_monetary_effects
      assert id == original.id
      assert World.account(world, unknown_at).goods_outlays == 20_000
      protected = FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

      assert Enum.find(protected.commitments, &(&1.id == trade.id)).reservations["credits"] ==
               25_000

      restart = restart_owned_runtime()
      assert MutationAttempts.get!(original.id).state == "ambiguous"
      assert credit_fences(fleet) == [original.id]

      retry =
        Enum.find(
          SpaceTraders.Timeline.pending_events(:ship, "PROOF824-1"),
          &(&1.event_type == "intent_retry")
        )

      assert retry
      until_event(retry)
      accepted = MutationAttempts.get!(original.id)
      assert accepted.state == "accepted"
      assert accepted.prepared_evidence == original.prepared_evidence
      assert accepted.provenance == original.provenance
      assert Enum.map(accepted.outcomes, & &1.classification) == ["ambiguous", "accepted"]
      assert credit_fences(fleet) == []

      # Repeated reconstruction is not another send, settlement, or income.
      for _ <- 1..2 do
        assert Runtime.run(fn -> Fleet.ShipServerBoot.start_link([]) end) == :ignore
        Runtime.settle_ships()
      end

      assert [final] = cargo_attempts(fleet, "purchase-cargo")
      assert final == accepted
      settled = Runtime.cash_evidence(fleet, Clock.utc_now())
      assert settled.net_cash == -20_000
      assert settled.net_cash_bounds == %{minimum: -20_000, maximum: -20_000}
      assert settled.unknown_monetary_effects == []
      # A later balance proves amount, not the actual instant of the lost effect.
      late = Runtime.cash_evidence(fleet, unknown_at)
      assert late.net_cash == nil
      assert late.net_cash_bounds == %{minimum: -20_000, maximum: 0}
      assert [%{amount: -20_000, effect_at: nil}] = late.unknown_monetary_effects

      account = World.account(world, Clock.utc_now())

      assert {account.net_cash, account.credits, account.goods_outlays} ==
               {-20_000, 380_000, 20_000}

      assert Enum.count(account.effects, &(&1.signed_cash != 0)) == 1

      [purchase] =
        Enum.filter(World.snapshot(world).requests, &String.ends_with?(&1.path, "/purchase"))

      assert purchase.completed_at == DateTime.add(original.sent_or_unknown_at, 1)
      assert DateTime.compare(List.last(final.outcomes).recorded_at, purchase.completed_at) == :gt
      assert Map.fetch!(account.cargo_basis["PROOF824-1"], purchase.body["symbol"]) == 20_000
      assert account.fuel["PROOF824-1"]["current"] == 38
      assert SpaceTraders.Outcomes.Earnings.list(fleet.generation.id) == []

      write_receipt("payment", @preset, world, fleet, %{
        unknown_at: unknown_at,
        unknown: unknown,
        original: original,
        original_commitment: trade,
        original_decision: FleetAllocation.commitment_decision_episode(trade),
        restart: restart,
        settled: settled,
        accepted: accepted,
        late_without_occurrence: late,
        authoritative_effect_at: purchase.completed_at
      })
    end

    test "#{preset}: goods bought before T and sold after T remain stock, not pre-T revenue" do
      {world, fleet} = fixture(@preset)
      assert {:ok, %{action: :published}} = Runtime.run(fn -> Runtime.reconcile(fleet) end)
      Runtime.settle_ships()
      state = World.snapshot(world)
      [purchase] = Enum.filter(state.requests, &String.ends_with?(&1.path, "/purchase"))
      [navigation] = Enum.filter(state.requests, &String.ends_with?(&1.path, "/navigate"))
      {:ok, arrival, 0} = DateTime.from_iso8601(navigation.response["nav"]["route"]["arrival"])
      cutoff = DateTime.add(arrival, -1)
      Clock.send_at(self(), :cash_cutoff, cutoff)
      until_marker(:cash_cutoff)
      at_cutoff = checkpoint(world, fleet, cutoff)
      assert DateTime.compare(purchase.completed_at, cutoff) == :lt
      assert at_cutoff.account.net_cash == -40_000
      assert at_cutoff.account.receipts == 0
      assert at_cutoff.account.goods_outlays == 40_000
      assert at_cutoff.account.ships["PROOF824-1"]["cargo"]["units"] == 40
      assert at_cutoff.account.cargo_basis["PROOF824-1"][purchase.body["symbol"]] == 40_000
      assert at_cutoff.account.fuel["PROOF824-1"]["current"] == 38
      [buy] = Enum.filter(Fleet.Intents.history(fleet.agent), &(&1.type == "buy"))

      assert buy.last_action_result["transaction"]["timestamp"] ==
               purchase.response["transaction"]["timestamp"]

      assert at_cutoff.evidence.net_cash == -40_000,
             inspect(%{evidence: at_cutoff.evidence, history: Fleet.Intents.history(fleet.agent)},
               limit: :infinity
             )

      assert at_cutoff.evidence.unknown_monetary_effects == []
      assert at_cutoff.earnings == []
      assert Enum.any?(at_cutoff.open_work, &(&1.type == "sell"))
      assert Enum.all?(at_cutoff.attempts, &(&1.state == "succeeded"))

      Runtime.next_arrival("PROOF824-1")
      Runtime.settle_ships()
      [sale] = Enum.filter(World.snapshot(world).requests, &String.ends_with?(&1.path, "/sell"))
      assert DateTime.compare(sale.completed_at, cutoff) == :gt
      after_tail = checkpoint(world, fleet, cutoff)
      assert after_tail.account.net_cash == -40_000
      assert after_tail.account.credits == 360_000
      assert after_tail.account.cargo_basis == at_cutoff.account.cargo_basis
      assert after_tail.account.fuel == at_cutoff.account.fuel
      assert after_tail.account.ships == at_cutoff.account.ships
      assert after_tail.evidence.net_cash == -40_000
      assert [%{amount: 60_000, effect_at: sale_at}] = after_tail.evidence.closure_tail
      assert sale_at == sale.completed_at
      assert Enum.sum_by(after_tail.account.closure_tail, & &1.signed_cash) == 60_000
      assert [record] = after_tail.earnings
      assert record.net_earnings == 20_000
      assert DateTime.compare(record.finished_at, cutoff) == :gt
      assert World.account(world, Clock.utc_now()).net_cash == 20_000

      write_receipt("cutoff", @preset, world, fleet, %{
        window: "separate near-cutoff first-cycle window; not a T48h replay",
        cutoff: cutoff,
        at_cutoff: at_cutoff,
        after_tail: after_tail,
        closure_tail: "post-T sale; excluded from the immutable primary T score"
      })
    end

    test "#{preset}: omitting the decisive sale receipt leaves profit and payback inconclusive" do
      {world, fleet} = fixture(@preset, lose: "/sell")
      assert {:ok, %{action: :published}} = Runtime.run(fn -> Runtime.reconcile(fleet) end)
      Runtime.settle_ships()
      Runtime.next_arrival("PROOF824-1")
      Runtime.settle_ships()
      cutoff = Clock.utc_now()
      [original] = cargo_attempts(fleet, "sell-cargo")
      assert original.state == "ambiguous"
      assert original.provenance["commitment_id"]
      assert credit_fences(fleet) == [original.id]
      evidence = Runtime.cash_evidence(fleet, cutoff)
      assert evidence.net_cash == nil
      assert evidence.known_net_cash == -40_000
      assert evidence.net_cash_bounds == %{minimum: -40_000, maximum: nil}
      assert evidence.economic_claim == :inconclusive

      assert [%{attempt_id: id, amount: nil, effect_at: nil, minimum: 0, maximum: nil}] =
               evidence.unknown_monetary_effects

      assert id == original.id
      # The forecast quote is not an authoritative maximum on an unseen sale.
      assert original.prepared_evidence["selected_action"]["listing_price"] == 1500
      assert SpaceTraders.Outcomes.Earnings.list(fleet.generation.id) == []

      assert Enum.any?(
               Fleet.Intents.current(fleet.agent),
               &(&1.type == "sell" and &1.status == "blocked")
             )

      [sale] = Enum.filter(World.snapshot(world).requests, &String.ends_with?(&1.path, "/sell"))
      assert sale.delivery == :lost_response
      assert sale.response["transaction"]["totalPrice"] == 60_000
      assert World.account(world, cutoff).net_cash == 20_000

      write_receipt("missing-receipt", @preset, world, fleet, %{
        cutoff: cutoff,
        available_evidence: evidence,
        claims: %{profit: :inconclusive, payback: :inconclusive},
        hidden_oracle_is_not_application_evidence: true
      })
    end

    test "#{preset}: definitive reset evidence fences the old queued sale without erasing its buy" do
      reset_at = DateTime.add(@t0, 30)
      {world, fleet} = fixture(@preset, reset_at: reset_at)
      assert {:ok, _} = Runtime.run(fn -> Evidence.get_status_binding(fleet.agent) end)
      status = Evidence.latest_observation(fleet.agent, "server:status")
      assert status
      assert {:ok, %{action: :published}} = Runtime.run(fn -> Runtime.reconcile(fleet) end)
      Runtime.settle_ships()

      [arrival] =
        Enum.filter(
          SpaceTraders.Timeline.pending_events(:ship, "PROOF824-1"),
          &(&1.event_type == "arrival")
        )

      assert SpaceTraders.Timeline.pending?(arrival)
      [buy] = cargo_attempts(fleet, "purchase-cargo")
      assert buy.state == "succeeded"
      [sell] = Enum.filter(Fleet.Intents.current(fleet.agent), &(&1.type == "sell"))
      assert sell.fleet_commitment_id == buy.provenance["commitment_id"]
      Clock.send_at(self(), :announced_reset, reset_at)
      until_marker(:announced_reset)
      assert SpaceTraders.Timeline.pending?(arrival)
      at_reset = checkpoint(world, fleet, reset_at)
      assert at_reset.account.net_cash == -40_000
      assert at_reset.account.ships["PROOF824-1"]["cargo"]["units"] == 40
      assert at_reset.account.fuel["PROOF824-1"]["current"] == 38

      # A real governed safety read learns the definitive mismatch. The normal
      # lifecycle owner, not a test-written fence/cancel, removes authority.
      assert {:error, :stale_agent} =
               Runtime.run(fn -> SpaceTraders.FleetGeneration.agent_overview(fleet.agent) end)

      assert {:ok, %{state: :transition, generation: fenced}} =
               SpaceTraders.FleetGeneration.current_fleet(fleet.scope)

      assert fenced.id == fleet.generation.id
      assert fenced.fenced_at
      assert fenced.fleet_strategy_revision_id == fleet.revision.id

      assert {:ok, historical} =
               SpaceTraders.FleetGeneration.generation_evidence(fleet.scope, fenced.id)

      assert historical.generation.id == fleet.generation.id
      before_queued_wake = World.snapshot(world)
      assert SpaceTraders.Timeline.pending?(arrival)
      Clock.send_at(self(), :old_arrival_due, DateTime.add(arrival.due_at, 1))
      until_marker(:old_arrival_due)
      # A fenced owner may retain the pending event until normal retirement;
      # completion/cancellation is not needed to prove the send fence.
      assert World.snapshot(world).requests == before_queued_wake.requests
      assert cargo_attempts(fleet, "sell-cargo") == []
      assert MutationAttempts.get!(buy.id) == buy
      assert SpaceTraders.Outcomes.Earnings.list(fleet.generation.id) == []
      assert World.account(world, reset_at).net_cash == -40_000
      assert World.account(world, Clock.utc_now()).net_cash == -40_000
      assert World.account(world, reset_at).cargo_basis == at_reset.account.cargo_basis

      refute Enum.any?(
               World.snapshot(world).requests,
               &(&1.method == "POST" and DateTime.compare(&1.started_at, reset_at) != :lt)
             )

      write_receipt("reset", @preset, world, fleet, %{
        announced_status: status,
        reset_at: reset_at,
        queued_arrival: arrival,
        queued_sale: sell,
        at_reset: at_reset,
        fenced: fenced,
        historical_generation: historical.generation,
        queued_event_after_wake: Repo.reload!(arrival),
        after_queued_wake: checkpoint(world, fleet, reset_at),
        classification:
          "reset-censored old work; costs retained, no old send or post-reset benefit"
      })
    end
  end

  defp checkpoint(world, fleet, cutoff) do
    %{
      at: Clock.utc_now(),
      account: World.account(world, cutoff),
      evidence: Runtime.cash_evidence(fleet, cutoff),
      open_work: Fleet.Intents.current(fleet.agent),
      attempts: MutationAttempts.list_for_agent(fleet.agent),
      earnings: SpaceTraders.Outcomes.Earnings.list(fleet.generation.id)
    }
  end

  defp until_marker(marker, remaining \\ 100)
  defp until_marker(_, 0), do: flunk("cutoff not reached within 100 scheduled events")

  defp until_marker(marker, remaining) do
    receive do
      ^marker -> :ok
    after
      0 ->
        Runtime.next_event()
        Runtime.settle_ships()
        until_marker(marker, remaining - 1)
    end
  end

  defp fixture(preset, opts \\ []) do
    {lose, opts} = Keyword.pop(opts, :lose)
    world = start_supervised!({World, opts})
    controller = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      delivery =
        if lose && conn.method == "POST" && String.ends_with?(conn.request_path, lose),
          do: :lost_response,
          else: :delivered

      World.reply(world, conn, controller, delivery)
    end)

    Req.Test.allow(SpaceTraders.API, self(), fn ->
      DynamicSupervisor.which_children(Fleet.ShipSupervisor)
      |> Enum.map(fn {_, pid, _, _} -> pid end)
    end)

    fleet = Runtime.fresh_generation(world, preset)

    on_exit(fn ->
      for symbol <- @symbols, do: SpaceTraders.Quiesced.stop_ship(symbol)
      assert {:ok, _} = Runtime.cleanup_control_fixture(fleet)
    end)

    assert SpaceTraders.Outcomes.Earnings.list(fleet.generation.id) == []
    {:ok, floor} = SpaceTraders.FleetExecution.credit_floor(fleet.revision)
    assert floor == if(preset == "steady_growth", do: 50_000, else: 75_000)
    {world, fleet}
  end

  defp restart_owned_runtime do
    old_scheduler = Process.whereis(Evidence.DemandScheduler)
    assert :ok = stop_supervised(Evidence.DemandScheduler)
    refute Process.alive?(old_scheduler)

    old =
      for symbol <- @symbols,
          {pid, _} <- Registry.lookup(Fleet.ShipRegistry, symbol),
          do: {symbol, pid}

    for {symbol, _} <- old, do: SpaceTraders.Quiesced.stop_ship(symbol)
    for {_, pid} <- old, do: refute(Process.alive?(pid))
    assert Runtime.run(fn -> Fleet.ShipServerBoot.start_link([]) end) == :ignore
    start_supervised!(SpaceTraders.Quiesced.child_spec(Evidence.DemandScheduler))
    new_scheduler = Process.whereis(Evidence.DemandScheduler)
    refute old_scheduler == new_scheduler

    new =
      for symbol <- @symbols,
          {pid, _} <- Registry.lookup(Fleet.ShipRegistry, symbol),
          do: {symbol, pid}

    for {symbol, pid} <- new, do: refute({symbol, pid} in old)
    assert List.keymember?(new, "PROOF824-1", 0)

    %{
      old_ships: inspect(old),
      new_ships: inspect(new),
      old_scheduler: inspect(old_scheduler),
      new_scheduler: inspect(new_scheduler)
    }
  end

  defp until_event(event, remaining \\ 100)
  defp until_event(_, 0), do: flunk("owned retry did not settle within 100 scheduled events")

  defp until_event(event, remaining) do
    if SpaceTraders.Timeline.pending?(event) do
      Runtime.next_event()
      Runtime.settle_ships()
      until_event(event, remaining - 1)
    end
  end

  defp cargo_attempts(fleet, operation),
    do: Enum.filter(MutationAttempts.list_for_agent(fleet.agent), &(&1.operation_id == operation))

  defp credit_fences(fleet) do
    SpaceTraders.SafetyFence.blocking_attempts([
      SpaceTraders.SafetyFence.DependencyKey.agent_credits(fleet.agent.id)
    ])
    |> Enum.map(& &1.id)
  end

  defp write_receipt(kind, preset, world, fleet, details) do
    state = World.snapshot(world)
    refute Enum.any?(state.requests, &Map.has_key?(&1, :failure))
    assert SpaceTraders.API.CapacityGovernor.diagnostics().in_flight == 0
    assert Repo.get!(SpaceTraders.FleetStrategy.Revision, fleet.revision.id) == fleet.revision
    {:ok, floor} = SpaceTraders.FleetExecution.credit_floor(fleet.revision)
    assert World.account(world, Clock.utc_now()).low_credits >= floor
    {code, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    data = %{
      ticket: 842,
      case: kind,
      preset: preset,
      code_revision: String.trim(code),
      fixture_revision:
        System.get_env("SHIPYARD_PROOF_FIXTURE_REVISION", "uncommitted; use source hashes"),
      manifest: Runtime.manifest(),
      floor: floor,
      variation: %{
        transaction_maximum: state.transaction_maximum,
        reset_at: state.reset_at,
        scope: "separate #{kind} variant; manifest carries unchanged canonical positive defaults"
      },
      generation: fleet.generation.id,
      strategy_revision: fleet.revision.id,
      preset_document: fleet.revision.document,
      as_of: Clock.utc_now(),
      reset_at: state.reset_at,
      details: details,
      oracle_account: World.account(world, Clock.utc_now()),
      requests: state.requests,
      attempts: MutationAttempts.list_for_agent(fleet.agent),
      intents: Fleet.Intents.current(fleet.agent) ++ Fleet.Intents.history(fleet.agent),
      earnings: SpaceTraders.Outcomes.Earnings.list(fleet.generation.id),
      source_sha256:
        Map.new(
          [
            __ENV__.file,
            "test/support/shipyard_proof_runtime.ex",
            "test/support/shipyard_proof_world.ex",
            "test/support/shipyard_payback.ex",
            "test/spacetraders/shipyard_payback_test.exs",
            "lib/spacetraders/fleet.ex"
          ],
          fn path ->
            {Path.relative_to_cwd(path),
             :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
          end
        ),
      limits: [
        "Owned runtime restart; not BEAM/database restart.",
        "Separate bounded safety variants; not P1, payback, B/V cash superiority or Gate 0."
      ]
    }

    json = Jason.encode!(Runtime.receipt_json(data), pretty: true)

    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "842-#{kind}-#{preset}.json"), json)
    end
  end
end
