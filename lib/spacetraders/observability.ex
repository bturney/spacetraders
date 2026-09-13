defmodule SpaceTraders.Observability do
  @moduledoc false

  require Logger

  @correlation_keys [
    :request_id,
    :operator_id,
    :agent_id,
    :fleet_generation_id,
    :strategy_revision_id,
    :decision_episode_id,
    :commitment_id,
    :ship_id,
    :ship_symbol,
    :job_id,
    :intent_id,
    :mutation_attempt_id
  ]

  def with_context(metadata, fun) when is_list(metadata) and is_function(fun, 0) do
    previous = Logger.metadata()
    Logger.metadata(metadata)

    try do
      fun.()
    after
      Logger.reset_metadata(previous)
    end
  end

  def api_request(path, status) do
    {endpoint, resource_metadata} = endpoint(path)

    metadata =
      logger_correlation()
      |> Map.merge(resource_metadata)
      |> Map.merge(%{endpoint: endpoint, status: status, outcome: request_outcome(status)})

    :telemetry.execute([:spacetraders, :api, :request], %{count: 1}, metadata)
    Logger.info("SpaceTraders API request", Map.to_list(metadata))
  end

  def fleet_activity(agent, ship, job, kind, metadata) do
    correlation = %{
      agent_id: agent.id,
      ship_id: ship.id,
      ship_symbol: ship.symbol,
      job_id: job && job.id,
      job_type: (job && job.type) || "none",
      job_state: (job && job.status) || "none",
      intent_id: metadata["intent_id"] || metadata[:intent_id],
      kind: kind
    }

    :telemetry.execute([:spacetraders, :fleet, :activity], %{count: 1}, correlation)
    Logger.info("Fleet activity", Map.to_list(correlation))
  end

  def intent_transition(intent, updated) do
    metadata = %{
      intent_id: intent.id,
      job_id: intent.job_id,
      ship_id: intent.ship_id,
      intent_type: intent.type,
      from_state: intent.status,
      to_state: updated.status
    }

    :telemetry.execute([:spacetraders, :intent, :transition], %{count: 1}, metadata)
    Logger.info("Intent transition", Map.to_list(metadata))
  end

  def redact(value, secret) when not is_binary(secret) or secret == "", do: value

  def redact(value, secret) when is_binary(value),
    do: String.replace(value, secret, "[REDACTED]")

  def redact(%module{} = value, secret) do
    fields = value |> Map.from_struct() |> redact(secret)
    struct(module, fields)
  end

  def redact(value, secret) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, redact(item, secret)} end)

  def redact(value, secret) when is_list(value), do: Enum.map(value, &redact(&1, secret))

  def redact(value, secret) when is_tuple(value) do
    value |> Tuple.to_list() |> redact(secret) |> List.to_tuple()
  end

  def redact(value, _secret), do: value

  defp logger_correlation do
    Logger.metadata()
    |> Map.new()
    |> Map.take(@correlation_keys)
  end

  defp request_outcome(status) when status in 200..299, do: "ok"
  defp request_outcome(status) when status in 400..499, do: "client_error"
  defp request_outcome(status) when status in 500..599, do: "server_error"
  defp request_outcome(_status), do: "unknown"

  defp endpoint(path) do
    case String.split(path, "/", trim: true) do
      [] ->
        {"/", %{}}

      ["register"] ->
        {"/register", %{}}

      ["my", "agent"] ->
        {"/my/agent", %{}}

      ["my", "contracts"] ->
        {"/my/contracts", %{}}

      ["my", "contracts", contract_id] ->
        {"/my/contracts/{contractId}", %{contract_id: contract_id}}

      ["my", "contracts", contract_id, action] ->
        {"/my/contracts/{contractId}/#{action}", %{contract_id: contract_id}}

      ["my", "ships"] ->
        {"/my/ships", %{}}

      ["my", "ships", ship_symbol | rest] ->
        suffix = if rest == [], do: "", else: "/" <> Enum.join(rest, "/")
        {"/my/ships/{shipSymbol}#{suffix}", %{ship_symbol: ship_symbol}}

      ["systems", system_symbol] ->
        {"/systems/{systemSymbol}", %{system_symbol: system_symbol}}

      ["systems", system_symbol, "waypoints"] ->
        {"/systems/{systemSymbol}/waypoints", %{system_symbol: system_symbol}}

      ["systems", system_symbol, "waypoints", waypoint_symbol | rest] ->
        suffix = if rest == [], do: "", else: "/" <> Enum.join(rest, "/")

        {"/systems/{systemSymbol}/waypoints/{waypointSymbol}#{suffix}",
         %{system_symbol: system_symbol, waypoint_symbol: waypoint_symbol}}

      ["factions"] ->
        {"/factions", %{}}

      ["factions", faction_symbol] ->
        {"/factions/{factionSymbol}", %{faction_symbol: faction_symbol}}

      _ ->
        {"unknown", %{}}
    end
  end
end
