defmodule SpaceTraders.ScenarioSeeds do
  @moduledoc """
  Synthetic scenario seeds (#768): one call puts one of five situations into a
  database, at 2 Ships or 120. Both the LiveView tests and the Operator
  acceptance check load it, so they see the same Fleet.

  Situations and the Ship status they produce on the affected Ships (every
  fourth Ship, starting with the first; the rest trade, and every tenth Ship of
  a 120-Ship Fleet refreshes Markets):

    * `:healthy` - nothing affected; all Ships earn steadily.
    * `:busy_not_earning` - Net Earnings of the last hour far below the
      6 h average (Busy not earning).
    * `:waiting` - unassigned during a Neutral Wait (Waiting on purpose).
    * `:stuck` - a blocked step with a plain reason, retries and next attempt.
    * `:old_information` - stored state long past its next known event, so the
      row is marked as old (status stays Trading).

  Values are shaped like Generation 5 (Ship types, speeds, waypoints, earnings
  per trade); nothing is copied from the snapshot. Seeding replaces the
  previous seed.

  Run it with `mix spacetraders.seed <situation> --ships 2|120`; the seeded
  Operator logs in with `credentials/0`.
  """

  import Ecto.Query

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Fleet.{Intent, IntentBlocker, Ship, ShipCargo}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{AllocationResultPointer, PortfolioCandidate}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.FleetGeneration.{Generation, Identity}
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MissionControl.ShipStatus
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.Repo

  @situations [:healthy, :busy_not_earning, :waiting, :stuck, :old_information]
  @sizes [2, 120]
  @email "seed@scenario.test"
  @password "scenario seed 12345"
  @agent_symbol "SEEDED"
  @headquarters "X1-UX81-A1"
  @waypoints ~w(X1-UX81-A1 X1-UX81-B6 X1-UX81-C37 X1-UX81-D42 X1-UX81-E48 X1-UX81-F50)
  @goods ~w(IRON_ORE COPPER_ORE FUEL MACHINERY ELECTRONICS)

  @doc "The five situations."
  def situations, do: @situations

  @doc "The Fleet sizes the seeds support."
  def sizes, do: @sizes

  @doc "Login of the seeded Operator."
  def credentials, do: %{email: @email, password: @password}

  @doc """
  Seeds `situation` at `ships` Ships (2 or 120), replacing any earlier seed.

  Returns `%{agent, generation, ships, affected, now}`: `affected` are the Ship
  symbols carrying the situation and `now` is the reference time to read
  statuses at.
  """
  def seed(situation, ships) when situation in @situations and ships in @sizes do
    clear!()
    now = DateTime.utc_now()

    {:ok, result} =
      Repo.transaction(fn -> build(situation, ships, now) end, timeout: :timer.minutes(2))

    result
  end

  @doc "Statuses of the seeded Ships as the Ships list reads them: `%{symbol => status}`."
  def statuses(%{agent: agent, now: now}) do
    ships = SpaceTraders.Fleet.current_ships(agent.id)
    statuses = ShipStatus.for_ships(agent, ships, now)
    Map.new(ships, &{&1.symbol, statuses[&1.id]})
  end

  @doc "Removes the seeded Operator and everything it owns."
  def clear! do
    case Repo.get_by(Operator, email: @email) do
      nil ->
        :ok

      %Operator{id: id} ->
        {:ok, _} =
          Repo.transaction(fn ->
            Repo.query!(
              "UPDATE current_fleet_identity SET operator_id = NULL, fleet_generation_id = NULL WHERE operator_id = $1",
              [id]
            )

            for table <- ~w(fleet_generations fleet_strategies agents mutation_attempts) do
              delete_cascading(table, "operator_id = #{id}", [table])
            end

            delete_cascading("operators", "id = #{id}", ["operators"])
          end)

        :ok
    end
  end

  # Deletes the rows of `table` matching `where`, children first, following
  # the foreign keys found in the catalog (no table list to rot).
  defp delete_cascading(table, where, path) do
    %{rows: references} =
      Repo.query!(
        """
        SELECT c.conrelid::regclass::text,
               (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord)
                  FROM unnest(c.conkey) WITH ORDINALITY k(attnum, ord)
                  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum),
               (SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord)
                  FROM unnest(c.confkey) WITH ORDINALITY k(attnum, ord)
                  JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum)
          FROM pg_constraint c
         WHERE c.contype = 'f' AND c.confrelid = $1::text::regclass
        """,
        [table]
      )

    for [child, child_columns, parent_columns] <- references, child not in path do
      delete_cascading(
        child,
        "(#{child_columns}) IN (SELECT #{parent_columns} FROM #{table} WHERE #{where})",
        [child | path]
      )
    end

    Repo.query!("DELETE FROM #{table} WHERE #{where}")
  end

  ## Build

  defp build(situation, count, now) do
    {operator, agent, revision, generation} = identity()

    symbols = for n <- 1..count, do: "SEEDED-#{n}"

    plan =
      Map.new(Enum.with_index(symbols), fn {symbol, index} -> {symbol, role(situation, index)} end)

    affected = for {symbol, role} <- plan, role == situation, do: symbol

    ships = insert_ships(agent, plan, now)
    portfolio = publish(operator, revision, generation, plan)
    insert_intents(ships, portfolio, plan, now)
    insert_earnings(generation, ships, plan, now)
    if situation == :waiting, do: neutral_wait(generation, revision, now)

    %{
      agent: agent,
      generation: generation,
      ships: symbols,
      affected: Enum.sort(affected),
      now: now
    }
  end

  defp role(situation, index) do
    cond do
      situation != :healthy and rem(index, 4) == 0 -> situation
      rem(index, 10) == 9 -> :scouting
      true -> :trading
    end
  end

  defp identity do
    {:ok, operator} = Agent.register_operator(%{email: @email, password: @password})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: @agent_symbol,
        faction: "COSMIC",
        headquarters: @headquarters,
        agent_token: "scenario-seed-token",
        operator_id: operator.id
      })

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))
    number = (Repo.one(from g in Generation, select: max(g.number)) || 0) + 1

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        number: number,
        symbol: agent.symbol,
        faction: agent.faction,
        fleet_strategy_revision_id: revision.id,
        initial_fleet_strategy_revision_id: revision.id,
        replacement_symbols: %{"symbols" => [agent.symbol]}
      })

    Identity.publish_generation!(operator.id, generation.id)
    {operator, agent, revision, generation}
  end

  defp insert_ships(agent, plan, now) do
    # Old enough for the 6 h Busy-not-earning average (one hour is the floor).
    inserted = now |> DateTime.add(-7 * 3600) |> DateTime.truncate(:second)

    Map.new(plan, fn {symbol, role} ->
      index = ship_index(symbol)

      ship =
        Repo.insert!(
          struct!(
            Ship,
            Map.merge(
              %{
                agent_id: agent.id,
                symbol: symbol,
                ship_type: ship_type(index),
                engine_speed: 30,
                engine_condition: 1.0,
                fuel_capacity: 400,
                cargo_capacity: 60,
                fuel_current: 400 - rem(index * 37, 300),
                inserted_at: inserted,
                updated_at: inserted
              },
              position(role, index, now)
            )
          )
        )

      if ship.nav_status == "IN_TRANSIT" and role == :trading do
        Repo.insert!(%ShipCargo{ship_id: ship.id, trade_symbol: good(index), units: 40})
      end

      {symbol, ship}
    end)
  end

  defp ship_type(index), do: if(rem(index, 10) == 9, do: "SHIP_PROBE", else: "SHIP_LIGHT_HAULER")
  defp ship_index("SEEDED-" <> n), do: String.to_integer(n) - 1
  defp good(index), do: Enum.at(@goods, rem(index, length(@goods)))
  defp waypoint(index), do: Enum.at(@waypoints, rem(index, length(@waypoints)))

  # Stationary Ships were observed seconds ago; Ships in transit arrive soon.
  # Old information was observed long ago, with an arrival long past.
  defp position(:old_information, index, now),
    do: transit(index, now, -35 * 60, -20 * 60, -30 * 60)

  defp position(_role, index, now) do
    if rem(index, 2) == 1 do
      transit(index, now, -5 * 60, 4 * 60, -30)
    else
      at = waypoint(index)

      %{
        nav_status: "DOCKED",
        waypoint_symbol: at,
        route_origin: at,
        route_destination: at,
        route_departed_at: now |> DateTime.add(-20 * 60) |> DateTime.truncate(:second),
        route_arrives_at: now |> DateTime.add(-19 * 60) |> DateTime.truncate(:second),
        state_observed_at: DateTime.add(now, -30)
      }
    end
  end

  defp transit(index, now, departed, arrives, observed) do
    to = waypoint(index + 1)

    %{
      nav_status: "IN_TRANSIT",
      waypoint_symbol: to,
      route_origin: waypoint(index),
      route_destination: to,
      route_departed_at: now |> DateTime.add(departed) |> DateTime.truncate(:second),
      route_arrives_at: now |> DateTime.add(arrives) |> DateTime.truncate(:second),
      state_observed_at: DateTime.add(now, observed)
    }
  end

  # Waiting Ships hold no Commitment: Fleet Allocation has nothing for them.
  defp publish(operator, revision, generation, plan) do
    candidates =
      for {symbol, role} <- Enum.sort_by(plan, &ship_index(elem(&1, 0))), role != :waiting do
        %PortfolioCandidate{
          id: "seed-#{symbol}",
          strategy_revision_id: revision.id,
          objective_index: 0,
          claims: [symbol],
          reservations: %{credits: 0},
          pledges: [],
          dependencies: [],
          expected_value: 1_200 + rem(ship_index(symbol) * 97, 800),
          unwind_cost: 0
        }
      end

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, candidates, %{
        as_of: SpaceTraders.Clock.utc_now(),
        source_version: 0,
        claims: Enum.flat_map(candidates, & &1.claims),
        reservations: %{credits: 10_000}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{selected_trades: selected_trades(candidates)},
        calibration_version: "market-purchase-v1-25pct"
      })

    portfolio
  end

  # What the Market decision kept per selected trade (#763): the estimate after
  # fuel, its rate per Ship-hour and the best trades it beat, so Ship + Why has
  # a choice to explain. Rates are synthetic, shaped like Generation 5.
  defp selected_trades(candidates) do
    for candidate <- candidates do
      index = ship_index(hd(candidate.claims))
      trade = trade_summary(candidate.id, index, 1.0)

      Map.put(trade, :alternatives, [
        trade_summary("seed-alt-#{index}-1", index + 2, 0.8),
        trade_summary("seed-alt-#{index}-2", index + 3, 0.6)
      ])
    end
  end

  defp trade_summary(id, index, factor) do
    net = round((540 + rem(index * 31, 300)) * factor)
    seconds = 1_320
    rate = round(net * 3600 / seconds)

    %{
      candidate_id: id,
      trade_symbol: good(index),
      source_waypoint: waypoint(index),
      destination_waypoint: waypoint(index + 1),
      maximum_credit_change: net + 60,
      net_credits_per_ship_hour: rate,
      trade_estimate: %{net_credits: net, fuel_credits: 60, seconds: seconds}
    }
  end

  defp insert_intents(ships, portfolio, plan, now) do
    for commitment <- portfolio.commitments do
      [symbol] = commitment.claims

      # Market refresh work depends on a Market with no evidence yet.
      if plan[symbol] == :scouting do
        commitment
        |> Ecto.Changeset.change(dependencies: [%{"subject" => "market:X1-UX81-F50"}])
        |> Repo.update!()
      end

      ship = ships[symbol]
      index = ship_index(symbol)
      role = plan[symbol]

      base = %Intent{
        ship_id: ship.id,
        caller: "commitment",
        type: Enum.at(~w(buy sell navigate), rem(index, 3)),
        status: "active",
        target_waypoint: waypoint(index + 1),
        parameters: %{
          "units" => 40,
          "trade_symbol" => good(index),
          "market_trade" => %{
            "source_waypoint" => waypoint(index),
            "destination_waypoint" => waypoint(index + 1),
            "uncertainty" => %{
              "source_evidence_age_seconds" => 600 + rem(index * 29, 600),
              "destination_evidence_age_seconds" => 300
            }
          }
        },
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version
      }

      Repo.insert!(
        case role do
          :stuck ->
            %{
              base
              | status: "blocked",
                retries: 2,
                next_attempt_at: now |> DateTime.add(240) |> DateTime.truncate(:second),
                blocker: %IntentBlocker{
                  reason: "insufficient_unreserved_headroom",
                  summary: "Not enough credits above the floor."
                }
            }

          :scouting ->
            %{base | type: "acquire_intelligence"}

          _ ->
            base
        end
      )
    end
  end

  defp insert_earnings(generation, ships, plan, now) do
    rows =
      for {symbol, ship} <- ships,
          {net, minutes_ago} <- records(plan[symbol], ship_index(symbol)) do
        index = ship_index(symbol)
        finished = DateTime.add(now, -minutes_ago * 60)

        %{
          source: "trade",
          fleet_generation_id: generation.id,
          ship_symbol: symbol,
          ship_type: ship.ship_type,
          good: good(index),
          source_waypoint: waypoint(index),
          destination_waypoint: waypoint(index + 1),
          units: 40,
          jettisoned_units: 0,
          revenue: max(net, 0) + 2_000,
          goods_cost: 2_000 + max(-net, 0),
          fuel_cost: 0,
          other_cost: 0,
          net_earnings: net,
          expected_value: 1_000,
          expected_net_per_ship_hour: 2_000.0,
          price_age_seconds: 600 + rem(index * 29, 600),
          alternatives: [],
          ship_seconds: 1_800,
          started_at: DateTime.add(finished, -1_800),
          finished_at: finished,
          inserted_at: finished
        }
      end

    rows |> Enum.chunk_every(500) |> Enum.each(&Repo.insert_all(EarningsRecord, &1))
  end

  # {Net Earnings, minutes ago}. Steady trade is a round trip of about 1 000
  # every 30 minutes; a Ship that stopped earning made 5 700 three hours ago
  # and 300 in the last hour.
  defp records(:busy_not_earning, _index), do: [{5_700, 180}, {300, 30}]
  defp records(_role, index), do: for(n <- 0..11, do: {900 + rem(index * 13, 200), 20 + n * 30})

  defp neutral_wait(generation, revision, now) do
    next = %{DateTime.add(now, 600) | microsecond: {0, 6}}

    episode =
      Repo.insert!(%Episode{
        operator_id: generation.operator_id,
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 1,
        calibration_version: "market-v1",
        selection_kind: :neutral_wait,
        binding_limitation_kind: :below_economic_threshold,
        next_observation_at: next,
        alternatives: [
          %{
            "kind" => Episode.neutral_wait_bundle(),
            "candidates" => [
              wait_candidate("IRON_ORE", "X1-UX81-B6", "X1-UX81-C37", 41),
              wait_candidate("COPPER_ORE", "X1-UX81-D42", "X1-UX81-E48", 55)
            ]
          }
        ],
        expectations: %{"binding_limitation" => %{"reason" => "below_economic_threshold"}}
      })

    Repo.update_all(
      from(p in AllocationResultPointer, where: p.fleet_generation_id == ^generation.id),
      set: [selection_kind: :neutral_wait, strategy_decision_episode_id: episode.id]
    )
  end

  # A trade the Neutral Wait found below the economic threshold.
  defp wait_candidate(good, source, destination, net) do
    %{
      "kind" => "market_trade",
      "trade_symbol" => good,
      "source_waypoint" => source,
      "destination_waypoint" => destination,
      "expected_outcomes" => %{
        "maximum_credit_change" => net + 60,
        "net_credits_per_ship_hour" => round(net * 3600 / 1_320),
        "trade_estimate" => %{"net_credits" => net, "fuel_credits" => 60, "seconds" => 1_320}
      }
    }
  end
end
