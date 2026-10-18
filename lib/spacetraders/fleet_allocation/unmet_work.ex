defmodule SpaceTraders.FleetAllocation.UnmetWork do
  @moduledoc false

  import Ecto.Query

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo

  def read(%Agent{} = agent, %DateTime{} = now) do
    with %{id: generation_id} <- FleetAllocation.active_generation(agent),
         %StrategyDecisionEpisode{selection_kind: :selected_plan} = episode <-
           latest_market_decision(generation_id) do
      candidates =
        for %{"reasons" => ["claim_conflict"], "alternative" => candidate} <-
              episode.alternatives,
            is_map(candidate),
            candidate["kind"] == "market_trade",
            is_list(candidate["dependencies"]) and candidate["dependencies"] != [],
            do: candidate

      current = current_evidence(agent, candidates, now)

      for candidate <- candidates,
          Enum.all?(candidate["dependencies"], fn dependency ->
            MapSet.member?(current, {dependency["subject"], dependency["evidence_id"]})
          end),
          {:ok, as_of} <- [timestamp(candidate["validity"]["as_of"])],
          {:ok, expires_at} <- [timestamp(candidate["validity"]["expires_at"])],
          DateTime.compare(as_of, now) != :gt,
          DateTime.compare(expires_at, now) == :gt do
        %{
          candidate_id: candidate["id"],
          decision_episode_id: episode.id,
          fleet_generation_id: episode.fleet_generation_id,
          strategy_revision_id: episode.fleet_strategy_revision_id,
          objective_index: candidate["objective_index"],
          objective: candidate["objective"],
          source_waypoint: candidate["source_waypoint"],
          destination_waypoint: candidate["destination_waypoint"],
          trade_symbol: candidate["trade_symbol"],
          required_roles: candidate["required_roles"],
          required_capabilities: candidate["required_capabilities"],
          required_resources: candidate["required_resources"],
          expected_outcomes: candidate["expected_outcomes"],
          planned_rate: candidate["expected_outcomes"]["net_credits_per_ship_hour"],
          dependencies: candidate["dependencies"],
          validity: %{
            as_of: as_of,
            expires_at: expires_at,
            conditions: candidate["validity"]["conditions"]
          }
        }
      end
    else
      _ -> []
    end
  end

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, datetime}
      _ -> :error
    end
  end

  defp timestamp(_), do: :error

  defp current_evidence(agent, candidates, now) do
    systems =
      for candidate <- candidates,
          dependency <- candidate["dependencies"],
          "market:" <> tail <- [dependency["subject"]],
          do: hd(String.split(tail, ":"))

    for system <- Enum.uniq(systems),
        market <- Intelligence.market_interpretation(agent, system, now).markets,
        market.state == :current,
        into: MapSet.new(),
        do: {market.subject, market.evidence_id}
  end

  defp latest_market_decision(generation_id) do
    Repo.one(
      from episode in StrategyDecisionEpisode,
        join: strategy in Strategy,
        on:
          strategy.operator_id == episode.operator_id and
            strategy.active_revision_id == episode.fleet_strategy_revision_id,
        where:
          episode.fleet_generation_id == ^generation_id and
            (episode.expectations["domain"] == "market" or
               episode.expectations["producer"] == "fleet_allocation_market_reconciliation"),
        order_by: [desc: episode.id],
        limit: 1
    )
  end
end
