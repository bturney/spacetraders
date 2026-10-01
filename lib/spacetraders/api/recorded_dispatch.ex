defmodule SpaceTraders.API.RecordedDispatch do
  @moduledoc """
  Admission of recorded Ship actions. Ship Execution supplies the selected
  outcome; this boundary commits its identity and the sole MutationAttempts
  ledger together, then commits send admission before transport can run.

  Orbit is the initial activated adapter. No network callback runs under these
  transactions. Legacy selected actions without linkage remain unknown.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.Portfolio
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.ManualIntervention
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @doc "Commits one selected outcome and its prepared attempt, without sending."
  def prepare(
        %Agent{} = agent,
        %Intent{} = intent,
        %{"kind" => "orbit", "waypoint" => waypoint, "expected" => %{"status" => "IN_ORBIT"}} =
          action
      )
      when is_binary(waypoint) and waypoint != "" do
    with :ok <- require_commit_boundary() do
      Repo.transaction(fn ->
        current = locked_intent(intent.id)

        with true <- Intent.unfinished?(current) and is_nil(current.in_flight_action),
             {:ok, authority} <- authority(agent.id, current),
             :ok <- claim_matches(current, authority.claim) do
          selected =
            action
            |> Map.merge(action_binding(authority.claim))
            |> Map.put("selection_id", Ecto.UUID.generate())

          {:ok, attempt} = prepare_attempt(authority, %{current | in_flight_action: selected})

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

  @doc "Consumes proven absence and links its one retry under the current owner."
  def prepare_retry(%Agent{} = agent, %Intent{} = intent, %Attempt{} = absent) do
    with :ok <- require_commit_boundary() do
      Repo.transaction(fn ->
        current = locked_intent(intent.id)

        with %Intent{} <- current,
             true <- current.mutation_attempt_id == absent.id,
             {:ok, authority} <- authority(agent.id, current),
             :ok <- claim_matches(current, authority.claim),
             true <- current.in_flight_action["kind"] == "orbit",
             {:ok, retry} <- prepare_attempt(authority, current, absent) do
          current
          |> Ecto.Changeset.change(mutation_attempt_id: retry.id)
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
        current = locked_intent(attempt.provenance["intent_id"])
        attempt = Repo.one!(from a in Attempt, where: a.id == ^attempt.id, lock: "FOR UPDATE")

        with "prepared" <- attempt.state,
             %Intent{} <- current,
             true <- current.mutation_attempt_id == attempt.id,
             true <-
               Evidence.fingerprint(current.in_flight_action) ==
                 attempt.provenance["selected_action_fingerprint"],
             {:ok, authority} <- authority(attempt.agent_id, current),
             true <- authority.generation.id == attempt.fleet_generation_id,
             true <- authority.revision.id == attempt.strategy_revision_id,
             :ok <- claim_matches(current, authority.claim),
             true <-
               Map.merge(current.in_flight_action, action_binding(authority.claim)) ==
                 current.in_flight_action do
          MutationAttempts.mark_sent_or_unknown(attempt)
        else
          state when is_binary(state) -> {:error, :attempt_already_dispatched}
          {:error, reason} -> suppress(attempt, reason)
          _ -> suppress(attempt, :recorded_action_no_longer_selected)
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp suppress(attempt, reason) do
    case MutationAttempts.record_not_sent(attempt, inspect_reason(reason)) do
      {:ok, _} -> {:error, reason}
      {:error, persistence_reason} -> {:error, persistence_reason}
    end
  end

  defp inspect_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp inspect_reason(reason), do: inspect(reason)

  @doc false
  def require_commit_boundary do
    if Repo.in_transaction?(),
      do: {:error, :recorded_dispatch_requires_commit},
      else: :ok
  end

  defp prepare_attempt(authority, intent, original \\ nil) do
    operation = OperationInventory.fetch!("orbit-ship")
    path = "/my/ships/#{authority.ship.symbol}/orbit"

    opts = [
      agent_id: authority.agent.id,
      selected_intent: intent,
      dispatch_context: %{
        operator_id: authority.agent.operator_id,
        fleet_generation_id: authority.generation.id,
        strategy_revision_id: authority.revision.id,
        decision_episode_id: authority.claim[:decision_episode_id],
        intervention_id: authority.claim[:intervention_id],
        ship_reservation_id: authority.claim[:ship_reservation_id]
      }
    ]

    result =
      if original,
        do: MutationAttempts.prepare_retry(original, operation, path, opts),
        else: MutationAttempts.prepare(operation, path, opts)

    case result do
      {:ok, attempt} -> {:ok, attempt}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp preparation_committed({:ok, %{intent: intent, attempt: attempt}} = result) do
    emit_prepared(intent.id, attempt.id)
    result
  end

  defp preparation_committed({:ok, %Attempt{} = attempt} = result) do
    emit_prepared(attempt.provenance["intent_id"], attempt.id)
    result
  end

  defp preparation_committed(result), do: result

  defp emit_prepared(intent_id, attempt_id) do
    :telemetry.execute(
      [:spacetraders, :recorded_dispatch, :prepared],
      %{count: 1},
      %{intent_id: intent_id, attempt_id: attempt_id}
    )
  end

  defp locked_intent(id) do
    Repo.one(from i in Intent, where: i.id == ^id, lock: "FOR UPDATE")
  end

  defp authority(agent_id, intent) do
    agent = Repo.get!(Agent, agent_id)
    ship = Repo.get!(Ship, intent.ship_id)

    strategy =
      Repo.one(from s in Strategy, where: s.operator_id == ^agent.operator_id, lock: "FOR SHARE")

    generation =
      Repo.one(
        from g in Generation,
          where: g.agent_id == ^agent_id and is_nil(g.retired_at),
          lock: "FOR SHARE"
      )

    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- SpaceTraders.EmergencyStopAdmission.mutation_allowed?(agent.agent_token),
         :ok <- SpaceTraders.FleetGenerationAdmission.mutation_allowed?(agent.agent_token),
         true <- is_nil(agent.stale_at) and ship.agent_id == agent.id,
         true <- Intent.unfinished?(intent),
         %Strategy{emergency_stopped_at: nil, active_revision_id: revision_id}
         when not is_nil(revision_id) <- strategy,
         %Generation{fenced_at: nil, fleet_strategy_revision_id: ^revision_id} <- generation,
         %Revision{} = revision <- Repo.get(Revision, revision_id),
         {:ok, claim} <- owner(agent, ship, intent, generation, revision),
         :ok <- posture_consequence_authorized(revision) do
      {:ok, %{agent: agent, ship: ship, generation: generation, revision: revision, claim: claim}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :recorded_dispatch_authority_stale}
    end
  end

  defp owner(agent, ship, %Intent{caller: "commitment"}, generation, revision) do
    with {:ok, claim} <- FleetAllocation.current_ship_claim(agent, ship.symbol, lock: true),
         %Portfolio{fleet_generation_id: generation_id, fleet_strategy_revision_id: revision_id} <-
           Repo.get(Portfolio, claim.portfolio_id),
         true <- generation_id == generation.id and revision_id == revision.id do
      {:ok, claim}
    else
      _ -> {:error, :no_current_ship_claim}
    end
  end

  defp owner(agent, ship, %Intent{caller: "intervention"} = intent, _generation, _revision) do
    with {:ok, authority} <-
           ManualIntervention.authorization(agent.operator_id, ship.symbol, intent.id, lock: true) do
      {:ok,
       Map.merge(authority, %{commitment_id: nil, portfolio_id: nil, portfolio_version: nil})}
    end
  end

  defp owner(_agent, _ship, _intent, _generation, _revision),
    do: {:error, :invalid_intent_owner}

  # Orbit changes posture only: it cannot spend credits or scrap a Ship. Validate
  # the revision's enforceable rules rather than importing gameplay price bounds
  # or a second operational interpretation of Strategy prose.
  defp posture_consequence_authorized(revision) do
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
end
