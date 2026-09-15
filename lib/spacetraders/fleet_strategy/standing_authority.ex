defmodule SpaceTraders.FleetStrategy.StandingAuthority do
  @moduledoc false

  alias SpaceTraders.FleetStrategy.Revision

  @conditional_price_explanation "SpaceTraders does not provide a conditional maximum price, so the guarantee cannot be enforced at mutation time. Use a worst-case exposure bound or a Preference instead."

  def validate_constraints(constraints) when is_list(constraints) do
    Enum.reduce_while(constraints, :ok, fn constraint, :ok ->
      case parse_constraint(constraint) do
        {:ok, _rule} ->
          {:cont, :ok}

        {:error, explanation} ->
          {:halt, {:error, {:unenforceable_hard_constraint, constraint, explanation}}}
      end
    end)
  end

  def authorize(
        %Revision{id: revision_id, document: %{"hard_constraints" => constraints}},
        %{
          revision_id: revision_id,
          evidence_id: evidence_id,
          observed_at: %DateTime{},
          bounds: consequence_bounds
        }
      )
      when not is_nil(evidence_id) and is_map(consequence_bounds) do
    reasons =
      constraints
      |> Enum.map(&constraint_rejection(&1, consequence_bounds))
      |> Enum.reject(&is_nil/1)

    if reasons == [] do
      {:ok, %{revision_id: revision_id, evidence_id: evidence_id}}
    else
      {:error, reasons}
    end
  end

  def authorize(_revision, _consequence_bounds),
    do: {:error, ["Safety consequence bounds are unavailable."]}

  defp constraint_rejection(constraint, consequence_bounds) do
    case parse_constraint(constraint) do
      {:ok, {:credit_floor, floor, display_floor}} ->
        case Map.fetch(consequence_bounds, :minimum_credits) do
          {:ok, credits} when is_number(credits) and credits >= floor ->
            nil

          {:ok, credits} when is_number(credits) ->
            "Would leave #{credits} credits, below the #{display_floor} credit floor."

          _ ->
            "Cannot prove the #{display_floor} credit floor from available safety evidence."
        end

      {:ok, :no_scrap} ->
        case Map.fetch(consequence_bounds, :scraps_ship) do
          {:ok, false} -> nil
          {:ok, true} -> "Would scrap a Ship."
          _ -> "Cannot prove that no Ship would be scrapped from available safety evidence."
        end

      {:error, explanation} ->
        explanation
    end
  end

  defp parse_constraint(constraint) when is_binary(constraint) do
    cond do
      captures =
          Regex.run(
            ~r/^Keep(?: at least)? ((?:\d{1,3}(?:,\d{3})+|\d+)) credits available$/i,
            constraint
          ) ->
        [_, display_floor] = captures
        floor = display_floor |> String.replace(",", "") |> String.to_integer()
        {:ok, {:credit_floor, floor, display_floor}}

      Regex.match?(~r/^(?:No scrap|Never scrap ships?)$/i, constraint) ->
        {:ok, :no_scrap}

      Regex.match?(~r/(?:pay more than|maximum .*price|max(?:imum)? price|profit)/i, constraint) ->
        {:error, @conditional_price_explanation}

      true ->
        {:error,
         "No enforceable consequence rule is defined for this guarantee. Restate it as a supported exposure bound or a Preference."}
    end
  end

  defp parse_constraint(_constraint) do
    {:error, "A Hard Constraint must be a non-empty enforceable statement."}
  end
end
