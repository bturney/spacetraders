defmodule SpaceTraders.FleetShadow do
  @moduledoc """
  Evaluates Fleet Planning and Fleet Allocation against governed evidence.

  Shadow evaluation is deterministic and in-memory. It proposes a Fleet
  Commitment portfolio for comparison, but never publishes Claims or dispatches
  gameplay mutations.
  """

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.CapacityGovernor.Disposition
  alias SpaceTraders.{Clock, CreditCalibration, Evidence, Intelligence}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.Revision

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
    |> market_input(system_symbol, decision_time(opts))
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
    |> market_input(system_symbol, decision_time(opts))
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
    with {:ok, planning} <- plan_market(snapshot, revision, availability),
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

  # Planning binds evidence at the application clock. A Capacity Disposition
  # is advisory capacity meaning stamped by the governor's own clock; it never
  # fixes decision time.
  defp decision_time(opts), do: Keyword.get_lazy(opts, :as_of, &Clock.utc_now/0)

  @doc """
  The Fleet Planning Market input for one Agent System at one decision time:
  the shared Operational Intelligence Market interpretation plus the active
  credit calibration margin. Runtime planning, coverage and Strategy review
  all plan from this input.
  """
  def market_input(%AgentRecord{} = agent, system_symbol, %DateTime{} = decision_time)
      when is_binary(system_symbol) do
    agent
    |> Intelligence.market_interpretation(system_symbol, decision_time)
    |> Map.put(:credit_margin_percent, CreditCalibration.active().margin_percent)
  end

  @doc """
  Pure Fleet Planning of Market trade Candidate Contributions for every
  Strategic Objective of `revision`, sized to the trade-capable Claims in
  `availability`. Selects, claims and publishes nothing.
  """
  def plan_market(market_input, %Revision{} = revision, availability)
      when is_map(market_input) and is_map(availability) do
    plan(revision, put_claimable_ships(market_input, availability))
  end

  # Trade quantity is bounded by the holds of Ships the Fleet can actually
  # claim for trading, taken from the same availability Allocation uses so
  # planning and selection cannot disagree. Evidence the caller already
  # supplied is kept.
  defp put_claimable_ships(%{ships: _} = snapshot, _availability), do: snapshot

  defp put_claimable_ships(snapshot, availability) do
    ships =
      availability
      |> Map.get(:claims, [])
      |> Enum.flat_map(fn
        %{resource: symbol, roles: roles, capabilities: %{cargo_transport: capacity}}
        when is_list(roles) and is_integer(capacity) ->
          if :market_trader in roles,
            do: [%{symbol: symbol, cargo: %{capacity: capacity, units: 0}}],
            else: []

        _ ->
          []
      end)

    # No trade-capable Claim leaves sizing at Market depth; Allocation then
    # rejects the Candidate for lack of a capable Claim.
    if ships == [], do: snapshot, else: Map.put(snapshot, :ships, ships)
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
end
