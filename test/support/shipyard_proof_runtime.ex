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
        starting_credits: 400_000,
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
          "#834: finite markets, offer stock, disjoint uncertain-debit event and matched controls; this slice accounts only two ordinary trades, not acquisition funding"
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

  def run(fun), do: run_trace(fun).result

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

  def settle_ships do
    for symbol <- ~w(PROOF824-1 PROOF824-2),
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
