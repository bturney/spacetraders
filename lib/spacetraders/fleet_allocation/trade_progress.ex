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
  `unknown`: a missing receipt is never zero, and Net Earnings stays unknown
  because supporting costs (fuel and others) are not retained against the
  Episode. Estimates never enter this projection.

  Receipts come from the completed Intent's `last_action_result`, linked to
  its reconciled MutationAttempt by `mutation_attempt_id`: the bounded
  deviation recorded in ADR 0011, since attempt outcomes do not retain the
  transaction.
  """

  import Ecto.Query

  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.Repo

  @unknown "unknown"
  @supporting_costs_reason "supporting costs such as fuel are not retained against this decision's receipts"

  @doc "Progress from the receipts of every completed trade Intent of one Episode."
  def for_episode(episode_id) when is_integer(episode_id) do
    base_query()
    |> where([_i, _c, portfolio], portfolio.strategy_decision_episode_id == ^episode_id)
    |> Repo.all()
    |> build()
  end

  @doc "Progress from the receipts of every completed trade Intent of one Portfolio."
  def for_portfolio(portfolio_id) when is_integer(portfolio_id) do
    base_query()
    |> where([_i, _c, portfolio], portfolio.id == ^portfolio_id)
    |> Repo.all()
    |> build()
  end

  @doc """
  Builds the projection from buy/sell Intents of any status (pure).

  Only completed Intents contribute receipts. `open_commitments` names each
  Commitment whose trade is still under way: an unfinished buy or sell, or a
  completed buy whose sell leg has not been requested yet.
  """
  def build(all_intents) when is_list(all_intents) do
    all_intents = Enum.sort_by(all_intents, & &1.id)
    intents = Enum.filter(all_intents, &(&1.status == "completed"))
    {receipts, receipt_less} = split_receipts(intents)
    trips = round_trips(intents, receipts)
    proven = for {:ok, trip} <- trips, do: trip

    %{
      receipts: receipts,
      receipt_less_intents: Enum.map(receipt_less, & &1.id),
      units_bought: sum(receipts, "buy", :units),
      units_sold: sum(receipts, "sell", :units),
      credits_spent: sum(receipts, "buy", :total_price),
      credits_received: sum(receipts, "sell", :total_price),
      completed_round_trips: length(proven),
      round_trips: proven,
      trade_margin: aggregate_margin(trips),
      open_commitments: open_commitments(all_intents),
      net_earnings: @unknown,
      unknown:
        [%{item: "net_earnings", reason: @supporting_costs_reason}] ++
          for({:unproven, commitment_id, reason} <- trips, do: gap(commitment_id, reason))
    }
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
