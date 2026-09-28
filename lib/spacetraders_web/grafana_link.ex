defmodule SpaceTradersWeb.GrafanaLink do
  @moduledoc "Credential-free links into the provisioned SpaceTraders Grafana families."

  @dashboards %{
    strategy_outcomes: {"spacetraders-strategy-outcomes", "strategy-outcomes"},
    economics_capital: {"spacetraders-economics-capital", "economics-capital"},
    fleet_logistics: {"spacetraders-fleet-logistics", "fleet-logistics"},
    intelligence_api_capacity:
      {"spacetraders-intelligence-api-capacity", "intelligence-api-capacity"},
    reliability_recovery: {"spacetraders-reliability-recovery", "reliability-recovery"}
  }

  @identity_parameters %{
    fleet_generation: "var-fleet_generation",
    strategy_revision: "var-strategy_revision",
    decision_episode: "var-decision_episode",
    commitment: "var-commitment",
    intent: "var-intent",
    attempt: "var-attempt"
  }

  def url(family, context) when is_map_key(@dashboards, family) and is_list(context) do
    {uid, slug} = Map.fetch!(@dashboards, family)

    query =
      context
      |> Enum.flat_map(&query_parameter/1)
      |> Map.new()
      |> Map.put("timezone", "utc")

    "#{base_url()}/d/#{uid}/#{slug}?#{URI.encode_query(query)}"
  end

  def family_for_condition(%{key: "objective-infeasible:" <> _}), do: :strategy_outcomes

  def family_for_condition(%{condition_key: key}), do: family_for_condition(%{key: key})

  def family_for_condition(%{key: key}) when is_binary(key) do
    cond do
      String.contains?(key, ["credit", "market", "economic", "capital"]) ->
        :economics_capital

      String.contains?(key, ["intelligence", "api-capacity", "observation"]) ->
        :intelligence_api_capacity

      String.contains?(key, ["ship", "fleet", "contract", "construction", "transfer"]) ->
        :fleet_logistics

      true ->
        :reliability_recovery
    end
  end

  def family_for_calibration("market" <> _), do: :economics_capital
  def family_for_calibration("ship-acquisition" <> _), do: :economics_capital
  def family_for_calibration("ship-refit" <> _), do: :economics_capital
  def family_for_calibration("intelligence" <> _), do: :intelligence_api_capacity
  def family_for_calibration("owned-recovery" <> _), do: :reliability_recovery

  def family_for_calibration("resources" <> _), do: :fleet_logistics
  def family_for_calibration("construction" <> _), do: :fleet_logistics
  def family_for_calibration("contracts" <> _), do: :fleet_logistics
  def family_for_calibration("transfer" <> _), do: :fleet_logistics

  def family_for_calibration(_version), do: :strategy_outcomes

  def family_label(:strategy_outcomes), do: "Strategy Outcomes"
  def family_label(:economics_capital), do: "Economics and Capital"
  def family_label(:fleet_logistics), do: "Fleet and Logistics"
  def family_label(:intelligence_api_capacity), do: "Intelligence and API Capacity"
  def family_label(:reliability_recovery), do: "Reliability and Recovery"

  def condition_url(condition) do
    {key_generation_id, key_revision_id} = objective_context(condition_key(condition))

    url(family_for_condition(condition),
      fleet_generation: Map.get(condition, :fleet_generation_id) || key_generation_id,
      strategy_revision: Map.get(condition, :fleet_strategy_revision_id) || key_revision_id,
      decision_episode: Map.get(condition, :strategy_decision_episode_id),
      from: DateTime.add(condition_inserted_at(condition), -300),
      to: condition_end(condition)
    )
  end

  defp query_parameter({key, value}) when key in [:from, :to],
    do: [{Atom.to_string(key), time_value(value)}]

  defp query_parameter({key, value}) do
    case {@identity_parameters[key], value} do
      {parameter, value} when is_binary(parameter) and not is_nil(value) ->
        [{parameter, to_string(value)}]

      _ ->
        []
    end
  end

  defp time_value(:now), do: "now"
  defp time_value(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp time_value(value) when is_integer(value) or is_binary(value), do: value

  defp condition_key(condition),
    do: Map.get(condition, :key) || Map.fetch!(condition, :condition_key)

  defp condition_inserted_at(condition),
    do: Map.get(condition, :inserted_at) || Map.fetch!(condition, :at)

  defp condition_end(%{resolved_at: %DateTime{} = resolved_at}),
    do: DateTime.add(resolved_at, 300)

  defp condition_end(_condition), do: :now

  defp objective_context("objective-infeasible:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [generation_id, revision_id, _objective_index] ->
        {parse_id(generation_id), parse_id(revision_id)}

      _ ->
        {nil, nil}
    end
  end

  defp objective_context(_key), do: {nil, nil}

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp base_url do
    configured =
      :spacetraders
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:base_url)

    case URI.parse(configured) do
      %URI{userinfo: userinfo} when not is_nil(userinfo) ->
        raise ArgumentError, "Grafana base URL must not contain credentials"

      %URI{scheme: scheme, host: host, query: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
        String.trim_trailing(configured, "/")

      _ ->
        raise ArgumentError,
              "Grafana base URL must be an HTTP(S) origin without query or fragment"
    end
  end
end
