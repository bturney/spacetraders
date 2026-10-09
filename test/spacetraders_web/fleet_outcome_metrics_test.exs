defmodule SpaceTradersWeb.FleetOutcomeMetricsTest do
  # The worker observes independently committed state, never the test's sandbox.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Ecto.Query
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.{Fleet, Repo, Quiesced}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.{Evidence, ShipReservation, MutationAttempts}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Outcomes.Fleet, as: FleetOutcomes

  @endpoint SpaceTradersWeb.Endpoint
  @projection [:spacetraders, :outcome, :fleet, :projection]
  @failure [:spacetraders, :outcome, :fleet, :projection_failed]

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_PROBE")
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(handler, [@projection, @failure], &__MODULE__.handle_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)

      Sandbox.unboxed_run(Repo, fn ->
        Quiesced.stop_ship(ship.symbol)

        attempt_ids =
          Repo.all(
            from a in MutationAttempts.Attempt, where: a.agent_id == ^agent.id, select: a.id
          )

        Repo.delete_all(
          from o in MutationAttempts.Outcome, where: o.mutation_attempt_id in ^attempt_ids
        )

        Repo.delete_all(from a in MutationAttempts.Attempt, where: a.id in ^attempt_ids)
        Repo.delete_all(from e in SpaceTraders.Timeline.Event, where: e.owner_id == ^ship.symbol)

        Repo.delete_all(
          from i in SpaceTraders.ManualIntervention,
            join: r in ShipReservation,
            on: r.id == i.ship_reservation_id,
            where: r.operator_id == ^operator.id
        )

        Repo.delete_all(
          from o in SpaceTraders.Evidence.Observation, where: o.agent_id == ^agent.id
        )

        Repo.delete_all(
          from d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id == ^agent.id
        )

        Repo.delete_all(
          from n in SpaceTraders.Outbox.Notification,
            where: n.topic in ^["fleet:#{agent.id}", "fleet_allocation:#{operator.id}"]
        )

        Repo.delete!(operator)
      end)

      :ok = Sandbox.mode(Repo, :manual)
    end)

    %{agent: agent, ship: ship, operator: operator}
  end

  test "real Navigate flow coalesces Intent states and mutation nav facts into full vectors",
       context do
    %{scope: scope, agent: agent, ship: ship} = allocation_fixture(context)
    assert {:ok, _} = ShipReservation.reserve(scope, ship.id, "Course correction")
    start_worker(coalesce_ms: 1_000)
    baseline()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = ship_path <> "/orbit"
    navigate_path = ship_path <> "/navigate"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 80},
              "nav" =>
                nav_body("IN_TRANSIT",
                  destination: "X1-UX81-A2",
                  arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
                )
            }
          })

        request ->
          flunk("Unexpected gameplay request: #{inspect(request)}")
      end
    end)

    assert {:ok, %{status: "waiting"}} =
             Intents.intervene_navigate(scope, agent, ship.symbol, "X1-UX81-A2", "Correct course")

    assert_projection(:intent_state, %{"none" => 0, "active" => 0, "waiting" => 1})

    assert_projection(:nav_status, %{
      "DOCKED" => 0,
      "IN_ORBIT" => 0,
      "IN_TRANSIT" => 1,
      "unknown" => 0
    })

    assert_metric(:intent_state, "waiting", 1)
    assert_metric(:nav_status, "IN_TRANSIT", 1)
    refute_receive {:projection, _, _, _}, 250

    Quiesced.stop_ship(ship.symbol)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", ship_path}

      Req.Test.json(conn, %{
        "data" =>
          ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
      })
    end)

    assert {:ok, _} = Evidence.get_ship(agent, ship.symbol)
    assert_projection(:nav_status, %{"IN_ORBIT" => 1, "IN_TRANSIT" => 0})
    assert_metric(:nav_status, "IN_TRANSIT", 0)
  end

  test "boot reconstructs all Fleet vectors without waiting for gameplay or polling" do
    before = System.system_time(:microsecond) / 1_000_000
    start_worker()
    assert_projection(:claim, %{"claimed" => 0, "free" => 1})
    assert_projection(:intent_state, %{"none" => 1, "active" => 0, "waiting" => 0})

    assert_projection(:nav_status, %{
      "unknown" => 1,
      "DOCKED" => 0,
      "IN_ORBIT" => 0,
      "IN_TRANSIT" => 0
    })

    assert_metric(:claim, "free", 1)
    assert_metric(:intent_state, "none", 1)
    assert_metric(:nav_status, "unknown", 1)
    observed = metric_value(~s(spacetraders_outcome_observed_at_seconds{family="fleet"}))
    assert observed >= before
    refute_receive {:projection, _, _, _}, 150
    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="fleet"})) == observed
  end

  test "Claim publication and unwind bursts replace the full vector once", context do
    allocation = allocation_fixture(context)
    start_worker(coalesce_ms: 200)
    baseline()
    recomputes = metric_value(~s(spacetraders_outcome_fleet_recomputes_total{family="claim"}))

    publish_claim(allocation)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(allocation.scope, allocation.generation.id)

    publish_claim(allocation)

    assert_projection(:claim, %{"claimed" => 1, "free" => 0})
    assert_metric(:claim, "claimed", 1)
    assert_metric(:claim, "free", 0)

    assert metric_value(~s(spacetraders_outcome_fleet_recomputes_total{family="claim"})) ==
             recomputes + 1

    refute_receive {:projection, :claim, _, _}, 250

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(allocation.scope, allocation.generation.id)

    assert_projection(:claim, %{"claimed" => 0, "free" => 1})
    assert_metric(:claim, "claimed", 0)
    assert_metric(:claim, "free", 1)
  end

  test "an independent observer publishes only after an outer transaction commits", context do
    allocation = allocation_fixture(context)
    start_worker()
    baseline()
    parent = self()

    writer =
      Task.async(fn ->
        Repo.transaction(fn ->
          publish_claim(allocation)
          send(parent, :claim_written)

          receive do
            :commit -> :ok
          after
            5_000 -> Repo.rollback(:writer_not_released)
          end
        end)
      end)

    assert_receive :claim_written
    # Hold the write beyond several coalescing windows. Timing cannot make an
    # early notification accidentally see committed data in this proof.
    refute_receive {:projection, _, _, _}, 150
    assert_metric(:claim, "claimed", 0)
    send(writer.pid, :commit)
    assert {:ok, :ok} = Task.await(writer)
    assert_projection(:claim, %{"claimed" => 1, "free" => 0})
    assert_metric(:claim, "claimed", 1)
  end

  test "boot uses retained Fleet and newer Ship reads with one aggregate query per family", %{
    agent: agent,
    ship: ship
  } do
    ships = [
      ship
      | for n <- 2..30 do
          {:ok, registered} =
            Fleet.register_ship(agent, %{symbol: "#{agent.symbol}-#{n}"}, "SHIP_PROBE")

          registered
        end
    ]

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/ships"
      Req.Test.json(conn, %{"data" => Enum.map(ships, &ship_body(&1.symbol))})
    end)

    assert {:ok, fleet} = Evidence.get_ships(agent)
    assert length(fleet) == 30

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/ships/#{ship.symbol}"
      Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})})
    end)

    assert {:ok, _} = Evidence.get_ship(agent, ship.symbol)

    # Boot and all recomputes must remain DB-only: any extra game call fails.
    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk("Projection called game: #{conn.request_path}")
    end)

    handler = {__MODULE__, :queries, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.handle_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    start_worker()

    assert_projection(:claim, %{"free" => 30, "claimed" => 0})
    assert_projection(:intent_state, %{"none" => 30})
    assert_projection(:nav_status, %{"DOCKED" => 29, "IN_ORBIT" => 1, "unknown" => 0})
    for _ <- 1..3, do: assert_receive(:projection_query)
    refute_receive :projection_query, 100
    assert_metric(:nav_status, "DOCKED", 29)

    assert {:ok, _} = Fleet.register_ship(agent, %{symbol: "#{agent.symbol}-31"}, "SHIP_PROBE")
    assert_projection(:claim, %{"free" => 31})
    assert_projection(:intent_state, %{"none" => 31})
    assert_projection(:nav_status, %{"DOCKED" => 29, "IN_ORBIT" => 1, "unknown" => 1})
    for _ <- 1..3, do: assert_receive(:projection_query)
    refute_receive :projection_query, 100
  end

  test "rolled back and nested rolled back Claims never advance the projection", context do
    allocation = allocation_fixture(context)
    start_worker()
    baseline()

    assert {:error, :discard} =
             Repo.transaction(fn ->
               assert {:error, :discard} =
                        Repo.transaction(fn ->
                          publish_claim(allocation)
                          Repo.rollback(:discard)
                        end)

               Repo.rollback(:discard)
             end)

    refute_receive {:projection, _, _, _}, 150
    assert_metric(:claim, "claimed", 0)
    publish_claim(allocation)
    assert_projection(:claim, %{"claimed" => 1, "free" => 0})
  end

  test "unrelated owned Agent observations do not refresh Fleet projections", context do
    allocation_fixture(context)
    start_worker()
    baseline()
    observed = metric_value(~s(spacetraders_outcome_observed_at_seconds{family="fleet"}))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/agent"
      Req.Test.json(conn, %{"data" => %{"symbol" => context.agent.symbol, "credits" => 123_456}})
    end)

    assert {:ok, %{credits: 123_456}} = Evidence.get_agent(context.agent)
    refute_receive {:projection, _, _, _}, 150
    assert metric_value(~s(spacetraders_outcome_observed_at_seconds{family="fleet"})) == observed
  end

  test "scrapes cannot see a partially rewritten Fleet vector", context do
    allocation = allocation_fixture(context)
    start_worker()
    baseline()
    handler = {__MODULE__, :pause, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:spacetraders, :outcome, :fleet, :ships],
        &__MODULE__.pause_vector/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    # Gameplay returns independently of the deliberately paused publisher.
    publish_claim(allocation)
    assert_receive {:vector_paused, publisher}, 2_000
    scrape = Task.async(fn -> build_conn() |> get("/metrics") |> response(200) end)
    partial = Task.yield(scrape, 100)
    send(publisher, :resume_vector)
    body = if partial, do: elem(partial, 1), else: Task.await(scrape)
    assert is_nil(partial), "scrape exposed a partially published vector"

    assert body =~
             ~s(spacetraders_outcome_ships_total{claim="free",intent_state="",nav_status=""} 0\n)

    assert_projection(:claim, %{"claimed" => 1, "free" => 0})
  end

  defmodule UnavailableDatabase do
    def query!(_query), do: raise(DBConnection.ConnectionError, "projection database unavailable")
  end

  test "projection database failure logs and drops while Claim flow remains available", context do
    allocation = allocation_fixture(context)

    log =
      capture_log(fn ->
        start_worker(repo: UnavailableDatabase)

        for family <- [:claim, :intent_state, :nav_status],
            do: assert_receive({:projection_failed, ^family})

        publish_claim(allocation)
        assert {:ok, _} = FleetAllocation.current_ship_claim(context.agent, context.ship.symbol)
        assert_receive {:projection_failed, :claim}, 2_000
        refute_receive {:projection, _, _, _}, 100
      end)

    assert log =~ "Fleet outcome projection failed; dropping recompute"
    assert Process.alive?(Process.whereis(FleetOutcomes))

    stop_supervised!(FleetOutcomes)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(allocation.scope, allocation.generation.id)

    publish_claim(allocation)
    start_worker()
    assert_projection(:claim, %{"claimed" => 1, "free" => 0})
    assert_metric(:claim, "claimed", 1)
  end

  def handle_event(@failure, _measurements, metadata, pid),
    do: send(pid, {:projection_failed, metadata.family})

  def handle_event(@projection, measurements, metadata, pid),
    do: send(pid, {:projection, metadata.family, measurements.counts, measurements.recomputes})

  def handle_query(_event, _measurements, %{result: {:ok, %{command: :select}}}, pid) do
    if self() == Process.whereis(FleetOutcomes), do: send(pid, :projection_query)
  end

  def handle_query(_event, _measurements, _metadata, _pid), do: :ok

  def pause_vector(_event, %{count: 1}, %{claim: "claimed"}, parent) do
    send(parent, {:vector_paused, self()})

    receive do
      :resume_vector -> :ok
    after
      5_000 -> raise "publisher not released"
    end
  end

  def pause_vector(_event, _measurements, _metadata, _parent), do: :ok

  defp start_worker(opts \\ []) do
    start_supervised!(
      Quiesced.child_spec({FleetOutcomes, Keyword.merge([coalesce_ms: 30], opts)})
    )
  end

  defp baseline do
    assert_projection(:claim, %{"claimed" => 0, "free" => 1})
    assert_projection(:intent_state, %{"none" => 1})
    assert_projection(:nav_status, %{"unknown" => 1})
  end

  defp allocation_fixture(%{operator: operator, agent: agent} = context) do
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        document: %{"objectives" => [%{"objective" => "Grow credits"}], "hard_constraints" => []},
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
        faction: agent.faction
      })

    Map.merge(context, %{
      scope: Scope.for_operator(operator),
      revision: revision,
      generation: generation
    })
  end

  defp publish_claim(%{ship: ship, revision: revision, generation: generation, scope: scope}) do
    candidate = %PortfolioCandidate{
      id: "fleet-outcomes",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: Repo.get!(Generation, generation.id).allocation_version,
        claims: [ship.symbol],
        reservations: %{}
      })

    assert {:ok, portfolio} =
             FleetAllocation.publish_portfolio(scope, generation.id, selection, %{
               evidence_references: [],
               expectations: %{},
               calibration_version: "fleet-outcomes"
             })

    portfolio
  end

  defp assert_projection(family, expected) do
    assert_receive {:projection, ^family, counts, 1}, 2_000
    assert Map.take(counts, Map.keys(expected)) == expected
  end

  defp assert_metric(family, state, value) do
    body = build_conn() |> get("/metrics") |> response(200)

    labels =
      Enum.map_join([:claim, :intent_state, :nav_status], ",", fn label ->
        ~s(#{label}="#{if label == family, do: state, else: ""}")
      end)

    assert body =~ "spacetraders_outcome_ships_total{#{labels}} #{value}\n"
  end

  defp metric_value(series) do
    body = build_conn() |> get("/metrics") |> response(200)
    assert [_, value] = Regex.run(~r/^#{Regex.escape(series)} ([^\n]+)$/m, body)
    {value, ""} = Float.parse(value)
    value
  end
end
