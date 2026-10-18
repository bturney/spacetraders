defmodule SpaceTraders.Outcomes.Earnings do
  @moduledoc """
  Earnings records: one per completed piece of earning work, written when
  that work completes and read by every realized-money answer.

  Trading is the only earning activity today. Its work is a Completed Round
  Trip: one Fleet Commitment's purchases, written once when all the bought
  Cargo is gone, sold or jettisoned. Jettisoned units add their goods cost and
  no revenue. A trip cut off before then (a reset, an abandoned hold) writes
  nothing, and the balance shows the gap.

  A record holds the source, revenue, costs by type (goods; fuel per the
  glossary's charge-at-purchase rule, so every realized refuel charge its own
  root Intents issued; other, such as jump antimatter) and Net Earnings; the
  expected value and expected net per Ship-hour at selection, the price age it
  relied on and the alternatives it beat, copied; and the Ship and Ship-hours
  from taking the work until its last disposal. A charge with no recorded
  Realization is not a known amount and is left out.

  Metrics and the one structured Loki line per record are emitted by the
  Outcomes worker after the record's transaction commits
  (`SpaceTraders.Outcomes.PostCommit`), never here.

  Delivery rule: every future earning activity (contracts, charts, ore sales,
  ...) writes its own record, with its own `source`, as part of its own
  delivery.
  """

  import Ecto.Query

  alias SpaceTraders.CreditCalibration.Realization
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, StrategyDecisionEpisode}
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Outcomes.{EarningsRecord, PostCommit}
  alias SpaceTraders.Repo

  @fuel_operations ~w(refuel-ship)
  @other_operations ~w(jump-ship)
  @not_trades ~w(contract_id construction construction_upstream)

  @doc "A Generation's Earnings records, oldest first."
  def list(generation_id) when is_integer(generation_id) do
    Repo.all(
      from record in EarningsRecord,
        where: record.fleet_generation_id == ^generation_id,
        order_by: [asc: record.finished_at, asc: record.id]
    )
  end

  @doc "Earnings records of the Commitments of one Decision Episode's Portfolios."
  def for_episode(episode_id) when is_integer(episode_id),
    do: records(dynamic([portfolio: p], p.strategy_decision_episode_id == ^episode_id))

  @doc "Earnings records of one Portfolio's Commitments."
  def for_portfolio(portfolio_id) when is_integer(portfolio_id),
    do: records(dynamic([portfolio: p], p.id == ^portfolio_id))

  defp records(scope) do
    Repo.all(
      from record in EarningsRecord,
        join: commitment in Commitment,
        on: commitment.id == record.fleet_commitment_id,
        join: portfolio in Portfolio,
        as: :portfolio,
        on: portfolio.id == commitment.fleet_commitment_portfolio_id,
        where: ^scope,
        order_by: [asc: record.finished_at, asc: record.id]
    )
  end

  @doc "The `price_age` metric bucket of a selection-time price age in seconds."
  def price_age_bucket(nil), do: "n/a"
  def price_age_bucket(seconds) when seconds < 600, do: "fresh"
  def price_age_bucket(seconds) when seconds <= 1_800, do: "10-30m"
  def price_age_bucket(_seconds), do: ">30m"

  @doc """
  Realized outcome of one Market Decision Episode from its Earnings records.

  `classification` is `:still_evaluating` while any trading Commitment still
  holds work (an unfinished trade Intent, or a purchase with no disposal
  requested yet), else `:realized` when every trading Commitment wrote its
  record, else `:partially_realized`.
  """
  def episode_outcome(episode_id) when is_integer(episode_id) do
    intents =
      Repo.all(
        from intent in Intent,
          join: commitment in Commitment,
          on: commitment.id == intent.fleet_commitment_id,
          join: portfolio in Portfolio,
          on: portfolio.id == commitment.fleet_commitment_portfolio_id,
          where:
            portfolio.strategy_decision_episode_id == ^episode_id and
              (intent.type in ["buy", "sell"] or
                 (intent.type == "acquire_resources" and
                    fragment("?->>'kind' = 'jettison'", intent.last_action_result)))
      )

    records = for_episode(episode_id)
    recorded = MapSet.new(records, & &1.fleet_commitment_id)
    by_commitment = Enum.group_by(intents, & &1.fleet_commitment_id)

    open =
      for {id, mine} <- by_commitment,
          Enum.any?(mine, &Intent.unfinished?/1) or
            (Enum.any?(mine, &(&1.type == "buy" and &1.status == "completed")) and
               not Enum.any?(mine, &(&1.type != "buy"))),
          do: id

    traded =
      for {id, mine} <- by_commitment,
          Enum.any?(mine, &(&1.status == "completed")),
          do: id

    unrecorded = Enum.reject(traded, &MapSet.member?(recorded, &1))

    classification =
      cond do
        open != [] -> :still_evaluating
        unrecorded == [] -> :realized
        true -> :partially_realized
      end

    {classification, summary(records, Enum.sort(open), Enum.sort(unrecorded))}
  end

  defp summary(records, open, unrecorded) do
    sum = fn field -> if records != [], do: Enum.sum_by(records, &Map.fetch!(&1, field)) end

    %{
      earnings_record_ids: Enum.map(records, & &1.id),
      completed_round_trips: length(records),
      revenue: sum.(:revenue),
      goods_cost: sum.(:goods_cost),
      fuel_cost: sum.(:fuel_cost),
      other_cost: sum.(:other_cost),
      net_earnings: sum.(:net_earnings),
      open_commitments: open,
      unrecorded_commitments: unrecorded
    }
  end

  @doc """
  Writes the Earnings record of each of the Portfolio's trading Commitments
  whose bought Cargo is all gone. Idempotent: a Commitment writes at most one.
  """
  def record_trades(%Portfolio{id: portfolio_id}) do
    Repo.all(
      from commitment in Commitment,
        left_join: record in EarningsRecord,
        on: record.fleet_commitment_id == commitment.id,
        where: commitment.fleet_commitment_portfolio_id == ^portfolio_id and is_nil(record.id),
        select: commitment.id
    )
    |> Enum.each(&record_trade/1)
  end

  @doc "Writes one Commitment's trade record once its Cargo is all gone; else nil."
  def record_trade(commitment_id) when is_integer(commitment_id) do
    {:ok, record} =
      Repo.transaction(fn ->
        commitment =
          Repo.one!(
            from c in Commitment, where: c.id == ^commitment_id, lock: "FOR NO KEY UPDATE"
          )

        unless Repo.exists?(
                 from r in EarningsRecord, where: r.fleet_commitment_id == ^commitment_id
               ) do
          with %{} = attrs <- trade_attrs(commitment) do
            record = Repo.insert!(struct(EarningsRecord, attrs))
            PostCommit.earnings(record)
            record
          end
        end
      end)

    record
  end

  defp trade_attrs(commitment) do
    intents =
      Repo.all(
        from intent in Intent,
          where: intent.fleet_commitment_id == ^commitment.id,
          order_by: intent.id
      )

    buys =
      for %{type: "buy", status: "completed"} = i <- intents, r <- [receipt(i)], r, do: {i, r}

    sells =
      for %{type: "sell", status: "completed"} = i <- intents, r <- [receipt(i)], r, do: {i, r}

    jettisons = for %{status: "completed"} = i <- intents, u <- [jettisoned(i)], u, do: {i, u}
    bought = Enum.sum_by(buys, fn {_, r} -> r["units"] end)
    sold = Enum.sum_by(sells, fn {_, r} -> r["units"] end)
    dumped = Enum.sum_by(jettisons, &elem(&1, 1))

    cond do
      buys == [] or bought == 0 -> nil
      Enum.any?(intents, &(&1.type == "buy" and not trade?(&1))) -> nil
      Enum.any?(intents, &Intent.unfinished?/1) -> nil
      sold + dumped < bought -> nil
      true -> build(commitment, intents, buys, sells, jettisons, dumped)
    end
  end

  defp build(commitment, intents, buys, sells, jettisons, dumped) do
    [{first_buy, first_receipt} | _] = buys
    portfolio = Repo.get!(Portfolio, commitment.fleet_commitment_portfolio_id)
    episode_id = commitment.replan_decision_episode_id || portfolio.strategy_decision_episode_id
    ship = Repo.get!(Ship, first_buy.ship_id)
    market_trade = first_buy.parameters["market_trade"] || %{}
    outcomes = market_trade["expected_outcomes"] || %{}
    selected = selected_trade(episode_id, commitment.candidate_id)
    revenue = Enum.sum_by(sells, fn {_, r} -> r["total_price"] end)
    goods = Enum.sum_by(buys, fn {_, r} -> r["total_price"] end)
    # A coverage root Intent's refuel is observation-only spending, never the trade's.
    {fuel, other} =
      supporting_charges(
        commitment.id,
        for(i <- intents, i.type != "acquire_intelligence", do: i.id)
      )

    started_at = to_usec(first_buy.inserted_at)

    finished_at =
      (sells ++ jettisons)
      |> Enum.map(fn {intent, _} -> to_usec(intent.finished_at || intent.updated_at) end)
      |> Enum.max(DateTime)

    %{
      source: "trade",
      fleet_generation_id: portfolio.fleet_generation_id,
      fleet_commitment_id: commitment.id,
      strategy_decision_episode_id: episode_id,
      ship_symbol: ship.symbol,
      ship_type: ship.ship_type,
      good: first_receipt["trade_symbol"] || first_buy.parameters["trade_symbol"],
      source_waypoint: market_trade["source_waypoint"] || first_buy.target_waypoint,
      destination_waypoint:
        market_trade["destination_waypoint"] ||
          Enum.find_value(sells, fn {intent, _} -> intent.target_waypoint end),
      units: Enum.sum_by(buys, fn {_, r} -> r["units"] end),
      jettisoned_units: dumped,
      revenue: revenue,
      goods_cost: goods,
      fuel_cost: fuel,
      other_cost: other,
      net_earnings: revenue - goods - fuel - other,
      expected_value: expected_value(outcomes),
      expected_net_per_ship_hour:
        number(outcomes["net_credits_per_ship_hour"] || selected["net_credits_per_ship_hour"]),
      price_age_seconds: price_age(market_trade["uncertainty"]),
      alternatives: selected["alternatives"] || [],
      ship_seconds: max(DateTime.diff(finished_at, started_at), 0),
      started_at: started_at,
      finished_at: finished_at
    }
  end

  defp receipt(%Intent{last_action_result: %{"transaction" => %{} = transaction}}) do
    if is_integer(transaction["units"]) and transaction["units"] > 0 and
         is_integer(transaction["total_price"]) and transaction["total_price"] >= 0,
       do: transaction
  end

  defp receipt(_intent), do: nil

  defp jettisoned(%Intent{last_action_result: %{"kind" => "jettison", "units" => units}})
       when is_integer(units) and units > 0,
       do: units

  defp jettisoned(_intent), do: nil

  defp trade?(%Intent{parameters: %{"market_trade" => %{} = trade}}),
    do: not Enum.any?(@not_trades, &Map.has_key?(trade, &1))

  defp trade?(_intent), do: true

  # Charge-at-purchase: every realized refuel (fuel) or jump (other) charge
  # sent with one of this Commitment's root Intents as its provenance.
  defp supporting_charges(commitment_id, intent_ids) do
    charges =
      Repo.all(
        from attempt in Attempt,
          join: realization in Realization,
          on: realization.mutation_attempt_id == attempt.id,
          where:
            attempt.operation_id in ^(@fuel_operations ++ @other_operations) and
              fragment("(?->>'intent_id')::bigint", attempt.provenance) in ^intent_ids and
              fragment("(?->>'commitment_id')::bigint", attempt.provenance) == ^commitment_id,
          select: {attempt.operation_id, realization.realized_charge}
      )

    sum = fn operations ->
      Enum.sum(for {op, charge} <- charges, op in operations, is_integer(charge), do: charge)
    end

    {sum.(@fuel_operations), sum.(@other_operations)}
  end

  defp selected_trade(episode_id, candidate_id) do
    case episode_id && Repo.get(StrategyDecisionEpisode, episode_id) do
      %{expectations: %{"selected_trades" => trades}} when is_list(trades) ->
        Enum.find(trades, %{}, &(&1["candidate_id"] == candidate_id))

      _ ->
        %{}
    end
  end

  # The estimate after fuel when selection had one; else the gross spread.
  defp expected_value(outcomes) do
    case outcomes["trade_estimate"] do
      %{"net_credits" => net} when is_number(net) ->
        round(net)

      _ ->
        if is_number(outcomes["maximum_credit_change"]),
          do: round(outcomes["maximum_credit_change"])
    end
  end

  # The oldest Listing the selection relied on.
  defp price_age(%{} = uncertainty) do
    ages =
      for key <- ~w(source_evidence_age_seconds destination_evidence_age_seconds),
          age <- [uncertainty[key]],
          is_number(age),
          do: round(age)

    if ages != [], do: Enum.max(ages)
  end

  defp price_age(_uncertainty), do: nil

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil

  defp to_usec(%DateTime{} = at), do: DateTime.add(at, 0, :microsecond)
  defp to_usec(%NaiveDateTime{} = at), do: at |> DateTime.from_naive!("Etc/UTC") |> to_usec()
end
