defmodule SpaceTraders.MarketSpendingQualificationTest do
  @moduledoc """
  #581 qualification at the spec-approved concurrent RecordedAction admission
  seam. Real commits, independent PostgreSQL backends and discarded sender/clock
  processes prove durable accounting. This does not claim Gate 1 autonomy.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import SpaceTraders.AgentFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.FleetAcquisition
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.{API, Evidence, MutationAttempts, Repo, TestClock}

  setup do
    Sandbox.mode(Repo, :auto)
    start_supervised!({TestClock, DateTime.utc_now()})
    previous = Application.fetch_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)
    operator = operator_fixture()
    agent = agent_fixture(operator)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        attempts = MutationAttempts.list_for_agent(agent) |> Enum.map(& &1.id)

        Repo.delete_all(
          from o in MutationAttempts.Outcome, where: o.mutation_attempt_id in ^attempts
        )

        Repo.delete_all(from a in MutationAttempts.Attempt, where: a.id in ^attempts)
        Repo.delete_all(from d in Evidence.ObservationDemand, where: d.agent_id == ^agent.id)
        Repo.delete_all(from o in Evidence.Observation, where: o.agent_id == ^agent.id)
        topics = ["fleet_allocation:#{operator.id}", "fleet:#{agent.id}"]

        Repo.delete_all(
          from n in SpaceTraders.Outbox.Notification,
            where:
              n.topic in ^topics or fragment("(?->>'agent_id')::bigint", n.payload) == ^agent.id
        )

        Repo.delete!(operator)
      end)

      case previous do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end

      Sandbox.mode(Repo, :manual)
    end)

    {:ok, agent: agent, operator: operator}
  end

  test "simultaneous admissions serialize on Agent before Intent and Attempt; only one fits",
       ctx do
    [one, two] = prepare(ctx, [0, 0], 1_100)
    owner = self()

    # An independent transaction holds the Agent row. Both production callers
    # must actually reach PostgreSQL contention before it is released.
    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")
          Repo.query!("SELECT id FROM agents WHERE id = $1 FOR UPDATE", [ctx.agent.id])
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:holder, backend})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holder, holder_backend}, 5_000

    callers =
      Enum.map([one, two], fn attempt ->
        Task.async(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(owner, {:caller, backend})
            RecordedAction.admit_send(attempt)
          end)
        end)
      end)

    assert_receive {:caller, first_backend}, 5_000
    assert_receive {:caller, second_backend}, 5_000
    assert length(Enum.uniq([holder_backend, first_backend, second_backend])) == 3
    await_blocked(first_backend, holder_backend)
    await_blocked(second_backend, holder_backend)

    # Neither caller acquired a later row while waiting for Agent: an observer
    # can lock every Intent and MutationAttempt without waiting.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               ids = Enum.map([one, two], & &1.provenance["intent_id"])
               Repo.all(from i in Intent, where: i.id in ^ids, lock: "FOR UPDATE NOWAIT")
               ids = Enum.map([one, two], & &1.id)

               Repo.all(
                 from a in MutationAttempts.Attempt,
                   where: a.id in ^ids,
                   lock: "FOR UPDATE NOWAIT"
               )

               :ok
             end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    results = Enum.map(callers, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, %{state: "sent_or_unknown"}}, &1)) == 1
    assert {:error, :insufficient_unreserved_headroom} in results
    [loser] = Enum.filter(MutationAttempts.list_for_agent(ctx.agent), &(&1.state == "not_sent"))
    assert loser.sent_or_unknown_at == nil
    Req.Test.stub(API, fn _ -> flunk("losing admission reached transport") end)
    assert {:error, :attempt_already_dispatched} = API.dispatch_recorded(loser)
  end

  test "Fleet Ship acquisition and recorded spending queue on the same Agent lock", ctx do
    [cargo] = prepare(ctx, [0], 1_100)

    ship =
      Repo.insert!(%MutationAttempts.Attempt{
        operator_id: ctx.operator.id,
        agent_id: ctx.agent.id,
        fleet_generation_id: cargo.fleet_generation_id,
        operation_id: "purchase-ship",
        operation_owner: "fleet_reconciliation",
        state: "prepared",
        request_fingerprint: "queue-ship-#{System.unique_integer([:positive])}",
        prepared_at: DateTime.utc_now(),
        prepared_evidence: %{"spending" => %{"worst_case_exposure" => 12_500}}
      })

    owner = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM agents WHERE id = $1 FOR UPDATE", [ctx.agent.id])
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:holder, backend})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holder, holder_backend}, 5_000

    callers =
      Enum.map([&FleetAcquisition.admit_send/1, &RecordedAction.admit_send/1], fn admit ->
        attempt = if admit == (&RecordedAction.admit_send/1), do: cargo, else: ship

        Task.async(fn ->
          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(owner, {:caller, backend})
            admit.(attempt)
          end)
        end)
      end)

    assert_receive {:caller, first_backend}, 5_000
    assert_receive {:caller, second_backend}, 5_000
    await_blocked(first_backend, holder_backend)
    await_blocked(second_backend, holder_backend)

    # Acquisition waits on Agent first: its Attempt row is not yet locked.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Repo.all(
                 from a in MutationAttempts.Attempt,
                   where: a.id in ^[ship.id, cargo.id],
                   lock: "FOR UPDATE NOWAIT"
               )

               :ok
             end)

    send(holder.pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    results = Enum.map(callers, &Task.await(&1, 5_000))
    assert {:error, :ship_offer_evidence_unavailable} in results
    assert Enum.any?(results, &match?({:ok, %{state: "sent_or_unknown"}}, &1))
  end

  test "lower priority arriving first cannot consume the higher priority Reservation", ctx do
    [low, high] = prepare(ctx, [0, 63], 1_100)
    Req.Test.stub(API, fn _ -> flunk("admission or reconstruction reached transport") end)
    assert {:error, :insufficient_unreserved_headroom} = RecordedAction.admit_send(low)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(low.id)
    assert {:ok, %{state: "sent_or_unknown"}} = RecordedAction.admit_send(high)
  end

  test "restart retains prepared quote identity and Reservation before new admission", ctx do
    [prepared, next] = prepare(ctx, [63, 0], 1_100)
    retained = prepared.prepared_evidence
    restart_runtime(1)
    Req.Test.stub(API, fn _ -> flunk("restart reacquired or restamped retained quote") end)

    assert {:error, :insufficient_unreserved_headroom} =
             fresh_sender(fn -> RecordedAction.admit_send(MutationAttempts.get!(next.id)) end)

    reloaded = MutationAttempts.get!(prepared.id)
    assert reloaded.prepared_evidence == retained
    assert reloaded.state == "prepared"

    assert {:ok, %{state: "sent_or_unknown"}} =
             fresh_sender(fn -> RecordedAction.admit_send(reloaded) end)
  end

  for state <- ["sent_or_unknown", "bounded_unknown"] do
    @exposure_state state
    test "restart reconstructs #{@exposure_state} exposure alongside prepared Reservations",
         ctx do
      [exposed, prepared, next] = prepare(ctx, [0, 63, 0], 1_150)
      assert {:ok, exposed} = RecordedAction.admit_send(exposed)
      if @exposure_state == "bounded_unknown", do: bound_unknown(ctx.agent, exposed)
      original = Map.new([exposed, prepared], &{&1.id, &1.prepared_evidence})
      restart_runtime(1)
      Req.Test.stub(API, fn _ -> flunk("restart acquired facts or dispatched spending") end)

      assert {:error, :insufficient_unreserved_headroom} =
               fresh_sender(fn -> RecordedAction.admit_send(MutationAttempts.get!(next.id)) end)

      assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(next.id)
      assert MutationAttempts.get!(exposed.id).state == @exposure_state
      assert %{state: "prepared"} = MutationAttempts.get!(prepared.id)

      Enum.each(original, fn {id, evidence} ->
        assert MutationAttempts.get!(id).prepared_evidence == evidence
      end)
    end
  end

  test "quote aging during downtime withdraws and releases work for replanning before marker",
       ctx do
    [prepared] = prepare(ctx, [63], 1_100)
    original = prepared.prepared_evidence
    restart_runtime(31)
    Req.Test.stub(API, fn _ -> flunk("expired restarted purchase reached transport") end)

    assert {:error, :market_quote_stale_or_missing} =
             fresh_sender(fn -> API.dispatch_recorded(MutationAttempts.get!(prepared.id)) end)

    assert %{state: "not_sent", sent_or_unknown_at: nil, prepared_evidence: ^original} =
             MutationAttempts.get!(prepared.id)

    assert {:error, :no_current_ship_claim} =
             FleetAllocation.current_ship_claim(ctx.agent, "QUALIFY-0")

    assert %{commitments: []} =
             FleetAllocation.current_portfolio(Scope.for_operator(ctx.operator), ctx.agent)
  end

  defp prepare(ctx, reservations, credits) do
    strategy = Repo.insert!(%Strategy{operator_id: ctx.operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: %{
          "objectives" => [
            %{"objective" => "Grow credits"},
            %{"objective" => "Keep low priority work"}
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        }
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: ctx.operator.id,
        agent_id: ctx.agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: ctx.agent.symbol,
        faction: ctx.agent.faction
      })

    candidates =
      Enum.with_index(reservations, fn credits, index ->
        symbol = "QUALIFY-#{index}"
        {:ok, _} = SpaceTraders.Fleet.record_ship(ctx.agent, symbol, "SHIP_COMMAND_FRIGATE")

        %PortfolioCandidate{
          id: "purchase-#{index}",
          strategy_revision_id: revision.id,
          objective_index: if(index == 0, do: 1, else: 0),
          claims: [symbol],
          reservations: %{credits: credits},
          pledges: [],
          dependencies: [],
          expected_value: 10,
          unwind_cost: 0
        }
      end)

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, candidates, %{
        as_of: SpaceTraders.Clock.utc_now(),
        source_version: 0,
        claims: Enum.flat_map(candidates, & &1.claims),
        reservations: %{credits: 2_000}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(ctx.operator),
        generation.id,
        selection,
        %{
          evidence_references: [],
          expectations: %{},
          calibration_version: "market-purchase-v1-25pct"
        }
      )

    Req.Test.stub(API, fn conn ->
      assert conn.method == "GET"

      data =
        if conn.request_path == "/v2/my/agent" do
          %{"symbol" => ctx.agent.symbol, "credits" => credits}
        else
          %{
            "symbol" => ctx.agent.headquarters,
            "exports" => [],
            "imports" => [],
            "exchange" => [],
            "tradeGoods" => [%{"symbol" => "IRON_ORE", "purchasePrice" => 10, "tradeVolume" => 5}]
          }
        end

      Req.Test.json(conn, %{"data" => data})
    end)

    portfolio.commitments
    |> Enum.sort_by(& &1.candidate_id)
    |> Enum.map(fn commitment ->
      [symbol] = commitment.claims
      ship = Repo.get_by!(SpaceTraders.Fleet.Ship, agent_id: ctx.agent.id, symbol: symbol)

      intent =
        Repo.insert!(%Intent{
          ship_id: ship.id,
          caller: "commitment",
          type: "buy",
          status: "active",
          target_waypoint: ctx.agent.headquarters,
          parameters: %{"units" => 5, "trade_symbol" => "IRON_ORE"},
          fleet_commitment_id: commitment.id,
          fleet_commitment_portfolio_id: portfolio.id,
          fleet_commitment_portfolio_version: portfolio.version
        })

      assert {:ok, %{attempt: attempt}} =
               RecordedAction.prepare(ctx.agent, intent, %{
                 "kind" => "buy",
                 "trade_symbol" => "IRON_ORE",
                 "units" => 5,
                 "listing_price" => 10
               })

      attempt
    end)
  end

  defp bound_unknown(agent, attempt) do
    TestClock.advance(1)

    Req.Test.stub(API, fn conn ->
      data =
        if conn.request_path == "/v2/my/agent",
          do: %{"symbol" => agent.symbol, "credits" => 1_150},
          else: SpaceTraders.ShipBody.ship_body("QUALIFY-0")

      Req.Test.json(conn, %{"data" => data})
    end)

    assert {:ok, ship} = Evidence.get_ship_binding(agent, "QUALIFY-0")
    assert {:ok, credits} = Evidence.get_agent_binding(agent)

    assert {:ok, proof} =
             Evidence.recovery_proof(attempt, :bounded_unknown, "At most 63 credits", [
               ship,
               credits
             ])

    accounting =
      Evidence.constraint_accounting("At most 63 credits", [
        %{
          constraint: "Keep at least 1,000 credits available",
          satisfied: true,
          evidence: "1,150 minus 63 leaves 1,087"
        }
      ])

    assert {:ok, _} =
             MutationAttempts.reconcile(attempt, :bounded_unknown, proof,
               constraint_accounting: accounting
             )
  end

  defp restart_runtime(seconds) do
    now = SpaceTraders.Clock.utc_now() |> DateTime.add(seconds, :second)
    stop_supervised!(TestClock)
    start_supervised!({TestClock, now})
    previous_repo = Process.whereis(Repo)
    # The spending seam is stateless: discard its senders, clock and every
    # Repo connection. Fleet boot/recovery is qualified separately at its owner.
    assert :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, Repo)
    assert {:ok, _} = Supervisor.restart_child(SpaceTraders.Supervisor, Repo)
    assert Process.whereis(Repo) != previous_repo
    Sandbox.mode(Repo, :auto)
  end

  defp fresh_sender(fun), do: Task.async(fun) |> Task.await(5_000)

  defp await_blocked(backend, blocker, remaining \\ 200)
  defp await_blocked(_backend, _blocker, 0), do: flunk("admission did not contend on Agent")

  defp await_blocked(backend, blocker, remaining) do
    # PostgreSQL may soft-block the second waiter behind the first waiter.
    if Repo.query!(
         """
         WITH RECURSIVE blockers(pid) AS (
           SELECT unnest(pg_blocking_pids($2::int))
           UNION SELECT unnest(pg_blocking_pids(pid)) FROM blockers
         ) SELECT EXISTS(SELECT 1 FROM blockers WHERE pid = $1::int)
         """,
         [blocker, backend]
       ).rows !=
         [[true]] do
      Process.sleep(10)
      await_blocked(backend, blocker, remaining - 1)
    end
  end
end
