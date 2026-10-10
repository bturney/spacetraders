defmodule SpaceTraders.FleetAllocationLockOrderTest do
  @moduledoc """
  #675 lock order on independent PostgreSQL backends: a replan and a Ship's
  locked authority check both take the Generation before any Portfolio row,
  as publication does, so neither can deadlock against the other.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import SpaceTraders.AgentFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Portfolio, PortfolioCandidate}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Repo

  setup do
    Sandbox.mode(Repo, :auto)
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, _ship} = Fleet.record_ship(agent, "SHIP-1", "SHIP_COMMAND_FRIGATE")
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => [%{"objective" => "Grow credits"}]},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    scope = Scope.for_operator(operator)
    selection = selection(revision)

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(scope, generation.id, selection, decision())

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(
          from n in SpaceTraders.Outbox.Notification,
            where: n.topic == ^"fleet_allocation:#{operator.id}"
        )

        Repo.delete!(operator)
      end)

      Sandbox.mode(Repo, :manual)
    end)

    {:ok,
     agent: agent,
     scope: scope,
     generation: generation,
     selection: selection,
     portfolio: portfolio}
  end

  test "a locked Ship authority check waits on the Generation before any Portfolio", ctx do
    assert_generation_first(ctx, fn ->
      FleetAllocation.current_ship_claim(ctx.agent, "SHIP-1", lock: true)
    end)
  end

  test "a replan waits on the Generation before any Portfolio", ctx do
    assert_generation_first(ctx, fn ->
      FleetAllocation.replan_subgraph(
        ctx.scope,
        ctx.generation.id,
        %{ctx.selection | source_version: 1},
        ["candidate-1"],
        decision()
      )
    end)
  end

  defp assert_generation_first(ctx, call) do
    owner = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")

          Repo.query!("SELECT id FROM fleet_generations WHERE id = $1 FOR UPDATE", [
            ctx.generation.id
          ])

          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:holder, backend})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:holder, holder_backend}, 5_000

    caller =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL lock_timeout = '5s'")
          [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(owner, {:caller, backend})
          call.()
        end)
      end)

    assert_receive {:caller, caller_backend}, 5_000
    await_blocked(caller_backend, holder_backend)

    # While it waits on the Generation the caller holds no Portfolio row.
    assert {:ok, [_]} =
             Repo.transaction(fn ->
               Repo.all(
                 from p in Portfolio, where: p.id == ^ctx.portfolio.id, lock: "FOR UPDATE NOWAIT"
               )
             end)

    send(holder.pid, :release)
    assert {:ok, _} = Task.await(holder, 10_000)
    assert {:ok, _} = Task.await(caller, 10_000)
  end

  defp await_blocked(backend, blocker, remaining \\ 200)
  defp await_blocked(_backend, _blocker, 0), do: flunk("caller did not wait on the Generation")

  defp await_blocked(backend, blocker, remaining) do
    if Repo.query!("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [blocker, backend]).rows !=
         [[true]] do
      Process.sleep(10)
      await_blocked(backend, blocker, remaining - 1)
    end
  end

  defp selection(revision) do
    candidate = %PortfolioCandidate{
      id: "candidate-1",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["SHIP-1"],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 100,
      unwind_cost: 10
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: ["SHIP-1"],
        reservations: %{}
      })

    selection
  end

  defp decision do
    %{evidence_references: [], expectations: %{}, calibration_version: "lock-order-v1"}
  end
end
