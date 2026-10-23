defmodule SpaceTraders.ShipyardProofRuntime do
  @moduledoc """
  #821's synchronous application-seam driver. Runs normal Allocation and Ship
  execution; time advances only to registered clock events. No planner doubles.
  """
  alias SpaceTraders.{Clock, FleetStrategy, Intelligence, Repo, TestClock}
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetAllocation.MarketDomain
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.ShipyardProofWorld, as: World
  require Ecto.Query

  @t0 ~U[2026-10-22 00:00:00Z]
  @system "X1-UX81"

  def fresh_generation(world, preset_id) do
    operator = SpaceTraders.AgentFixtures.operator_fixture()

    agent =
      SpaceTraders.AgentFixtures.agent_fixture(operator, %{
        symbol: "PROOF824",
        headquarters: "X1-UX81-A1",
        faction: "COSMIC"
      })

    preset = Enum.find(FleetStrategy.presets(), &(&1.id == preset_id))
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    document =
      Map.new(~w(objectives hard_constraints preferences)a, &{Atom.to_string(&1), preset[&1]})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: document,
        source: "preset:#{preset_id}",
        activated_at: @t0
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        fleet_strategy_revision_id: revision.id,
        starting_credits: World.snapshot(world).initial_credits,
        inserted_at: @t0
      })

    for {symbol, _ship} <- World.snapshot(world).ships do
      {:ok, _} =
        SpaceTraders.Fleet.record_ship(
          agent,
          symbol,
          if(symbol == "PROOF824-1", do: "SHIP_LIGHT_HAULER", else: "SHIP_PROBE")
        )

      {:ok, _} = SpaceTraders.Fleet.ShipServer.ensure_started(agent, symbol)
    end

    for symbol <- ~w(X1-UX81-A1 X1-UX81-A2 X1-UX81-A3) do
      # The frozen contract permits these starting Listings, not an API read
      # or free opening tour. Every later Listing must come through transport.
      waypoint = SpaceTraders.API.Model.Waypoint.from_json(World.waypoint(symbol))

      {:ok, _} =
        Intelligence.observe_waypoint(agent, waypoint,
          source: "controlled_start",
          observed_at: @t0
        )

      market = World.market(world, symbol)
      goods = SpaceTraders.API.Model.Market.from_json(market).trade_goods
      facts = %{"symbol" => symbol, "trade_goods" => Enum.map(goods, &Map.from_struct/1)}
      subject = "market:#{@system}:#{symbol}"

      source =
        Repo.insert!(%SpaceTraders.Evidence.Observation{
          id: "00000000-0000-4000-8000-00000000000#{String.last(symbol)}",
          agent_id: agent.id,
          fleet_generation_id: generation.id,
          subject: subject,
          operation_id: "get-market",
          dependency_keys: [subject],
          facts: facts,
          response_fingerprint: SpaceTraders.Evidence.fingerprint(facts),
          observed_at: DateTime.add(@t0, 0, :microsecond)
        })

      {:ok, _} =
        Intelligence.observe_market(
          agent,
          @system,
          SpaceTraders.API.Model.Market.from_json(market),
          source: "controlled_start",
          observing_ship_symbol: "PROOF824-1",
          observed_at: @t0,
          evidence: source
        )
    end

    %{
      agent: agent,
      scope: Scope.for_operator(operator),
      revision: revision,
      generation: generation
    }
  end

  def reconcile(fleet) do
    MarketDomain.reconcile(
      fleet.scope,
      fleet.agent,
      fleet.revision,
      @system,
      SpaceTraders.FleetCapacity.disposition("get-market")
    )
  end

  @doc "Matched finite control through the existing reconciliation entries, never a policy double."
  def finite_control(world, fleet, preset, cutoff \\ DateTime.add(@t0, 48, :hour), opts \\ []) do
    Process.put(:proof_captured_waits, [])

    try do
      do_finite_control(world, fleet, preset, cutoff, opts)
    after
      Process.delete(:proof_captured_waits)
    end
  end

  defp do_finite_control(world, fleet, preset, cutoff, opts) do
    fixture_sources = fixture_sources()
    host_started_at = DateTime.utc_now()

    for topic <- ~w(fleet_market_evidence fleet_intelligence_evidence observation_demands),
        do: Phoenix.PubSub.subscribe(SpaceTraders.PubSub, topic)

    Clock.send_at(self(), :proof_cutoff, cutoff)
    Clock.send_at(self(), :proof_world_tick, DateTime.add(@t0, 1800))
    first = run(fn -> control_boundary(fleet, opts) end)

    progress =
      control_events(world, fleet, cutoff, opts, [
        %{at: Clock.utc_now(), result: boundary_summary(first)}
      ])

    prefix? =
      Keyword.get(opts, :stop_at_readiness, false) or
        Keyword.get(opts, :stop_at_unsettled_purchase, false) or
        Keyword.has_key?(opts, :stop_after_cycles)

    as_of = if prefix?, do: Clock.utc_now(), else: cutoff
    state = World.snapshot(world)
    {:ok, floor} = SpaceTraders.FleetExecution.credit_floor(fleet.revision)
    {code, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    decisions =
      Repo.all(
        Ecto.Query.from(e in SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
          where: e.fleet_generation_id == ^fleet.generation.id,
          order_by: [asc: e.id]
        )
      )

    portfolio = SpaceTraders.FleetAllocation.current_portfolio(fleet.scope, fleet.agent)

    %{
      ticket: 834,
      classification: "blocked",
      run_kind:
        cond do
          Keyword.get(opts, :stop_at_unsettled_purchase) -> "unsettled_purchase_prefix"
          Keyword.has_key?(opts, :stop_after_cycles) -> "productive_cycles_prefix"
          Keyword.get(opts, :stop_at_readiness) -> "acquisition_readiness_prefix"
          cutoff == DateTime.add(@t0, 48, :hour) -> "matched_control_48h"
          true -> "prefix_only"
        end,
      limits: [
        "Positive manifest follows approved #821 payment amendment; real-owner payment safety is a separate variation.",
        "Current unmet work/Shipyard observation may recur; co-location and independent fuel-price hand-off remain #836 obligations.",
        "Controlled finite world only; not acquisition qualification, cash superiority, or Gate 0."
      ],
      code_revision: String.trim(code),
      baseline: "accae0cced7a6d3e866724b0117ddaaaf66d6afc",
      manifest: manifest(),
      fixture_sources: fixture_sources,
      fixture_revision:
        System.get_env("SHIPYARD_PROOF_FIXTURE_REVISION", "uncommitted; use source hashes"),
      test_support_overlay: System.get_env("SHIPYARD_PROOF_OVERLAY", "native V support"),
      repo_pool: inspect(Repo.config()[:pool]),
      preset: preset,
      floor: floor,
      agent: fleet.agent.symbol,
      generation: fleet.generation.id,
      strategy_revision: fleet.revision.id,
      t0: @t0,
      reset_at: state.reset_at,
      as_of: as_of,
      execution_stopped_at: Clock.utc_now(),
      host_started_at: host_started_at,
      host_finished_at: DateTime.utc_now(),
      account: World.account(world, as_of),
      stock_at_stop: state.routes,
      request_effects: state.requests,
      waits: Process.get(:proof_captured_waits) |> Enum.reverse(),
      capacity_at_stop:
        SpaceTraders.API.CapacityGovernor.diagnostics()
        |> Map.take(
          ~w(observed_at in_flight deferred retry_after_until outage protocol_rejections scoped_failures)a
        ),
      progress: progress,
      decisions:
        Enum.map(
          decisions,
          &Map.take(
            &1,
            ~w(id selection_kind alternatives evidence_references expectations actual_outcomes classification inserted_at)a
          )
        ),
      current_commitments:
        if(portfolio,
          do:
            Enum.map(
              portfolio.commitments,
              &Map.take(
                &1,
                ~w(id candidate_id claims reservations dependencies expected_value unwind_state)a
              )
            ),
          else: []
        ),
      unmet_work_at_stop: SpaceTraders.FleetAllocation.ship_bound_unmet_work(fleet.agent),
      open_demands:
        Enum.map(
          SpaceTraders.Evidence.list_open_demands(fleet.agent),
          &Map.take(
            &1,
            ~w(id subject required_facts freshness_seconds due_at deadline_at deadline_missed_at owner withdrawn_at agent_id strategy_revision_id fulfilled_observation_id replaces_id)a
          )
        ),
      observations:
        Repo.all(
          Ecto.Query.from(o in SpaceTraders.Evidence.Observation,
            where: o.agent_id == ^fleet.agent.id,
            order_by: [asc: o.observed_at]
          )
        )
        |> Enum.map(
          &Map.take(
            &1,
            ~w(id subject operation_id dependency_keys facts response_fingerprint observed_at fleet_generation_id agent_id)a
          )
        ),
      all_demands:
        Repo.all(
          Ecto.Query.from(d in SpaceTraders.Evidence.ObservationDemand,
            where: d.agent_id == ^fleet.agent.id,
            order_by: [asc: d.inserted_at]
          )
        )
        |> Enum.map(
          &Map.take(
            &1,
            ~w(id subject required_facts freshness_seconds due_at deadline_at deadline_missed_at owner withdrawn_at agent_id strategy_revision_id fulfilled_observation_id replaces_id)a
          )
        ),
      all_commitments:
        Repo.all(
          Ecto.Query.from(c in SpaceTraders.FleetAllocation.Commitment,
            join: p in SpaceTraders.FleetAllocation.Portfolio,
            on: p.id == c.fleet_commitment_portfolio_id,
            where: p.fleet_generation_id == ^fleet.generation.id,
            order_by: [asc: c.id]
          )
        )
        |> Enum.map(
          &Map.take(
            &1,
            ~w(id candidate_id fleet_commitment_portfolio_id claims reservations dependencies expected_value unwind_state inserted_at updated_at)a
          )
        ),
      intents:
        Enum.map(
          SpaceTraders.Fleet.Intents.current(fleet.agent) ++
            SpaceTraders.Fleet.Intents.history(fleet.agent),
          &Map.take(
            &1,
            ~w(id ship_id type status target_waypoint parameters blocker last_action_result in_flight_action mutation_attempt_id fleet_commitment_id inserted_at updated_at finished_at)a
          )
        ),
      earnings:
        Enum.map(
          SpaceTraders.Outcomes.Earnings.list(fleet.generation.id),
          &Map.take(
            &1,
            ~w(id fleet_commitment_id strategy_decision_episode_id ship_symbol good units goods_cost revenue fuel_cost other_cost net_earnings expected_value ship_seconds started_at finished_at)a
          )
        ),
      attempts:
        Enum.map(SpaceTraders.MutationAttempts.list_for_agent(fleet.agent), fn a ->
          Map.take(
            a,
            ~w(id operation_id state prepared_evidence provenance prepared_at sent_or_unknown_at inserted_at updated_at)a
          )
          |> Map.put(
            :outcomes,
            Enum.map(a.outcomes, &Map.take(&1, ~w(classification recorded_at evidence)a))
          )
        end)
    }
  end

  def manifest do
    %{
      version: "821-finite-control-834-approved-payment-v3",
      amendment: "https://github.com/bturney/spacetraders/issues/821#issuecomment-6355891158",
      t0: @t0,
      hours: 48,
      reset_hours: 120,
      initial_credits: 400_000,
      margin_percent: 25,
      routes: ~w(IRON COPPER),
      source_units: 1600,
      demand_units: 1600,
      transaction_maximum: 40,
      initial_buy: 1000,
      initial_sell: 1500,
      price_change_per_40: 10,
      replenish_seconds: 1800,
      replenish_units: 40,
      service_ms: 1000,
      offer_stock: 1,
      ship_price: 100_000,
      modification_fee: 2000,
      external_liability: false,
      selected_work_initial_reservation: 50_000,
      acquisition_preparation_bound: 135_000,
      first_cycle_envelope: 60_000,
      worst_preset_funding: 320_000,
      fractional_credit_quote: "blocked instead of rounding; canonical 40-unit effects exact"
    }
  end

  defp fixture_sources do
    Map.new(
      ~w(test/support/shipyard_proof_world.ex test/support/shipyard_proof_runtime.ex test/support/test_clock.ex test/diagnostics/shipyard_finite_control.exs),
      fn path ->
        {path, :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)}
      end
    )
  end

  def write_control_receipt(receipt, preset) do
    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "834-#{preset}.json"),
        receipt |> receipt_json() |> Jason.encode!(pretty: true)
      )
    end

    :ok
  end

  @doc "Separate amended payment case: real selected owner, no joint-positive liability."
  def write_payment_receipt(world, fleet, preset, unknown) do
    {:ok, floor} = SpaceTraders.FleetExecution.credit_floor(fleet.revision)
    attempts = SpaceTraders.MutationAttempts.list_for_agent(fleet.agent)
    purchase = Enum.find(attempts, &(&1.id == unknown.attempt.id))
    state = World.snapshot(world)
    {code, 0} = System.cmd("git", ["rev-parse", "HEAD"])

    receipt =
      %{
        ticket: 834,
        scenario: "separate_real_owner_payment_safety",
        classification: "bounded owner restart/protection/settlement; not all #842 S4",
        code_revision: String.trim(code),
        fixture_sources: fixture_sources(),
        fixture_revision:
          System.get_env("SHIPYARD_PROOF_FIXTURE_REVISION", "uncommitted; use source hashes"),
        manifest:
          Map.merge(manifest(), %{
            scenario: "separate_real_owner_payment_safety",
            transaction_maximum: 20
          }),
        amendment: manifest().amendment,
        preset: preset,
        floor: floor,
        agent: fleet.agent.symbol,
        generation: fleet.generation.id,
        strategy_revision: fleet.revision.id,
        variation: %{
          transaction_maximum: 20,
          unit_price: 1000,
          actual_charge: 20_000,
          calibrated_bound: 25_000
        },
        unknown: unknown,
        settled_at: Clock.utc_now(),
        settled_attempt:
          Map.take(
            purchase,
            ~w(id state prepared_evidence provenance prepared_at sent_or_unknown_at sequence)a
          ),
        outcomes:
          Enum.map(purchase.outcomes, &Map.take(&1, ~w(classification recorded_at evidence)a)),
        account: World.account(world, Clock.utc_now()),
        request_effects: state.requests,
        realisations:
          Repo.all(
            Ecto.Query.from(r in SpaceTraders.CreditCalibration.Realization,
              where: r.agent_id == ^fleet.agent.id
            )
          )
          |> Enum.map(
            &Map.take(
              &1,
              ~w(id mutation_attempt_id operation_id unit_price units worst_case_exposure realized_charge credits_after within_bound)a
            )
          ),
        deferred:
          "#842 full process/application restart, cutoff/unknown-receipt/reset and repeated exposure matrix remains separate"
      }
      |> receipt_json()

    # Encode even without persistence: a blocked owner's structured facts must
    # remain exportable, including the original IntentBlocker.
    json = Jason.encode!(receipt, pretty: true)

    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      File.mkdir_p!(directory)
      File.write!(Path.join(directory, "834-payment-safety-#{preset}.json"), json)
    end

    receipt
  end

  # Preserve structured blockers/diagnostics in B as well as V; never discard a
  # blocked Intent just because its struct does not derive Jason.Encoder.
  def receipt_json(%DateTime{} = time), do: DateTime.to_iso8601(time)
  def receipt_json(%MapSet{} = set), do: set |> Enum.to_list() |> receipt_json()
  def receipt_json(%_{} = struct), do: struct |> Map.from_struct() |> receipt_json()

  def receipt_json(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = if is_binary(key) or is_atom(key), do: key, else: inspect(key)
      {key, receipt_json(value)}
    end)
  end

  def receipt_json(list) when is_list(list), do: Enum.map(list, &receipt_json/1)
  def receipt_json(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> receipt_json()
  def receipt_json(value), do: value

  @doc "Clean only the committed diagnostic's installation, after owned runtime children stop."
  def cleanup_control_fixture(fleet) do
    symbols =
      Repo.all(
        Ecto.Query.from(s in SpaceTraders.Fleet.Ship,
          where: s.agent_id == ^fleet.agent.id,
          select: s.symbol
        )
      )

    Repo.transaction(fn ->
      Repo.query!(
        "DELETE FROM mutation_attempt_outcomes WHERE mutation_attempt_id IN (SELECT id FROM mutation_attempts WHERE operator_id = $1)",
        [fleet.scope.operator.id]
      )

      for table <- ~w(credit_realizations credit_shortfalls) do
        Repo.query!("DELETE FROM #{table} WHERE agent_id = $1", [fleet.agent.id])
      end

      Repo.query!(
        """
        DELETE FROM outbox_notifications
        WHERE payload->>'agent_id' = $1 OR payload->>'fleet_generation_id' = $2
          OR payload->>'portfolio_id' IN (
            SELECT id::text FROM fleet_commitment_portfolios WHERE fleet_generation_id = $2::bigint
          )
          OR payload->>'decision_episode_id' IN (
            SELECT id::text FROM strategy_decision_episodes WHERE fleet_generation_id = $2::bigint
          )
        """,
        [to_string(fleet.agent.id), to_string(fleet.generation.id)]
      )

      # The Episode delete trigger updates its pointer. Remove this owned
      # pointer before cascading the Generation, while its FK is still valid.
      Repo.query!("DELETE FROM allocation_result_pointers WHERE fleet_generation_id = $1", [
        fleet.generation.id
      ])

      SpaceTraders.AgentFixtures.cleanup_operator_fixture(fleet.scope.operator.id)
      Repo.query!("DELETE FROM timeline_events WHERE owner_id = ANY($1)", [symbols])
    end)
  end

  defp control_boundary(fleet, opts, event \\ :boot)

  defp control_boundary(fleet, opts, event) when is_list(opts),
    do: control_boundary(fleet, Keyword.get(opts, :boundary, :control), event)

  defp control_boundary(fleet, :application, event) do
    result =
      case event do
        :market_evidence_observed ->
          SpaceTraders.FleetAllocation.Reconciler.observe_market_evidence(fleet.agent.id, @system)

        :observation_demand_due ->
          SpaceTraders.FleetAllocation.Reconciler.wake_due_demands(fleet.agent.id)

        _ ->
          SpaceTraders.FleetAllocation.Reconciler.observe_waypoint_intelligence(
            fleet.agent.id,
            @system
          )
      end

    %{market: result, acquisition: :application_boundary}
  end

  defp control_boundary(fleet, :control, _event) do
    market = reconcile(fleet)

    acquisition =
      SpaceTraders.FleetAllocation.Acquisition.reconcile(
        fleet.scope,
        fleet.agent,
        fleet.revision,
        @system,
        nil
      )

    :ok =
      SpaceTraders.FleetIntelligence.sync_market_observation_demands(
        fleet.agent,
        fleet.revision,
        @system
      )

    %{market: market, acquisition: acquisition}
  end

  defp control_events(world, fleet, cutoff, opts, progress) do
    settle_ships()
    # The existing scheduler is the only owner of demand due/retry times.
    if pid = Process.whereis(SpaceTraders.Evidence.DemandScheduler), do: :sys.get_state(pid)

    ready? =
      Keyword.get(opts, :stop_at_readiness, false) and
        match?({:ok, _}, SpaceTraders.Fleet.owned_ship(fleet.agent, "PROOF824-3"))

    unsettled? =
      Keyword.get(opts, :stop_at_unsettled_purchase, false) and
        match?(
          {_, %{state: state}} when state in ["sent_or_unknown", "ambiguous", "bounded_unknown"],
          SpaceTraders.FleetAcquisition.open_purchase(fleet.agent)
        )

    cycled? =
      case Keyword.get(opts, :stop_after_cycles) do
        {symbol, count} ->
          SpaceTraders.Outcomes.Earnings.list(fleet.generation.id)
          |> Enum.count(&(&1.ship_symbol == symbol)) >= count

        nil ->
          false
      end

    if ready? or unsettled? or cycled? or DateTime.compare(Clock.utc_now(), cutoff) != :lt do
      Enum.reverse(progress)
    else
      receive do
        :proof_cutoff ->
          Enum.reverse(progress)

        :proof_world_tick ->
          World.snapshot(world)
          next = DateTime.add(@t0, (div(DateTime.diff(Clock.utc_now(), @t0), 1800) + 1) * 1800)

          if DateTime.compare(next, cutoff) != :gt,
            do: Clock.send_at(self(), :proof_world_tick, next)

          control_events(world, fleet, cutoff, opts, progress)

        {kind, agent_id, _subject}
        when kind in [
               :market_evidence_observed,
               :waypoint_intelligence_observed,
               :observation_demand_due
             ] and agent_id == fleet.agent.id ->
          result = run(fn -> control_boundary(fleet, opts, kind) end)
          work = SpaceTraders.FleetAllocation.ship_bound_unmet_work(fleet.agent)

          entry = %{
            at: Clock.utc_now(),
            event: kind,
            result: boundary_summary(result),
            unmet_work: work
          }

          if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
            File.mkdir_p!(directory)

            File.write!(
              Path.join(directory, "834-progress.jsonl"),
              Jason.encode!(%{
                at: entry.at,
                event: kind,
                requests: length(World.snapshot(world).requests),
                unmet_work: length(work)
              }) <> "\n",
              [:append]
            )
          end

          control_events(world, fleet, cutoff, opts, [entry | progress])

        {:observation_demands_changed, _} ->
          control_events(world, fleet, cutoff, opts, progress)
      after
        0 ->
          next_event()
          control_events(world, fleet, cutoff, opts, progress)
      end
    end
  end

  defp boundary_summary(%{market: market, acquisition: acquisition}) do
    market =
      case market do
        {:ok, result} -> Map.take(result, [:action, :reason])
        other -> inspect(other)
      end

    %{market: market, acquisition: inspect(acquisition, limit: 10)}
  end

  @doc "Optionally retain the complete effect trace outside the test database."
  def write_receipt(world, fleet, preset_id) do
    if directory = System.get_env("SHIPYARD_PROOF_RECEIPTS") do
      state = World.snapshot(world)
      {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      records = SpaceTraders.Outcomes.Earnings.list(fleet.generation.id)
      attempts = SpaceTraders.MutationAttempts.list_for_agent(fleet.agent)
      {:ok, floor} = SpaceTraders.FleetExecution.credit_floor(fleet.revision)

      receipt = %{
        ticket: 833,
        classification: "bounded ordinary-trader proof, not acquisition or Gate 0",
        code_revision: String.trim(revision),
        baseline: "accae0cced7a6d3e866724b0117ddaaaf66d6afc",
        preset: preset_id,
        floor: floor,
        agent: fleet.agent.symbol,
        generation: fleet.generation.id,
        strategy_revision: fleet.revision.id,
        t0: @t0,
        reset_at: state.reset_at,
        as_of: Clock.utc_now(),
        starting_credits: 400_000,
        credits: state.credits,
        low_credits: state.low_credits,
        elapsed_seconds: DateTime.diff(Clock.utc_now(), @t0),
        request_count: length(state.requests),
        request_effects: state.requests,
        ships: state.ships,
        decisions:
          Enum.map(records, fn record ->
            commitment =
              Repo.get!(SpaceTraders.FleetAllocation.Commitment, record.fleet_commitment_id)

            episode = SpaceTraders.FleetAllocation.commitment_decision_episode(commitment)

            %{
              commitment:
                Map.take(
                  commitment,
                  ~w(id candidate_id claims reservations dependencies expected_value)a
                ),
              episode:
                Map.take(
                  episode,
                  ~w(id alternatives evidence_references expectations actual_outcomes classification)a
                )
            }
          end),
        earnings:
          Enum.map(
            records,
            &Map.take(
              &1,
              ~w(id fleet_commitment_id strategy_decision_episode_id ship_symbol good units goods_cost revenue fuel_cost other_cost net_earnings expected_value ship_seconds started_at finished_at)a
            )
          ),
        attempts:
          Enum.map(attempts, fn attempt ->
            attempt
            |> Map.take(
              ~w(id operation_id state prepared_evidence provenance prepared_at sent_or_unknown_at)a
            )
            |> Map.put(
              :outcomes,
              Enum.map(
                attempt.outcomes,
                &Map.take(&1, [:classification, :recorded_at, :evidence])
              )
            )
          end),
        deferred_scope:
          "#834 owns amended finite controls and a separately labeled real-owner payment safety variation; these two ordinary trips do not prove acquisition funding"
      }

      File.mkdir_p!(directory)

      File.write!(
        Path.join(directory, "833-#{preset_id}.json"),
        Jason.encode!(receipt, pretty: true)
      )
    end

    :ok
  end

  # A real scheduled wait, used for transport service and the raw limiter's
  # existing injectable clock. The controller never invents a wakeup.
  def wait(controller, kind, milliseconds) do
    ref = make_ref()
    started_at = Clock.utc_now()
    due_at = DateTime.add(started_at, milliseconds, :millisecond)
    Clock.send_at(self(), ref, due_at)
    send(controller, {:proof_wait, %{kind: kind, started_at: started_at, due_at: due_at}})

    receive do
      ^ref -> :ok
    after
      5000 -> raise "proof controller did not release #{kind} wait at #{due_at}"
    end
  end

  def run(fun) do
    trace = run_trace(fun)

    if captured = Process.get(:proof_captured_waits) do
      Process.put(:proof_captured_waits, Enum.reverse(trace.waits, captured))
    end

    trace.result
  end

  def run_trace(fun) do
    task = Task.async(fun)
    await(task, [])
  end

  defp await(%Task{ref: ref, pid: pid} = task, waits) do
    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        %{result: result, waits: Enum.reverse(waits)}

      {:proof_wait, wait} ->
        advance_to(wait.due_at)
        await(task, [wait | waits])

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "proof application boundary failed: #{inspect(reason)}"
    after
      5000 -> raise "proof application boundary stalled without a scheduled wait"
    end
  end

  defp advance_to(due_at) do
    if DateTime.compare(Clock.utc_now(), due_at) == :lt do
      next_event()
      advance_to(due_at)
    end
  end

  def next_event do
    case TestClock.next_due_at() do
      %DateTime{} = due_at ->
        TestClock.advance(DateTime.diff(due_at, Clock.utc_now(), :microsecond), :microsecond)

      nil ->
        raise "proof has no scheduled event"
    end
  end

  @doc "Processes actual scheduled events until this Ship's pending arrival settles."
  def next_arrival(symbol) do
    settle_ships()

    case Enum.filter(
           SpaceTraders.Timeline.pending_events(:ship, symbol),
           &(&1.event_type == "arrival")
         ) do
      [arrival] -> await_arrival(arrival)
      events -> raise "expected one pending arrival for #{symbol}, got #{inspect(events)}"
    end
  end

  defp await_arrival(arrival) do
    if SpaceTraders.Timeline.pending?(arrival) do
      case TestClock.next_due_at() do
        %DateTime{} = due_at ->
          if DateTime.compare(due_at, DateTime.add(@t0, 48, :hour)) == :gt,
            do: raise("proof arrival did not settle within its 48-hour window")

          next_event()
          settle_ships()
          await_arrival(arrival)

        nil ->
          raise "proof arrival is pending without a scheduled event"
      end
    else
      :ok
    end
  end

  def settle_ships do
    for symbol <- ~w(PROOF824-1 PROOF824-2 PROOF824-3),
        {pid, _} <- Registry.lookup(SpaceTraders.Fleet.ShipRegistry, symbol) do
      run(fn ->
        # The first barrier waits for the arrival callback. That callback can
        # cast its next arrival arm to itself behind an already queued system
        # request; the second barrier observes that self-cast too.
        :sys.get_state(pid)
        :sys.get_state(pid)
      end)
    end

    :ok
  end
end
