defmodule SpaceTraders.Fleet.Intents.RecordedAction do
  @moduledoc """
  Admission of recorded Ship actions. Ship Execution supplies the selected
  outcome; this boundary commits its identity and the sole MutationAttempts
  ledger together, then commits send admission before transport can run.

  All implemented Ship adapters share this protocol. No network callback runs
  under these transactions. Legacy selected actions without linkage remain unknown.
  Market purchases retain calibrated quote exposure before preparation and
  revalidate Fleet spending authority before the send marker.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.API.ShipAction
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.Fleet.Intents.Recovery
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.Portfolio
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.ManualIntervention
  alias SpaceTraders.MarketSpending
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @spending_replan_reasons [
    :market_quote_stale_or_missing,
    :insufficient_unreserved_headroom,
    :authoritative_credit_facts_required,
    :unbounded_purchase_exposure
  ]

  @doc "Commits one selected outcome and its prepared attempt, without sending."
  def prepare(
        %Agent{} = agent,
        %Intent{} = intent,
        %{"kind" => _kind} = action
      ) do
    with :ok <- require_commit_boundary(),
         :ok <- purchase_preparation_authority(agent, intent, action),
         {:ok, spending} <- MarketSpending.acquire(agent, intent, action) do
      Repo.transaction(fn ->
        if spending, do: MarketSpending.lock_agent(agent.id)
        current = locked_intent(intent.id)

        with %Intent{} <- current,
             true <- Intent.unfinished?(current) and is_nil(current.in_flight_action),
             {:ok, authority} <- authority(agent.id, current),
             :ok <- claim_matches(current, authority.claim),
             {:ok, action} <- bind_transfer(authority, current, action),
             {:ok, request} <- ShipAction.request(authority.ship.symbol, action) do
          selected =
            action
            |> Map.merge(action_binding(authority.claim))
            |> Map.put("selection_id", Ecto.UUID.generate())

          {:ok, attempt} =
            prepare_attempt(
              authority,
              %{current | in_flight_action: selected},
              request,
              nil,
              spending
            )

          emit_phase(:preparation_written, attempt)

          selected =
            current
            |> Ecto.Changeset.change(
              status: "active",
              in_flight_action: selected,
              mutation_attempt_id: attempt.id
            )
            |> Repo.update!()

          %{intent: selected, attempt: attempt}
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:intent_dispatch_no_longer_allowed)
        end
      end)
      |> preparation_committed()
    end
  end

  def prepare(_agent, _intent, _action), do: {:error, :invalid_recorded_action}

  defp purchase_preparation_authority(agent, intent, %{"kind" => kind})
       when kind in ["buy", "refuel", "jump"] do
    Repo.transaction(fn ->
      MarketSpending.lock_agent(agent.id)

      with %Intent{} = current <- locked_intent(intent.id),
           true <- Intent.unfinished?(current) and is_nil(current.in_flight_action),
           {:ok, owner} <- authority(agent.id, current),
           :ok <- claim_matches(current, owner.claim) do
        :ok
      else
        {:error, _} = error -> error
        _ -> {:error, :intent_dispatch_no_longer_allowed}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp purchase_preparation_authority(_agent, _intent, _action), do: :ok

  @doc "Checks retry authority before capability reads; preparation and final admission recheck it."
  def retry_authority(
        %Agent{id: agent_id},
        %Intent{} = intent,
        %Attempt{agent_id: agent_id} = absent
      ) do
    with :ok <- require_commit_boundary() do
      Repo.transaction(fn ->
        MarketSpending.lock_agent(absent)

        case selected_owner_authority(locked_intent(intent.id), absent) do
          {:ok, _authority} -> :ok
          error -> error
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Consumes proven absence and links its one retry under the current owner."
  def prepare_retry(%Agent{} = agent, %Intent{} = intent, %Attempt{} = absent, opts \\ []) do
    with :ok <- require_commit_boundary(),
         :ok <- retry_authority(agent, intent, absent),
         {:ok, spending} <- MarketSpending.acquire(agent, intent, intent.in_flight_action) do
      Repo.transaction(fn ->
        if spending, do: MarketSpending.lock_agent(agent.id)
        current = locked_intent(intent.id)

        with %Intent{} <- current,
             true <- current.mutation_attempt_id == absent.id,
             {:ok, authority} <- authority(agent.id, current),
             :ok <- claim_matches(current, authority.claim),
             action <- refresh_evidence_references(current.in_flight_action, opts[:evidence]),
             {:ok, action} <- bind_transfer(authority, current, action),
             true <-
               Recovery.request_identity(action) ==
                 Recovery.request_identity(current.in_flight_action),
             {:ok, request} <- ShipAction.request(authority.ship.symbol, action),
             {:ok, retry} <-
               prepare_attempt(
                 authority,
                 %{current | in_flight_action: action},
                 request,
                 absent,
                 spending
               ) do
          current
          |> Ecto.Changeset.change(mutation_attempt_id: retry.id, in_flight_action: action)
          |> Repo.update!()

          retry
        else
          {:error, reason} -> Repo.rollback(reason)
          _ -> Repo.rollback(:retry_not_authorized)
        end
      end)
      |> preparation_committed()
    end
  end

  @doc "Commits current authority and sent-or-unknown admission before bytes leave."
  def admit_send(%Attempt{} = attempt) do
    with :ok <- require_commit_boundary() do
      Repo.transaction(fn ->
        MarketSpending.lock_agent(attempt)
        current = locked_intent(attempt.provenance["intent_id"])
        attempt = Repo.one!(from a in Attempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

        with "prepared" <- attempt.state,
             {:ok, owner} <- selected_authority(current, attempt),
             :ok <- MarketSpending.admit(attempt, current, owner.revision) do
          result = MutationAttempts.mark_sent_or_unknown(attempt)

          case result do
            {:ok, admitted} -> emit_phase(:marker_written, admitted)
            _ -> :ok
          end

          result
        else
          state when is_binary(state) -> {:error, :attempt_already_dispatched}
          {:error, reason} -> suppress_before_send(current, attempt, reason)
          _ -> suppress(attempt, :recorded_action_no_longer_selected)
        end
      end)
      |> case do
        {:ok, {:ok, admitted} = result} ->
          emit_phase(:marker_committed, admitted)
          result

        {:ok, result} ->
          if match?(
               {:error, reason}
               when reason in @spending_replan_reasons,
               result
             ),
             do: SpaceTraders.Outbox.dispatch_pending()

          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Rechecks authority after the send marker commits. Successful completion of
  this transaction is final transport admission: a later revocation cannot
  recall that one admitted request. Transport runs outside all transactions.
  """
  def authorize_transport(%Attempt{} = attempt) do
    with :ok <- require_commit_boundary() do
      Repo.transaction(fn ->
        MarketSpending.lock_agent(attempt)
        current = locked_intent(attempt.provenance["intent_id"])
        attempt = Repo.one!(from a in Attempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

        with "sent_or_unknown" <- attempt.state,
             {:ok, _owner} <- selected_authority(current, attempt) do
          emit_phase(:transport_authorization_checked, attempt)
          :ok
        else
          {:error, reason} -> suppress_admitted(attempt, reason)
          _ -> {:error, :attempt_already_dispatched}
        end
      end)
      |> case do
        {:ok, :ok} ->
          emit_phase(:transport_authorized, attempt)
          :ok

        {:ok, result} ->
          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # A committed marker cannot be erased. If authority disappears before transport,
  # retain it conservatively and record why this sender did not send. Recovery
  # still needs authoritative observations before it can release dependencies.
  defp suppress_admitted(attempt, reason) do
    case MutationAttempts.record_outcome(attempt, :ambiguous, %{
           reason: inspect_reason(reason),
           transport_disposition: "suppressed_before_transport"
         }) do
      {:ok, _} -> {:error, reason}
      {:error, persistence_reason} -> {:error, persistence_reason}
    end
  end

  defp selected_authority(%Intent{} = current, attempt) do
    with {:ok, authority} <- selected_owner_authority(current, attempt),
         {:ok, action} <- bind_transfer(authority, current, current.in_flight_action),
         true <- action == current.in_flight_action,
         {:ok, request} <- ShipAction.request(authority.ship.symbol, action),
         true <- request_matches?(attempt, request, action),
         true <-
           Map.merge(current.in_flight_action, action_binding(authority.claim)) ==
             current.in_flight_action do
      {:ok, authority}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recorded_action_no_longer_selected}
    end
  end

  defp selected_authority(_, _), do: {:error, :recorded_action_no_longer_selected}

  defp selected_owner_authority(%Intent{} = current, attempt) do
    with true <- current.mutation_attempt_id == attempt.id,
         true <-
           Evidence.fingerprint(current.in_flight_action) ==
             attempt.provenance["selected_action_fingerprint"],
         {:ok, authority} <- authority(attempt.agent_id, current),
         true <- generation_id(authority.generation) == attempt.fleet_generation_id,
         true <- revision_id(authority.revision) == attempt.strategy_revision_id,
         :ok <- claim_matches(current, authority.claim) do
      {:ok, authority}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recorded_action_no_longer_selected}
    end
  end

  defp selected_owner_authority(_, _), do: {:error, :recorded_action_no_longer_selected}

  defp suppress(attempt, reason) do
    case MutationAttempts.record_not_sent(attempt, inspect_reason(reason)) do
      {:ok, _} -> {:error, reason}
      {:error, persistence_reason} -> {:error, persistence_reason}
    end
  end

  # Only a Market purchase can be re-planned with fresh evidence. Refuel and jump
  # spending stays paused: the Intent blocks and the Operator decides.
  defp suppress_before_send(current, %Attempt{operation_id: "purchase-cargo"} = attempt, reason)
       when reason in @spending_replan_reasons do
    with {:ok, _} <- MutationAttempts.record_not_sent(attempt, inspect_reason(reason)) do
      current
      |> Ecto.Changeset.change(
        status: "superseded",
        in_flight_action: nil,
        mutation_attempt_id: nil,
        finished_at: DateTime.utc_now(:second),
        blocker: nil,
        last_action_result: %{
          "outcome" => "spending_replan_required",
          "reason" => inspect_reason(reason),
          "mutation_attempt_id" => attempt.id
        }
      )
      |> Repo.update!()

      FleetAllocation.return_purchase_for_replanning(
        Repo.get!(Agent, attempt.agent_id),
        current,
        attempt,
        reason
      )

      {:error, reason}
    end
  end

  defp suppress_before_send(_current, attempt, reason), do: suppress(attempt, reason)

  defp inspect_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp inspect_reason(reason), do: inspect(reason)

  @doc false
  def require_commit_boundary do
    if Repo.in_transaction?(),
      do: {:error, :recorded_dispatch_requires_commit},
      else: :ok
  end

  defp prepare_attempt(authority, intent, request, original, spending) do
    opts =
      request.opts ++
        [
          agent_id: authority.agent.id,
          selected_intent: intent,
          spending: spending,
          evidence_references: Recovery.describe(intent.in_flight_action).evidence_references,
          dispatch_context: %{
            operator_id: authority.agent.operator_id,
            fleet_generation_id: generation_id(authority.generation),
            strategy_revision_id: revision_id(authority.revision),
            decision_episode_id: authority.claim[:decision_episode_id],
            intervention_id: authority.claim[:intervention_id],
            ship_reservation_id: authority.claim[:ship_reservation_id]
          }
        ]

    result =
      if original,
        do: MutationAttempts.prepare_retry(original, request.operation, request.path, opts),
        else: MutationAttempts.prepare(request.operation, request.path, opts)

    case result do
      {:ok, attempt} -> {:ok, attempt}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp preparation_committed({:ok, %{attempt: attempt}} = result) do
    emit_phase(:prepared, attempt)
    result
  end

  defp preparation_committed({:ok, %Attempt{} = attempt} = result) do
    emit_phase(:prepared, attempt)
    result
  end

  defp preparation_committed(result), do: result

  defp emit_phase(phase, attempt) do
    :telemetry.execute(
      [:spacetraders, :recorded_dispatch, phase],
      %{count: 1},
      %{
        intent_id: attempt.provenance["intent_id"],
        attempt_id: attempt.id,
        operation_id: attempt.operation_id
      }
    )
  end

  defp locked_intent(id) when is_integer(id) do
    Repo.one(from i in Intent, where: i.id == ^id, lock: "FOR UPDATE")
  end

  defp locked_intent(_id), do: nil

  defp authority(agent_id, intent) do
    agent = Repo.get!(Agent, agent_id)
    ship = Repo.get!(Ship, intent.ship_id)

    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- SpaceTraders.EmergencyStopAdmission.mutation_allowed?(agent.agent_token),
         :ok <- SpaceTraders.FleetGenerationAdmission.mutation_allowed?(agent.agent_token),
         true <- is_nil(agent.stale_at) and ship.agent_id == agent.id,
         true <- Intent.unfinished?(intent),
         {:ok, owned} <- owner(agent, ship, intent),
         :ok <- supported_constraints(owned.revision) do
      {:ok, Map.merge(owned, %{agent: agent, ship: ship})}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recorded_dispatch_authority_stale}
    end
  end

  # Authenticated Manual Intervention remains a supported execution authority
  # before the Fleet has an active Revision, so it needs no Strategy Revision.
  defp owner(agent, ship, %Intent{caller: "intervention"} = intent) do
    strategy =
      Repo.one(from s in Strategy, where: s.operator_id == ^agent.operator_id, lock: "FOR SHARE")

    with {:ok, authority} <-
           ManualIntervention.authorization(agent.operator_id, ship.symbol, intent.id, lock: true) do
      claim =
        Map.merge(authority, %{commitment_id: nil, portfolio_id: nil, portfolio_version: nil})

      {:ok,
       %{
         claim: claim,
         generation: current_generation(agent.id),
         revision: optional_revision(strategy),
         decision_episode_id: authority[:decision_episode_id],
         intervention_id: authority[:intervention_id],
         ship_reservation_id: authority[:ship_reservation_id]
       }}
    end
  end

  defp owner(agent, ship, %Intent{caller: "commitment"}) do
    strategy =
      Repo.one(from s in Strategy, where: s.operator_id == ^agent.operator_id, lock: "FOR SHARE")

    generation = current_generation(agent.id)

    cond do
      is_nil(generation) ->
        {:error, :fleet_generation_absent}

      not is_nil(generation.fenced_at) ->
        {:error, :fleet_generation_fenced}

      true ->
        commitment_claim(agent, ship, strategy, generation)
    end
  end

  defp owner(_agent, _ship, _intent), do: {:error, :invalid_intent_owner}

  defp active_revision(%Strategy{emergency_stopped_at: nil, active_revision_id: revision_id})
       when not is_nil(revision_id),
       do: {:ok, revision_id}

  defp active_revision(%Strategy{emergency_stopped_at: stopped}) when not is_nil(stopped),
    do: {:error, :emergency_stopped}

  defp active_revision(_strategy), do: {:error, :strategy_revision_absent}

  defp commitment_claim(agent, ship, strategy, generation) do
    with {:ok, revision_id} <- active_revision(strategy),
         %Revision{} = revision <- Repo.get(Revision, revision_id),
         {:ok, claim} <- FleetAllocation.current_ship_claim(agent, ship.symbol, lock: true),
         %Portfolio{fleet_generation_id: generation_id, fleet_strategy_revision_id: ^revision_id} <-
           Repo.get(Portfolio, claim.portfolio_id),
         true <- generation_id == generation.id do
      {:ok, %{claim: claim, generation: generation, revision: revision}}
    else
      false -> {:error, :no_current_ship_claim}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :no_current_ship_claim}
      _ -> {:error, :strategy_revision_absent}
    end
  end

  defp generation_id(nil), do: nil
  defp generation_id(generation), do: generation.id

  defp revision_id(nil), do: nil
  defp revision_id(revision), do: revision.id

  defp optional_revision(%Strategy{active_revision_id: revision_id}) when not is_nil(revision_id),
    do: Repo.get(Revision, revision_id)

  defp optional_revision(_strategy), do: nil

  defp current_generation(agent_id) do
    Repo.one(
      from g in Generation,
        where: g.agent_id == ^agent_id and is_nil(g.retired_at),
        lock: "FOR SHARE"
    )
  end

  # The selected outcomes retain their existing spending preflights. Validate
  # supported Strategy rules here without introducing a new economic authority.
  defp supported_constraints(nil), do: :ok

  defp supported_constraints(revision) do
    SpaceTraders.FleetStrategy.StandingAuthority.validate_constraints(
      Map.get(revision.document, "hard_constraints", [])
    )
  end

  defp claim_matches(intent, claim) do
    binding = FleetAllocation.ship_claim_binding(claim).intent

    if Map.take(intent, Map.keys(binding)) == binding,
      do: :ok,
      else: {:error, :no_current_ship_claim}
  end

  defp action_binding(claim), do: FleetAllocation.ship_claim_binding(claim).action

  defp request_matches?(attempt, request, action) do
    attempt.operation_owner == "ship_execution" and
      attempt.operation_id == request.operation.id and
      attempt.prepared_evidence["selected_action"] == action and
      is_binary(action["selection_id"]) and
      attempt.prepared_evidence["request"] == %{
        "path" => request.path,
        "body" => request.opts[:json],
        "query" => request.opts[:params]
      }
  end

  defp bind_transfer(authority, intent, %{"kind" => "transfer", "target_ship" => target} = action) do
    with {:ok, claim} <- FleetAllocation.current_ship_claim(authority.agent, target, lock: true),
         true <- target != authority.ship.symbol,
         true <-
           claim.portfolio_id == intent.fleet_commitment_portfolio_id and
             claim.portfolio_version == intent.fleet_commitment_portfolio_version,
         %Commitment{} = receiver <- Repo.get(Commitment, claim.commitment_id),
         units when is_integer(units) and units > 0 <- action["units"],
         true <- Map.get(receiver.reservations, "cargo_capacity:#{target}", 0) >= units,
         :ok <- transfer_evidence(authority, action) do
      {:ok, Map.put(action, "target_claim", action_binding(claim))}
    else
      {:error, :transfer_evidence_unavailable} = gap -> gap
      _ -> {:error, :transfer_authority_unavailable}
    end
  end

  defp bind_transfer(_authority, _intent, %{} = action), do: {:ok, action}
  defp bind_transfer(_, _, _), do: {:error, :invalid_recorded_action}

  # A retry may replace expired preflight sources with the newly judged ones,
  # in the order the kind's Recovery description names its references.
  defp refresh_evidence_references(action, bindings) when is_list(bindings) do
    references = Recovery.describe(action).evidence_references

    if references != [] and length(references) == length(bindings) and
         Enum.all?(bindings, &match?(%Evidence.Binding{}, &1)) do
      references
      |> Enum.zip(bindings)
      |> Enum.reduce(action, fn {key, binding}, action ->
        Map.put(action, key, binding.observation.id)
      end)
    else
      action
    end
  end

  defp refresh_evidence_references(action, _bindings), do: action

  defp transfer_evidence(authority, action) do
    with {:ok, source} <-
           Evidence.retained_ship_binding(authority.agent, action["source_observation_id"]),
         {:ok, target} <-
           Evidence.retained_ship_binding(authority.agent, action["target_observation_id"]),
         true <-
           Enum.all?(
             [{source, authority.ship.symbol}, {target, action["target_ship"]}],
             fn {binding, symbol} ->
               binding.observation.fleet_generation_id == generation_id(authority.generation) and
                 SpaceTraders.Evidence.ShipObservation.matches?(
                   binding.observation,
                   binding.value,
                   symbol,
                   nil
                 )
             end
           ),
         true <-
           source.value.nav.status != "IN_TRANSIT" and target.value.nav.status != "IN_TRANSIT",
         true <- source.value.nav.waypoint_symbol == target.value.nav.waypoint_symbol,
         true <-
           SpaceTraders.Fleet.item_units(source.value.cargo, action["trade_symbol"]) >=
             action["units"],
         true <- target.value.cargo.capacity - target.value.cargo.units >= action["units"] do
      :ok
    else
      _ -> {:error, :transfer_evidence_unavailable}
    end
  end
end
