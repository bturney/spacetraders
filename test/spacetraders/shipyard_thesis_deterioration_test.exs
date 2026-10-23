defmodule SpaceTraders.ShipyardThesisDeteriorationTest do
  # #841 / #821 S3: after the acquired Ship is ready, its route's destination
  # sell falls to 1,000. Only a legitimate on-site Market read can reveal it.
  # Both arms run under one request per two game-seconds through the normal
  # limiter, with the original trader holding disjoint work across the fence.
  use ExUnit.Case, async: false

  # Wall-time budget, not a wait: each run is bounded by its 6-game-hour
  # cutoff. Readiness lands at 00:27 or 02:16 and the original trader may share
  # the acquired Ship's route for whole cycles, so the disjoint fence point can
  # arrive near 04:30 game time (about 70-80 s of real reconciliation).
  @moduletag timeout: 180_000

  import Ecto.Query

  alias SpaceTraders.{Clock, FleetAllocation, Repo}
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.ShipyardProofRuntime, as: Runtime
  alias SpaceTraders.ShipyardProofWorld, as: World

  @t0 ~U[2026-10-22 00:00:00Z]
  @symbols ~w(PROOF824-1 PROOF824-2 PROOF824-3)
  @destination %{"IRON" => "X1-UX81-A2", "COPPER" => "X1-UX81-A3"}

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

    # The S3 external capacity: one request per two game-seconds, imposed by
    # the client's ordinary limiter on the shared application clock.
    start_supervised!(
      {SpaceTraders.API.RateLimiter,
       rate: 0.5,
       burst: 1,
       pool_rate: 0.0,
       pool_burst: 0,
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
    end)

    :ok
  end

  for preset <- ~w(steady_growth charted_expansion), arm <- [:before_buy, :after_buy] do
    @preset preset
    @arm arm
    test "#{preset} #{arm}: a deteriorated thesis is fenced while independent work completes" do
      world = start_supervised!({World, []})
      controller = self()
      context = start_supervised!({Elixir.Agent, fn -> %{fleet: nil, s3: nil, marks: []} end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn = World.reply(world, conn, controller)
        mark_progress(context, conn)
        maybe_deteriorate(world, context, @arm, conn)
        conn
      end)

      Req.Test.allow(SpaceTraders.API, self(), fn ->
        DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor)
        |> Enum.map(fn {_, pid, _, _} -> pid end)
      end)

      fleet = Runtime.fresh_generation(world, @preset)

      on_exit(fn ->
        for symbol <- @symbols, do: SpaceTraders.Quiesced.stop_ship(symbol)
        Runtime.cleanup_control_fixture(fleet)
      end)

      Elixir.Agent.update(context, &%{&1 | fleet: fleet})
      start_supervised!(SpaceTraders.Quiesced.child_spec(SpaceTraders.Evidence.DemandScheduler))
      cutoff = DateTime.add(@t0, 6, :hour)

      result =
        Runtime.finite_control(world, fleet, @preset, cutoff,
          boundary: :application,
          stop_when: fn -> fenced_proof_complete?(context, @arm) end
        )

      s3 = Elixir.Agent.get(context, & &1.s3)
      assert s3, "the acquired Ship never reached the #{@arm} point beside disjoint work"
      receipt = receipt(result, world, fleet, s3, @arm)
      write_receipt(receipt, @preset, @arm)
      %{good: good, destination: destination} = s3

      # The observable change: a later legitimate on-site Market read.
      assert %{observed_at: observed_at} = changed = receipt.changed_evidence
      assert changed.operation_id == "get-market"
      assert changed.sell_price <= 1000
      assert DateTime.compare(observed_at, s3.deteriorated_at) != :lt

      # Recovery was not starved: both the fenced reconciliation and the
      # independent sale finished before the hard cutoff, under real waits.
      assert DateTime.compare(result.execution_stopped_at, cutoff) == :lt
      starts = result.request_effects |> Enum.map(& &1.started_at) |> Enum.sort(DateTime)

      assert starts
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> DateTime.diff(b, a, :millisecond) >= 2000 end)

      assert Enum.any?(result.waits, &(&1.kind == :protocol))
      refute Enum.any?(result.request_effects, &Map.has_key?(&1, :failure))

      # No further spending on the deteriorated route once it was observed.
      assert [] ==
               for(
                 r <- result.request_effects,
                 r.method == "POST" and String.ends_with?(r.path, "/purchase"),
                 r.body["symbol"] == good,
                 DateTime.compare(r.started_at, observed_at) == :gt,
                 do: {r.path, r.started_at}
               )

      # Independent authority: the original trader's disjoint Commitment held
      # its Claim across the fence and completed a profitable sale after it.
      independent = s3.independent
      assert independent.claims == ["PROOF824-1"]
      refute "market:X1-UX81:#{destination}" in subjects(independent)
      [sale | _] = receipt.independent_sales
      assert DateTime.compare(sale.finished_at, observed_at) == :gt
      assert sale.net_earnings > 0

      refute Enum.any?(
               receipt.intents.independent,
               &(&1.status in ~w(infeasible superseded blocked))
             )

      assert result.account.unexplained_cash == 0

      case @arm do
        :before_buy ->
          # The originally planned purchase was refused by ordinary execution
          # revalidation against the newer destination evidence.
          assert [refused | _] = receipt.refused_dependent_buys
          assert refused.trade_symbol == good
          assert refused.reason == "destination_spread_lost"
          assert refused.planned_destination_evidence != "evidence-observation:#{changed.id}"

        :after_buy ->
          # Sunk cost stays truthful: the actual charge remains recorded,
          # either in the realized cycle or as retained Cargo basis.
          [bought] = receipt.fenced_purchase

          case receipt.fenced_cycle do
            %{} = cycle ->
              # World charge/receipt, not the ledger's own arithmetic: a sale
              # at no more than 1,000 cannot recover a 1,000+ unit cost.
              assert cycle.goods_cost == bought.charge
              assert cycle.revenue == receipt.fenced_sale_receipt
              assert cycle.expected_value > 0 and cycle.net_earnings <= 0

            nil ->
              assert get_in(result.account.cargo_basis, ["PROOF824-3", good]) == bought.charge
          end
      end
    end
  end

  # -- S3 trigger -----------------------------------------------------------

  # Deteriorate exactly once, only while the acquired Ship's route depends on
  # the destination and the original trader holds disjoint work.
  defp maybe_deteriorate(world, context, arm, conn) do
    with %{s3: nil, fleet: %{} = fleet} <- Elixir.Agent.get(context, & &1),
         {:ok, good} <- trigger(world, arm, conn),
         other = if(good == "IRON", do: "COPPER", else: "IRON"),
         {:ok, independent} <- independent_work(fleet, good, other),
         {:ok, dependent} <- FleetAllocation.current_ship_claim(fleet.agent, "PROOF824-3") do
      World.deteriorate_destination(world, good)

      Elixir.Agent.update(context, fn state ->
        %{
          state
          | s3: %{
              arm: arm,
              good: good,
              destination: @destination[good],
              deteriorated_at: Clock.utc_now(),
              independent: independent,
              dependent_claim: dependent
            }
        }
      end)
    end

    :ok
  end

  # Before buy: the acquired Ship has just sold at the destination, its next
  # goods buy not yet sent. After buy: it is docking there with the goods.
  defp trigger(_world, :before_buy, %{method: "POST", request_path: path} = conn)
       when path == "/v2/my/ships/PROOF824-3/sell",
       do: {:ok, conn.body_params["symbol"]}

  defp trigger(world, :after_buy, %{method: "POST", request_path: path})
       when path == "/v2/my/ships/PROOF824-3/dock" do
    ship = World.snapshot(world).ships["PROOF824-3"]

    Enum.find_value(ship["cargo"]["inventory"], :not_loaded, fn item ->
      if item["units"] > 0 and @destination[item["symbol"]] == ship["nav"]["waypointSymbol"],
        do: {:ok, item["symbol"]}
    end)
  end

  defp trigger(_world, _arm, _conn), do: :not_triggered

  defp independent_work(fleet, good, other) do
    with {:ok, claim} <- FleetAllocation.current_ship_claim(fleet.agent, "PROOF824-1"),
         %Commitment{} = commitment <- Repo.get(Commitment, claim.commitment_id),
         subjects = subjects(commitment),
         true <- "market:X1-UX81:#{@destination[other]}" in subjects,
         false <- "market:X1-UX81:#{@destination[good]}" in subjects,
         # Work still ahead of it: an unfinished Intent of that Commitment.
         true <-
           Enum.any?(
             SpaceTraders.Fleet.Intents.current(fleet.agent),
             &(&1.fleet_commitment_id == commitment.id)
           ) do
      {:ok,
       commitment
       |> Map.take(~w(id candidate_id claims dependencies expected_value)a)
       |> Map.put(:claim, claim)}
    else
      _ -> :no_disjoint_work
    end
  end

  defp subjects(commitment),
    do: Enum.map(commitment.dependencies, &(&1["subject"] || &1[:subject]))

  # -- Stop condition: observed fence, independent sale, dependent resolved --

  # Request marks after the deterioration, recorded by the stub so the stop
  # check never copies the World's whole request history.
  defp mark_progress(context, %{method: method, request_path: path} = conn) do
    Elixir.Agent.update(context, fn
      %{s3: %{} = s3} = state ->
        mark =
          case {method, path} do
            {"GET", "/v2/systems/X1-UX81/waypoints/" <> rest} ->
              if rest == "#{s3.destination}/market", do: :destination_read

            {"POST", "/v2/my/ships/PROOF824-3/purchase"} ->
              :dependent_purchase

            {"POST", "/v2/my/ships/PROOF824-3/sell"} ->
              if conn.body_params["symbol"] == s3.good, do: :fenced_sale

            {"POST", "/v2/my/ships/PROOF824-1/sell"} ->
              :independent_sale

            _ ->
              nil
          end

        if mark, do: %{state | marks: state.marks ++ [{mark, Clock.utc_now()}]}, else: state

      state ->
        state
    end)
  end

  defp fenced_proof_complete?(context, arm) do
    with %{s3: %{} = s3, fleet: fleet, marks: marks} <- Elixir.Agent.get(context, & &1),
         {:destination_read, read_at} <- List.keyfind(marks, :destination_read, 0),
         true <- after_mark?(marks, :independent_sale, read_at),
         true <- arm == :before_buy or after_mark?(marks, :fenced_sale, s3.deteriorated_at) do
      after_mark?(marks, :dependent_purchase, read_at) or refused_dependent_buys(fleet, s3) != []
    else
      _ -> false
    end
  end

  defp after_mark?(marks, kind, at),
    do:
      Enum.any?(marks, fn {mark, time} -> mark == kind and DateTime.compare(time, at) == :gt end)

  defp changed_evidence(fleet, s3) do
    subject = "market:X1-UX81:#{s3.destination}"

    Repo.one(
      from o in SpaceTraders.Evidence.Observation,
        where:
          o.agent_id == ^fleet.agent.id and o.subject == ^subject and
            o.observed_at >= ^s3.deteriorated_at,
        order_by: [asc: o.observed_at],
        limit: 1
    )
    |> case do
      nil ->
        nil

      observation ->
        good = Enum.find(observation.facts["trade_goods"], &(&1["symbol"] == s3.good))

        observation
        |> Map.take(~w(id subject operation_id observed_at response_fingerprint)a)
        |> Map.put(:sell_price, good["sell_price"])
    end
  end

  defp independent_sales(fleet, s3, observed_at) do
    fleet.generation.id
    |> SpaceTraders.Outcomes.Earnings.list()
    |> Enum.filter(
      &(&1.fleet_commitment_id == s3.independent.id and
          DateTime.compare(&1.finished_at, observed_at) == :gt)
    )
  end

  defp refused_dependent_buys(fleet, s3) do
    ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: fleet.agent.id, symbol: "PROOF824-3")

    Repo.all(
      from i in SpaceTraders.Fleet.Intent,
        where: i.ship_id == ^ship.id and i.type == "buy" and i.status == "infeasible",
        order_by: [asc: i.id]
    )
    |> Enum.map(fn intent ->
      %{
        intent_id: intent.id,
        commitment_id: intent.fleet_commitment_id,
        trade_symbol: intent.parameters["trade_symbol"],
        reason: get_in(intent.last_action_result, ["evidence", "reason"]),
        planned_destination_evidence:
          Enum.find_value(
            get_in(intent.parameters, ["market_trade", "dependencies"]) || [],
            &if(&1["subject"] == "market:X1-UX81:#{s3.destination}", do: &1["evidence_id"])
          ),
        evidence: intent.last_action_result["evidence"]
      }
    end)
    |> Enum.filter(&(&1.trade_symbol == s3.good))
  end

  # -- Receipt ---------------------------------------------------------------

  defp receipt(result, world, fleet, s3, arm) do
    changed = changed_evidence(fleet, s3)
    observed_at = changed && changed.observed_at
    requests = result.request_effects

    purchase? = fn r, ship ->
      r.method == "POST" and r.path == "/v2/my/ships/#{ship}/purchase" and
        r.body["symbol"] == s3.good
    end

    ship_ids =
      Map.new(
        Repo.all(
          from s in SpaceTraders.Fleet.Ship,
            where: s.agent_id == ^fleet.agent.id,
            select: {s.symbol, s.id}
        )
      )

    fenced_purchase =
      if arm == :after_buy,
        do:
          requests
          |> Enum.filter(
            &(purchase?.(&1, "PROOF824-3") and before?(&1.started_at, s3.deteriorated_at))
          )
          |> Enum.take(-1)
          |> Enum.map(
            &%{started_at: &1.started_at, charge: -&1.signed_cash, units: &1.body["units"]}
          ),
        else: []

    fenced_sale =
      Enum.find(
        requests,
        &(&1.method == "POST" and &1.path == "/v2/my/ships/PROOF824-3/sell" and
            &1.body["symbol"] == s3.good and not before?(&1.started_at, s3.deteriorated_at))
      )

    fenced_cycle =
      if arm == :after_buy,
        do:
          Enum.find(
            result.earnings,
            &(&1.ship_symbol == "PROOF824-3" and &1.good == s3.good and
                not before?(&1.finished_at, s3.deteriorated_at))
          )

    %{
      ticket: 841,
      scenario: "S3 thesis deterioration / independent work",
      arm: arm,
      limits: [
        "Bounded controlled world; one request per two game-seconds via the ordinary limiter.",
        "Before-buy deterioration follows the acquired Ship's own destination sale: its next goods buy is the first one any legitimate read can precede.",
        "Not acquisition qualification, cash superiority, live qualification or Gate 0."
      ],
      code_revision: result.code_revision,
      preset: result.preset,
      floor: result.floor,
      generation: result.generation,
      strategy_revision: result.strategy_revision,
      capacity: %{rate_per_second: 0.5, burst: 1, overflow_pool: 0},
      deterioration: Map.take(s3, ~w(good destination deteriorated_at)a),
      world_deteriorations: Map.get(World.snapshot(world), :deteriorations, []),
      changed_evidence: changed,
      dependent_authority: s3.dependent_claim,
      independent: s3.independent,
      independent_sales: if(observed_at, do: independent_sales(fleet, s3, observed_at), else: []),
      refused_dependent_buys: refused_dependent_buys(fleet, s3),
      dependent_purchases_after_readiness:
        for(
          r <- requests,
          purchase?.(r, "PROOF824-3"),
          do: %{
            started_at: r.started_at,
            charge: -r.signed_cash,
            at_or_before_fence: is_nil(observed_at) or before?(r.started_at, observed_at)
          }
        ),
      fenced_purchase: fenced_purchase,
      fenced_sale_receipt: fenced_sale && fenced_sale.signed_cash,
      fenced_cycle: fenced_cycle,
      intents: %{
        independent: Enum.filter(result.intents, &(&1.fleet_commitment_id == s3.independent.id)),
        dependent: Enum.filter(result.intents, &(&1.ship_id == ship_ids["PROOF824-3"]))
      },
      earnings: result.earnings,
      account: Map.drop(result.account, [:effects, :closure_tail]),
      request_effects:
        Enum.map(
          requests,
          &Map.take(&1, ~w(method path body started_at completed_at signed_cash failure)a)
        ),
      waits: Enum.frequencies_by(result.waits, & &1.kind),
      execution_stopped_at: result.execution_stopped_at,
      decisions: result.decisions
    }
  end

  defp write_receipt(receipt, preset, arm) do
    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "841-#{preset}-#{arm}.json"),
        receipt |> Runtime.receipt_json() |> Jason.encode!(pretty: true)
      )
    end

    :ok
  end

  defp before?(at, limit), do: DateTime.compare(at, limit) != :gt
end
