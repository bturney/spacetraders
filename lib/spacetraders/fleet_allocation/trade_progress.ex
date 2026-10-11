defmodule SpaceTraders.FleetAllocation.TradeProgress do
  @moduledoc """
  Receipt-backed trade progress for one Strategy Decision Episode or Portfolio.

  Reads the completed buy and sell Intents that Fleet Commitments already
  recorded and reports only what their retained transaction receipts prove:
  receipt references, quantities, credits spent and received, and a Trade Margin
  for each Completed Round Trip whose acquisition and disposal are causally
  linked. Nothing here is a ledger: every figure is re-derived from the
  Intents on each read, so repeated reconciliation, restart and supersession
  report the same receipts once.

  Anything the receipts do not prove is the string `"unknown"`, with a reason in
  `unknown`: a missing receipt is never zero. Estimates, quotes, predicted
  burn and Agent-balance change never enter this projection.

  Goods receipts come from the completed Intent's `last_action_result`, linked
  to its reconciled MutationAttempt by `mutation_attempt_id`: the bounded
  deviation recorded in ADR 0011, since attempt outcomes do not retain the
  transaction.

  Supporting charges (refuel, jump antimatter) use charge-at-purchase
  attribution (#689): each realized charge belongs in full to the root Intent
  that issued it, named by its MutationAttempt's recorded provenance, hence to
  that Intent's Fleet Commitment and original Decision Episode. The amount is
  the attempt's Credit Calibration Realization, recorded once per attempt from
  the decoded success response. Fuel left aboard for a later trip is never
  moved or prorated. A charge-bearing attempt without a Realization, or whose
  provenance does not name its Intent's Commitment, is `"unknown"`.

  Net Earnings of a Completed Round Trip is its Trade Margin minus the
  supporting charges of its own Commitment's root Intents. Episode Cash Flow
  counts every receipt and charge in scope, finished work or not;
  observation-only spending is the charges issued by coverage
  (`acquire_intelligence`) root Intents.
  """

  import Ecto.Query

  alias SpaceTraders.CreditCalibration.Realization
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @unknown "unknown"
  @supporting_operations ~w(refuel-ship jump-ship)
  @supporting_kinds ~w(refuel jump)
  @trade_operations ~w(purchase-cargo sell-cargo)

  @doc "Progress from the receipts and charges of one Episode."
  def for_episode(episode_id) when is_integer(episode_id),
    do: load(dynamic([portfolio: p], p.strategy_decision_episode_id == ^episode_id))

  @doc "Progress from the receipts and charges of one Portfolio."
  def for_portfolio(portfolio_id) when is_integer(portfolio_id),
    do: load(dynamic([portfolio: p], p.id == ^portfolio_id))

  @doc "Progress from the receipts and charges of every Episode of one Fleet Generation."
  def for_generation(generation_id) when is_integer(generation_id),
    do: load(dynamic([portfolio: p], p.fleet_generation_id == ^generation_id))

  defp load(scope) do
    intents = base_query() |> where(^scope) |> Repo.all()
    build(intents, attempt_charges(scope))
  end

  @doc """
  Builds the projection from buy/sell Intents of any status and the
  credit-bearing attempts issued by the same scope's root Intents (pure).

  Only completed Intents contribute receipts. `open_commitments` names each
  Commitment whose trade is still under way: an unfinished buy or sell, or a
  completed buy whose sell leg has not been requested yet. `attempts` are
  `attempt_charges/1` rows; each attempt counts once however often it is read.
  """
  def build(all_intents, attempts \\ []) when is_list(all_intents) and is_list(attempts) do
    all_intents = Enum.sort_by(all_intents, & &1.id)
    intents = Enum.filter(all_intents, &(&1.status == "completed"))
    {receipts, receipt_less} = split_receipts(intents)
    attempts = Enum.uniq_by(attempts, & &1.mutation_attempt_id)
    charges = attempts |> Enum.filter(&(&1.role == :supporting)) |> Enum.flat_map(&charge/1)
    traced = traced_intents(attempts)
    trips = intents |> round_trips(receipts) |> Enum.map(&with_supporting(&1, charges, traced))
    proven = for {:ok, trip} <- trips, do: trip
    trade_margin = aggregate_margin(trips)
    net_earnings = aggregate_net(trips)
    {cash_flow, cash_flow_gaps} = cash_flow(receipts, receipt_less, charges, attempts)

    %{
      receipts: receipts,
      receipt_less_intents: Enum.map(receipt_less, & &1.id),
      units_bought: sum(receipts, "buy", :units),
      units_sold: sum(receipts, "sell", :units),
      credits_spent: sum(receipts, "buy", :total_price),
      credits_received: sum(receipts, "sell", :total_price),
      completed_round_trips: length(proven),
      round_trips: proven,
      trade_margin: trade_margin,
      open_commitments: open_commitments(all_intents),
      supporting_cost: aggregate_supporting_cost(proven),
      supporting_charges: Enum.map(charges, &Map.delete(&1, :reason)),
      observation_only_spending: charges |> Enum.filter(& &1.observation_only) |> total(),
      net_earnings: net_earnings,
      episode_cash_flow: cash_flow,
      unknown:
        net_gap(trade_margin, net_earnings) ++
          for({:unproven, commitment_id, reason} <- trips, do: gap(commitment_id, reason)) ++
          for(%{realized_charge: @unknown} = charge <- charges, do: charge_gap(charge)) ++
          for(
            %{supporting_limitation: reason} = trip when is_binary(reason) <- proven,
            do: %{item: "supporting_charge", commitment_id: trip.commitment_id, reason: reason}
          ) ++
          cash_flow_gaps
    }
  end

  @doc """
  Credit-bearing MutationAttempts issued by the root Intents of the scoped
  Portfolios' Commitments, with their Realization when one was recorded.

  The root Intent is the attempt's recorded `intent_id` provenance; nothing is
  inferred from the Ship's later work.
  """
  def attempt_charges(scope) do
    from(attempt in Attempt,
      join: intent in Intent,
      on: fragment("?->'intent_id' = to_jsonb(?)", attempt.provenance, intent.id),
      join: commitment in Commitment,
      on: commitment.id == intent.fleet_commitment_id,
      join: portfolio in Portfolio,
      as: :portfolio,
      on: portfolio.id == commitment.fleet_commitment_portfolio_id,
      left_join: realization in Realization,
      on: realization.mutation_attempt_id == attempt.id,
      where: ^credit_bearing(),
      where: ^scope,
      order_by: [asc: attempt.prepared_at, asc: attempt.id],
      select: %{
        mutation_attempt_id: attempt.id,
        operation_id: attempt.operation_id,
        state: attempt.state,
        provenance: attempt.provenance,
        intent_id: intent.id,
        intent_type: intent.type,
        commitment_id: intent.fleet_commitment_id,
        realized_charge: realization.realized_charge
      }
    )
    |> Repo.all()
    |> Enum.map(fn row ->
      Map.put(
        row,
        :role,
        if(row.operation_id in @trade_operations, do: :trade, else: :supporting)
      )
    end)
  end

  defp credit_bearing do
    historical = MutationAttempts.selected_action_kind_in(@supporting_kinds)

    dynamic(
      [attempt],
      attempt.operation_id in ^(@supporting_operations ++ @trade_operations) or
        (attempt.operation_id == "historical-ship-action" and ^historical)
    )
  end

  # One charge per supporting attempt that may have charged credits.
  defp charge(attempt) do
    if is_nil(attempt.realized_charge) and attempt.state in MutationAttempts.no_effect_states(),
      do: [],
      else: [charge_row(attempt)]
  end

  defp charge_row(attempt) do
    {amount, reason} =
      cond do
        attempt.provenance["commitment_id"] != attempt.commitment_id ->
          {@unknown, "the attempt's provenance does not name its root Intent's Commitment"}

        is_integer(attempt.realized_charge) ->
          {attempt.realized_charge, nil}

        true ->
          {@unknown, "no realized charge receipt for this attempt"}
      end

    %{
      mutation_attempt_id: attempt.mutation_attempt_id,
      operation_id: attempt.operation_id,
      intent_id: attempt.intent_id,
      intent_type: attempt.intent_type,
      commitment_id: attempt.commitment_id,
      ship_symbol: attempt.provenance["ship_symbol"],
      realized_charge: amount,
      observation_only: attempt.intent_type == "acquire_intelligence",
      reason: reason
    }
  end

  # Root Intents whose own trade send was recorded with exact root-Intent
  # provenance and succeeded: proof that their supporting sends, if any, were
  # recorded the same way. Without it (older history) an absent charge is not
  # evidence of no charge.
  defp traced_intents(attempts) do
    for %{role: :trade, state: state} = attempt <- attempts,
        state in ~w(succeeded accepted),
        attempt.provenance["commitment_id"] == attempt.commitment_id,
        into: MapSet.new(),
        do: attempt.intent_id
  end

  defp with_supporting({:ok, trip}, charges, traced) do
    # The trade's own root Intents: a coverage Intent owns its scouting fuel.
    mine =
      Enum.filter(charges, &(&1.commitment_id == trip.commitment_id and not &1.observation_only))

    {cost, limitation} =
      if MapSet.member?(traced, trip.purchase_intent_id) and
           MapSet.member?(traced, trip.sale_intent_id),
         do: {total(mine), nil},
         else: {@unknown, "this trip's sends carry no exact root-Intent provenance"}

    {:ok,
     Map.merge(trip, %{
       supporting_attempt_ids: Enum.map(mine, & &1.mutation_attempt_id),
       supporting_cost: cost,
       supporting_limitation: limitation,
       net_earnings: if(is_integer(cost), do: trip.trade_margin - cost, else: @unknown)
     })}
  end

  defp with_supporting(unproven, _charges, _traced), do: unproven

  defp total(charges) do
    if Enum.all?(charges, &is_integer(&1.realized_charge)),
      do: Enum.sum_by(charges, & &1.realized_charge),
      else: @unknown
  end

  # The proven trips' own supporting charges; unknown (not zero) unless each is known.
  defp aggregate_supporting_cost(trips) do
    costs = Enum.map(trips, & &1.supporting_cost)

    if costs != [] and Enum.all?(costs, &is_integer/1),
      do: Enum.sum(costs),
      else: @unknown
  end

  defp aggregate_net(trips) do
    if trips != [] and
         Enum.all?(trips, &match?({:ok, %{net_earnings: net}} when is_integer(net), &1)),
       do: Enum.sum_by(trips, fn {:ok, trip} -> trip.net_earnings end),
       else: @unknown
  end

  defp net_gap(_margin, net) when is_integer(net), do: []

  defp net_gap(margin, _net) when is_integer(margin),
    do: [%{item: "net_earnings", reason: "a Completed Round Trip's supporting charge is unknown"}]

  defp net_gap(_margin, _net),
    do: [
      %{item: "net_earnings", reason: "Trade Margin is not proven for every traded Commitment"}
    ]

  defp charge_gap(charge),
    do: %{
      item: "supporting_charge",
      commitment_id: charge.commitment_id,
      mutation_attempt_id: charge.mutation_attempt_id,
      reason: charge.reason
    }

  # Every proven receipt and charge in scope, finished work or not.
  defp cash_flow(receipts, receipt_less, charges, attempts) do
    unresolved_trade? =
      Enum.any?(
        attempts,
        &(&1.role == :trade and &1.state in MutationAttempts.unresolved_states())
      )

    gaps =
      [
        receipt_less != [] && "a completed trade Intent has no transaction receipt",
        unresolved_trade? && "a trade attempt's outcome is unresolved",
        total(charges) == @unknown && "a supporting charge is unknown"
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&%{item: "episode_cash_flow", reason: &1})

    if gaps == [] do
      signed = fn
        %{type: "sell", total_price: price} -> price
        %{total_price: price} -> -price
      end

      {Enum.sum_by(receipts, signed) - total(charges), []}
    else
      {@unknown, gaps}
    end
  end

  @doc "The proven integer Trade Margin of a stored or built projection, else nil."
  def trade_margin(%{trade_margin: margin}) when is_integer(margin), do: margin
  def trade_margin(%{"trade_margin" => margin}) when is_integer(margin), do: margin
  def trade_margin(_progress), do: nil

  @doc """
  The terminal classification the receipts support, or `:still_evaluating`.

  While any Commitment's trade is still under way the Episode keeps
  evaluating. Once none is, it is `:realized` when every traded Commitment
  proved a Completed Round Trip, else `:partially_realized`.
  """
  def classification(%{open_commitments: [_ | _]}), do: :still_evaluating

  def classification(%{unknown: unknown}) do
    if Enum.any?(unknown, &(&1.item == "completed_round_trip")),
      do: :partially_realized,
      else: :realized
  end

  defp base_query do
    from(intent in Intent,
      join: commitment in Commitment,
      on: commitment.id == intent.fleet_commitment_id,
      join: portfolio in Portfolio,
      as: :portfolio,
      on: portfolio.id == commitment.fleet_commitment_portfolio_id,
      where: intent.type in ["buy", "sell"],
      order_by: intent.id
    )
  end

  # Trade Margin is per Completed Round Trip; an Episode-wide figure is shown
  # only when every traded Commitment proved its round trip.
  defp aggregate_margin(trips) do
    if trips != [] and Enum.all?(trips, &match?({:ok, _}, &1)),
      do: Enum.sum_by(trips, fn {:ok, trip} -> trip.trade_margin end),
      else: @unknown
  end

  defp open_commitments(intents) do
    intents
    |> Enum.group_by(& &1.fleet_commitment_id)
    |> Enum.filter(fn {_commitment_id, mine} ->
      Enum.any?(mine, &Intent.unfinished?/1) or
        (Enum.any?(mine, &(&1.type == "buy" and &1.status == "completed")) and
           not Enum.any?(mine, &(&1.type == "sell")))
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp split_receipts(intents) do
    {receipts, missing} =
      Enum.reduce(intents, {[], []}, fn intent, {receipts, missing} ->
        case receipt(intent) do
          {:ok, receipt} -> {[receipt | receipts], missing}
          :none -> {receipts, [intent | missing]}
        end
      end)

    {Enum.reverse(receipts), Enum.reverse(missing)}
  end

  defp receipt(%Intent{last_action_result: %{"transaction" => transaction}} = intent)
       when is_map(transaction) do
    total = transaction["total_price"]
    units = transaction["units"]

    if is_integer(total) and total >= 0 and is_integer(units) and units > 0 do
      {:ok,
       %{
         intent_id: intent.id,
         commitment_id: intent.fleet_commitment_id,
         type: intent.type,
         ship_symbol: transaction["ship_symbol"],
         waypoint_symbol: transaction["waypoint_symbol"] || intent.target_waypoint,
         trade_symbol: transaction["trade_symbol"],
         units: units,
         price_per_unit: transaction["price_per_unit"],
         total_price: total,
         mutation_attempt_id: intent.mutation_attempt_id,
         finished_at: intent.finished_at
       }}
    else
      :none
    end
  end

  defp receipt(_intent), do: :none

  defp sum(receipts, type, field) do
    case Enum.filter(receipts, &(&1.type == type)) do
      [] -> @unknown
      matching -> Enum.sum_by(matching, &Map.fetch!(&1, field))
    end
  end

  # Pilot limitation, not the GLOSSARY definition: this projection proves a
  # Completed Round Trip only when one Commitment holds exactly one receipted
  # acquisition followed by one receipted disposal of the same Trade Good and
  # quantity, and none of its completed trade Intents lacks a receipt.
  # Multiple purchases, partial sales and transfers stay unproven ("unknown")
  # until causal linkage between them is retained.
  defp round_trips(intents, receipts) do
    intents
    |> Enum.group_by(& &1.fleet_commitment_id)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {commitment_id, commitment_intents} ->
      mine = Enum.filter(receipts, &(&1.commitment_id == commitment_id))
      receipted = MapSet.new(mine, & &1.intent_id)
      receipt_less? = Enum.any?(commitment_intents, &(&1.id not in receipted))
      buys = Enum.filter(mine, &(&1.type == "buy"))
      sells = Enum.filter(mine, &(&1.type == "sell"))

      case {receipt_less?, buys, sells} do
        {true, _, _} ->
          {:unproven, commitment_id, "a completed trade Intent has no transaction receipt"}

        {false, [], _} ->
          {:unproven, commitment_id, "no purchase receipt"}

        {false, _, []} ->
          {:unproven, commitment_id, "no sale receipt yet"}

        {false, [buy], [sell]} ->
          cond do
            buy.trade_symbol != sell.trade_symbol or buy.units != sell.units ->
              {:unproven, commitment_id, "purchase and sale quantity or Trade Good differ"}

            not sold_after_purchase?(buy, sell) ->
              {:unproven, commitment_id, "the sale does not follow the purchase"}

            true ->
              {:ok, trip(commitment_id, buy, sell)}
          end

        {false, _, _} ->
          {:unproven, commitment_id,
           "multiple acquisitions or disposals are not causally linked by a receipt"}
      end
    end)
  end

  # The sell leg is requested only after the buy completes, so its Intent is
  # later; a recorded finish time never precedes the purchase's.
  defp sold_after_purchase?(buy, sell) do
    sell.intent_id > buy.intent_id and
      (is_nil(buy.finished_at) or is_nil(sell.finished_at) or
         DateTime.compare(sell.finished_at, buy.finished_at) != :lt)
  end

  defp trip(commitment_id, buy, sell) do
    %{
      commitment_id: commitment_id,
      trade_symbol: buy.trade_symbol,
      units: buy.units,
      source_waypoint: buy.waypoint_symbol,
      destination_waypoint: sell.waypoint_symbol,
      purchase_intent_id: buy.intent_id,
      sale_intent_id: sell.intent_id,
      purchase_cost: buy.total_price,
      sale_revenue: sell.total_price,
      trade_margin: sell.total_price - buy.total_price
    }
  end

  defp gap(commitment_id, reason),
    do: %{item: "completed_round_trip", commitment_id: commitment_id, reason: reason}
end
