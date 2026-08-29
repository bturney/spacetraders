defmodule SpaceTraders.Fleet.MarketTradingPolicy do
  @moduledoc "Selects a currently known, constraint-safe market trade."

  @doc "Returns the best viable candidate and rejected candidates with reasons."
  def select(candidates, constraints) when is_list(candidates) and is_map(constraints) do
    {viable, rejected} =
      Enum.reduce(candidates, {[], []}, fn candidate, {viable, rejected} ->
        case evaluate(candidate, constraints) do
          {:ok, candidate} -> {[candidate | viable], rejected}
          {:error, reason} -> {viable, [%{candidate: candidate, reason: reason} | rejected]}
        end
      end)

    selected =
      viable
      |> Enum.sort_by(fn candidate ->
        {-candidate.expected_net_profit, candidate.transit_seconds, -candidate.destination_age}
      end)
      |> List.first()

    {selected, Enum.reverse(rejected)}
  end

  defp evaluate(candidate, constraints) do
    candidate = normalize(candidate)

    with true <- valid_candidate?(candidate),
         true <- candidate.units > 0,
         true <- candidate.sell_price > candidate.purchase_price,
         expected_net_profit <-
           (candidate.sell_price - candidate.purchase_price) * candidate.units -
             Map.get(candidate, :estimated_fuel_cost, 0),
         true <- expected_net_profit >= Map.get(constraints, :minimum_profit, 0),
         invested <- candidate.purchase_price * candidate.units,
         true <-
           is_nil(Map.get(constraints, :credit_exposure)) or
             invested <= Map.get(constraints, :credit_exposure),
         true <-
           invested <=
             max(
               Map.get(constraints, :credits, invested) -
                 Map.get(constraints, :reserve_credits, 0),
               0
             ),
         true <-
           return_percentage(expected_net_profit, invested) >=
             Map.get(constraints, :minimum_return_percentage, 0),
         true <- compatible_cargo?(candidate, constraints) do
      {:ok,
       candidate
       |> Map.put(:expected_net_profit, expected_net_profit)
       |> Map.put(:invested_credits, invested)
       |> Map.put(:destination_age, Map.get(candidate, :destination_age, 0))
       |> Map.put(:transit_seconds, Map.get(candidate, :transit_seconds, 0))}
    else
      false -> {:error, :candidate_constraints}
      :error -> {:error, :invalid_candidate}
    end
  end

  defp normalize(candidate) do
    Map.new(candidate, fn {key, value} ->
      {if(is_binary(key), do: String.to_existing_atom(key), else: key), value}
    end)
  end

  defp valid_candidate?(candidate) do
    Enum.all?(
      [:trade_symbol, :source_waypoint, :destination_waypoint],
      &is_binary(Map.get(candidate, &1))
    ) and
      Enum.all?([:units, :purchase_price, :sell_price], &is_integer(Map.get(candidate, &1)))
  end

  defp compatible_cargo?(candidate, constraints) do
    Map.get(constraints, :compatible_existing_cargo, false) or
      Map.get(candidate, :existing_cargo_units, 0) == 0
  end

  defp return_percentage(_profit, 0), do: 0
  defp return_percentage(profit, invested), do: profit / invested * 100
end
