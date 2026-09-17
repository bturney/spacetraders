defmodule SpaceTraders.FleetPlanning do
  @moduledoc """
  Deterministically proposes evidence-bound Candidate Contributions.

  Planning is pure: it describes required resources and Observation Demands but
  never claims resources, creates execution work, or invokes gameplay.
  """

  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Demand
  alias SpaceTraders.FleetStrategy.Revision

  defmodule CandidateContribution do
    @moduledoc "An objective-specific proposal that Fleet Allocation may accept or reject."

    @enforce_keys [
      :id,
      :strategy_revision_id,
      :objective_index,
      :objective,
      :kind,
      :trade_symbol,
      :source_waypoint,
      :destination_waypoint,
      :expected_outcomes,
      :uncertainty,
      :required_roles,
      :required_capabilities,
      :required_resources,
      :dependencies,
      :validity,
      :alternatives
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{}
  end

  @doc """
  Proposes Market Candidate Contributions for one Strategic Objective.

  The snapshot fixes the decision time with `:as_of` and supplies
  `:freshness_seconds` plus a list of Markets. Each Market has an evidence
  `:subject`, `:observed_at`, and `:trade_goods`. Optional `:agent_id` and
  `:demand_deadline_seconds` values are copied into proposed Observation
  Demands. The function performs no persistence or gameplay calls.
  """
  def plan_market(%Revision{} = revision, objective_index, snapshot)
      when is_integer(objective_index) and objective_index >= 0 and is_map(snapshot) do
    with {:ok, objective} <- objective_at(revision, objective_index),
         {:ok, normalized} <- normalize_snapshot(snapshot) do
      if market_objective?(objective) do
        plan_market_objective(revision, objective_index, objective, normalized)
      else
        {:ok,
         result(revision, objective_index, normalized,
           limitations: [%{subject: :market_planning, reason: :unsupported_market_objective}]
         )}
      end
    end
  end

  def plan_market(%Revision{}, _objective_index, _snapshot),
    do: {:error, :invalid_market_planning_input}

  defp plan_market_objective(revision, objective_index, objective, snapshot) do
    {markets, demands, limitations} = classify_markets(revision, objective_index, snapshot)

    candidates =
      markets
      |> candidate_routes(revision, objective_index, objective, snapshot)
      |> add_alternatives()

    limitations =
      if candidates == [] and limitations == [] do
        [%{subject: :market_planning, reason: :no_viable_market_routes}]
      else
        limitations
      end

    {:ok,
     result(revision, objective_index, snapshot,
       candidate_contributions: candidates,
       observation_demands: demands,
       limitations: limitations
     )}
  end

  defp result(revision, objective_index, snapshot, overrides) do
    Map.merge(
      %{
        strategy_revision_id: revision.id,
        objective_index: objective_index,
        evidence_as_of: snapshot.as_of,
        candidate_contributions: [],
        observation_demands: [],
        limitations: []
      },
      Map.new(overrides)
    )
  end

  defp objective_at(%Revision{document: %{"objectives" => objectives}}, objective_index)
       when is_list(objectives) do
    case Enum.fetch(objectives, objective_index) do
      {:ok, objective} when is_map(objective) -> {:ok, objective}
      _ -> {:error, :objective_not_found}
    end
  end

  defp objective_at(_revision, _objective_index), do: {:error, :objective_not_found}

  defp normalize_snapshot(
         %{
           as_of: %DateTime{} = as_of,
           freshness_seconds: freshness_seconds,
           markets: markets
         } = snapshot
       )
       when is_integer(freshness_seconds) and freshness_seconds >= 0 and is_list(markets) do
    demand_deadline_seconds = Map.get(snapshot, :demand_deadline_seconds, 60)

    if is_integer(demand_deadline_seconds) and demand_deadline_seconds >= 0 and
         Enum.all?(markets, &(valid_market_subject?(market_subject(&1)) and is_map(&1))) do
      {:ok,
       %{
         as_of: as_of,
         freshness_seconds: freshness_seconds,
         demand_deadline_seconds: demand_deadline_seconds,
         agent_id: Map.get(snapshot, :agent_id),
         markets: normalize_market_observations(markets)
       }}
    else
      {:error, :invalid_market_planning_input}
    end
  end

  defp normalize_snapshot(_snapshot), do: {:error, :invalid_market_planning_input}

  defp normalize_market_observations(markets) do
    markets
    |> Enum.group_by(&market_subject/1)
    |> Enum.map(fn {_subject, observations} ->
      Enum.max_by(observations, fn observation ->
        {observed_at_sort_value(observation), Evidence.fingerprint(observation)}
      end)
    end)
    |> Enum.sort_by(&market_subject/1)
  end

  defp observed_at_sort_value(%{observed_at: %DateTime{} = observed_at}),
    do: DateTime.to_unix(observed_at, :microsecond)

  defp observed_at_sort_value(_observation), do: -1

  defp classify_markets(revision, objective_index, snapshot) do
    snapshot.markets
    |> Enum.reduce({[], [], []}, fn market, {markets, demands, limitations} ->
      subject = market_subject(market)

      case usable_market(market, snapshot) do
        {:ok, market} ->
          {[market | markets], demands, limitations}

        {:error, reason} ->
          demand = observation_demand(revision, objective_index, snapshot, subject)
          limitation = %{subject: subject, reason: reason}
          {markets, [demand | demands], [limitation | limitations]}
      end
    end)
    |> then(fn {markets, demands, limitations} ->
      {
        Enum.sort_by(markets, &{&1.subject, &1.observed_at}),
        demands |> Enum.uniq_by(& &1.subject) |> Enum.sort_by(& &1.subject),
        limitations
        |> Enum.uniq_by(&{&1.subject, &1.reason})
        |> Enum.sort_by(&{&1.subject, &1.reason})
      }
    end)
  end

  defp usable_market(
         %{observed_at: %DateTime{} = observed_at, trade_goods: trade_goods} = market,
         snapshot
       )
       when is_list(trade_goods) do
    age = DateTime.diff(snapshot.as_of, observed_at, :second)
    goods = trade_goods |> Enum.map(&normalize_good/1) |> Enum.filter(&valid_good?/1)

    cond do
      age < 0 ->
        {:error, :inconsistent_market_evidence}

      value(market, :state) == :stale ->
        {:error, :stale_market_evidence}

      age > snapshot.freshness_seconds ->
        {:error, :stale_market_evidence}

      length(goods) != length(trade_goods) ->
        {:error, :insufficient_market_evidence}

      not valid_provenance?(market) ->
        {:error, :insufficient_market_evidence}

      true ->
        {:ok,
         %{
           subject: market_subject(market),
           waypoint: waypoint_from_subject(market_subject(market)),
           observed_at: observed_at,
           evidence_age_seconds: age,
           evidence_id: value(market, :evidence_id),
           source: value(market, :source),
           trade_goods: Enum.sort_by(goods, &good_key/1)
         }}
    end
  end

  defp usable_market(_market, _snapshot), do: {:error, :insufficient_market_evidence}

  defp normalize_good(good) when is_map(good) do
    %{
      symbol: value(good, :symbol),
      purchase_price: value(good, :purchase_price),
      sell_price: value(good, :sell_price),
      trade_volume: value(good, :trade_volume),
      supply: value(good, :supply),
      activity: value(good, :activity)
    }
  end

  defp normalize_good(_good), do: %{}

  defp valid_good?(good) do
    is_binary(good[:symbol]) and is_integer(good[:purchase_price]) and
      good.purchase_price >= 0 and is_integer(good[:sell_price]) and good.sell_price >= 0 and
      is_integer(good[:trade_volume]) and good.trade_volume > 0
  end

  defp candidate_routes(markets, revision, objective_index, objective, snapshot) do
    candidates =
      for source <- markets,
          destination <- markets,
          source.subject != destination.subject,
          source_good <- source.trade_goods,
          destination_good <- destination.trade_goods,
          source_good.symbol == destination_good.symbol,
          destination_good.sell_price > source_good.purchase_price do
        contribution(
          revision,
          objective_index,
          objective,
          source,
          source_good,
          destination,
          destination_good,
          snapshot
        )
      end

    candidates
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(fn candidate ->
      {
        -candidate.expected_outcomes.maximum_credit_change,
        -candidate.expected_outcomes.credit_change_per_unit,
        candidate.source_waypoint,
        candidate.destination_waypoint,
        candidate.trade_symbol,
        candidate.id
      }
    end)
  end

  defp contribution(
         revision,
         objective_index,
         objective,
         source,
         source_good,
         destination,
         destination_good,
         snapshot
       ) do
    units = min(source_good.trade_volume, destination_good.trade_volume)
    spread = destination_good.sell_price - source_good.purchase_price

    expected_outcomes = %{
      credit_change_per_unit: spread,
      maximum_credit_change: spread * units,
      maximum_units: units
    }

    dependencies =
      [dependency(source, snapshot), dependency(destination, snapshot)]
      |> Enum.sort_by(& &1.subject)

    required_resources = %{
      credits: source_good.purchase_price * units,
      cargo_capacity: units,
      ship_count: 1
    }

    identity = %{
      strategy_revision_id: revision.id,
      objective_index: objective_index,
      trade_symbol: source_good.symbol,
      source: source.subject,
      destination: destination.subject,
      expected_outcomes: expected_outcomes,
      required_resources: required_resources,
      dependencies: dependencies
    }

    %CandidateContribution{
      id: Evidence.fingerprint(identity),
      strategy_revision_id: revision.id,
      objective_index: objective_index,
      objective: objective,
      kind: :market_trade,
      trade_symbol: source_good.symbol,
      source_waypoint: source.waypoint,
      destination_waypoint: destination.waypoint,
      expected_outcomes: expected_outcomes,
      uncertainty: %{
        source_evidence_age_seconds: source.evidence_age_seconds,
        destination_evidence_age_seconds: destination.evidence_age_seconds,
        source_market_signal: market_signal(source_good),
        destination_market_signal: market_signal(destination_good),
        unaccounted_costs: [:fuel, :travel_time]
      },
      required_roles: [%{role: :market_trader, count: 1}],
      required_capabilities: [
        %{capability: :cargo_transport, minimum_capacity: units},
        %{
          capability: :market_access,
          waypoints: Enum.sort([source.waypoint, destination.waypoint])
        }
      ],
      required_resources: required_resources,
      dependencies: dependencies,
      validity: %{
        as_of: snapshot.as_of,
        expires_at: Enum.min_by(dependencies, & &1.valid_until, DateTime).valid_until,
        conditions: [
          %{fact: :source_purchase_price, operator: :equals, value: source_good.purchase_price},
          %{fact: :destination_sell_price, operator: :equals, value: destination_good.sell_price},
          %{fact: :positive_spread, operator: :greater_than, value: 0}
        ]
      },
      alternatives: []
    }
  end

  defp dependency(market, snapshot) do
    %{
      subject: market.subject,
      required_facts: ["trade_goods"],
      observed_at: market.observed_at,
      evidence_id: market.evidence_id,
      source: market.source,
      freshness_seconds: snapshot.freshness_seconds,
      valid_until: DateTime.add(market.observed_at, snapshot.freshness_seconds, :second)
    }
  end

  defp observation_demand(revision, objective_index, snapshot, subject) do
    %Demand{
      subject: subject,
      required_facts: ["trade_goods"],
      owner: "fleet_planning",
      deadline_at: DateTime.add(snapshot.as_of, snapshot.demand_deadline_seconds, :second),
      freshness_seconds: snapshot.freshness_seconds,
      agent_id: snapshot.agent_id,
      strategy_revision_id: revision.id,
      strategic_priority: objective_index,
      expected_value: nil,
      discovery: false
    }
  end

  defp add_alternatives(candidates) do
    alternatives = Map.new(candidates, &{&1.id, alternative(&1)})

    Enum.map(candidates, fn candidate ->
      candidate_alternatives =
        candidates
        |> Enum.reject(&(&1.id == candidate.id))
        |> Enum.map(&Map.fetch!(alternatives, &1.id))

      %{candidate | alternatives: candidate_alternatives}
    end)
  end

  defp alternative(candidate) do
    Map.take(candidate, [
      :id,
      :trade_symbol,
      :source_waypoint,
      :destination_waypoint,
      :expected_outcomes
    ])
  end

  defp market_signal(good) do
    %{supply: good.supply, activity: good.activity, trade_volume: good.trade_volume}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp valid_provenance?(market) do
    is_binary(value(market, :evidence_id)) and value(market, :evidence_id) != "" and
      is_binary(value(market, :source)) and value(market, :source) != ""
  end

  defp market_objective?(%{"kind" => "continuous"} = objective) do
    [objective["objective"], objective["evaluation"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&Regex.match?(~r/\bcredits?\b/i, &1))
  end

  defp market_objective?(_objective), do: false

  defp good_key(good) do
    {good.symbol, good.purchase_price, good.sell_price, good.trade_volume, good.supply,
     good.activity}
  end

  defp market_subject(market) when is_map(market) do
    value(market, :subject) || ""
  end

  defp market_subject(_market), do: ""

  defp valid_market_subject?(subject) do
    case String.split(subject, ":") do
      ["market", system, waypoint] -> system != "" and waypoint != ""
      _ -> false
    end
  end

  defp waypoint_from_subject(subject), do: subject |> String.split(":") |> List.last()
end
