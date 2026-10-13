defmodule SpaceTraders.FleetGeneration do
  @moduledoc """
  Owns the lifecycle of an Agent and its Fleet across Server Resets.

  AccountTokens cross this module only while dispatching registration. Callers
  identify the authenticated Operator through a tokenless scope; this module
  resolves the corresponding credential reference immediately before minting.
  """

  require Logger

  import Ecto.Changeset, only: [get_field: 2]
  import Ecto.Query, warn: false

  alias SpaceTraders.API.GameplayError
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.API.Model.Agent, as: GameAgent
  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Fleet.{Ship, ShipServer}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetGeneration.Identity
  alias SpaceTraders.FleetGeneration.Registration
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  alias SpaceTraders.{
    Clock,
    Evidence,
    Fleet,
    FleetAllocation,
    FleetStrategy,
    MutationAttempts,
    OperatorConditions,
    Repo,
    Timeline
  }

  defmodule CredentialReference do
    @moduledoc "A non-secret reference to an Operator's stored AccountToken."

    @enforce_keys [:operator_id]
    defstruct [:operator_id]
  end

  @doc "Adopts an unambiguous installation without modifying credentials or history."
  defdelegate adopt_current_fleet(), to: Identity, as: :adopt

  @doc "Resolves the durable deployment Operator, Agent and Generation, without secrets."
  defdelegate current_fleet(), to: Identity, as: :current

  @doc "Whether an Agent's credential carries new gameplay authority: only the current Generation's."
  defdelegate gameplay_authority(agent_id), to: Identity

  @doc """
  Read-only access to the evidence a retained Agent holds, with its original
  Generation. Confers no gameplay authority and never reports itself current.
  """
  def evidence_holder(agent_id) when is_integer(agent_id) do
    case Repo.get(Agent, agent_id) do
      %Agent{} = agent ->
        {:ok,
         %{
           agent: %{agent | agent_token: nil},
           generation: Repo.get_by(Generation, agent_id: agent.id)
         }}

      nil ->
        :error
    end
  end

  @doc "Resolves current identity only for its authenticated deployment Operator."
  def current_fleet(%Scope{operator: %Operator{id: operator_id}}) do
    with {:ok, identity} <- current_fleet() do
      if identity.operator && identity.operator.id == operator_id,
        do: {:ok, identity},
        else:
          {:error,
           %{
             reason: :not_deployment_operator,
             summary: "Sign in as the deployment Operator to access the current Fleet."
           }}
    end
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

  @doc """
  Mints the initial or replacement Fleet Generation for the authenticated Operator.

  Establishment is serialized in PostgreSQL before registration is dispatched:
  a competing mint or import waits, then observes the committed current Fleet
  rather than sending a second registration.

  Each step commits through the registration's MutationAttempt (ADR 0011). A
  lost response leaves it unresolved, which suppresses every further
  registration, import and candidate until it is reconciled. A proven success
  whose local adoption was interrupted is adopted here instead of minting.
  """
  def mint(%Scope{} = scope, attrs),
    do: establish_by_registration(scope, attrs, [:empty], :initial)

  @doc """
  Replaces the current Agent after definitive Server Reset evidence fenced it.

  Requests the predecessor's symbol and faction first, then the remaining
  distinct Agent Name Bank names in order. Only a definitive name conflict
  advances to the next name. Any other outcome stops at that candidate, and an
  uncertain one is left to registration recovery, which this resumes instead
  of minting again. The predecessor Agent, its Ships and its Generation are
  retained as history; the replacement is a distinct Generation carrying the
  accepted Fleet Strategy forward.

  Returns `{:error, :no_server_reset}` unless the current Fleet is a fenced
  Server Reset predecessor. Lifecycle for later voluntary replacement: a
  caller that fences its own predecessor can reuse `establish_by_registration/4`.
  """
  def replace_after_reset(%Scope{} = scope) do
    with {:ok, identity} <- current_fleet(scope),
         {:ok, attrs} <- server_reset_replacement(identity) do
      establish_by_registration(scope, attrs, [:transition], :server_reset)
    end
  end

  @doc """
  Resumes an interrupted Server Reset replacement after application restart.

  A fenced predecessor whose replacement never committed is replaced, or its
  proven registration adopted, under the same establishment authority as any
  other wakeup. Anything else is left untouched.
  """
  def resume_reset_replacement do
    case current_fleet() do
      {:ok, %{state: :transition, operator: %Operator{} = operator}} ->
        replace_after_reset(Scope.for_operator(operator))

      _ ->
        {:error, :no_server_reset}
    end
  end

  defp server_reset_replacement(%{
         state: :transition,
         generation: %Generation{fenced_at: %DateTime{}, retired_at: nil} = generation,
         agent: %Agent{stale_at: %DateTime{}} = agent
       }) do
    faction = generation.faction || agent.faction
    symbol = generation.symbol || agent.symbol

    # Banked names are preferences; one the registration contract would refuse
    # is never submitted.
    banked =
      Enum.filter(SpaceTraders.AgentNameBank.list(), fn name ->
        Agent.changeset(%Agent{}, %{symbol: name, faction: faction}).valid?
      end)

    {:ok, %{symbol: symbol, faction: faction, replacement_symbols: Enum.uniq([symbol | banked])}}
  end

  defp server_reset_replacement(_identity), do: {:error, :no_server_reset}

  defp establish_by_registration(
         %Scope{operator: %Operator{id: operator_id}} = scope,
         attrs,
         states,
         kind
       ) do
    # Controls and validation fail before queueing for the establishment
    # authority; they are checked again once it is held.
    result =
      with :ok <- validate_registration(scope, attrs),
           {:ok, _identity} <- current_fleet(scope) do
        Registration.with_authority(fn ->
          mint_with_authority(scope, attrs, operator_id, states)
        end)
        |> finish_establishment(scope)
      end

    :ok = sync_replacement_conditions(scope, kind, result)
    sync_registration_condition(scope)
    result
  end

  @replacement_handled [
    :account_token_not_linked,
    :replacement_symbols_exhausted,
    :registration_unresolved,
    :emergency_stopped,
    :current_fleet_exists,
    :no_server_reset
  ]

  defp sync_replacement_conditions(scope, kind, result) do
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
          "Every replacement name was definitively taken. Edit the Agent Name Bank in Settings, then retry replacement from Mission Control."
        )

      {:error, reason} when kind == :server_reset and reason not in @replacement_handled ->
        OperatorConditions.raise(
          scope,
          "server-reset-replacement",
          :intervention,
          "Server Reset replacement stopped: the game refused registration or local adoption failed. " <>
            "The predecessor stays fenced. Retry replacement from Mission Control."
        )

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  The durable registration recovery state for the authenticated Operator,
  without credentials: `:clear`, `:in_progress`, `:unresolved` or
  `:awaiting_adoption`, with the attempted symbol and an actionable summary.
  """
  def registration_recovery(%Scope{operator: %Operator{id: operator_id}}) do
    operator_id |> Registration.recovery() |> Map.delete(:attempt)
  end

  @doc """
  Resumes registration recovery from authoritative evidence, without registering.

  A proven registration awaiting local adoption is adopted
  (`{:ok, :adopted}`). An unresolved one is settled only when the public Agent
  read proves the symbol unregistered (`{:ok, :clear}`). Otherwise it remains
  `{:error, :registration_unresolved}`.
  """
  def reconcile_registration(%Scope{operator: %Operator{id: operator_id}} = scope) do
    result =
      with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
           {:ok, _identity} <- current_fleet(scope) do
        Registration.with_authority(fn ->
          case Registration.recovery(operator_id, authority: true) do
            %{status: :clear} ->
              {:ok, :clear}

            %{status: :awaiting_adoption, attempt: attempt} ->
              with {:ok, _} <-
                     scope |> adopt_registration(attempt) |> finish_establishment(scope),
                   do: {:ok, :adopted}

            %{status: :unresolved, attempt: attempt} ->
              with {:ok, :absent} <- Registration.reconcile_from_public_read(attempt),
                   do: {:ok, :clear}
          end
        end)
      end

    sync_registration_condition(scope)
    result
  end

  @doc """
  Adopts the Agent of this deployment's own unresolved registration from its
  AgentToken, confirmed by the Operator.

  This is recovery, not import. The token must authenticate as the exact
  symbol the unresolved attempt registered. There must be no current Fleet.
  Any other token returns `{:error, :registration_identity_mismatch}`, and no
  outstanding registration returns `{:error, :no_registration_to_recover}`.
  """
  def adopt_registered_agent(scope, agent_token, confirmed)

  def adopt_registered_agent(
        %Scope{operator: %Operator{id: operator_id}} = scope,
        agent_token,
        true
      )
      when is_binary(agent_token) and agent_token != "" do
    result =
      with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
           {:ok, _identity} <- current_fleet(scope) do
        Registration.with_authority(fn ->
          with {:ok, _state} <- locked_state(operator_id, [:empty, :transition]) do
            case Registration.recovery(operator_id, authority: true) do
              %{status: :clear} ->
                {:error, :no_registration_to_recover}

              %{status: :awaiting_adoption, attempt: attempt} ->
                scope |> adopt_registration(attempt) |> finish_establishment(scope)

              %{status: :unresolved, attempt: attempt} ->
                with {:ok, %GameAgent{} = game_agent} <-
                       import_read(agent_token, &Evidence.get_agent/1),
                     :ok <- Registration.intended_identity(attempt, game_agent),
                     {:ok, ships} when is_list(ships) <-
                       import_read(agent_token, &Evidence.get_ships/1),
                     {:ok, accepted} <-
                       Registration.reconcile_from_agent_token(
                         attempt,
                         agent_token,
                         game_agent,
                         ships
                       ) do
                  scope |> adopt_registration(accepted) |> finish_establishment(scope)
                end
            end
          end
        end)
      end

    sync_registration_condition(scope)
    result
  end

  def adopt_registered_agent(_scope, _agent_token, false), do: {:error, :confirmation_required}

  def adopt_registered_agent(_scope, _agent_token, _confirmed),
    do: {:error, :agent_token_required}

  @doc """
  Establishes an existing upstream Agent as the initial current Fleet.

  The AccountToken cannot recover AgentTokens, so this never registers. The
  AgentToken is validated by authoritative reads under the same establishment
  authority as minting. Import is initial setup only: it never replaces a
  current or fenced Fleet, and never runs while a registration is unresolved.
  """
  def import_agent(%Scope{operator: %Operator{id: operator_id}} = scope, agent_token, true)
      when is_binary(agent_token) and agent_token != "" do
    scope
    |> establish([:empty], fn ->
      case Registration.recovery(operator_id, authority: true) do
        %{status: :clear} -> do_import(scope, agent_token)
        _pending -> {:error, :registration_unresolved}
      end
    end)
    |> finish_establishment(scope)
    |> case do
      {:ok, %{agent: agent}} -> {:ok, agent}
      error -> error
    end
  end

  def import_agent(_scope, _agent_token, false), do: {:error, :confirmation_required}
  def import_agent(_scope, _agent_token, _confirmed), do: {:error, :agent_token_required}

  # Lazy legacy adoption runs before the authority, so a reader's adoption
  # table locks are never requested while an establishment is held.
  defp establish(%Scope{operator: %Operator{id: operator_id}} = scope, states, fun) do
    with {:ok, _identity} <- current_fleet(scope) do
      Registration.with_authority(fn -> locked(operator_id, states, fn _state -> fun.() end) end)
    end
  end

  # One establishment step: the Operator row, a state allowlist, then `fun`.
  defp locked(operator_id, states, fun) do
    Repo.transaction(fn ->
      case Identity.lock_establishment(operator_id) do
        {:ok, %{state: state}} ->
          if state in states do
            case fun.(state) do
              {:ok, established} -> established
              {:error, reason} -> Repo.rollback(reason)
            end
          else
            Repo.rollback(establishment_unavailable(state))
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp locked_state(operator_id, states),
    do: locked(operator_id, states, fn state -> {:ok, state} end)

  defp establishment_unavailable(:current), do: :current_fleet_exists
  defp establishment_unavailable(:transition), do: :fleet_transition_pending

  # Holds the establishment authority. Every step commits on its own.
  defp mint_with_authority(scope, attrs, operator_id, states) do
    with {:ok, _state} <- locked_state(operator_id, states) do
      case Registration.recovery(operator_id, authority: true) do
        %{status: :clear} -> register(scope, attrs, operator_id)
        %{status: :awaiting_adoption, attempt: attempt} -> adopt_registration(scope, attempt)
        %{status: :unresolved} -> {:error, :registration_unresolved}
      end
    end
  end

  # Adopts a proven registration from its own attempt, never from memory, so
  # an interrupted mint and its restart take the same path.
  defp adopt_registration(%Scope{operator: %Operator{id: operator_id}} = scope, attempt) do
    locked(operator_id, [:empty, :transition], fn _state ->
      with {:ok, current} <- Registration.lock_awaiting_adoption(attempt) do
        identity = Registration.registered_identity(current)

        case replace_stale_agent_and_create(
               Repo.get!(Operator, operator_id),
               %{agent: identity.agent, ships: identity.ships},
               identity.token,
               faction: identity.faction,
               replacement_symbols: identity.replacement_symbols
             ) do
          {:ok, {agent, generation, _retired, _ships}} = established ->
            :ok = MutationAttempts.record_registration_adoption(current, agent.id, generation.id)

            # Recovery and ordinary replacement publish the same success. Resolve
            # prior failures in that commit so an interrupted notification cannot
            # leave a healthy successor presented as exhausted or unadopted.
            for key <- [
                  "replacement-authority",
                  "replacement-symbols",
                  "server-reset-replacement",
                  "registration-recovery"
                ] do
              :ok = OperatorConditions.resolve(scope, key, notify?: false)
            end

            established

          error ->
            error
        end
      end
    end)
  end

  defp sync_registration_condition(%Scope{operator: %Operator{id: operator_id}} = scope) do
    case Registration.recovery(operator_id) do
      %{status: status, summary: summary} when status in [:unresolved, :awaiting_adoption] ->
        _ = OperatorConditions.raise(scope, "registration-recovery", :intervention, summary)

      _clear_or_in_progress ->
        OperatorConditions.resolve(scope, "registration-recovery")
    end

    :ok
  end

  # Side effects only after commit: no consumer can observe an uncommitted Agent.
  defp finish_establishment({:ok, {agent, generation, retired_symbols, ship_symbols}}, scope) do
    Enum.each(ship_symbols, &ShipServer.stop/1)
    if generation.fleet_strategy_revision_id, do: _ = request_intelligence(agent)
    :ok = OperatorConditions.notify(scope)

    :ok =
      OperatorConditions.resolve_objective_conditions(
        scope,
        generation.id,
        generation.fleet_strategy_revision_id
      )

    {:ok, %{agent: %{agent | agent_token: nil}, retired_symbols: retired_symbols}}
  end

  defp finish_establishment(error, _scope), do: error

  defp do_import(%Scope{operator: %Operator{id: operator_id}}, agent_token) do
    operator = Repo.get!(Operator, operator_id)

    with {:ok, %GameAgent{} = game_agent} <- import_read(agent_token, &Evidence.get_agent/1),
         {:ok, ships} when is_list(ships) <- import_read(agent_token, &Evidence.get_ships/1),
         :ok <- ensure_agent_is_new(game_agent.symbol),
         {:ok, agent} <- store_imported_agent(operator, game_agent, agent_token) do
      bootstrap_ships(agent, ships)

      generation =
        establish_generation!(
          operator,
          agent,
          nil,
          [agent.symbol],
          agent.faction,
          game_agent.credits
        )

      :ok = Identity.publish_generation!(operator.id, generation.id)
      {:ok, {agent, generation, [], []}}
    end
  end

  # A temporary reference is consumed by its one request.
  defp import_read(agent_token, read) do
    credential_ref = AgentTokenReference.temporary(agent_token)

    try do
      read.(credential_ref)
    after
      AgentTokenReference.release(credential_ref)
    end
  end

  defp ensure_agent_is_new(symbol) do
    if Repo.exists?(from agent in Agent, where: agent.symbol == ^symbol),
      do: {:error, :agent_already_imported},
      else: :ok
  end

  defp store_imported_agent(operator, game_agent, agent_token) do
    case SpaceTraders.Agent.store_agent(
           operator,
           game_agent,
           agent_token,
           game_agent.starting_faction
         ) do
      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :symbol),
          do: {:error, :agent_already_imported},
          else: {:error, Ecto.Changeset.delete_change(changeset, :agent_token)}

      {:ok, _agent} = result ->
        result
    end
  end

  defp validate_registration(scope, attrs) do
    changeset = Agent.changeset(%Agent{}, attrs)

    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- FleetStrategy.mutation_allowed?(scope),
         :ok <- validate_mint_attrs(changeset) do
      validate_replacement_symbols(
        replacement_symbols(attrs, changeset),
        get_field(changeset, :faction)
      )
    end
  end

  defp prepare_mint(scope, attrs, operator_id) do
    changeset = Agent.changeset(%Agent{}, attrs)
    replacement_symbols = replacement_symbols(attrs, changeset)
    faction = get_field(changeset, :faction)

    # Mint authority is needed only for a new request. A proven registration
    # awaiting adoption already holds its own encrypted AgentToken.
    with :ok <- validate_registration(scope, attrs),
         {:ok, operator, account_token} <-
           resolve_account_token(%CredentialReference{operator_id: operator_id}),
         :ok <- ensure_symbol_is_not_stale_for_another_operator(operator, replacement_symbols) do
      {:ok,
       %{
         operator: operator,
         account_token: account_token,
         faction: faction,
         replacement_symbols: replacement_symbols,
         registration_symbols: registration_symbols(attrs, replacement_symbols),
         exhaustible?:
           Map.has_key?(attrs, :replacement_symbols) or
             Map.has_key?(attrs, "replacement_symbols")
       }}
    end
  end

  defp register(scope, attrs, operator_id) do
    with {:ok, plan} <- prepare_mint(scope, attrs, operator_id) do
      revision = active_revision(operator_id)

      SpaceTraders.Observability.with_context(
        # Registration establishes a new identity. The reset-detecting call's
        # Agent/Generation/Ship context must not look like an adoption link or
        # attribute this attempt to the predecessor's gameplay work.
        [
          operator_id: operator_id,
          strategy_revision_id: revision && revision.id,
          agent_id: nil,
          fleet_generation_id: nil,
          decision_episode_id: nil,
          commitment_id: nil,
          ship_id: nil,
          ship_symbol: nil,
          intent_id: nil,
          mutation_attempt_id: nil
        ],
        fn -> register_first_available(scope, plan, plan.registration_symbols) end
      )
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
                  opts
                  |> Keyword.put(:notify?, false)
                  |> Keyword.put(:entity_ref, condition_entity_ref(evidence))
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

  defp condition_entity_ref(%Observation{subject: subject}) when is_binary(subject) do
    case String.split(subject, ":", parts: 2) do
      [type, _rest]
      when type in [
             "system",
             "waypoint",
             "market",
             "shipyard",
             "construction",
             "ship",
             "contract"
           ] ->
        subject

      _ ->
        nil
    end
  end

  defp condition_entity_ref(_evidence), do: nil

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
  def observe_observation(%Agent{id: agent_id}, %Observation{} = evidence)
      when is_integer(agent_id) and evidence.operation_id == "get-my-agent" do
    # The observing Agent's own live Generation: a late predecessor result
    # never reaches another Generation's credits.
    generation =
      Repo.one(
        from generation in Generation,
          where:
            generation.agent_id == ^agent_id and is_nil(generation.fenced_at) and
              is_nil(generation.retired_at)
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
              candidate.id == ^generation.id and is_nil(candidate.fenced_at) and
                is_nil(candidate.retired_at)
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
    now = Clock.utc_now()

    # The canonical current Generation, read once before it moves to the new
    # Revision. A fenced, retired or historical Generation keeps the Revision
    # that governed it. Before adoption publishes an identity (compatible
    # legacy writers only; boot preflight always publishes), the sole
    # Operator's unfinished Generation is the candidate.
    canonical_id =
      Repo.one(
        from identity in "current_fleet_identity",
          where: identity.id == 1,
          select: identity.fleet_generation_id
      )

    live_query =
      from generation in Generation,
        where:
          generation.operator_id == ^operator_id and is_nil(generation.fenced_at) and
            is_nil(generation.retired_at)

    live_query =
      if canonical_id,
        do: from(generation in live_query, where: generation.id == ^canonical_id),
        else: live_query

    live =
      Repo.all(
        from generation in live_query,
          select: %{
            id: generation.id,
            agent_id: generation.agent_id,
            previous_revision_id: generation.fleet_strategy_revision_id
          }
      )

    live_ids = Enum.map(live, & &1.id)

    Repo.update_all(
      from(generation in Generation, where: generation.id in ^live_ids),
      set: [
        fleet_strategy_revision_id: revision_id,
        objective_progress: generation_progress(revision, nil),
        strategy_capable_at: now,
        updated_at: DateTime.utc_now(:second)
      ]
    )

    # A changed active Revision invalidates the old allocation result before a
    # fresh reconciliation selects its successor.
    :ok = FleetAllocation.NeutralWait.supersede_for_operator(operator_id)

    # The wake is a prompt, not the liveness authority: the active Revision's
    # Observation Demands and boot reconstruction re-enter allocation if it
    # is lost. The next Market boundary retires any older-Revision Portfolio.
    log_activation(scope, revision_id, live)

    :ok =
      OperatorConditions.resolve_objective_conditions(
        scope,
        List.first(live_ids),
        revision_id
      )

    :ok
  end

  @doc "Whether a Server Reset predecessor still awaits its replacement."
  def retire_stale_agents(%Scope{} = scope) do
    with {:ok, identity} <- current_fleet(scope) do
      case server_reset_replacement(identity) do
        {:ok, _attrs} -> {:error, :replacement_required}
        {:error, :no_server_reset} -> {:ok, []}
      end
    end
  end

  @doc "Retries Server Reset replacement after mutation admission resumes."
  def replace_stale_agents(%Scope{} = scope) do
    case replace_after_reset(scope) do
      {:ok, replacement} -> {:ok, [replacement]}
      {:error, :no_server_reset} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
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

      {:ok, _overview} = result ->
        # Any authoritative balance below the floor pauses spending at once.
        _ = SpaceTraders.CreditFloorWatch.observe(agent)
        result

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

  # Runs inside the establishment transaction; side effects follow its commit.
  # The predecessor Agent, Ships and Generation are retained as history; only
  # their live claims (reservations, timers, symbol occupancy) are released.
  defp replace_stale_agent_and_create(operator, registration, agent_token, opts) do
    game_agent = registration.agent
    faction = Keyword.fetch!(opts, :faction)
    replacement_symbols = Keyword.fetch!(opts, :replacement_symbols)

    predecessors =
      Repo.all(
        from generation in Generation,
          where: generation.operator_id == ^operator.id and is_nil(generation.retired_at),
          order_by: [desc: generation.number]
      )

    predecessor = List.first(predecessors)

    {retired_symbols, ship_symbols} =
      predecessors
      |> Enum.map(&release_predecessor/1)
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
          &retire_generation(&1, generation.strategy_capable_at || Clock.utc_now())
        )

        :ok = Identity.publish_generation!(operator.id, generation.id)

        {:ok, {agent, generation, retired_symbols, ship_symbols}}

      {:error, changeset} ->
        {:error, Ecto.Changeset.delete_change(changeset, :agent_token)}
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

  defp register_first_available(_scope, _plan, []),
    do: {:error, :replacement_symbols_exhausted}

  # Only a proven rejection of the symbol advances to the next candidate.
  defp register_first_available(scope, plan, [symbol | rest]) do
    case SpaceTraders.API.register(
           plan.account_token,
           symbol,
           plan.faction,
           plan.operator.email,
           registration: %{
             "faction" => plan.faction,
             "replacement_symbols" => plan.replacement_symbols
           }
         ) do
      {:ok, _registration} ->
        case Registration.recovery(plan.operator.id) do
          %{status: :awaiting_adoption, attempt: attempt} -> adopt_registration(scope, attempt)
          _ -> {:error, :registration_unresolved}
        end

      {:error, %GameplayError{code: 4103}} when rest != [] ->
        register_first_available(scope, plan, rest)

      {:error, %GameplayError{code: 4103}} = error ->
        if plan.exhaustible?, do: {:error, :replacement_symbols_exhausted}, else: error

      {:error, _reason} = error ->
        case Registration.recovery(plan.operator.id) do
          %{status: :in_progress, attempt: attempt} ->
            :ok = Registration.settle_undispatched(attempt)
            error

          %{status: :clear} ->
            error

          _pending ->
            {:error, :registration_unresolved}
        end
    end
  end

  defp replacement_symbols(attrs, changeset) do
    symbols = attrs[:replacement_symbols] || attrs["replacement_symbols"]

    # No generated suffixes: only the chosen symbol or explicit candidates.
    symbols = if is_list(symbols), do: symbols, else: [get_field(changeset, :symbol)]

    Enum.uniq(symbols)
  end

  defp registration_symbols(attrs, replacement_symbols) do
    if Map.has_key?(attrs, :replacement_symbols) or Map.has_key?(attrs, "replacement_symbols") do
      replacement_symbols
    else
      [hd(replacement_symbols)]
    end
  end

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
        conflict_target: {:unsafe_fragment, "(symbol) WHERE retired_at IS NULL"}
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

  # Every activation is logged, one line per live Generation (with the
  # Portfolio it held) or one line saying no Generation was live.
  defp log_activation(%Scope{operator: %Operator{id: operator_id}}, revision_id, []) do
    Logger.info("Fleet Strategy Revision activated",
      operator_id: operator_id,
      active_revision_id: revision_id,
      disposition: :no_live_generation
    )
  end

  defp log_activation(scope, revision_id, live) do
    for generation <- live do
      agent = Repo.get(Agent, generation.agent_id)
      portfolio = agent && FleetAllocation.current_portfolio(scope, agent)
      # Outside the Logger call: its metadata is not evaluated below the level.
      disposition = request_intelligence(agent)

      Logger.info("Fleet Strategy Revision activated",
        operator_id: scope.operator.id,
        agent_id: generation.agent_id,
        fleet_generation_id: generation.id,
        previous_revision_id: generation.previous_revision_id,
        active_revision_id: revision_id,
        portfolio_id: portfolio && portfolio.id,
        portfolio_revision_id: portfolio && portfolio.fleet_strategy_revision_id,
        commitment_ids:
          portfolio &&
            FleetAllocation.log_ids(Enum.map(portfolio.commitments, & &1.id)),
        decision_episode_id: portfolio && portfolio.strategy_decision_episode_id,
        disposition: disposition
      )
    end

    :ok
  end

  # A failed broadcast is reported, never raised: activation has committed.
  defp request_intelligence(%Agent{} = agent) do
    case Fleet.system_from_headquarters(agent.headquarters) do
      {:ok, system} ->
        case Phoenix.PubSub.broadcast(
               SpaceTraders.PubSub,
               "fleet_intelligence_evidence",
               {:waypoint_intelligence_observed, agent.id, system}
             ) do
          :ok -> :allocation_wake_requested
          {:error, _reason} -> :allocation_wake_failed
        end

      _ ->
        :no_allocation_wake
    end
  end

  defp request_intelligence(nil), do: :no_allocation_wake

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

    :ok = SpaceTraders.FleetAllocation.NeutralWait.supersede_for_operator(generation.operator_id)

    # A retired Generation's Strategy no longer makes its demands relevant.
    Evidence.withdraw_agent_demands(generation.agent_id)

    :ok
  end

  # Only the wakeup that newly fences the current Generation starts its
  # replacement. Repeated or late reset evidence finds it already fenced, so
  # it neither re-fences a successor nor retries registration in a loop.
  defp mark_stale_and_replace(%Agent{} = agent) do
    case mark_stale(agent) do
      {:ok, {:fenced, stale_agent}} ->
        with %Operator{} = operator <- Repo.get(Operator, stale_agent.operator_id) do
          _ = replace_after_reset(Scope.for_operator(operator))
        end

      _already_fenced ->
        :ok
    end

    :ok
  end

  defp release_predecessor(%Generation{agent_id: nil}), do: {[], []}

  defp release_predecessor(%Generation{agent_id: agent_id}) do
    stale_agent = Repo.get!(Agent, agent_id)
    :ok = SpaceTraders.ShipReservation.release_for_agent!(stale_agent.id)

    live_ships =
      from(ship in Ship, where: ship.agent_id == ^stale_agent.id and is_nil(ship.retired_at))

    ship_symbols = Repo.all(from(ship in live_ships, select: ship.symbol))
    Enum.each(ship_symbols, &Timeline.cancel_events(:ship, &1))
    Repo.update_all(live_ships, set: [retired_at: DateTime.utc_now(:second)])
    {[stale_agent.symbol], ship_symbols}
  end

  defp mark_stale(%Agent{} = agent) do
    :ok = SpaceTraders.FleetGenerationAdmission.fence(agent.agent_token)

    Repo.transaction(fn ->
      now = DateTime.utc_now()
      ensure_generation_for_agent!(agent)

      # The first definitive evidence is the Server Reset's recorded time.
      Repo.update_all(
        from(stale in Agent, where: stale.id == ^agent.id and is_nil(stale.stale_at)),
        set: [stale_at: DateTime.truncate(now, :second)]
      )

      {fenced, _} =
        Repo.update_all(
          from(generation in Generation,
            where:
              generation.agent_id == ^agent.id and is_nil(generation.fenced_at) and
                is_nil(generation.retired_at)
          ),
          set: [fenced_at: now, updated_at: DateTime.truncate(now, :second)]
        )

      if fenced > 0 and is_integer(agent.operator_id) do
        :ok = SpaceTraders.FleetAllocation.NeutralWait.supersede_for_operator(agent.operator_id)
      end

      Evidence.withdraw_agent_demands(agent.id, DateTime.truncate(now, :second))

      {if(fenced > 0, do: :fenced, else: :already_fenced), Repo.get!(Agent, agent.id)}
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
    case gameplay_authority(id) do
      {:error, :agent_token_missing} -> {:error, :stale_agent}
      authority -> authority
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
