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
