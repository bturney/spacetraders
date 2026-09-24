defmodule SpaceTraders.World do
  @moduledoc """
  Read-only projection of acquired Operational Intelligence.

  A Waypoint's known existence is independent of the freshness of its mutable
  facts. Reading this projection never schedules or performs game traffic.
  """

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence

  @doc "Returns retained facts for a subject with explicit freshness and provenance."
  def intelligence(%AgentRecord{} = agent, type, system, symbol, as_of, freshness_seconds)
      when type in [:waypoint, :market, :shipyard] and is_binary(system) and
             is_binary(symbol) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    facts = Intelligence.subject(agent, type, system, symbol)

    %{
      subject: {type, system, symbol},
      known_existence?: known_existence?(facts),
      facts:
        Map.new(facts, fn {field, fact} -> {field, project(fact, as_of, freshness_seconds)} end)
    }
  end

  defp known_existence?(facts) do
    case facts["symbol"] do
      %{state: "known", value: symbol} when is_binary(symbol) and symbol != "" -> true
      _ -> false
    end
  end

  defp project(fact, as_of, freshness_seconds) do
    observation = fact.observation
    age = DateTime.diff(as_of, observation.observed_at, :second)

    %{
      state: fact.state,
      value: if(fact.state == "known", do: fact.value),
      freshness: if(age >= 0 and age <= freshness_seconds, do: :fresh, else: :stale),
      observed_at: observation.observed_at,
      source: observation.source,
      observing_ship_symbol: observation.observing_ship_symbol
    }
  end
end
