defmodule SpaceTraders.FleetGeneration do
  @moduledoc """
  Owns the lifecycle of an Agent and its Fleet across Server Resets.

  AccountTokens cross this module only while dispatching registration. Callers
  identify the authenticated Operator through a tokenless scope; this module
  resolves the corresponding credential reference immediately before minting.
  """

  import Ecto.Changeset, only: [get_field: 2]
  import Ecto.Query, warn: false

  alias SpaceTraders.API.GameplayError
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.API.Model.Agent, as: GameAgent
  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Fleet.{Ship, ShipServer}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.{Evidence, Fleet, FleetStrategy, OperatorConditions, Repo, Timeline}

  defmodule CredentialReference do
    @moduledoc "A non-secret reference to an Operator's stored AccountToken."

    @enforce_keys [:operator_id]
    defstruct [:operator_id]
  end

  @doc "Carries Strategic Objective progress into a replacement Fleet Generation by scope."
  def advance_objective_progress(
        %Revision{id: revision_id, document: %{"objectives" => objectives}},
        %{
          revision_id: revision_id,
          fleet_generation_id: current_generation_id,
          objectives: progress
        },
        next_generation_id
      )
      when is_list(objectives) and is_map(progress) and not is_nil(current_generation_id) and
             not is_nil(next_generation_id) do
    expected_indexes = objectives |> Enum.with_index() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

    if MapSet.new(Map.keys(progress)) == expected_indexes do
      next_progress =
        objectives
        |> Enum.with_index()
        |> Map.new(fn
          {%{"scope" => "strategy_lifetime"}, index} -> {index, Map.fetch!(progress, index)}
          {%{"scope" => "recurring"}, index} -> {index, %{recurrence_id: nil, progress: nil}}
          {_objective, index} -> {index, nil}
        end)

      {:ok,
       %{
         revision_id: revision_id,
         fleet_generation_id: next_generation_id,
         objectives: next_progress
       }}
    else
      {:error, :invalid_objective_progress}
    end
  end

  def advance_objective_progress(_revision, _progress, _next_generation_id),
    do: {:error, :invalid_objective_progress}

  @doc "Mints a new Fleet Generation for the authenticated Operator."
  def mint(%Scope{operator: %Operator{id: operator_id}} = scope, attrs) do
    :global.trans({{__MODULE__, :mint, operator_id}, self()}, fn ->
      result = do_mint(scope, attrs, operator_id)

      case result do
        {:error, :account_token_not_linked} ->
          OperatorConditions.raise(
            scope,
            "replacement-authority",
            :intervention,
            "AccountToken authority is unavailable. Link an AccountToken to mint a Fleet Generation."
          )

        {:error, :replacement_symbols_exhausted} ->
          OperatorConditions.raise(
            scope,
            "replacement-symbols",
            :intervention,
            "Replacement Agent symbols are exhausted. Revise the replacement identity choices."
          )

        {:ok, _} ->
          OperatorConditions.resolve(scope, "replacement-authority")
          OperatorConditions.resolve(scope, "replacement-symbols")

        _ ->
          :ok
      end

      result
    end)
  end

  defp do_mint(scope, attrs, operator_id) do
    changeset = Agent.changeset(%Agent{}, attrs)
    credential_ref = %CredentialReference{operator_id: operator_id}
    replacement_symbols = replacement_symbols(attrs, changeset)
    registration_symbols = registration_symbols(attrs, replacement_symbols)

    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- FleetStrategy.mutation_allowed?(scope),
         :ok <- validate_mint_attrs(changeset),
         :ok <- validate_replacement_symbols(replacement_symbols, get_field(changeset, :faction)),
         {:ok, operator, account_token} <- resolve_account_token(credential_ref),
         :ok <-
           ensure_symbol_is_not_stale_for_another_operator(
             operator,
             replacement_symbols
           ) do
      revision = active_revision(operator.id)

      registration_result =
        SpaceTraders.Observability.with_context(
          [operator_id: operator.id, strategy_revision_id: revision && revision.id],
          fn ->
            register_first_available(
              account_token,
              registration_symbols,
              get_field(changeset, :faction),
              operator.email
            )
          end
        )

      case registration_result do
        {:ok, %{token: agent_token, agent: %GameAgent{}} = registration} ->
          replace_stale_agent_and_create(operator, registration, agent_token,
            faction: get_field(changeset, :faction),
            replacement_symbols: replacement_symbols
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Returns the Operator's Fleet Generation history, newest first."
  def list_generations(%Scope{operator: %Operator{id: operator_id}}) do
    Repo.all(
      from generation in Generation,
        where: generation.operator_id == ^operator_id,
        order_by: [desc: generation.number]
    )
  end

  @doc "Records a verified Objective evaluation for an active Fleet Generation."
  def record_objective_progress(scope, generation_id, index, facts, opts \\ [])

  def record_objective_progress(
        %Scope{operator: %Operator{id: operator_id}} = scope,
        generation_id,
        index,
        facts,
        opts
      )
      when is_integer(generation_id) and is_integer(index) and index >= 0 and is_map(facts) do
    result =
      Repo.transaction(fn ->
        generation =
          Repo.one(
            from g in Generation,
              where:
                g.id == ^generation_id and g.operator_id == ^operator_id and
                  is_nil(g.fenced_at) and is_nil(g.retired_at),
              lock: "FOR UPDATE"
          )

        revision =
          generation && generation.fleet_strategy_revision_id &&
            Repo.get(Revision, generation.fleet_strategy_revision_id)

        evidence = facts["evidence_id"] && Repo.get(Observation, facts["evidence_id"])

        case revision && FleetStrategy.evaluate_persisted_objective(revision, index, facts) do
          {:ok, evaluation} ->
            if objective_evidence_supports?(revision, index, generation, evidence, facts) do
              progress =
                Map.put(
                  generation.objective_progress,
                  Integer.to_string(index),
                  Map.put(facts, "revision_id", revision.id)
                )

              updated =
                generation
                |> Ecto.Changeset.change(objective_progress: progress)
                |> Repo.update!()

              _ =
                OperatorConditions.objective_evaluation(
                  scope,
                  updated,
                  revision,
                  index,
                  evaluation,
                  Keyword.put(opts, :notify?, false)
                )

              updated
            else
              Repo.rollback(:invalid_objective_progress)
            end

          _ ->
            Repo.rollback(:invalid_objective_progress)
        end
      end)

    case result do
      {:ok, generation} ->
        if Keyword.get(opts, :notify?, true), do: OperatorConditions.notify(scope)
        {:ok, generation}

      error ->
        error
    end
  end

  def record_objective_progress(_scope, _generation_id, _index, _facts, _opts),
    do: {:error, :invalid_objective_progress}

  @doc "Persists complete, evidence-bound Objective evaluations carried by ranked plans."
  def record_objective_evaluations(scope, revision, plans, opts \\ [])

  def record_objective_evaluations(%Scope{} = scope, %Revision{} = revision, plans, opts)
      when is_list(plans) do
    generation =
      Repo.one(
        from generation in Generation,
          where:
            generation.operator_id == ^scope.operator.id and
              generation.fleet_strategy_revision_id == ^revision.id and
              is_nil(generation.fenced_at) and is_nil(generation.retired_at),
          order_by: [desc: generation.number],
          limit: 1
      )

    if generation do
      result =
        Enum.reduce_while(plans, :ok, fn plan, :ok ->
          evidence_id =
            Map.get(plan, :objective_evidence_id) || Map.get(plan, "objective_evidence_id")

          evaluations = Map.get(plan, :objective_evaluations, [])

          if evaluations != [] and not is_binary(evidence_id) do
            {:halt, {:error, :objective_evidence_required}}
          else
            plan
            |> Map.get(:objective_evaluations, [])
            |> Enum.with_index()
            |> Enum.reduce_while(:ok, fn {evaluation, index}, :ok ->
              facts =
                %{
                  "change" => evaluation[:change],
                  "current" => evaluation[:current],
                  "elapsed_seconds" => evaluation[:elapsed_seconds],
                  "expected_seconds_to_target" => evaluation[:expected_seconds_to_target],
                  "feasible?" => evaluation[:feasible?],
                  "horizon_seconds" => evaluation[:horizon_seconds],
                  "required_margin" => evaluation[:required_margin],
                  "target" => evaluation[:target]
                }
                |> Enum.reject(fn {_key, value} -> is_nil(value) end)
                |> Map.new()
                |> Map.put("evidence_id", evidence_id)

              if is_binary(evidence_id) do
                case record_objective_progress(scope, generation.id, index, facts, opts) do
                  {:ok, _} -> {:cont, :ok}
                  {:error, reason} -> {:halt, {:error, reason}}
                end
              else
                {:cont, :ok}
              end
            end)
          end
          |> case do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      result
    else
      :ok
    end
  end

  def record_objective_evaluations(_scope, _revision, _plans, _opts), do: :ok

  @doc "Retains current authoritative Agent credits for Objective evidence and recaps."
  def observe_observation(%Agent{operator_id: operator_id}, %Observation{} = evidence)
      when is_integer(operator_id) and evidence.operation_id == "get-my-agent" do
    generation =
      Repo.one(
        from generation in Generation,
          where:
            generation.operator_id == ^operator_id and is_nil(generation.fenced_at) and
              is_nil(generation.retired_at),
          order_by: [desc: generation.number],
          limit: 1
      )

    revision =
      generation && generation.fleet_strategy_revision_id &&
        Repo.get(Revision, generation.fleet_strategy_revision_id)

    objective_index =
      revision &&
        revision.document
        |> Map.get("objectives", [])
        |> Enum.find_index(fn objective ->
          objective["kind"] == "continuous" and objective["objective"] == "Grow credits"
        end)

    credits = get_in(evidence.facts, ["response", "credits"])

    if generation && generation.starting_credits && objective_index && is_integer(credits) &&
         evidence.agent_id == generation.agent_id && Evidence.valid_observation?(evidence) &&
         DateTime.compare(evidence.observed_at, generation.inserted_at) != :lt &&
         DateTime.compare(evidence.observed_at, DateTime.utc_now()) != :gt &&
         DateTime.diff(DateTime.utc_now(), evidence.observed_at, :second) <= 300 do
      {count, _} =
        Repo.update_all(
          from(candidate in Generation,
            where:
              candidate.id == ^generation.id and candidate.operator_id == ^operator_id and
                is_nil(candidate.fenced_at) and is_nil(candidate.retired_at)
          ),
          set: [
            last_observed_credits: credits,
            last_observed_at: evidence.observed_at,
            last_observed_evidence_id: evidence.id,
            updated_at: DateTime.truncate(DateTime.utc_now(), :second)
          ]
        )

      if count == 1, do: :ok
    else
      :ok
    end
  end

  def observe_observation(_agent, _evidence), do: :ok

  @doc false
  def activate_strategy(
        %Scope{operator: %Operator{id: operator_id}} = scope,
        %Revision{id: revision_id} = revision
      ) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(generation in Generation,
        where:
          generation.operator_id == ^operator_id and is_nil(generation.fenced_at) and
            is_nil(generation.retired_at)
      ),
      set: [
        fleet_strategy_revision_id: revision_id,
        objective_progress: generation_progress(revision, nil),
        strategy_capable_at: now,
        updated_at: DateTime.utc_now(:second)
      ]
    )

    Generation
    |> where(
      [generation],
      generation.operator_id == ^operator_id and
        is_nil(generation.fenced_at) and is_nil(generation.retired_at)
    )
    |> select([generation], generation.agent_id)
    |> Repo.all()
    |> Enum.each(&request_intelligence/1)

    active_generation =
      Repo.one(
        from generation in Generation,
          where:
            generation.operator_id == ^operator_id and is_nil(generation.fenced_at) and
              is_nil(generation.retired_at),
          order_by: [desc: generation.number],
          limit: 1
      )

    :ok =
      OperatorConditions.resolve_objective_conditions(
        scope,
        active_generation && active_generation.id,
        revision_id
      )

    :ok
  end

  @doc "Retires every Stale Agent owned by the authenticated Operator."
  def retire_stale_agents(%Scope{operator: %Operator{} = operator}) do
    if detected_stale_agent_ids(operator) == [] do
      {:ok, []}
    else
      {:error, :replacement_required}
    end
  end

  @doc "Retries replacement for every fenced Fleet Generation after mutation admission resumes."
  def replace_stale_agents(%Scope{operator: %Operator{} = operator}) do
    operator
    |> SpaceTraders.Agent.list_agents()
    |> Enum.filter(&stale?/1)
    |> Enum.reduce_while({:ok, []}, fn agent, {:ok, replacements} ->
      case replace_stale_agent(agent) do
        {:ok, replacement} -> {:cont, {:ok, [replacement | replacements]}}
        {:error, :strategy_not_active} -> {:cont, {:ok, replacements}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Pulls an Agent's live game record and records definitive Server Reset evidence."
  def agent_overview(%Agent{agent_token: agent_token} = agent)
      when is_binary(agent_token) and agent_token != "" do
    case Evidence.get_agent(AgentTokenReference.new(agent), lane: :safety) do
      {:error, %SpaceTraders.API.GameplayError{} = error} = result ->
        if server_reset_mismatch?(error) do
          mark_stale_and_replace(agent)
          {:error, :stale_agent}
        else
          result
        end

      result ->
        result
    end
  end

  def agent_overview(%Agent{}), do: {:error, :agent_token_missing}

  @doc "Returns whether the game has verified this Agent as stale after a Server Reset."
  def stale?(%Agent{stale_at: stale_at}), do: not is_nil(stale_at)

  @doc "Fences execution against an Agent retired or invalidated by a Server Reset."
  def execution_allowed?(%Agent{} = agent) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?() do
      agent_execution_allowed?(agent)
    end
  end

  @doc "Converts a reset mismatch from any game call into the durable stale state."
  def handle_game_result(%Agent{} = agent, {:error, error}) do
    if server_reset_mismatch?(error) do
      mark_stale_and_replace(agent)
      {:error, :stale_agent}
    else
      {:error, error}
    end
  end

  def handle_game_result(_agent, result), do: result

  defp resolve_account_token(%CredentialReference{operator_id: operator_id}) do
    case Repo.get(Operator, operator_id) do
      %Operator{account_token: account_token} = operator
      when is_binary(account_token) and account_token != "" ->
        {:ok, operator, account_token}

      _ ->
        {:error, :account_token_not_linked}
    end
  end

  defp validate_mint_attrs(%{valid?: true}), do: :ok
  defp validate_mint_attrs(%{valid?: false} = changeset), do: {:error, changeset}

  defp ensure_symbol_is_not_stale_for_another_operator(%Operator{id: operator_id}, symbols) do
    if Repo.exists?(
         from agent in Agent,
           where:
             agent.symbol in ^symbols and agent.operator_id != ^operator_id and
               not is_nil(agent.stale_at)
       ) do
      {:error, :stale_symbol_owned_elsewhere}
    else
      :ok
    end
  end

  defp replace_stale_agent_and_create(operator, registration, agent_token, opts) do
    game_agent = registration.agent
    faction = Keyword.fetch!(opts, :faction)
    replacement_symbols = Keyword.fetch!(opts, :replacement_symbols)

    with {:ok, {agent, generation, retired_symbols, ship_symbols}} <-
           Repo.transaction(fn ->
             stale_ids = stale_agent_ids(operator, game_agent.symbol)

             predecessors =
               Repo.all(
                 from generation in Generation,
                   where:
                     generation.operator_id == ^operator.id and
                       generation.agent_id in ^stale_ids and is_nil(generation.retired_at),
                   order_by: [desc: generation.number]
               )

             predecessor = List.first(predecessors)

             {retired_symbols, ship_symbols} =
               stale_ids
               |> Enum.map(&retire_stale_agent/1)
               |> Enum.unzip()
               |> then(fn {symbols, ships} -> {List.flatten(symbols), List.flatten(ships)} end)

             case SpaceTraders.Agent.store_agent(operator, game_agent, agent_token, faction) do
               {:ok, agent} ->
                 bootstrap_ships(agent, Map.get(registration, :ships, []))

                 generation =
                   establish_generation!(
                     operator,
                     agent,
                     predecessor,
                     replacement_symbols,
                     faction,
                     game_agent.credits
                   )

                 Enum.each(
                   predecessors,
                   &retire_generation(&1, generation.strategy_capable_at)
                 )

                 {agent, generation, retired_symbols, ship_symbols}

               {:error, changeset} ->
                 changeset
                 |> Ecto.Changeset.delete_change(:agent_token)
                 |> Repo.rollback()
             end
           end) do
      Enum.each(ship_symbols, &ShipServer.stop/1)
      if generation.fleet_strategy_revision_id, do: request_intelligence(agent.id)

      scope = Scope.for_operator(operator)

      :ok =
        OperatorConditions.resolve_objective_conditions(
          scope,
          generation.id,
          generation.fleet_strategy_revision_id
        )

      {:ok, %{agent: %{agent | agent_token: nil}, retired_symbols: retired_symbols}}
    end
  end

  defp objective_evidence_supports?(
         revision,
         index,
         generation,
         evidence,
         facts
       ) do
    objective = revision.document |> Map.get("objectives", []) |> Enum.at(index)

    valid_current_evidence =
      Evidence.valid_observation?(evidence) and evidence.agent_id == generation.agent_id and
        DateTime.compare(evidence.observed_at, generation.inserted_at) != :lt and
        DateTime.compare(evidence.observed_at, DateTime.utc_now()) != :gt and
        DateTime.diff(DateTime.utc_now(), evidence.observed_at, :second) <= 300

    cond do
      not valid_current_evidence ->
        false

      objective["objective"] != "Grow credits" ->
        true

      true ->
        response_credits = get_in(evidence.facts, ["response", "credits"])

        is_integer(generation.starting_credits) and is_integer(response_credits) and
          is_integer(facts["change"]) and
          response_credits - generation.starting_credits == facts["change"]
    end
  end

  defp register_first_available(_account_token, [], _faction, _email),
    do: {:error, :replacement_symbols_exhausted}

  defp register_first_available(account_token, [symbol | rest], faction, email) do
    case SpaceTraders.API.register(account_token, symbol, faction, email) do
      {:error, %GameplayError{code: 4103}} when rest != [] ->
        register_first_available(account_token, rest, faction, email)

      result ->
        result
    end
  end

  defp replacement_symbols(attrs, changeset) do
    symbols = attrs[:replacement_symbols] || attrs["replacement_symbols"]

    symbols =
      if is_list(symbols), do: symbols, else: fallback_symbols(get_field(changeset, :symbol))

    Enum.uniq(symbols)
  end

  defp registration_symbols(attrs, replacement_symbols) do
    if Map.has_key?(attrs, :replacement_symbols) or Map.has_key?(attrs, "replacement_symbols") do
      replacement_symbols
    else
      [hd(replacement_symbols)]
    end
  end

  defp fallback_symbols(symbol) when is_binary(symbol) do
    base = String.slice(symbol, 0, 18)
    Enum.uniq([symbol, base <> "-2", base <> "-3"])
  end

  defp fallback_symbols(symbol), do: [symbol]

  defp validate_replacement_symbols([_ | _] = symbols, faction) do
    if Enum.all?(symbols, fn symbol ->
         Agent.changeset(%Agent{}, %{symbol: symbol, faction: faction}).valid?
       end) do
      :ok
    else
      {:error, :invalid_replacement_symbols}
    end
  end

  defp validate_replacement_symbols(_symbols, _faction),
    do: {:error, :invalid_replacement_symbols}

  defp bootstrap_ships(agent, ships) do
    Enum.each(ships, fn ship ->
      %Ship{}
      |> Ecto.Changeset.change(symbol: ship.symbol, ship_type: "UNKNOWN", agent_id: agent.id)
      |> Ecto.Changeset.validate_required([:symbol, :ship_type, :agent_id])
      |> Repo.insert!(
        on_conflict: [
          set: [agent_id: agent.id, ship_type: "UNKNOWN", updated_at: DateTime.utc_now(:second)]
        ],
        conflict_target: :symbol
      )
    end)
  end

  defp establish_generation!(
         operator,
         agent,
         predecessor,
         replacement_symbols,
         faction,
         starting_credits \\ nil
       ) do
    revision = active_revision(operator.id)
    number = next_generation_number(operator.id)
    now = DateTime.utc_now()

    objective_progress =
      generation_progress(revision, predecessor && predecessor.objective_progress)

    %Generation{}
    |> Generation.changeset(%{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision && revision.id,
      number: number,
      symbol: agent.symbol,
      faction: faction,
      replacement_symbols: %{"symbols" => replacement_symbols},
      objective_progress: objective_progress,
      starting_credits: starting_credits,
      strategy_capable_at: if(revision, do: now)
    })
    |> Repo.insert!()
  end

  defp request_intelligence(agent_id) do
    with %Agent{} = agent <- Repo.get(Agent, agent_id),
         true <-
           Repo.exists?(
             from generation in Generation,
               where:
                 generation.agent_id == ^agent_id and
                   not is_nil(generation.fleet_strategy_revision_id) and
                   is_nil(generation.fenced_at) and is_nil(generation.retired_at)
           ),
         {:ok, system} <- Fleet.system_from_headquarters(agent.headquarters) do
      Phoenix.PubSub.broadcast(
        SpaceTraders.PubSub,
        "fleet_intelligence_evidence",
        {:waypoint_intelligence_observed, agent.id, system}
      )
    end

    :ok
  end

  defp active_revision(operator_id) do
    Repo.one(
      from strategy in Strategy,
        join: revision in Revision,
        on: revision.id == strategy.active_revision_id,
        where: strategy.operator_id == ^operator_id,
        select: revision
    )
  end

  defp next_generation_number(operator_id) do
    (Repo.one(
       from generation in Generation,
         where: generation.operator_id == ^operator_id,
         select: max(generation.number)
     ) || 0) + 1
  end

  defp generation_progress(nil, _prior), do: %{}

  defp generation_progress(%Revision{document: %{"objectives" => objectives}}, prior)
       when is_list(objectives) do
    objectives
    |> Enum.with_index()
    |> Map.new(fn {objective, index} ->
      key = Integer.to_string(index)

      progress =
        case objective["scope"] do
          "strategy_lifetime" -> get_in(prior || %{}, [key])
          "recurring" -> %{"recurrence_id" => nil, "progress" => nil}
          _ -> nil
        end

      {key, progress}
    end)
  end

  defp retire_generation(nil, _retired_at), do: :ok

  defp retire_generation(%Generation{} = generation, retired_at) do
    generation
    |> Ecto.Changeset.change(retired_at: retired_at)
    |> Repo.update!()

    :ok
  end

  defp mark_stale_and_replace(%Agent{} = agent) do
    with {:ok, stale_agent} <- mark_stale(agent) do
      _ = replace_stale_agent(stale_agent)
    end

    :ok
  end

  defp replace_stale_agent(%Agent{} = stale_agent) do
    with %Generation{retired_at: nil, fleet_strategy_revision_id: revision_id} = generation
         when not is_nil(revision_id) <-
           Repo.get_by(Generation, agent_id: stale_agent.id),
         %Operator{} = operator <- Repo.get(Operator, stale_agent.operator_id) do
      symbols = generation.replacement_symbols["symbols"]
      symbols = if is_list(symbols) and symbols != [], do: symbols, else: [stale_agent.symbol]

      mint(Scope.for_operator(operator), %{
        symbol: hd(symbols),
        faction: generation.faction,
        replacement_symbols: symbols
      })
    else
      _ -> {:error, :strategy_not_active}
    end
  end

  defp stale_agent_ids(%Operator{id: operator_id}, symbol) do
    same_symbol_id =
      Repo.one(
        from(agent in Agent,
          where: agent.operator_id == ^operator_id and agent.symbol == ^symbol,
          select: agent.id
        )
      )

    [same_symbol_id | detected_stale_agent_ids(operator_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp detected_stale_agent_ids(%Operator{id: operator_id}),
    do: detected_stale_agent_ids(operator_id)

  defp detected_stale_agent_ids(operator_id) do
    Repo.all(
      from(agent in Agent,
        where: agent.operator_id == ^operator_id and not is_nil(agent.stale_at),
        select: agent.id
      )
    )
  end

  defp retire_stale_agent(stale_agent_id) do
    stale_agent = Repo.get!(Agent, stale_agent_id)
    :ok = SpaceTraders.ShipReservation.release_for_agent!(stale_agent.id)

    ship_symbols =
      Repo.all(from(ship in Ship, where: ship.agent_id == ^stale_agent.id, select: ship.symbol))

    Enum.each(ship_symbols, &Timeline.cancel_events(:ship, &1))
    Repo.delete!(stale_agent)
    {[stale_agent.symbol], ship_symbols}
  end

  defp mark_stale(%Agent{} = agent) do
    :ok = SpaceTraders.FleetGenerationAdmission.fence(agent.agent_token)

    Repo.transaction(fn ->
      now = DateTime.utc_now()
      ensure_generation_for_agent!(agent)

      stale_agent =
        agent
        |> Ecto.Changeset.change(stale_at: DateTime.truncate(now, :second))
        |> Repo.update!()

      Repo.update_all(
        from(generation in Generation,
          where: generation.agent_id == ^agent.id and is_nil(generation.fenced_at)
        ),
        set: [fenced_at: now, updated_at: DateTime.truncate(now, :second)]
      )

      stale_agent
    end)
  end

  defp ensure_generation_for_agent!(%Agent{id: agent_id, operator_id: operator_id} = agent)
       when is_integer(operator_id) do
    Repo.get_by(Generation, agent_id: agent_id) ||
      establish_generation!(
        Repo.get!(Operator, operator_id),
        agent,
        nil,
        [agent.symbol],
        agent.faction
      )
  end

  defp ensure_generation_for_agent!(%Agent{}), do: nil

  defp agent_execution_allowed?(%Agent{id: nil}), do: :ok

  defp agent_execution_allowed?(%Agent{id: id}) do
    case Repo.get(Agent, id) do
      %Agent{stale_at: nil} -> :ok
      _ -> {:error, :stale_agent}
    end
  end

  defp server_reset_mismatch?(%SpaceTraders.API.GameplayError{message: message}) do
    Regex.match?(
      ~r/^Failed to parse token\. Token reset_date does not match the server\. Server resets happen .+ After a reset, you should re-register your agent\. Expected: \d{4}-\d{2}-\d{2}, Actual: \d{4}-\d{2}-\d{2}$/,
      message
    )
  end

  defp server_reset_mismatch?(_error), do: false
end
