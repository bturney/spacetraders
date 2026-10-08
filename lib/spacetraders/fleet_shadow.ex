defmodule SpaceTraders.FleetShadow do
  @moduledoc """
  Evaluates Fleet Planning and Fleet Allocation against governed evidence.

  Shadow evaluation is deterministic and in-memory. It proposes a Fleet
  Commitment portfolio for comparison, but never publishes Claims or dispatches
  gameplay mutations.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.CapacityGovernor.Disposition
  alias SpaceTraders.Evidence
  alias SpaceTraders.Clock
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Repo

  @doc "Builds a shadow comparison from persisted governed Market evidence."
  def compare_market(
        %AgentRecord{} = agent,
        %Revision{} = revision,
        system_symbol,
        availability,
        %Disposition{} = capacity,
        opts \\ []
      )
      when is_binary(system_symbol) and is_map(availability) and is_list(opts) do
    agent
    |> market_snapshot(system_symbol, decision_time(opts))
    |> compare(revision, availability, capacity, opts)
  end

  @doc """
  Builds a shadow comparison for a not-yet-activated draft document.

  The draft is evaluated with an explicit draft identity, so proposed
  Commitments can never be mistaken for published work. Evaluation is
  deterministic and in-memory: it publishes no Claims and dispatches no
  gameplay.
  """
  def compare_draft_market(
        %AgentRecord{} = agent,
        document,
        system_symbol,
        availability,
        %Disposition{} = capacity,
        opts \\ []
      )
      when is_map(document) and is_binary(system_symbol) and is_map(availability) and
             is_list(opts) do
    agent
    |> market_snapshot(system_symbol, decision_time(opts))
    |> compare(
      %Revision{id: {:draft, agent.id}, document: document},
      availability,
      capacity,
      opts
    )
  end

  @doc "Builds a shadow comparison from one governed evidence and capacity snapshot."
  def compare(snapshot, revision, availability, capacity, opts \\ [])

  def compare(
        snapshot,
        %Revision{} = revision,
        availability,
        %Disposition{} = capacity,
        opts
      )
      when is_map(snapshot) and is_map(availability) and is_list(opts) do
    with {:ok, planning} <- plan(revision, snapshot),
         {:ok, portfolio} <-
           FleetAllocation.select_portfolio(
             revision,
             Enum.flat_map(planning, & &1.candidate_contributions),
             availability,
             Keyword.get(opts, :current_commitments, [])
           ) do
      {:ok,
       %{
         listings_fingerprint: listings_fingerprint(snapshot),
         capacity_status: capacity.status,
         planning: planning,
         proposed_choices: portfolio.commitments,
         alternatives: portfolio.rejected,
         expectations: expectations(portfolio.commitments),
         actual_outcomes: Keyword.get(opts, :actual_outcomes, :unknown),
         decisive_reasons: decisive_reasons(portfolio),
         strategy_decision_episode: episode_comparison(Keyword.get(opts, :episode)),
         source_version: portfolio.source_version
       }}
    end
  end

  def compare(_snapshot, _revision, _availability, _capacity, _opts),
    do: {:error, :invalid_shadow_input}

  @doc "Re-evaluates only when Listings or API pressure have materially changed."
  def replan(previous, snapshot, revision, availability, capacity, opts \\ [])

  def replan(
        previous,
        snapshot,
        %Revision{} = revision,
        availability,
        %Disposition{} = capacity,
        opts
      )
      when is_map(previous) and is_map(snapshot) and is_map(availability) and is_list(opts) do
    case replan_trigger(previous, snapshot, capacity) do
      :unchanged ->
        {:ok, Map.put(previous, :replan_trigger, :unchanged)}

      trigger ->
        with {:ok, comparison} <- compare(snapshot, revision, availability, capacity, opts) do
          {:ok, Map.put(comparison, :replan_trigger, trigger)}
        end
    end
  end

  def replan(_previous, _snapshot, _revision, _availability, _capacity, _opts),
    do: {:error, :invalid_shadow_input}

  # Planning binds evidence at the application clock. A Capacity Disposition
  # is advisory capacity meaning stamped by the governor's own clock; it never
  # fixes decision time.
  defp decision_time(opts), do: Keyword.get_lazy(opts, :as_of, &Clock.utc_now/0)

  defp market_snapshot(agent, system_symbol, as_of) do
    subject_prefix = "market:#{system_symbol}:"

    markets =
      Observation
      |> where([observation], observation.agent_id == ^agent.id)
      |> where([observation], like(observation.subject, ^"#{subject_prefix}%"))
      |> where([observation], observation.observed_at <= ^as_of)
      |> order_by([observation], desc: observation.observed_at, desc: observation.id)
      |> Repo.all()
      |> Enum.uniq_by(& &1.subject)
      |> Enum.map(fn observation ->
        %{
          subject: observation.subject,
          observed_at: observation.observed_at,
          evidence_id: observation.id,
          source: observation.operation_id,
          trade_goods: observation.facts["trade_goods"]
        }
      end)

    # The authoritative Market coverage target is every known Marketplace of
    # the headquarters System, including never-observed ones the retained
    # Listing query cannot see.
    baseline = FleetIntelligence.known_marketplace_subjects(agent, system_symbol, as_of)

    as_of
    |> FleetPlanning.market_snapshot(system_symbol, agent.id, markets)
    |> Map.merge(FleetPlanning.baseline_coverage(baseline))
    |> Map.put(:credit_margin_percent, SpaceTraders.CreditCalibration.active().margin_percent)
  end

  defp plan(revision, snapshot) do
    revision.document
    |> Map.get("objectives", [])
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {_objective, objective_index}, {:ok, planned} ->
      case FleetPlanning.plan_market(revision, objective_index, snapshot) do
        {:ok, result} -> {:cont, {:ok, [result | planned]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, planned} -> {:ok, Enum.reverse(planned)}
      error -> error
    end)
  end

  defp expectations(commitments) do
    %{
      expected_value: Enum.sum_by(commitments, & &1.expected_value),
      commitment_count: length(commitments)
    }
  end

  defp decisive_reasons(portfolio) do
    (portfolio.commitments ++ portfolio.rejected)
    |> Enum.map(&%{candidate_id: &1.candidate_id, reason: &1.decisive_reason})
  end

  defp episode_comparison(nil), do: nil

  defp episode_comparison(%StrategyDecisionEpisode{} = episode) do
    Map.take(episode, [
      :id,
      :evidence_references,
      :alternatives,
      :expectations,
      :classification,
      :calibration_version
    ])
  end

  defp listings_fingerprint(snapshot) do
    snapshot
    |> Map.get(:markets, [])
    |> Enum.map(&Map.take(&1, [:subject, :trade_goods]))
    |> Enum.sort_by(& &1.subject)
    |> Evidence.fingerprint()
  end

  defp replan_trigger(previous, snapshot, capacity) do
    cond do
      previous[:listings_fingerprint] != listings_fingerprint(snapshot) -> :listings_changed
      previous[:capacity_status] != capacity.status -> :capacity_disposition_changed
      true -> :unchanged
    end
  end
end
