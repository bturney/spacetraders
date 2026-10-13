defmodule SpaceTraders.FleetGeneration.Registration do
  @moduledoc """
  Registration outcomes for Fleet Generation, kept in the one MutationAttempts
  recovery record (ADR 0011). There is no second registration ledger.

  The Operator's latest `register` attempt decides recovery:

  - `:clear`: no attempt, proven not sent, proven rejected, proven absent, or
    adopted. A new registration may be dispatched.
  - `:in_progress`: prepared and not yet dispatched. Only a holder of the
    establishment authority may treat it as abandoned.
  - `:unresolved`: sent with an unknown outcome. Nothing may register,
    import or move to another candidate until authoritative evidence settles
    it.
  - `:awaiting_adoption`: success proven, but local adoption has not
    committed. The encrypted AgentToken is retained on the attempt, so
    recovery adopts this identity and never mints again.

  A succeeded attempt with no retained credential and no adoption link was
  committed by the earlier single-transaction mint. That mint adopted its
  identity in the same commit, so it reads as `:clear`.
  """

  import Ecto.Query

  alias SpaceTraders.API.Model.Agent, as: GameAgent
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.{Evidence, MutationAttempts, Repo}
  alias SpaceTraders.MutationAttempts.Attempt

  @authority_key "fleet-establishment"
  # Registration may wait for API capacity while the authority is held.
  @authority_timeout :timer.minutes(2)

  @doc """
  Runs `fun` while holding the deployment's establishment authority.

  The authority is a PostgreSQL session lock held on one checked-out
  connection. Unlike a transaction, it lets each registration step commit
  independently, so a lost response or a crash leaves durable evidence. Every
  mint, import and recovery queues on it across processes and app instances.
  If the holder dies, its connection closes and the lock is released.
  """
  def with_authority(fun) when is_function(fun, 0) do
    Repo.checkout(
      fn ->
        Repo.query!("SELECT pg_advisory_lock(hashtextextended($1, 0))", [@authority_key],
          timeout: @authority_timeout
        )

        try do
          fun.()
        after
          unlock()
        end
      end,
      timeout: @authority_timeout
    )
  end

  defp unlock do
    Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [@authority_key])
  rescue
    # A broken connection has already released its session lock.
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> :ok
  end

  @doc """
  Classifies the Operator's registration recovery.

  Pass `authority: true` only while holding `with_authority/1`. Any prepared
  attempt then belongs to a holder that has died, because dispatch admission
  requires the same authority. Such an attempt is recorded `not_sent`.
  """
  def recovery(operator_id, opts \\ []) when is_integer(operator_id) do
    attempt = MutationAttempts.latest_registration(operator_id)

    case classify(attempt) do
      :in_progress ->
        if Keyword.get(opts, :authority, false) do
          {:ok, _} = MutationAttempts.record_not_sent(attempt, "abandoned_before_dispatch")
          recovery(operator_id, opts)
        else
          describe(:in_progress, attempt)
        end

      status ->
        describe(status, attempt)
    end
  end

  defp classify(nil), do: :clear
  defp classify(%Attempt{state: "prepared"}), do: :in_progress

  defp classify(%Attempt{state: state}) when state in ["not_sent", "rejected", "absent"],
    do: :clear

  defp classify(%Attempt{state: state} = attempt) do
    cond do
      state in MutationAttempts.unresolved_states() ->
        :unresolved

      state in ["succeeded", "accepted"] and is_nil(attempt.fleet_generation_id) and
          is_binary(attempt.recovery_credential) ->
        :awaiting_adoption

      true ->
        :clear
    end
  end

  defp describe(:clear, _attempt),
    do: %{status: :clear, attempt: nil, attempt_id: nil, symbol: nil, summary: nil}

  defp describe(status, %Attempt{} = attempt) do
    symbol = symbol(attempt)

    %{
      status: status,
      attempt: attempt,
      attempt_id: attempt.id,
      symbol: symbol,
      summary: summary(status, symbol)
    }
  end

  defp summary(:in_progress, symbol),
    do: "Registration of #{symbol} is in progress."

  defp summary(:unresolved, symbol),
    do:
      "Registration of #{symbol} may have succeeded: its response was lost. No other " <>
        "Agent will be registered or imported until it is reconciled. Check the game " <>
        "again, or supply #{symbol}'s AgentToken if your account registered it."

  defp summary(:awaiting_adoption, symbol),
    do:
      "#{symbol} was registered, but local setup was interrupted. Resume setup to adopt " <>
        "#{symbol}; no new Agent will be registered."

  @doc "The registered Agent symbol an attempt asked for."
  def symbol(%Attempt{prepared_evidence: evidence}),
    do: get_in(evidence, ["request", "body", "symbol"])

  @doc "Prepares one candidate's registration and commits it before dispatch."
  def prepare(symbol, faction, email, replacement_symbols) do
    MutationAttempts.prepare(OperationInventory.fetch!("register"), "/register",
      json: %{"symbol" => symbol, "faction" => faction, "email" => email},
      registration: %{"faction" => faction, "replacement_symbols" => replacement_symbols}
    )
  end

  @doc """
  Marks a prepared registration as sent, immediately before transport.

  An attempt already marked `not_sent` by a later establishment holder is
  refused, so an abandoned registration can never be dispatched afterwards.
  """
  def admit_send(%Attempt{id: id}) do
    Repo.transaction(fn ->
      current = Repo.one!(from(a in Attempt, where: a.id == ^id, lock: "FOR UPDATE"))

      with "prepared" <- current.state,
           {:ok, admitted} <- MutationAttempts.mark_sent_or_unknown(current) do
        admitted
      else
        state when is_binary(state) -> Repo.rollback(:attempt_already_dispatched)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Records suppression of a prepared registration that never reached transport."
  def settle_undispatched(%Attempt{id: id}) do
    case MutationAttempts.get!(id) do
      %Attempt{state: "prepared"} = attempt ->
        {:ok, _} = MutationAttempts.record_not_sent(attempt, "suppressed_before_transport")
        :ok

      _dispatched ->
        :ok
    end
  end

  @doc "Non-secret identity facts retained with a registration's success."
  def success_evidence(%{} = decoded) do
    %{
      "registered_agent" => agent_facts(Map.get(decoded, :agent)),
      "registered_ships" => ship_symbols(Map.get(decoded, :ships))
    }
  end

  defp agent_facts(%GameAgent{} = agent) do
    %{
      "symbol" => agent.symbol,
      "headquarters" => agent.headquarters,
      "credits" => agent.credits,
      "startingFaction" => agent.starting_faction
    }
  end

  defp agent_facts(_agent), do: %{}

  defp ship_symbols(ships) when is_list(ships),
    do: ships |> Enum.map(&Map.get(&1, :symbol)) |> Enum.filter(&is_binary/1)

  defp ship_symbols(_ships), do: []

  @doc """
  Reconstructs the proven identity from the attempt's own evidence, with the
  retained AgentToken. It makes no game request.
  """
  def registered_identity(%Attempt{} = attempt) do
    facts =
      attempt.outcomes
      |> Enum.reverse()
      |> Enum.find_value(fn outcome -> identity_facts(outcome.evidence) end)

    registration = attempt.prepared_evidence["registration"] || %{}

    %{
      agent: GameAgent.from_json(facts["registered_agent"]),
      ships: Enum.map(facts["registered_ships"], &%{symbol: &1}),
      token: attempt.recovery_credential,
      faction:
        registration["faction"] ||
          get_in(attempt.prepared_evidence, ["request", "body", "faction"]),
      replacement_symbols: registration["replacement_symbols"] || [symbol(attempt)]
    }
  end

  defp identity_facts(%{"registered_agent" => %{}} = facts), do: facts

  defp identity_facts(%{"observations" => observations}) when is_list(observations),
    do: Enum.find_value(observations, &identity_facts(&1["facts"]))

  defp identity_facts(_evidence), do: nil

  @doc "Locks an attempt that still awaits adoption, inside the adopting transaction."
  def lock_awaiting_adoption(%Attempt{id: id}) do
    current =
      from(a in Attempt, where: a.id == ^id, lock: "FOR UPDATE")
      |> Repo.one!()
      |> Repo.preload(:outcomes, force: true)

    if classify(current) == :awaiting_adoption,
      do: {:ok, current},
      else: {:error, :registration_not_awaiting_adoption}
  end

  @doc """
  Settles an unresolved registration from the public Agent read, the
  narrowest boundary the game offers without the AgentToken.

  Only a 404 is conclusive: then the registration never took effect. An
  occupied symbol proves neither ownership nor failure, so the attempt stays
  unresolved.
  """
  def reconcile_from_public_read(%Attempt{} = attempt) do
    symbol = symbol(attempt)

    case SpaceTraders.API.get_public_agent(symbol) do
      {:error, :not_found} ->
        observation =
          Evidence.authoritative_observation("get-agent", attempt.dependency_keys, %{
            reconciliation: conclusion(attempt, :absent, "public_agent_not_found"),
            public_agent: %{symbol: symbol, found: false}
          })

        with {:ok, _} <- MutationAttempts.reconcile(attempt, :absent, [observation]),
             do: {:ok, :absent}

      _occupied_or_unknown ->
        {:error, :registration_unresolved}
    end
  end

  @doc """
  Settles an unresolved registration as accepted from the Operator's AgentToken.

  The token must authenticate as the exact attempted symbol. The token and
  identity facts commit together with the reconciliation, so a later
  interruption still recovers this identity.
  """
  def reconcile_from_agent_token(%Attempt{} = attempt, agent_token, %GameAgent{} = agent, ships) do
    if intended_identity(attempt, agent) == :ok do
      observation =
        Evidence.authoritative_observation(
          "get-my-agent",
          attempt.dependency_keys,
          Map.merge(
            %{reconciliation: conclusion(attempt, :accepted, "agent_token_authenticates_symbol")},
            success_evidence(%{agent: agent, ships: ships})
          )
        )

      MutationAttempts.reconcile(attempt, :accepted, [observation],
        recovery_credential: agent_token
      )
    else
      {:error, :registration_identity_mismatch}
    end
  end

  @doc "Whether an authenticated Agent is exactly the identity the attempt registered."
  def intended_identity(%Attempt{} = attempt, %GameAgent{symbol: symbol})
      when is_binary(symbol) do
    if String.upcase(symbol) == String.upcase(symbol(attempt)),
      do: :ok,
      else: {:error, :registration_identity_mismatch}
  end

  def intended_identity(_attempt, _agent), do: {:error, :registration_identity_mismatch}

  defp conclusion(attempt, outcome, basis) do
    %{
      mutation_attempt_id: attempt.id,
      request_fingerprint: attempt.request_fingerprint,
      outcome: Atom.to_string(outcome),
      basis: basis
    }
  end
end
