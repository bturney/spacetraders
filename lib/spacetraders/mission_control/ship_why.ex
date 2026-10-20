defmodule SpaceTraders.MissionControl.ShipWhy do
  @moduledoc """
  The Ship + Why read (#772): one Ship's status and the reason behind it,
  from stored facts only; it never calls the game.

    * a Ship with trade work carries its `choice`: the trade it took, the
      estimate after fuel, its duration and rate per Ship-hour, the price age
      it relied on and the alternatives it beat, all copied from the selection
      evidence kept on the Market decision (`selected_trades`, #763), with the
      buy step's own estimate when the decision predates it;
    * `options` lists the choice and its alternatives for the "Options it had"
      chart;
    * a Ship in a Neutral Wait carries `wait`: the best option the wait found,
      when it last checked and when it checks again;
    * `last_skipped_buy` is the Ship's most recent buy step that ended
      infeasible (#813): good, Waypoint, live price, planned maximum, time,
      and whether a later buy completed (`replanned?`: a successful replan,
      not an abandoned trade). A price refusal is the guardrail working;
    * a stuck Ship's reason, retries and next attempt are in `status`;
    * `history` is its last 10 Earnings records: expected vs actual.

  `status` is `MissionControl.ShipStatus`; `credits_per_hour` is its gauge.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{AllocationResultPointer, Commitment}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.MissionControl.{ShipRow, ShipStatus}
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.Repo

  @history 10

  @doc """
  Why the current Ship `symbol` of the Agent is doing what it does as of `now`,
  or `{:error, :not_found}`.
  """
  def for_ship(%AgentRecord{} = agent, symbol, %DateTime{} = now) when is_binary(symbol) do
    with {:ok, %{id: id}} <- Fleet.owned_ship(agent, symbol),
         [ship] <- Fleet.current_ships(agent.id, [id]) do
      {:ok, build(agent, ship, now)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp build(agent, ship, now) do
    status = ShipStatus.for_ships(agent, [ship], now) |> Map.fetch!(ship.id)
    generation = FleetAllocation.active_generation(agent)
    portfolio = generation && FleetAllocation.current_portfolio()
    choice = choice(portfolio, ship)

    %{
      ship: ship,
      row: ShipRow.build(ship, status, now),
      status: status,
      credits_per_hour: status.credits_per_hour,
      choice: choice,
      options: options(choice),
      last_skipped_buy: last_skipped_buy(ship),
      wait: if(status.kind == :waiting and is_nil(choice), do: wait(generation)),
      history: history(generation, ship.symbol)
    }
  end

  ## The last skipped buy

  defp last_skipped_buy(ship) do
    skipped =
      Repo.one(
        from i in Intent,
          where: i.ship_id == ^ship.id and i.type == "buy" and i.status == "infeasible",
          order_by: [desc: i.finished_at, desc: i.id],
          limit: 1
      )

    if skipped do
      reason = ShipStatus.skip_reason(skipped) || %{}

      %{
        good: reason[:good] || skipped.parameters["trade_symbol"],
        waypoint: skipped.target_waypoint,
        observed_price: reason[:observed_price],
        max_price: reason[:max_price],
        at: skipped.finished_at,
        replanned?:
          Repo.exists?(
            from i in Intent,
              where:
                i.ship_id == ^ship.id and i.type == "buy" and i.status == "completed" and
                  i.finished_at >= ^skipped.finished_at
          )
      }
    end
  end

  ## The trade it chose

  defp choice(nil, _ship), do: nil

  defp choice(portfolio, ship) do
    commitment =
      Enum.find(portfolio.commitments, fn commitment ->
        commitment.unwind_state == :not_required and ship.symbol in commitment.claims and
          not Commitment.coverage?(commitment)
      end)

    commitment && trade(portfolio, commitment)
  end

  defp trade(portfolio, commitment) do
    intents =
      Repo.all(
        from i in Intent, where: i.fleet_commitment_id == ^commitment.id, order_by: [asc: i.id]
      )

    intent = Enum.find(intents, &is_map(&1.parameters["market_trade"])) || List.first(intents)

    parameters = (intent && intent.parameters) || %{}
    market_trade = parameters["market_trade"] || %{}
    outcomes = market_trade["expected_outcomes"] || %{}

    selected =
      selected_trade(
        commitment.replan_decision_episode_id || portfolio.strategy_decision_episode_id,
        commitment.candidate_id
      )

    estimate = selected["trade_estimate"] || outcomes["trade_estimate"] || %{}
    good = selected["trade_symbol"] || parameters["trade_symbol"] || market_trade["trade_symbol"]

    if good do
      %{
        good: good,
        source: selected["source_waypoint"] || market_trade["source_waypoint"],
        destination: selected["destination_waypoint"] || market_trade["destination_waypoint"],
        net_credits: round_or_nil(estimate["net_credits"]),
        seconds: round_or_nil(estimate["seconds"]),
        rate:
          round_or_nil(
            selected["net_credits_per_ship_hour"] || outcomes["net_credits_per_ship_hour"]
          ),
        price_age_seconds: price_age(market_trade["uncertainty"]),
        alternatives: Enum.map(selected["alternatives"] || [], &option/1)
      }
    end
  end

  defp selected_trade(nil, _candidate_id), do: %{}

  defp selected_trade(episode_id, candidate_id) do
    case Repo.get(Episode, episode_id) do
      %{expectations: %{"selected_trades" => trades}} when is_list(trades) ->
        Enum.find(trades, %{}, &(&1["candidate_id"] == candidate_id))

      _ ->
        %{}
    end
  end

  # The oldest Listing the selection relied on.
  defp price_age(%{} = uncertainty) do
    ages =
      for key <- ~w(source_evidence_age_seconds destination_evidence_age_seconds),
          age = uncertainty[key],
          is_number(age),
          do: round(age)

    if ages != [], do: Enum.max(ages)
  end

  defp price_age(_uncertainty), do: nil

  defp option(trade) do
    estimate = trade["trade_estimate"] || %{}

    %{
      good: trade["trade_symbol"],
      source: trade["source_waypoint"],
      destination: trade["destination_waypoint"],
      net_credits: round_or_nil(estimate["net_credits"]),
      rate: round_or_nil(trade["net_credits_per_ship_hour"])
    }
  end

  defp options(nil), do: []

  defp options(choice) do
    [
      Map.put(choice, :chosen?, true)
      | Enum.map(choice.alternatives, &Map.put(&1, :chosen?, false))
    ]
    |> Enum.map(&Map.take(&1, [:good, :source, :destination, :net_credits, :rate, :chosen?]))
  end

  ## The wait

  defp wait(nil), do: nil

  defp wait(generation) do
    with %AllocationResultPointer{selection_kind: :neutral_wait, strategy_decision_episode_id: id} <-
           Repo.get_by(AllocationResultPointer, fleet_generation_id: generation.id),
         %Episode{} = episode <- Repo.get(Episode, id) do
      %{
        best: best(episode),
        next_check_at: episode.next_observation_at,
        last_checked_at: last_checked_at(episode)
      }
    else
      _ -> nil
    end
  end

  # The best trade the wait weighed, by rate per Ship-hour.
  defp best(%Episode{alternatives: alternatives}) do
    for(
      %{"candidates" => candidates} <- alternatives || [],
      %{"kind" => "market_trade"} = candidate <- candidates,
      do: candidate
    )
    |> Enum.map(fn candidate ->
      outcomes = candidate["expected_outcomes"] || %{}
      estimate = outcomes["trade_estimate"] || %{}

      %{
        good: candidate["trade_symbol"],
        source: candidate["source_waypoint"],
        destination: candidate["destination_waypoint"],
        net_credits: round_or_nil(estimate["net_credits"]),
        rate: round_or_nil(outcomes["net_credits_per_ship_hour"]),
        gross: outcomes["maximum_credit_change"] || 0
      }
    end)
    |> Enum.sort_by(&{is_nil(&1.rate), -(&1.rate || 0), -&1.gross})
    |> List.first()
    |> then(&(&1 && Map.delete(&1, :gross)))
  end

  # The wait's latest re-evaluation, else when the wait last changed.
  defp last_checked_at(%Episode{} = episode) do
    with [_ | _] = entries <- get_in(episode.actual_outcomes || %{}, ["re_evaluations"]),
         %{"observed_at" => at} <- List.last(entries),
         {:ok, at, _offset} <- DateTime.from_iso8601(at) do
      at
    else
      _ -> episode.updated_at
    end
  end

  ## Expected vs actual

  defp history(nil, _symbol), do: []

  defp history(generation, symbol) do
    Repo.all(
      from r in EarningsRecord,
        where: r.fleet_generation_id == ^generation.id and r.ship_symbol == ^symbol,
        order_by: [desc: r.finished_at, desc: r.id],
        limit: ^@history
    )
    |> Enum.reverse()
    |> Enum.map(fn record ->
      %{
        id: record.id,
        good: record.good,
        source: record.source_waypoint,
        destination: record.destination_waypoint,
        expected: record.expected_value,
        actual: record.net_earnings,
        finished_at: record.finished_at
      }
    end)
  end

  defp round_or_nil(value) when is_number(value), do: round(value)
  defp round_or_nil(_value), do: nil
end
