defmodule SpaceTraders.Fleet.Intents do
  @moduledoc """
  The public seam for durable, caller-owned Intent execution.

  Ship Execution and Manual Intervention request operational outcomes here; ShipServer
  timers and boot recovery re-enter the same reconciliation. The module hides
  ownership transactions, mutation claims, game calls, Timeline scheduling,
  ShipServer arming and evidence reconciliation.
  """

  import Ecto.Query

  require Logger

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.API.Model.{Contract, ShipNav}
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Repo
  alias SpaceTraders.SafetyFence.DependencyKey

  alias SpaceTraders.{
    Agent,
    Clock,
    Contracts,
    Evidence,
    FleetExecution,
    ManualIntervention,
    MutationAttempts,
    ShipReservation,
    Timeline
  }

  alias SpaceTraders.FleetPlanning.CandidateContribution
  alias SpaceTraders.{Intelligence, World}

  @doc false
  def emergency_stop_reconciled?(ship_ids) when is_list(ship_ids) do
    unfinished_states = Intent.unfinished_states()

    not Repo.exists?(
      from intent in Intent,
        where:
          intent.ship_id in ^ship_ids and intent.status in ^unfinished_states and
            not is_nil(intent.in_flight_action)
    )
  end

  @doc false
  def censor_reset_generation(ship_ids, now) when is_list(ship_ids) do
    if ship_ids != [] do
      unfinished_states = Intent.unfinished_states()

      Repo.update_all(
        from(intent in Intent,
          where:
            intent.ship_id in ^ship_ids and intent.status in ^unfinished_states and
              not is_nil(intent.in_flight_action)
        ),
        set: [
          status: "superseded",
          in_flight_action: nil,
          mutation_attempt_id: nil,
          last_action_result: %{"outcome" => "reset_censored"},
          finished_at: now,
          updated_at: now
        ]
      )
    end

    :ok
  end

  @doc false
  def supersede_for_emergency_stop(ship_ids, now) when is_list(ship_ids) do
    if ship_ids != [] do
      unfinished_states = Intent.unfinished_states()

      Repo.update_all(
        from(intent in Intent,
          where: intent.ship_id in ^ship_ids and intent.status in ^unfinished_states
        ),
        set: [status: "superseded", finished_at: now, updated_at: now]
      )
    end

    :ok
  end

  defmodule ContractRecipient do
    @moduledoc "A typed Contract recipient for Deliver Goods."
    defstruct [:contract_id, :waypoint]
  end

  defmodule ConstructionRecipient do
    @moduledoc "A typed Construction recipient for Deliver Goods."
    defstruct [:system, :waypoint]
  end

  defmodule InstallModule do
    @moduledoc "A closed Install Module goal for a Ship."
    defstruct [:module_symbol, parameters: %{}]
  end

  defmodule RemoveModule do
    @moduledoc "A closed Remove Module goal for a Ship."
    defstruct [:module_symbol, authorized_removals: %{}, parameters: %{}]
  end

  defmodule CommitmentOwner do
    @moduledoc "Fleet Commitment ownership for a round-trip Intent."
    defstruct [:commitment, :portfolio]
  end

  @unfinished_states Intent.unfinished_states()
  @terminal_states Intent.terminal_states()
  @navigation_intent_types ~w(navigate acquire_intelligence acquire_resources buy sell deliver install_module remove_module)

  defp token_present(%AgentRecord{agent_token: token}) when is_binary(token) and token != "",
    do: :ok

  defp token_present(_agent), do: {:error, :agent_token_missing}

  defp scoped_agent_for_ship(
         %Scope{operator: %{id: operator_id}},
         agent_id,
         ship_symbol
       ) do
    case Repo.one(
           from agent in AgentRecord,
             join: ship in Ship,
             on: ship.agent_id == agent.id,
             where:
               agent.id == ^agent_id and agent.operator_id == ^operator_id and
                 ship.symbol == ^ship_symbol,
             select: agent
         ) do
      %AgentRecord{} = agent -> {:ok, agent}
      nil -> {:error, :agent_not_owned}
    end
  end

  defp scoped_agent_for_ship(_current_scope, _agent_id, _ship_symbol),
    do: {:error, :agent_not_owned}

  defp owned_intent_for_operator(operator_id, intent_id) do
    Repo.one(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        join: agent in AgentRecord,
        on: agent.id == ship.agent_id,
        where: intent.id == ^intent_id and agent.operator_id == ^operator_id,
        select: {intent, agent}
    )
  end

  defp installed_warp_drive(%{modules: modules}) do
    case Enum.find(modules || [], &warp_drive_module?/1) do
      nil -> {:error, :warp_drive_missing}
      module -> {:ok, module}
    end
  end

  defp warp_drive_module?(%{symbol: symbol}) when is_binary(symbol),
    do: symbol in ~w(MODULE_WARP_DRIVE_I MODULE_WARP_DRIVE_II MODULE_WARP_DRIVE_III)

  defp warp_drive_module?(_), do: false

  # Intent parameters persist as JSONB, so structs and other Elixir values must
  # become a JSON-safe, string-keyed representation before insert.
  defp stringify_keys(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify_keys(%_{} = value), do: value |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  defp stringify_keys(value), do: value

  defp do_stop_intent(%AgentRecord{} = agent, intent_id, :intervention) do
    result =
      Repo.transaction(fn ->
        intent =
          Repo.one(
            from intent in Intent,
              join: ship in Ship,
              on: ship.id == intent.ship_id,
              where:
                intent.id == ^intent_id and ship.agent_id == ^agent.id and
                  intent.status in ^@unfinished_states
          )

        case intent do
          %Intent{caller: "intervention"} = intent ->
            if unresolved_cargo_action?(intent) or unresolved_module_evidence?(intent) or
                 unresolved_jump_action?(intent) or unresolved_warp_action?(intent) or
                 unresolved_navigation_action?(intent) do
              Repo.rollback(:intents_reconciliation_required)
            else
              terminalize_intents!(intent, "stopped")
            end

          %Intent{} ->
            Repo.rollback(:invalid_intent_owner)

          nil ->
            Repo.rollback(:intents_not_active)
        end
      end)

    case result do
      {:ok, %Intent{} = intent} ->
        ship = Repo.get!(Ship, intent.ship_id)
        Fleet.record_activity(agent, ship, "manual_intervention_stopped", "Intervention stopped")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Requests one exceptional Navigate outcome for an explicitly reserved Ship."
  def intervene_navigate(%Scope{} = scope, %AgentRecord{} = agent, ship_symbol, waypoint, reason)
      when is_binary(waypoint) and is_binary(reason) do
    waypoint = String.trim(waypoint)
    reason = String.trim(reason)

    with :ok <- token_present(agent),
         :ok <- validate_intent_waypoint(waypoint),
         true <- reason != "" || {:error, :reason_required},
         {:ok, agent} <- scoped_agent_for_ship(scope, agent.id, ship_symbol),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, intent} <-
           Repo.transaction(fn ->
             reservation =
               Repo.one(
                 from r in ShipReservation,
                   where:
                     r.ship_id == ^ship.id and r.operator_id == ^scope.operator.id and
                       is_nil(r.released_at),
                   lock: "FOR SHARE"
               )

             if is_nil(reservation), do: Repo.rollback(:ship_not_reserved)

             if unfinished_intent_for_ship(ship.id), do: Repo.rollback(:ship_busy)

             if match?({:ok, _}, FleetAllocation.current_ship_claim(agent, ship_symbol)) do
               Repo.rollback(:ship_claimed)
             end

             intervention =
               Repo.insert!(%ManualIntervention{
                 ship_reservation_id: reservation.id,
                 reason: reason,
                 target_waypoint: waypoint
               })

             case replace_intents(ship, %{
                    caller: "intervention",
                    type: "navigate",
                    target_waypoint: waypoint,
                    parameters: %{}
                  }) do
               {:ok, intent} ->
                 Repo.update!(Ecto.Changeset.change(intervention, intent_id: intent.id))
                 intent

               {:error, cause} ->
                 Repo.rollback(cause)
             end
           end) do
      reconcile_intents(agent, intent)
    end
  end

  def intervene_navigate(_scope, _agent, _ship_symbol, _waypoint, _reason),
    do: {:error, :invalid_intervention}

  @doc "Stops an authenticated exceptional intervention after in-flight evidence is safe."
  def stop_intervention(%Scope{operator: %{id: operator_id}}, intent_id) do
    with {%Intent{caller: "intervention"} = intent, %AgentRecord{} = agent} <-
           owned_intent_for_operator(operator_id, intent_id),
         true <-
           ManualIntervention.authorized?(
             operator_id,
             Repo.get!(Ship, intent.ship_id).symbol,
             intent_id
           ) ||
             {:error, :intervention_not_authorized} do
      do_stop_intent(agent, intent_id, :intervention)
    else
      nil -> {:error, :intent_not_found}
      _ -> {:error, :intervention_not_authorized}
    end
  end

  @doc """
  Re-enters the one shared Intent reconciliation for a typed trigger.

  `:arrival`, `:cooldown`, and `:intent_retry` carry the expected Intent identity
  and ShipServer's fresh authoritative Ship observation. `:boot` with no observation performs the
  fresh authoritative read itself before any progress. Stale events that name a
  replaced Intent are ignored idempotently and cannot advance replacement work.
  """
  def reconcile(agent_id, ship_symbol, nil, :boot, expected_intent_id) do
    case Repo.get(AgentRecord, agent_id) do
      %AgentRecord{agent_token: agent_token} = agent
      when is_binary(agent_token) and agent_token != "" ->
        with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
             %Intent{status: status} = intent when status != "awaiting_confirmation" <-
               boot_intent(ship.id, expected_intent_id),
             :ok <- Agent.execution_allowed?(agent) do
          reconcile_selected(agent, ship, intent, nil, :boot)
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  def reconcile(agent_id, ship_symbol, live_ship, trigger, expected_intent_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      case unfinished_intent_for_ship(ship.id) do
        %Intent{} = intent ->
          if intent_matches_event?(intent, expected_intent_id) do
            reconcile_selected(agent, ship, intent, live_ship, trigger)
          else
            :ok
          end

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp reconcile_selected(agent, ship, intent, supplied, trigger) do
    {intent, evidence} = recovery_evidence(agent, intent, supplied)

    case evidence do
      {:ok, fresh} ->
        advance_intent_for_trigger(agent, intent.id, fresh)

      {:error, :stale_agent} ->
        :ok

      {:error, reason} when trigger == :boot ->
        intent_recovery_retry_or_block(ship, intent, agent.id, reason)

      {:error, reason} ->
        block_intents(intent, {:awaiting_reconciliation, reason})
    end
  end

  # Wake-up evidence re-enters the supported Intent engine. Retired timer
  # evidence is ignored and cannot resume execution.
  defp recover_selected_evidence(
         %Intent{mutation_attempt_id: nil, in_flight_action: action} = intent,
         agent_id
       )
       when is_map(action) do
    case MutationAttempts.recover_legacy(intent, agent_id) do
      {:ok, recovered} -> recovered
      {:error, _} -> intent
    end
  end

  defp recover_selected_evidence(intent, _agent_id), do: intent

  defp advance_intent_for_trigger(agent, intent_id, live_ship) do
    case Repo.get(Intent, intent_id) do
      %Intent{status: status} = intent when status in ["active", "waiting", "blocked"] ->
        case intent.caller do
          "commitment" ->
            case Repo.get(Commitment, intent.fleet_commitment_id) do
              %Commitment{} = commitment ->
                portfolio = Repo.get(Portfolio, commitment.fleet_commitment_portfolio_id)

                with {:ok, intent} <- advance_intents(agent, intent, live_ship) do
                  FleetExecution.continue_after_intent(agent, commitment, portfolio, intent)
                end

              nil ->
                :ok
            end

          "intervention" ->
            advance_intents(agent, intent, live_ship)

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  @doc "Re-enters reconciliation after boot's authoritative Ship read."
  def recover(agent, ship_symbol, live_ship, expected_intent_id) do
    reconcile(agent.id, ship_symbol, live_ship, :boot, expected_intent_id)
  end

  @doc """
  Re-arms Ship timers and re-enters reconciliation for persisted owned Intent
  work on boot. Intents already scheduled on a pending Ship timer are left for
  that trigger; their recovery would duplicate the timer's fresh read.
  """
  def rearm_on_boot do
    rearm_owned_intents_on_boot()

    # A sell may have completed just before a process crash. Its durable Intent
    # evidence is sufficient to classify the owning Decision Episode idempotently.
    FleetAllocation.reconcile_completed_outcomes()

    :ok
  end

  @doc "Reconstructs commitment and intervention Intents from supported ownership."
  def rearm_owned_intents_on_boot do
    symbols =
      Intent
      |> join(:inner, [i], s in Ship, on: i.ship_id == s.id)
      |> where(
        [i, _s],
        i.status in ^@unfinished_states and i.caller in ["commitment", "intervention"]
      )
      |> select([_i, s], s.symbol)
      |> Repo.all()
      |> Enum.uniq()

    Enum.filter(symbols, &rearm_intent_ship/1)
  end

  defp rearm_intent_ship(ship_symbol) do
    case Fleet.ship_agent(ship_symbol) do
      {:ok, agent} ->
        ShipServer.ensure_started(agent, ship_symbol)

        unless intents_waiting_on_timeline?(ship_symbol) do
          reconcile(agent.id, ship_symbol, nil, :boot, nil)
        end

        true

      :error ->
        Logger.warning(
          "ship #{ship_symbol}: no stored credentials, not re-arming timeline events"
        )

        false
    end
  end

  defp intents_waiting_on_timeline?(ship_symbol) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol),
         %Intent{} = intent <- unfinished_intent_for_ship(ship.id) do
      Timeline.pending_events(:ship, ship_symbol)
      |> Enum.any?(&(&1.payload["intent_id"] == intent.id))
    else
      _ -> false
    end
  end

  @doc "Re-enters reconciliation for one unfinished Intent with a fresh authoritative Ship observation."
  def advance(agent, %Intent{} = intent, live_ship) do
    {intent, evidence} = recovery_evidence(agent, intent, live_ship)

    case evidence do
      {:ok, fresh} -> advance_intents(agent, intent, fresh)
      {:error, reason} -> block_intents(intent, {:awaiting_reconciliation, reason})
    end
  end

  defp recovery_evidence(agent, intent, supplied) do
    intent = Repo.get!(Intent, intent.id)
    ship = Repo.get!(Ship, intent.ship_id)
    intent = recover_selected_evidence(intent, agent.id)
    attempt = MutationAttempts.latest_for_intent(intent)
    since = attempt && (attempt.sent_or_unknown_at || attempt.prepared_at)

    result =
      Agent.handle_game_result(
        agent,
        Evidence.recovery_ship_binding(agent, ship.symbol, supplied, since)
      )

    {intent,
     case result do
       {:ok, binding} -> {:ok, Evidence.bound_ship(binding)}
       error -> error
     end}
  end

  @doc false
  def unfinished_intent(intent_id) do
    case Repo.get(Intent, intent_id) do
      %Intent{} = intent ->
        if Intent.unfinished?(intent), do: intent, else: nil

      nil ->
        nil
    end
  end

  @doc "Lists unfinished Intents for all Ships owned by the Agent."
  def current(%AgentRecord{id: agent_id}) do
    Repo.all(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: ship.agent_id == ^agent_id and intent.status in ^@unfinished_states,
        order_by: [asc: intent.id]
    )
  end

  @doc "Lists completed and stopped Intents for all Ships owned by the Agent."
  def history(%AgentRecord{id: agent_id}) do
    Repo.all(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: ship.agent_id == ^agent_id and intent.status in ^@terminal_states,
        order_by: [desc: intent.finished_at, desc: intent.id]
    )
  end

  defp boot_intent(ship_id, intent_id) when is_integer(intent_id) do
    case Repo.get(Intent, intent_id) do
      %Intent{ship_id: ^ship_id, caller: caller, status: status} = intent
      when caller in ["commitment", "intervention"] and status in @unfinished_states ->
        intent

      _ ->
        nil
    end
  end

  defp boot_intent(ship_id, _expected_intent_id) do
    case unfinished_intent_for_ship(ship_id) do
      %Intent{caller: caller} = intent when caller in ["commitment", "intervention"] -> intent
      _ -> nil
    end
  end

  defp validate_intent_waypoint(""), do: {:error, :invalid_waypoint}
  defp validate_intent_waypoint(_waypoint), do: :ok

  defp fresh_ship(_agent, _ship_symbol, %SpaceTraders.API.Model.Ship{} = live_ship),
    do: {:ok, live_ship}

  defp fresh_ship(agent, ship_symbol, _live_ship) do
    Agent.handle_game_result(
      agent,
      SpaceTraders.Evidence.get_ship(AgentTokenReference.new(agent), ship_symbol)
    )
  end

  @doc """
  The intent is owned by the Fleet Commitment and only dispatches while the
  commitment's Ship Claim remains current. The buy intent navigates to the
  source Market, docks, and buys the admissible quantity through governed
  operations.
  """
  def request_commitment_round_trip(
        agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        candidate
      )
      when is_binary(ship_symbol) and is_map(candidate) do
    with {:ok, %{commitment_id: id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         true <-
           id == commitment.id and portfolio_id == portfolio.id and version == portfolio.version,
         :ok <- token_present(agent),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, nil),
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: "buy",
             target_waypoint: candidate_source(candidate),
             parameters: commitment_buy_parameters(candidate)
           }) do
      advance_new_intent(agent, intent, live_ship)
    else
      false -> {:error, :no_current_ship_claim}
      error -> error
    end
  end

  def request_commitment_round_trip(_agent, _commitment, _portfolio, _ship_symbol, _candidate),
    do: {:error, :invalid_commitment_round_trip}

  @doc "Starts a Contract Deliver Goods Intent only under its published Ship Claim."
  def request_commitment_contract_delivery(
        %AgentRecord{} = agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        %{
          contract_id: contract_id,
          destination_waypoint: waypoint,
          trade_symbol: symbol,
          units: units
        }
      )
      when is_binary(ship_symbol) and is_binary(contract_id) and is_binary(waypoint) and
             is_binary(symbol) and is_integer(units) and units > 0 do
    with {:ok, %{commitment_id: id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         true <-
           id == commitment.id and portfolio_id == portfolio.id and version == portfolio.version,
         :ok <- token_present(agent),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, nil),
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: "deliver",
             target_waypoint: waypoint,
             parameters: %{
               "trade_symbol" => symbol,
               "units" => units,
               "recipient" => %{
                 "type" => "contract",
                 "contract_id" => contract_id,
                 "waypoint" => waypoint
               }
             }
           }) do
      advance_new_intent(agent, intent, live_ship)
    else
      false -> {:error, :no_current_ship_claim}
      {:error, :no_current_ship_claim} = error -> error
      error -> error
    end
  end

  def request_commitment_contract_delivery(_agent, _commitment, _portfolio, _ship, _delivery),
    do: {:error, :invalid_contract_delivery}

  @doc "Starts Construction supply only under the matching current Ship Claim."
  def request_commitment_construction_delivery(
        %AgentRecord{} = agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        %{system: system, waypoint: waypoint, trade_symbol: symbol, units: units}
      )
      when is_binary(ship_symbol) and is_binary(system) and is_binary(waypoint) and
             is_binary(symbol) and is_integer(units) and units > 0 do
    with {:ok, %{commitment_id: id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         true <-
           id == commitment.id and portfolio_id == portfolio.id and version == portfolio.version,
         :ok <- token_present(agent),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, nil),
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: "deliver",
             target_waypoint: waypoint,
             parameters: %{
               "trade_symbol" => symbol,
               "units" => units,
               "recipient" => %{
                 "type" => "construction",
                 "system" => system,
                 "waypoint" => waypoint
               }
             }
           }) do
      advance_new_intent(agent, intent, live_ship)
    else
      false -> {:error, :no_current_ship_claim}
      error -> error
    end
  end

  def request_commitment_construction_delivery(_agent, _commitment, _portfolio, _ship, _delivery),
    do: {:error, :invalid_construction_delivery}

  @doc "Transfers Cargo under two current Claims; dependent work waits for both authoritative Cargo reads."
  def request_commitment_transfer(
        %AgentRecord{} = agent,
        %Commitment{} = producer,
        %Commitment{} = hauler,
        %Portfolio{} = portfolio,
        %{source_ship: source, target_ship: target, trade_symbol: symbol, units: units} = request
      )
      when is_binary(source) and is_binary(target) and source != target and
             is_binary(symbol) and is_integer(units) and units > 0 do
    with :ok <- token_present(agent),
         true <-
           transfer_claims?(agent, producer, hauler, portfolio, source, target, symbol, units),
         {:ok, ship} <- Fleet.owned_ship(agent, source),
         {:ok, _target} <- Fleet.owned_ship(agent, target),
         {:ok, live_source} <- fresh_ship(agent, source, nil),
         {:ok, intent} <-
           insert_commitment_intent(producer, portfolio, ship, %{
             type: "transfer",
             target_waypoint: live_source.nav.waypoint_symbol,
             parameters: %{
               "target_ship" => target,
               "trade_symbol" => symbol,
               "units" => units,
               "transfer_delivery" => Map.get(request, :delivery)
             }
           }) do
      advance_new_intent(agent, intent, live_source)
    else
      false -> {:error, :no_current_ship_claim}
      error -> error
    end
  end

  def request_commitment_transfer(_, _, _, _, _), do: {:error, :invalid_transfer}

  defp transfer_claims?(agent, producer, hauler, portfolio, source, target, symbol, units) do
    Enum.all?([{source, producer}, {target, hauler}], fn {symbol, commitment} ->
      match?(
        {:ok, %{commitment_id: id, portfolio_id: pid, portfolio_version: version}}
        when id == commitment.id and pid == portfolio.id and version == portfolio.version,
        FleetAllocation.current_ship_claim(agent, symbol)
      )
    end) and
      Map.get(hauler.reservations, "cargo_capacity:#{target}", 0) >= units and
      Enum.any?(producer.pledges, fn pledge ->
        pledge["outcome"] == ["cargo_transfer", source, target, symbol] and
          pledge["amount"] >= units
      end) and
      Enum.any?(hauler.dependencies, fn dep ->
        dep["kind"] == "acquisition" and dep["candidate_id"] == producer.candidate_id and
          dep["amount"] >= units
      end)
  end

  @intelligence_fields %{
    waypoint:
      ~w(symbol system_symbol type x y orbits orbitals traits modifiers chart faction is_under_construction),
    market: ~w(symbol exports imports exchange trade_goods transactions),
    shipyard: ~w(symbol ship_types ships transactions modifications_fee)
  }

  def request_commitment_intelligence(
        %AgentRecord{} = agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        request
      )
      when is_binary(ship_symbol) and is_map(request) do
    with :ok <- token_present(agent),
         {:ok, system} <- validate_intelligence_request(request),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok,
          %{commitment_id: commitment_id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         true <-
           (commitment_id == commitment.id and portfolio_id == portfolio.id and
              version == portfolio.version) || {:error, :no_current_ship_claim},
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: "acquire_intelligence",
             target_waypoint: request.waypoint,
             parameters:
               %{
                 "system" => system,
                 "subject_type" => to_string(request.subject_type),
                 "required_facts" => request.required_facts,
                 "freshness_seconds" => request.freshness_seconds
               }
               |> Map.merge(navigation_constraints(request))
           }),
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, nil) do
      advance_new_intent(agent, intent, live_ship)
    else
      false -> {:error, :no_current_ship_claim}
      error -> error
    end
  end

  def request_commitment_intelligence(_agent, _commitment, _portfolio, _ship_symbol, _request),
    do: {:error, :invalid_intelligence_request}

  defp validate_intelligence_request(%{
         subject_type: type,
         waypoint: waypoint,
         required_facts: fields,
         freshness_seconds: freshness
       })
       when is_binary(waypoint) and is_list(fields) and fields != [] and
              is_integer(freshness) and freshness >= 0 do
    with allowed when is_list(allowed) <- Map.get(@intelligence_fields, type),
         true <- Enum.all?(fields, &(&1 in allowed)),
         [_, system] <- Regex.run(~r/^(.+)-[^-]+$/, waypoint) do
      {:ok, system}
    else
      _ -> {:error, :invalid_intelligence_request}
    end
  end

  defp validate_intelligence_request(_), do: {:error, :invalid_intelligence_request}

  defp navigation_constraints(request) do
    constraints = Map.get(request, :constraints, %{})

    %{}
    |> maybe_put_constraint("allowed_methods", Map.get(constraints, :allowed_methods))
    |> maybe_put_constraint("flight_mode", Map.get(constraints, :flight_mode))
  end

  defp maybe_put_constraint(parameters, _key, nil), do: parameters
  defp maybe_put_constraint(parameters, key, value), do: Map.put(parameters, key, value)

  @doc "Starts one bounded resource outcome under a current Fleet Commitment Claim."
  def request_commitment_resources(
        agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        %{resource: %{mode: mode}} = candidate
      )
      when mode in [:extract, :siphon, :refine] do
    with :ok <- token_present(agent),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, %{commitment_id: id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         true <-
           id == commitment.id and portfolio_id == portfolio.id and version == portfolio.version,
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, nil),
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: "acquire_resources",
             target_waypoint: candidate.source_waypoint,
             parameters:
               %{
                 "mode" => to_string(mode),
                 "produce" => candidate.resource.produce,
                 "survey" => candidate.resource.survey
               }
               |> then(fn parameters ->
                 if is_map(candidate.transfer),
                   do: Map.put(parameters, "transfer", candidate.transfer),
                   else: parameters
               end)
           }) do
      advance_new_intent(agent, intent, live_ship)
    else
      false -> {:error, :no_current_ship_claim}
      error -> error
    end
  end

  @doc "Starts a Ship refit (module install or removal) under its published Ship Claim."
  def request_commitment_refit(
        agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        %CandidateContribution{kind: :ship_refit, refit: refit} = candidate
      )
      when is_binary(ship_symbol) and is_map(refit) do
    with {:ok, %{commitment_id: id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         true <-
           id == commitment.id and portfolio_id == portfolio.id and version == portfolio.version,
         :ok <- token_present(agent),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, nil),
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: to_string(refit_intent_type(candidate.refit)),
             target_waypoint: refit_target_waypoint(candidate.refit, live_ship),
             parameters: %{
               "module_symbol" => candidate.refit.module_symbol,
               "units" => 1,
               "refit" => %{
                 "capability" => to_string(candidate.refit.capability),
                 "sourcing" => candidate.refit.sourcing && to_string(candidate.refit.sourcing),
                 "market" => candidate.refit.market,
                 "max_unit_price" => candidate.refit.purchase_price,
                 "expected_cost" => candidate.refit.expected_cost,
                 "installed_before" => candidate.refit.installed_before
               }
             }
           }) do
      advance_new_intent(agent, intent, live_ship)
    else
      false -> {:error, :no_current_ship_claim}
      error -> error
    end
  end

  def request_commitment_refit(_agent, _commitment, _portfolio, _ship_symbol, _candidate),
    do: {:error, :invalid_ship_refit}

  defp refit_intent_type(%{action: :install}), do: :install_module
  defp refit_intent_type(%{action: :remove}), do: :remove_module

  # A purchase-sourced install navigates to the supply Market first; every other
  # refit runs where the Ship already is.
  defp refit_target_waypoint(%{action: :install, sourcing: :purchase, market: market}, _live_ship)
       when is_binary(market),
       do: market

  defp refit_target_waypoint(_refit, live_ship), do: live_ship.nav.waypoint_symbol

  @doc """
  Requests the authoritative sell leg of a commitment round trip at the
  destination Market after the buy leg completes.
  """
  def request_commitment_round_trip_sell(
        agent,
        %Commitment{} = commitment,
        %Portfolio{} = portfolio,
        ship_symbol,
        candidate,
        live_ship
      )
      when is_binary(ship_symbol) and is_map(candidate) do
    with :ok <- token_present(agent),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, live_ship} <- fresh_ship(agent, ship_symbol, live_ship),
         {:ok, intent} <-
           insert_commitment_intent(commitment, portfolio, ship, %{
             type: "sell",
             target_waypoint: candidate_destination(candidate),
             parameters: commitment_sell_parameters(candidate)
           }) do
      advance_new_intent(agent, intent, live_ship)
    end
  end

  def request_commitment_round_trip_sell(
        _agent,
        _commitment,
        _portfolio,
        _ship_symbol,
        _candidate,
        _live_ship
      ),
      do: {:error, :invalid_commitment_round_trip}

  @doc false
  def insert_commitment_intent(commitment, portfolio, ship, attrs) do
    %Intent{
      ship_id: ship.id,
      caller: "commitment",
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version
    }
    |> Intent.changeset(Map.put(attrs, :caller, "commitment"))
    |> Ecto.Changeset.put_change(:status, "active")
    |> Repo.insert()
  end

  defp commitment_buy_parameters(candidate) do
    %{
      "trade_symbol" => candidate_trade_symbol(candidate),
      "units" => candidate_units(candidate),
      "max_price" => candidate_purchase_price(candidate),
      "reserve_credits" => Map.get(candidate, :reserve_credits, 0),
      "market_trade" => market_trade(candidate)
    }
  end

  defp commitment_sell_parameters(candidate) do
    %{
      "trade_symbol" => candidate_trade_symbol(candidate),
      "units" => candidate_units(candidate),
      "min_price" => candidate_sell_price(candidate),
      "market_trade" => market_trade(candidate)
    }
  end

  # A Candidate Contribution may be a struct or a plain map. Persist a JSON-safe,
  # string-keyed copy and drop absent optional fields so later presence checks
  # keep matching the same shape callers pass in memory.
  defp market_trade(candidate) do
    candidate
    |> stringify_keys()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp candidate_source(candidate),
    do: Map.get(candidate, :source_waypoint) || candidate["source_waypoint"]

  defp candidate_destination(candidate),
    do: Map.get(candidate, :destination_waypoint) || candidate["destination_waypoint"]

  defp candidate_trade_symbol(candidate),
    do: Map.get(candidate, :trade_symbol) || candidate["trade_symbol"]

  defp candidate_units(candidate) do
    Map.get(candidate, :units) ||
      Map.get(candidate, "units") ||
      maximum_units(Map.get(candidate, :expected_outcomes)) ||
      maximum_units(Map.get(candidate, "expected_outcomes"))
  end

  defp maximum_units(%{} = expected_outcomes),
    do: Map.get(expected_outcomes, :maximum_units) || Map.get(expected_outcomes, "maximum_units")

  defp maximum_units(_expected_outcomes), do: nil

  defp candidate_purchase_price(candidate),
    do: Map.get(candidate, :purchase_price) || Map.get(candidate, "purchase_price")

  defp candidate_sell_price(candidate),
    do: Map.get(candidate, :sell_price) || Map.get(candidate, "sell_price")

  def unfinished_intent_for_ship(ship_id) do
    Repo.one(
      from intent in Intent,
        where: intent.ship_id == ^ship_id and intent.status in ^@unfinished_states
    )
  end

  defp reconcile_intents(agent, intent) do
    with {:ok, intent} <- bind_root_intent_authority(agent, intent) do
      ship = Repo.get!(Ship, intent.ship_id)

      case Agent.handle_game_result(
             agent,
             SpaceTraders.Evidence.get_ship_binding(AgentTokenReference.new(agent), ship.symbol)
           ) do
        {:ok, binding} -> advance_intents(agent, intent, Evidence.bound_ship(binding))
        {:error, reason} -> block_intents(intent, reason)
      end
    end
  end

  defp advance_new_intent(agent, intent, live_ship) do
    with {:ok, intent} <- bind_root_intent_authority(agent, intent) do
      advance_intents(agent, intent, live_ship)
    end
  end

  defp bind_root_intent_authority(agent, intent) do
    ship = Repo.get!(Ship, intent.ship_id)

    result =
      Repo.transaction(fn ->
        current = Repo.get!(Intent, intent.id)

        with {:ok, claim} <-
               FleetAllocation.authorize_ship_execution(agent, ship.symbol,
                 lock: true,
                 intent_id: current.id
               ),
             {:ok, binding} <- bind_intent_claim(current, claim) do
          if binding.intent == %{} do
            current
          else
            update_intent!(Ecto.Changeset.change(current, binding.intent))
          end
        else
          _ -> Repo.rollback(:no_current_ship_claim)
        end
      end)

    case result do
      {:ok, intent} ->
        {:ok, intent}

      {:error, :no_current_ship_claim} ->
        supersede_for_lost_claim(intent)
        {:error, :no_current_ship_claim}
    end
  end

  defp intent_matches_event?(_intent, nil), do: false
  defp intent_matches_event?(%Intent{id: id}, id), do: true
  defp intent_matches_event?(_intent, _expected_intent_id), do: false

  # Replacing a pending manual outcome is explicit; it cannot cancel an action
  # the game already accepted, which reconciliation below accounts for.
  defp replace_intents(ship, waypoint) when is_binary(waypoint),
    do: replace_intents(ship, %{type: "navigate", target_waypoint: waypoint})

  defp replace_intents(ship, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      if unresolved_cargo_intent(ship.id) do
        Repo.rollback(:cargo_operation_reconciliation_required)
      end

      case unfinished_intent_for_ship(ship.id) do
        %Intent{} = predecessor ->
          if unresolved_intent_evidence?(predecessor) do
            Repo.rollback(:intents_reconciliation_required)
          else
            terminalize_intents!(predecessor, "stopped")
          end

        nil ->
          :ok
      end

      {:ok, intent} =
        %Intent{ship_id: ship.id}
        |> Intent.changeset(attrs)
        |> Ecto.Changeset.put_change(:status, Map.get(attrs, :status, "active"))
        |> Repo.insert()

      intent
    end)
  end

  defp unresolved_cargo_action?(intent) do
    is_map(intent.in_flight_action) and
      intent.in_flight_action["kind"] in [
        "buy",
        "sell",
        "deliver",
        "extract",
        "siphon",
        "refine",
        "survey",
        "transfer"
      ]
  end

  defp unresolved_jump_action?(intent) do
    is_map(intent.in_flight_action) and intent.in_flight_action["kind"] == "jump"
  end

  defp unresolved_navigation_action?(intent) do
    (is_map(intent.in_flight_action) and
       intent.in_flight_action["kind"] in [
         "navigate",
         "orbit",
         "dock",
         "refuel",
         "set_flight_mode"
       ]) or
      (is_map(intent.last_action_result) and intent.last_action_result["wait"] == "arrival")
  end

  defp prerequisite_action_reconciled?(
         %{"kind" => "orbit", "waypoint" => waypoint},
         live_ship
       ),
       do: live_ship.nav.status == "IN_ORBIT" and live_ship.nav.waypoint_symbol == waypoint

  defp prerequisite_action_reconciled?(%{"kind" => "dock", "waypoint" => waypoint}, live_ship),
    do: live_ship.nav.status == "DOCKED" and live_ship.nav.waypoint_symbol == waypoint

  defp prerequisite_action_reconciled?(%{"kind" => "refuel"} = action, live_ship) do
    fuel_full?(live_ship) or fuel_independent?(live_ship) or
      (is_integer(action["fuel_before"]) and live_ship.fuel.current > action["fuel_before"])
  end

  defp prerequisite_action_reconciled?(
         %{"kind" => "set_flight_mode", "flight_mode" => flight_mode},
         live_ship
       ),
       do: live_ship.nav.flight_mode == flight_mode

  defp prerequisite_action_reconciled?(
         %{"kind" => "navigate", "waypoint" => waypoint},
         live_ship
       ),
       do: arrived_at_target?(live_ship, waypoint) or in_transit_to?(live_ship, waypoint)

  defp prerequisite_action_reconciled?(_action, _live_ship), do: false

  defp in_transit_to?(
         %{nav: %{status: "IN_TRANSIT", route: %{destination: %{symbol: destination}}}},
         destination
       ),
       do: true

  defp in_transit_to?(_live_ship, _destination), do: false

  defp unresolved_warp_action?(intent) do
    is_map(intent.in_flight_action) and intent.in_flight_action["kind"] == "warp"
  end

  @doc false
  def unresolved_cargo_intent(ship_id) do
    Intent
    |> where([intent], intent.ship_id == ^ship_id)
    |> Repo.all()
    |> Enum.find(fn intent ->
      unresolved_cargo_action?(intent)
    end)
  end

  defp terminalize_intents!(intent, status) when status in @terminal_states do
    preserve_evidence? = unresolved_intent_evidence?(intent)

    update_intent!(
      Ecto.Changeset.change(intent,
        status: status,
        in_flight_action: if(preserve_evidence?, do: intent.in_flight_action, else: nil),
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    )
  end

  defp unresolved_intent_evidence?(intent) do
    unresolved_cargo_action?(intent) or unresolved_module_evidence?(intent) or
      unresolved_jump_action?(intent) or unresolved_warp_action?(intent) or
      unresolved_navigation_action?(intent)
  end

  defp unresolved_module_evidence?(%Intent{type: type, in_flight_action: action})
       when type in ["install_module", "remove_module"] and is_map(action),
       do: true

  defp unresolved_module_evidence?(_intent), do: false

  # The Navigate Intent reconcile loop. Every step derives the next API action
  # from authoritative Ship state — location, navigation state, posture, fuel,
  # arrival, and cooldown — so recovery can resume from game truth instead of
  # replaying a fixed script.
  defp advance_intents(agent, intent, live_ship) do
    result =
      case MutationAttempts.latest_for_intent(intent) do
        nil when is_map(intent.in_flight_action) ->
          block_intents(intent, {:ambiguous_operation_evidence, intent.in_flight_action["kind"]})

        %{state: "prepared"} when is_map(intent.in_flight_action) ->
          resume_prepared_action(agent, intent, live_ship)

        %{state: "absent", retry_authorized: true}
        when is_map(intent.in_flight_action) and
               :erlang.map_get("kind", intent.in_flight_action) == "deliver" ->
          do_advance_intents(agent, intent, live_ship)

        %{state: "absent", retry_authorized: true} = absent
        when is_map(intent.in_flight_action) ->
          if prerequisite_action_reconciled?(intent.in_flight_action, live_ship) do
            with {:ok, observations} <-
                   accepted_observations(
                     agent,
                     live_ship,
                     absent,
                     intent.in_flight_action,
                     "Fresh evidence satisfies the selected outcome before retry"
                   ),
                 {:ok, _} <- MutationAttempts.withdraw_retry(absent, observations) do
              do_advance_intents(agent, intent, live_ship)
            end
          else
            retry_absent_action(agent, intent, live_ship, intent.in_flight_action, absent)
          end

        _ ->
          do_advance_intents(agent, intent, live_ship)
      end

    case result do
      {:error, reason} -> block_intents(intent, {:awaiting_reconciliation, reason})
      result -> result
    end
  end

  defp resume_prepared_action(agent, intent, live_ship) do
    if prerequisite_action_reconciled?(intent.in_flight_action, live_ship) do
      attempt = MutationAttempts.latest_for_intent(intent)

      with {:ok, _} <-
             MutationAttempts.record_not_sent(
               attempt,
               "Authoritative state already satisfies the selected outcome"
             ) do
        do_advance_intents(agent, intent, live_ship)
      end
    else
      if navigation_action?(intent.in_flight_action) or
           intent.in_flight_action["kind"] == "deliver" do
        send_selected_action(agent, intent, live_ship)
      else
        case Agent.handle_game_result(agent, SpaceTraders.API.dispatch_recorded(intent)) do
          {:ok, _result} -> reconcile(agent.id, live_ship.symbol, nil, :intent_retry, intent.id)
          {:error, reason} -> block_intents(intent, {:awaiting_reconciliation, reason})
        end
      end
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{recovery_attempts: attempts} = intent,
         live_ship
       )
       when attempts > 0 do
    case transition_intent(intent, recovery_attempts: 0) do
      {:ok, intent} -> advance_intents(agent, intent, live_ship)
      :intent_no_longer_owned -> :ok
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{type: type, in_flight_action: %{"kind" => "jump"} = action} = intent,
         live_ship
       )
       when type in @navigation_intent_types do
    if arrived_at_target?(live_ship, action["waypoint"]) do
      with :ok <-
             reconcile_accepted_attempt(
               agent,
               intent,
               live_ship,
               "Ship is authoritatively at the jump target"
             ) do
        continue_after_remote_arrival(agent, intent, live_ship)
      end
    else
      reconcile_absent_and_retry(agent, intent, live_ship, action)
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{type: type, in_flight_action: %{"kind" => "warp"} = action} = intent,
         live_ship
       )
       when type in @navigation_intent_types do
    cond do
      arrived_at_target?(live_ship, intent.target_waypoint) ->
        with :ok <-
               reconcile_accepted_attempt(
                 agent,
                 intent,
                 live_ship,
                 "Ship is authoritatively at the warp target"
               ) do
          continue_after_remote_arrival(agent, intent, live_ship)
        end

      in_transit_to?(live_ship, intent.target_waypoint) ->
        with :ok <-
               reconcile_accepted_attempt(
                 agent,
                 intent,
                 live_ship,
                 "Ship is authoritatively in transit by warp"
               ) do
          wait_for_manual_arrival(agent, intent, live_ship)
        end

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      true ->
        reconcile_absent_and_retry(agent, intent, live_ship, action)
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{
           type: "acquire_intelligence",
           in_flight_action: %{"kind" => "scan_waypoints"}
         } = intent,
         live_ship
       ) do
    if intelligence_satisfied_intent?(agent, intent) do
      complete_intents(agent, intent)
    else
      reconcile_scan_intelligence(agent, intent, live_ship)
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{type: "acquire_intelligence", in_flight_action: %{"kind" => "chart"}} = intent,
         _live_ship
       ) do
    if intelligence_satisfied_intent?(agent, intent) do
      complete_intents(agent, intent)
    else
      reconcile_chart_intelligence(agent, intent)
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{type: type, in_flight_action: %{"kind" => kind} = action} = intent,
         live_ship
       )
       when type in @navigation_intent_types and
              kind in ["navigate", "orbit", "dock", "refuel", "set_flight_mode"] do
    if prerequisite_action_reconciled?(action, live_ship) do
      with :ok <-
             reconcile_accepted_attempt(
               agent,
               intent,
               live_ship,
               "Authoritative Ship state proves the #{kind} outcome"
             ) do
        continue_after_reconciled_action(agent, intent, live_ship, action)
      end
    else
      reconcile_absent_and_retry(agent, intent, live_ship, action)
    end
  end

  defp do_advance_intents(agent, %Intent{type: "navigate"} = intent, live_ship),
    do: advance_navigation(agent, intent, live_ship)

  defp do_advance_intents(agent, %Intent{type: "acquire_intelligence"} = intent, live_ship) do
    type = intelligence_type(intent)
    system = intent.parameters["system"]

    if intelligence_satisfied_intent?(agent, intent) do
      complete_intents(agent, intent)
    else
      acquire_intelligence(agent, intent, live_ship, type, system)
    end
  end

  defp do_advance_intents(agent, %Intent{type: "acquire_resources"} = intent, live_ship) do
    case intent.in_flight_action do
      %{"kind" => kind} = action when kind in ["extract", "siphon", "refine", "survey"] ->
        reconcile_resource_action(agent, intent, live_ship, action)

      %{"kind" => kind} = action when kind in ["orbit", "navigate", "dock"] ->
        if prerequisite_action_reconciled?(action, live_ship) do
          with :ok <-
                 reconcile_accepted_attempt(
                   agent,
                   intent,
                   live_ship,
                   "Ship position is authoritative"
                 ),
               {:ok, intent} <- transition_intent(intent, in_flight_action: nil) do
            advance_intents(agent, intent, live_ship)
          end
        else
          block_intents(intent, {:ambiguous_operation_evidence, kind})
        end

      _ ->
        advance_resource_intent(agent, intent, live_ship)
    end
  end

  defp do_advance_intents(agent, %Intent{type: "transfer"} = intent, live_source) do
    case intent.in_flight_action do
      %{"kind" => "transfer"} = action ->
        reconcile_transfer(agent, intent, live_source, action)

      nil ->
        dispatch_transfer(agent, intent, live_source)
    end
  end

  defp do_advance_intents(agent, %Intent{type: type} = intent, live_ship)
       when type in ["install_module", "remove_module"] do
    case intent.in_flight_action do
      %{"kind" => ^type} ->
        confirm_module_mutation(agent, intent, live_ship)

      %{"kind" => "buy"} = action ->
        reconcile_refit_buy(agent, intent, live_ship, action)

      %{"kind" => kind} = action when kind in ["navigate", "orbit", "dock"] ->
        if prerequisite_action_reconciled?(action, live_ship) do
          with :ok <-
                 reconcile_accepted_attempt(
                   agent,
                   intent,
                   live_ship,
                   "Authoritative Ship state proves the #{kind} prerequisite outcome"
                 ) do
            case transition_intent(intent, in_flight_action: nil) do
              {:ok, intent} -> advance_intents(agent, intent, live_ship)
              :intent_no_longer_owned -> :ok
            end
          end
        else
          block_module_intent(intent, {:ambiguous_operation_evidence, kind})
        end

      _ ->
        dispatch_module_intent(agent, intent, live_ship)
    end
  end

  defp do_advance_intents(agent, %Intent{type: type} = intent, live_ship)
       when type in ["buy", "sell", "deliver"] do
    case intent.in_flight_action do
      %{"kind" => kind} = action when kind in ["navigate", "orbit", "dock"] ->
        if prerequisite_action_reconciled?(action, live_ship) do
          with :ok <-
                 reconcile_accepted_attempt(
                   agent,
                   intent,
                   live_ship,
                   "Authoritative Ship state proves the #{kind} prerequisite outcome"
                 ) do
            case transition_intent(intent, in_flight_action: nil) do
              {:ok, intent} -> advance_intents(agent, intent, live_ship)
              :intent_no_longer_owned -> :ok
            end
          end
        else
          block_cargo_intent(intent, {:ambiguous_operation_evidence, kind})
        end

      action when is_map(action) and type == "deliver" ->
        reconcile_deliver_cargo_intent(agent, intent, live_ship, action)

      action when is_map(action) ->
        # Ship cargo alone cannot correlate a Market sale to this command.
        block_cargo_intent(intent, {:ambiguous_operation_evidence, type})

      _ ->
        advance_cargo_intent(agent, intent, live_ship)
    end
  end

  defp dispatch_transfer(agent, intent, source) do
    target_symbol = intent.parameters["target_ship"]
    symbol = intent.parameters["trade_symbol"]

    with {:ok,
          %{commitment_id: target_id, portfolio_id: portfolio_id, portfolio_version: version}} <-
           FleetAllocation.current_ship_claim(agent, target_symbol),
         %Commitment{fleet_commitment_portfolio_id: ^portfolio_id} <-
           Repo.get(Commitment, target_id),
         true <-
           portfolio_id == intent.fleet_commitment_portfolio_id and
             version == intent.fleet_commitment_portfolio_version,
         {:ok, target} <- fresh_ship(agent, target_symbol, nil),
         true <-
           source.nav.status != "IN_TRANSIT" and target.nav.status != "IN_TRANSIT" and
             source.nav.waypoint_symbol == target.nav.waypoint_symbol,
         available <- Fleet.item_units(source.cargo, symbol),
         free <- target.cargo.capacity - target.cargo.units,
         true <- available > 0 and free > 0,
         units <- min(intent.parameters["units"], min(available, free)),
         {:ok, %{intent: intent}} <-
           prepare_recorded_action(agent, intent, %{
             "kind" => "transfer",
             "trade_symbol" => symbol,
             "target_ship" => target_symbol,
             "units" => units,
             "source_before" => available,
             "target_before" => Fleet.item_units(target.cargo, symbol)
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.dispatch_recorded(intent)
           ) do
        {:ok, %{cargo: cargo}} ->
          if Fleet.item_units(cargo, symbol) == available - units do
            reconcile_transfer(agent, intent, %{source | cargo: cargo}, intent.in_flight_action)
          else
            block_cargo_intent(intent, {:ambiguous_operation_evidence, "transfer"})
          end

        {:error, %SpaceTraders.API.GameplayError{} = reason} ->
          block_protocol_backpressure(intent, reason)

        {:error, reason} ->
          block_cargo_intent(intent, reason)
      end
    else
      false -> mark_infeasible(intent, :transfer_prerequisite_unavailable)
      {:error, reason} -> block_cargo_intent(intent, reason)
    end
  end

  defp reconcile_transfer(agent, intent, source, action) do
    symbol = action["trade_symbol"]

    with {:ok, fresh_source} <- fresh_ship(agent, source.symbol, nil),
         {:ok, target} <- fresh_ship(agent, action["target_ship"], nil),
         true <-
           Fleet.item_units(fresh_source.cargo, symbol) ==
             action["source_before"] - action["units"] and
             Fleet.item_units(target.cargo, symbol) == action["target_before"] + action["units"],
         :ok <- settle_transfer_attempt(agent, intent, fresh_source, target) do
      complete_cargo_intent(agent, intent, action["units"], nil, %{cargo: fresh_source.cargo})
    else
      _ ->
        case MutationAttempts.latest_for_intent(intent) do
          %{state: "rejected"} -> mark_infeasible(intent, :transfer_rejected)
          _ -> block_cargo_intent(intent, {:ambiguous_operation_evidence, "transfer"})
        end
    end
  end

  defp settle_transfer_attempt(agent, intent, source, target) do
    case MutationAttempts.unresolved_for_intent(intent) do
      nil ->
        :ok

      attempt ->
        observations =
          for ship <- [source, target] do
            reconciliation_observation(
              "get-my-ship",
              [DependencyKey.ship(agent.id, ship.symbol)],
              attempt,
              :accepted,
              "Both Ships' Cargo proves the transfer",
              %{cargo: cargo_evidence(ship.cargo)}
            )
          end

        case MutationAttempts.reconcile(attempt, :accepted, observations) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp advance_navigation(agent, intent, live_ship) do
    cond do
      arrived_at_target?(live_ship, intent.target_waypoint) ->
        if intent.type == "navigate",
          do: complete_intents(agent, intent),
          else: advance_intents(agent, intent, live_ship)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      arrived_at_intermediate_waypoint?(intent, live_ship) ->
        case transition_intent(intent, in_flight_action: nil) do
          {:ok, intent} -> advance_intents(agent, intent, live_ship)
          :intent_no_longer_owned -> :ok
        end

      refuel_required?(intent, live_ship) and docked?(live_ship) ->
        refuel_for_navigate(agent, intent, live_ship)

      refuel_required?(intent, live_ship) ->
        dock_for_navigate(agent, intent, live_ship)

      flight_mode_mismatch?(intent, live_ship) ->
        set_flight_mode_for_navigate(agent, intent, live_ship)

      true ->
        advance_navigation_route(agent, intent, live_ship)
    end
  end

  defp advance_navigation_route(agent, intent, live_ship) do
    case local_leg_fuel_preflight(agent, intent, live_ship) do
      :ok ->
        cond do
          docked?(live_ship) ->
            orbit_for_intents(agent, intent, live_ship)

          remote_waypoint?(live_ship.nav.waypoint_symbol, intent.target_waypoint) ->
            advance_manual_remote_route(agent, intent, live_ship)

          true ->
            dispatch_manual_navigate(agent, intent, live_ship)
        end

      {:refuel, required} ->
        parameters =
          intent.parameters
          |> Map.put("refuel", "to_capacity")
          |> Map.put("estimated_fuel_required", required)

        case transition_intent(intent, parameters: parameters) do
          {:ok, intent} -> advance_navigation(agent, intent, live_ship)
          :intent_no_longer_owned -> :ok
        end

      {:navigate_fuel_stop, waypoint} ->
        if docked?(live_ship),
          do: orbit_for_intents(agent, intent, live_ship),
          else: dispatch_manual_navigate(agent, intent, live_ship, waypoint)

      {:error, reason} ->
        block_intents(intent, reason)
    end
  end

  defp continue_after_remote_arrival(agent, intent, live_ship) do
    case transition_intent(intent, in_flight_action: nil) do
      {:ok, intent} ->
        if intent.type == "navigate" and arrived_at_target?(live_ship, intent.target_waypoint),
          do: complete_intents(agent, intent),
          else: advance_intents(agent, intent, live_ship)

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp intelligence_type(%Intent{parameters: %{"subject_type" => "waypoint"}}), do: :waypoint
  defp intelligence_type(%Intent{parameters: %{"subject_type" => "market"}}), do: :market
  defp intelligence_type(%Intent{parameters: %{"subject_type" => "shipyard"}}), do: :shipyard

  defp intelligence_satisfied_intent?(agent, intent) do
    intelligence_satisfied?(
      agent,
      intent,
      intelligence_type(intent),
      intent.parameters["system"],
      intent.parameters["required_facts"],
      intent.parameters["freshness_seconds"]
    )
  end

  defp intelligence_satisfied?(agent, intent, type, system, fields, freshness) do
    projection =
      World.intelligence(
        agent,
        type,
        system,
        intent.target_waypoint,
        Clock.utc_now(),
        freshness
      )

    Enum.all?(fields, &(get_in(projection, [:facts, &1, :freshness]) == :fresh))
  end

  defp acquire_intelligence(agent, intent, live_ship, :waypoint, system) do
    reference = AgentTokenReference.new(agent)

    case Agent.handle_game_result(
           agent,
           Evidence.get_waypoint(reference, system, intent.target_waypoint,
             owner: "ship_execution",
             required_facts: intent.parameters["required_facts"]
           )
         ) do
      {:ok, waypoint} ->
        with {:ok, _observation} <-
               Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoint") do
          projection =
            World.intelligence(
              agent,
              :waypoint,
              system,
              intent.target_waypoint,
              Clock.utc_now(),
              intent.parameters["freshness_seconds"]
            )

          missing =
            Enum.reject(
              intent.parameters["required_facts"],
              &(get_in(projection, [:facts, &1, :freshness]) == :fresh)
            )

          cond do
            missing == [] -> complete_intents(agent, intent)
            missing == ["chart"] -> chart_intelligence(agent, intent, live_ship)
            true -> block_intents(intent, :intelligence_incomplete)
          end
        end

      {:error, reason} ->
        case reason do
          %SpaceTraders.API.GameplayError{code: 404} ->
            scan_intelligence(agent, intent, live_ship)

          _ ->
            block_intents(intent, reason)
        end
    end
  end

  defp acquire_intelligence(agent, intent, live_ship, type, system)
       when type in [:market, :shipyard] do
    cond do
      live_ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_navigation(agent, intent, live_ship)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      not docked?(live_ship) ->
        dock_for_cargo_intent(agent, intent, live_ship)

      true ->
        reference = AgentTokenReference.new(agent)

        result =
          case type do
            :market ->
              Evidence.get_market(reference, system, intent.target_waypoint,
                owner: "ship_execution",
                required_facts: intent.parameters["required_facts"]
              )

            :shipyard ->
              Evidence.get_shipyard(reference, system, intent.target_waypoint,
                owner: "ship_execution",
                required_facts: intent.parameters["required_facts"]
              )
          end

        case Agent.handle_game_result(agent, result) do
          {:ok, listing} ->
            opts = [source: "get_#{type}", observing_ship_symbol: live_ship.symbol]

            retained =
              case type do
                :market ->
                  Intelligence.observe_market(agent, system, listing, opts)

                :shipyard ->
                  Intelligence.observe_shipyard(
                    agent,
                    system,
                    listing,
                    opts ++ [offers_visible: true]
                  )
              end

            with {:ok, _observation} <- retained do
              if intelligence_satisfied?(
                   agent,
                   intent,
                   type,
                   system,
                   intent.parameters["required_facts"],
                   intent.parameters["freshness_seconds"]
                 ) do
                complete_intents(agent, intent)
              else
                block_intents(intent, :intelligence_incomplete)
              end
            end

          {:error, reason} ->
            block_intents(intent, reason)
        end
    end
  end

  defp scan_intelligence(agent, intent, live_ship) do
    sensor? =
      Enum.any?(live_ship.mounts || [], fn mount ->
        is_binary(mount.symbol) and String.starts_with?(mount.symbol, "MOUNT_SENSOR_ARRAY")
      end)

    cond do
      intent.parameters["scan_attempted"] == true and
        "chart" in intent.parameters["required_facts"] and
          known_intelligence_waypoint?(agent, intent) ->
        chart_intelligence(agent, intent, live_ship)

      intent.parameters["scan_attempted"] ->
        block_intents(intent, :scan_result_unavailable)

      live_ship.nav.system_symbol != intent.parameters["system"] ->
        block_intents(intent, :scan_out_of_range)

      not sensor? ->
        block_intents(intent, :sensor_mount_missing)

      Fleet.cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      true ->
        with {:ok, %{intent: intent}} <-
               prepare_recorded_action(agent, intent, %{
                 "kind" => "scan_waypoints",
                 "waypoint" => intent.target_waypoint
               }) do
          case Agent.handle_game_result(
                 agent,
                 SpaceTraders.API.dispatch_recorded(intent)
               ) do
            {:ok, %{waypoints: waypoints}} ->
              Enum.each(waypoints, fn waypoint ->
                Intelligence.observe_waypoint(agent, waypoint,
                  source: "scan_waypoints",
                  observing_ship_symbol: live_ship.symbol
                )
              end)

              with {:ok, intent} <-
                     transition_intent(intent,
                       in_flight_action: nil,
                       parameters: Map.put(intent.parameters, "scan_attempted", true)
                     ) do
                cond do
                  intelligence_satisfied?(
                    agent,
                    intent,
                    :waypoint,
                    intent.parameters["system"],
                    intent.parameters["required_facts"],
                    intent.parameters["freshness_seconds"]
                  ) ->
                    complete_intents(agent, intent)

                  "chart" in intent.parameters["required_facts"] and
                      known_intelligence_waypoint?(agent, intent) ->
                    chart_intelligence(agent, intent, live_ship)

                  true ->
                    block_intents(intent, :scan_did_not_establish_required_facts)
                end
              end

            {:error, reason} ->
              block_intents(intent, reason)
          end
        else
          {:error, reason} -> block_preparation_refusal(intent, reason)
        end
    end
  end

  defp known_intelligence_waypoint?(agent, intent) do
    World.intelligence(
      agent,
      :waypoint,
      intent.parameters["system"],
      intent.target_waypoint,
      DateTime.utc_now(),
      intent.parameters["freshness_seconds"]
    ).known_existence?
  end

  defp reconcile_scan_intelligence(agent, intent, live_ship) do
    case MutationAttempts.latest_for_intent(intent) do
      %SpaceTraders.MutationAttempts.Attempt{state: "succeeded"} ->
        with {:ok, intent} <-
               transition_intent(intent,
                 in_flight_action: nil,
                 parameters: Map.put(intent.parameters, "scan_attempted", true)
               ) do
          if Fleet.cooldown_active?(live_ship),
            do: wait_for_manual_cooldown(agent, intent, live_ship),
            else: block_intents(intent, :scan_result_unavailable)
        end

      %{sent_or_unknown_at: %DateTime{}} = attempt
      when attempt.state in ["sent_or_unknown", "ambiguous", "bounded_unknown"] ->
        expiration = live_ship.cooldown && live_ship.cooldown.expiration

        with true <- Fleet.cooldown_active?(live_ship),
             {:ok, cooldown_at, _} <- DateTime.from_iso8601(expiration),
             true <- DateTime.after?(cooldown_at, attempt.sent_or_unknown_at),
             {:ok, _} <-
               MutationAttempts.reconcile(attempt, :accepted, [
                 Evidence.reconciliation_observation(
                   "get-my-ship",
                   attempt,
                   :accepted,
                   "Fresh Ship cooldown proves a scan occurred after its dispatch",
                   Evidence.recovery_observed_at(
                     attempt.agent_id,
                     "get-my-ship",
                     attempt.dependency_keys,
                     attempt.prepared_at
                   )
                 )
               ]),
             {:ok, intent} <-
               transition_intent(intent,
                 in_flight_action: nil,
                 parameters: Map.put(intent.parameters, "scan_attempted", true)
               ) do
          wait_for_manual_cooldown(agent, intent, live_ship)
        else
          _ -> block_intents(intent, :scan_outcome_unresolved)
        end

      _ ->
        block_intents(intent, :scan_outcome_unresolved)
    end
  end

  defp chart_intelligence(agent, intent, live_ship) do
    cond do
      live_ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_navigation(agent, intent, live_ship)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      docked?(live_ship) ->
        orbit_for_intents(agent, intent, live_ship)

      true ->
        with {:ok, %{intent: intent}} <-
               prepare_recorded_action(agent, intent, %{
                 "kind" => "chart",
                 "waypoint" => intent.target_waypoint
               }) do
          case Agent.handle_game_result(
                 agent,
                 SpaceTraders.API.dispatch_recorded(intent)
               ) do
            {:ok,
             %{chart: %{waypoint_symbol: waypoint}, waypoint: %{symbol: waypoint} = observed}}
            when waypoint == intent.target_waypoint ->
              with {:ok, _} <-
                     Intelligence.observe_waypoint(agent, observed,
                       source: "create_chart",
                       observing_ship_symbol: live_ship.symbol
                     ),
                   {:ok, intent} <- transition_intent(intent, in_flight_action: nil) do
                advance_intents(agent, intent, live_ship)
              end

            {:ok, _response} ->
              block_intents(intent, :chart_response_incomplete)

            {:error, reason} ->
              block_intents(intent, reason)
          end
        else
          {:error, reason} -> block_preparation_refusal(intent, reason)
        end
    end
  end

  defp reconcile_chart_intelligence(agent, intent) do
    attempt = MutationAttempts.latest_for_intent(intent)

    if attempt && attempt.state in ["sent_or_unknown", "ambiguous", "succeeded"] do
      reconcile_chart_observation(agent, intent, attempt)
    else
      block_intents(intent, :chart_response_incomplete)
    end
  end

  defp reconcile_chart_observation(agent, intent, attempt) do
    case Agent.handle_game_result(
           agent,
           Evidence.get_waypoint(
             AgentTokenReference.new(agent),
             intent.parameters["system"],
             intent.target_waypoint,
             lane: :safety,
             owner: "ship_execution",
             required_facts: ["chart"]
           )
         ) do
      {:ok, %{chart: %{submitted_by: submitted_by, submitted_on: submitted_on}} = waypoint}
      when submitted_by == agent.symbol and is_binary(submitted_on) ->
        with {:ok, chart_time, _} <- DateTime.from_iso8601(submitted_on),
             true <- chart_after_dispatch?(chart_time, attempt),
             :ok <- reconcile_successful_chart(attempt),
             {:ok, _} <-
               Intelligence.observe_waypoint(agent, waypoint,
                 source: "get_waypoint",
                 observing_ship_symbol: Repo.get!(Ship, intent.ship_id).symbol
               ),
             {:ok, intent} <- transition_intent(intent, in_flight_action: nil) do
          complete_intents(agent, intent)
        else
          _ -> block_intents(intent, :chart_outcome_unresolved)
        end

      _ ->
        block_intents(intent, :chart_outcome_unresolved)
    end
  end

  defp chart_after_dispatch?(_chart_time, %{sent_or_unknown_at: nil}), do: false

  defp chart_after_dispatch?(chart_time, %{state: state, sent_or_unknown_at: sent_at})
       when state == "succeeded",
       do: DateTime.compare(chart_time, DateTime.truncate(sent_at, :second)) in [:eq, :gt]

  defp chart_after_dispatch?(chart_time, attempt),
    do:
      DateTime.compare(chart_time, DateTime.truncate(attempt.sent_or_unknown_at, :second)) in [
        :eq,
        :gt
      ]

  defp reconcile_successful_chart(%{state: "succeeded"}), do: :ok

  defp reconcile_successful_chart(attempt) do
    with {:ok, _} <-
           MutationAttempts.reconcile(attempt, :accepted, [
             Evidence.reconciliation_observation(
               "get-waypoint",
               attempt,
               :accepted,
               "Fresh Waypoint chart is attributed to the Agent after dispatch",
               Evidence.recovery_observed_at(
                 attempt.agent_id,
                 "get-waypoint",
                 attempt.dependency_keys,
                 attempt.prepared_at
               )
             )
           ]) do
      :ok
    else
      _ -> {:error, :chart_reconciliation_failed}
    end
  end

  defp advance_resource_intent(agent, intent, ship) do
    cond do
      in_transit?(ship) ->
        wait_for_manual_arrival(agent, intent, ship)

      ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_navigation(agent, intent, ship)

      Fleet.cooldown_active?(ship) ->
        wait_for_manual_cooldown(agent, intent, ship)

      docked?(ship) ->
        orbit_for_intents(agent, intent, ship)

      not resource_ready?(intent, ship) ->
        block_intents(intent, :resource_capability_unavailable)

      ship.cargo.units >= ship.cargo.capacity and intent.parameters["mode"] != "refine" ->
        block_intents(intent, :cargo_full)

      true ->
        dispatch_resource_action(agent, intent, ship)
    end
  end

  defp resource_ready?(%Intent{parameters: %{"mode" => "extract"}}, ship),
    do: Enum.any?(ship.mounts || [], &String.starts_with?(&1.symbol, "MOUNT_MINING_LASER"))

  defp resource_ready?(%Intent{parameters: %{"mode" => "siphon"}}, ship),
    do: Enum.any?(ship.mounts || [], &String.starts_with?(&1.symbol, "MOUNT_GAS_SIPHON"))

  defp resource_ready?(%Intent{parameters: %{"mode" => "refine", "produce" => produce}}, ship) do
    Enum.any?(
      ship.modules || [],
      &(&1.symbol in ~w(MODULE_MINERAL_PROCESSOR_I MODULE_MICRO_REFINERY_I MODULE_ORE_REFINERY_I))
    ) and
      Fleet.item_units(ship.cargo, produce <> "_ORE") >= 100
  end

  defp dispatch_resource_action(agent, intent, ship) do
    mode = intent.parameters["mode"]
    survey = intent.parameters["survey"]
    survey? = mode == "extract" and valid_survey?(survey, ship.nav.waypoint_symbol)

    kind =
      if mode == "extract" and not survey? and intent.parameters["survey_attempted"] != true and
           Enum.any?(ship.mounts || [], &String.starts_with?(&1.symbol, "MOUNT_SURVEYOR")),
         do: "survey",
         else: mode

    action = %{
      "kind" => kind,
      "cargo_before" => cargo_evidence(ship.cargo),
      "waypoint" => ship.nav.waypoint_symbol,
      "survey" => if(survey?, do: survey),
      "produce" => intent.parameters["produce"]
    }

    with {:ok, %{intent: intent}} <- prepare_recorded_action(agent, intent, action) do
      case Agent.handle_game_result(agent, SpaceTraders.API.dispatch_recorded(intent)) do
        {:ok, response} ->
          accept_resource_response(agent, intent, ship, kind, response)

        {:error, %SpaceTraders.API.GameplayError{} = reason} ->
          clear_claim_and_block(intent, reason)

        {:error, reason} ->
          block_intents(intent, reason)
      end
    else
      {:error, reason} -> block_preparation_refusal(intent, reason)
    end
  end

  defp valid_survey?(
         %{"symbol" => symbol, "expiration" => expiration, "signature" => signature},
         symbol
       )
       when is_binary(signature) do
    case DateTime.from_iso8601(expiration) do
      {:ok, at, _} -> DateTime.after?(at, DateTime.utc_now())
      _ -> false
    end
  end

  defp valid_survey?(_, _), do: false

  defp accept_resource_response(agent, intent, ship, "survey", %{surveys: surveys} = response) do
    survey = Enum.find(surveys || [], &(&1.symbol == ship.nav.waypoint_symbol))

    parameters =
      intent.parameters
      |> Map.put("survey_attempted", true)
      |> Map.put("survey", if(survey, do: resource_survey_payload(survey)))

    with {:ok, intent} <- transition_intent(intent, parameters: parameters, in_flight_action: nil) do
      if response.cooldown && response.cooldown.remaining_seconds > 0,
        do: wait_for_manual_cooldown(agent, intent, %{ship | cooldown: response.cooldown}),
        else: advance_intents(agent, intent, ship)
    end
  end

  defp accept_resource_response(agent, intent, ship, kind, response) do
    with %{cargo: cargo, cooldown: cooldown} <- response,
         true <- is_map(cargo) and is_map(cooldown),
         {:ok, yield} <- resource_yield(kind, response),
         true <- resource_yield_matches_request?(kind, yield, intent),
         true <- resource_cargo_proves?(intent.in_flight_action["cargo_before"], cargo, yield) do
      # Keep the cooldown wakeup durable before finishing this Intent.
      schedule_cooldown(agent, ship.symbol, response)

      outcome =
        transition_intent(intent,
          status: "completed",
          in_flight_action: nil,
          last_action_result: %{
            "kind" => kind,
            "yield" => yield,
            "cargo" => cargo_evidence(cargo),
            "cooldown" => cooldown.expiration
          },
          blocker: nil,
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      if match?({:ok, _}, outcome) do
        FleetAllocation.reconcile_completed_outcomes()
        announce_resource_ready(agent, ship, cooldown)
      end

      outcome
    else
      _ -> block_intents(intent, :resource_outcome_unresolved)
    end
  end

  defp resource_yield("extract", %{extraction: %{yield: %{symbol: symbol, units: units}}}),
    do: {:ok, %{"symbol" => symbol, "units" => units}}

  defp resource_yield("siphon", %{siphon: %{yield: %{symbol: symbol, units: units}}}),
    do: {:ok, %{"symbol" => symbol, "units" => units}}

  defp resource_yield("refine", %{produced: produced, consumed: consumed})
       when is_list(produced) and is_list(consumed) and produced != [] and consumed != [],
       do: {:ok, %{"produced" => produced, "consumed" => consumed}}

  defp resource_yield(_, _), do: {:error, :missing_resource_yield}

  defp resource_yield_matches_request?("refine", yield, intent) do
    produce = intent.parameters["produce"]

    is_binary(produce) and
      yield == %{
        "produced" => [%{"tradeSymbol" => produce, "units" => 10}],
        "consumed" => [%{"tradeSymbol" => produce <> "_ORE", "units" => 100}]
      }
  end

  defp resource_yield_matches_request?(_, _yield, _intent), do: true

  defp resource_cargo_proves?(before, cargo, %{"symbol" => symbol, "units" => units})
       when is_binary(symbol) and is_integer(units) and units > 0 do
    cargo_delta(before, cargo) == %{symbol => units} and cargo.units - before["units"] == units
  end

  defp resource_cargo_proves?(before, cargo, %{"produced" => produced, "consumed" => consumed}) do
    valid? =
      Enum.all?(produced ++ consumed, fn
        %{"tradeSymbol" => symbol, "units" => units} ->
          is_binary(symbol) and symbol != "" and is_integer(units) and units > 0

        _ ->
          false
      end)

    if valid?, do: valid_refine_cargo?(before, cargo, produced, consumed), else: false
  end

  defp resource_cargo_proves?(_, _, _), do: false

  defp valid_refine_cargo?(before, cargo, produced, consumed) do
    changes =
      Enum.reduce(produced, %{}, fn %{"tradeSymbol" => symbol, "units" => units}, acc ->
        Map.update(acc, symbol, units, &(&1 + units))
      end)
      |> then(fn changes ->
        Enum.reduce(consumed, changes, fn %{"tradeSymbol" => symbol, "units" => units}, acc ->
          Map.update(acc, symbol, -units, &(&1 - units))
        end)
      end)

    map_size(changes) > 0 and
      cargo_delta(before, cargo) ==
        Map.reject(changes, fn {_symbol, delta} -> delta == 0 end) and
      cargo.units - before["units"] == Enum.sum(Map.values(changes))
  end

  defp cargo_units_evidence(%{"inventory" => items}, symbol),
    do: items |> Enum.find(%{"units" => 0}, &(&1["symbol"] == symbol)) |> Map.fetch!("units")

  defp cargo_units_evidence(cargo, symbol), do: Fleet.item_units(cargo, symbol)

  defp cargo_delta(before, cargo) do
    symbols =
      Enum.map(before["inventory"], & &1["symbol"]) ++
        Enum.map(cargo.inventory || [], & &1.symbol)

    symbols
    |> Enum.uniq()
    |> Map.new(fn symbol ->
      {symbol, cargo_units_evidence(cargo, symbol) - cargo_units_evidence(before, symbol)}
    end)
    |> Map.reject(fn {_symbol, delta} -> delta == 0 end)
  end

  defp resource_survey_payload(survey) do
    %{
      "symbol" => survey.symbol,
      "signature" => survey.signature,
      "expiration" => survey.expiration,
      "size" => survey.size,
      "deposits" => Enum.map(survey.deposits || [], &%{"symbol" => &1.symbol})
    }
  end

  defp reconcile_resource_action(agent, intent, ship, %{"kind" => "survey"}) do
    attempt = MutationAttempts.latest_for_intent(intent)

    confirmed? =
      case {attempt, ship.cooldown} do
        {%{state: "succeeded"}, _} ->
          true

        {%{state: state, sent_or_unknown_at: %DateTime{} = sent}, %{expiration: expiration}}
        when state in ["sent_or_unknown", "ambiguous", "bounded_unknown"] and
               is_binary(expiration) ->
          with true <- Fleet.cooldown_active?(ship),
               {:ok, expires, _} <- DateTime.from_iso8601(expiration),
               true <- DateTime.after?(expires, sent),
               :ok <- reconcile_resource_attempt(attempt) do
            true
          else
            _ -> false
          end

        _ ->
          false
      end

    if confirmed? do
      with {:ok, intent} <-
             transition_intent(intent,
               in_flight_action: nil,
               parameters: Map.put(intent.parameters, "survey_attempted", true)
             ) do
        if Fleet.cooldown_active?(ship),
          do: wait_for_manual_cooldown(agent, intent, ship),
          else: advance_intents(agent, intent, ship)
      end
    else
      block_intents(intent, :survey_outcome_unresolved)
    end
  end

  defp reconcile_resource_action(agent, intent, ship, %{"kind" => kind, "cargo_before" => before}) do
    attempt = MutationAttempts.latest_for_intent(intent)
    delta = cargo_delta(before, ship.cargo)

    accepted? =
      case {kind, delta} do
        {mode, %{}} when mode in ["extract", "siphon"] ->
          map_size(delta) == 1 and Enum.all?(delta, fn {_symbol, units} -> units > 0 end) and
            ship.cargo.units - before["units"] == Enum.sum(Map.values(delta))

        {"refine", changes} ->
          is_binary(intent.parameters["produce"]) and
            changes[intent.parameters["produce"]] == 10 and
            changes[intent.parameters["produce"] <> "_ORE"] == -100 and
            map_size(changes) == 2 and ship.cargo.units - before["units"] == -90

        _ ->
          false
      end

    cond do
      (attempt &&
         attempt.state in ["succeeded", "sent_or_unknown", "ambiguous", "bounded_unknown"]) and
          accepted? ->
        with :ok <- resource_acceptance_proven?(attempt, ship),
             :ok <- reconcile_resource_attempt(attempt) do
          yield =
            if kind == "refine",
              do: %{
                "produced" => [%{"tradeSymbol" => intent.parameters["produce"], "units" => 10}],
                "consumed" => [
                  %{"tradeSymbol" => intent.parameters["produce"] <> "_ORE", "units" => 100}
                ]
              },
              else:
                (fn {symbol, units} -> %{"symbol" => symbol, "units" => units} end).(
                  hd(Map.to_list(delta))
                )

          schedule_cooldown(agent, ship.symbol, %{cooldown: ship.cooldown})

          result =
            transition_intent(intent,
              status: "completed",
              in_flight_action: nil,
              last_action_result: %{
                "kind" => kind,
                "yield" => yield,
                "cargo" => cargo_evidence(ship.cargo),
                "reconciled" => true
              },
              finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
            )

          if match?({:ok, _}, result) do
            FleetAllocation.reconcile_completed_outcomes()
            announce_resource_ready(agent, ship, ship.cooldown)
          end

          result
        else
          _ -> block_intents(intent, :resource_outcome_unresolved)
        end

      true ->
        block_intents(intent, :resource_outcome_unresolved)
    end
  end

  defp reconcile_resource_attempt(%{state: "succeeded"}), do: :ok

  defp reconcile_resource_attempt(attempt) do
    case MutationAttempts.reconcile(attempt, :accepted, [
           Evidence.reconciliation_observation(
             "get-my-ship",
             attempt,
             :accepted,
             "Fresh Cargo and post-dispatch cooldown prove acquisition",
             Evidence.recovery_observed_at(
               attempt.agent_id,
               "get-my-ship",
               attempt.dependency_keys,
               attempt.prepared_at
             )
           )
         ]) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp announce_resource_ready(agent, ship, cooldown) do
    if not is_map(cooldown) or not is_integer(cooldown.remaining_seconds) or
         cooldown.remaining_seconds <= 0 do
      Phoenix.PubSub.broadcast(
        SpaceTraders.PubSub,
        "fleet_resource_evidence",
        {:resource_cooldown_recovered, agent.id, ship.nav.system_symbol}
      )
    end
  end

  defp resource_acceptance_proven?(%{state: "succeeded"}, _ship), do: :ok

  defp resource_acceptance_proven?(%{sent_or_unknown_at: nil}, _ship),
    do: {:error, :historical_action_unresolved}

  defp resource_acceptance_proven?(attempt, ship) do
    with true <- Fleet.cooldown_active?(ship),
         {:ok, expires, _} <- DateTime.from_iso8601(ship.cooldown.expiration),
         true <- DateTime.after?(expires, attempt.sent_or_unknown_at) do
      :ok
    else
      _ -> {:error, :resource_outcome_unresolved}
    end
  end

  defp advance_cargo_intent(agent, intent, live_ship) do
    cond do
      live_ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_navigation(agent, intent, live_ship)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      not docked?(live_ship) ->
        dock_for_cargo_intent(agent, intent, live_ship)

      true ->
        dispatch_cargo_intent(agent, intent, live_ship)
    end
  end

  defp dock_for_cargo_intent(agent, intent, live_ship) do
    with {:ok, %{intent: intent}} <-
           prepare_recorded_action(agent, intent, %{
             "kind" => "dock",
             "waypoint" => live_ship.nav.waypoint_symbol
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.dispatch_recorded(intent)
           ) do
        {:ok, %{nav: nav}} ->
          case transition_intent(intent, in_flight_action: nil) do
            {:ok, intent} -> advance_intents(agent, intent, %{live_ship | nav: nav})
            :intent_no_longer_owned -> :ok
          end

        {:error, reason} ->
          block_cargo_intent(intent, reason)
      end
    else
      {:error, reason} -> block_preparation_refusal(intent, reason)
    end
  end

  defp dispatch_cargo_intent(agent, intent, live_ship) do
    if intent.type == "deliver" do
      with {:ok, recipient} <- delivery_recipient_for_intent(agent, intent),
           result <- dispatch_or_complete_construction(agent, intent, live_ship, recipient) do
        result
      else
        {:error, reason} -> block_cargo_intent(intent, reason)
      end
    else
      dispatch_market_cargo_intent(agent, intent, live_ship)
    end
  end

  defp dispatch_or_complete_construction(agent, intent, _live_ship, {:construction, construction})
       when construction.is_complete do
    complete_cargo_intent(
      agent,
      intent,
      0,
      nil,
      %{construction: construction, external_completion: true}
    )
  end

  defp dispatch_or_complete_construction(
         agent,
         intent,
         live_ship,
         {:construction, construction} = recipient
       ) do
    if fulfillment_remaining({:construction, construction}, intent.parameters["trade_symbol"]) ==
         0 do
      complete_cargo_intent(agent, intent, 0, nil, %{
        construction: construction,
        external_completion: true
      })
    else
      dispatch_or_complete_delivery(agent, intent, live_ship, recipient)
    end
  end

  defp dispatch_or_complete_construction(
         agent,
         intent,
         live_ship,
         {:contract, contract} = recipient
       ) do
    if fulfillment_remaining(recipient, intent.parameters["trade_symbol"]) == 0 do
      complete_cargo_intent(agent, intent, 0, nil, %{
        contract: contract,
        external_completion: true
      })
    else
      dispatch_or_complete_delivery(agent, intent, live_ship, recipient)
    end
  end

  defp dispatch_or_complete_construction(agent, intent, live_ship, recipient) do
    dispatch_or_complete_delivery(agent, intent, live_ship, recipient)
  end

  defp dispatch_or_complete_delivery(agent, intent, live_ship, recipient) do
    with {:ok, units, _credits} <- executable_cargo_units(intent, live_ship, recipient, agent) do
      action =
        %{
          "kind" => "deliver",
          "trade_symbol" => intent.parameters["trade_symbol"],
          "units" => units,
          "recipient" => intent.parameters["recipient"]
        }
        |> delivery_action_evidence(recipient, live_ship.cargo, intent.parameters["trade_symbol"])

      execute_action(agent, intent, live_ship, action)
    else
      {:error, reason} -> block_cargo_intent(intent, reason)
    end
  end

  defp dispatch_market_cargo_intent(agent, intent, live_ship) do
    case contract_buy_units(agent, intent) do
      {:ok, 0} ->
        complete_cargo_intent(agent, intent, 0, nil, %{external_completion: true})

      {:ok, units} ->
        dispatch_market_cargo_intent_with_units(
          agent,
          %{intent | parameters: Map.put(intent.parameters, "units", units)},
          live_ship
        )

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp contract_buy_units(agent, %Intent{
         type: "buy",
         parameters: %{"market_trade" => %{"contract_id" => contract_id}} = parameters
       }) do
    with {:ok, contracts} <- Contracts.list_contracts(agent),
         %Contract{} = contract <- Enum.find(contracts, &(&1.id == contract_id)),
         true <- Contracts.active?(contract) or contract.fulfilled do
      {:ok,
       min(
         parameters["units"],
         fulfillment_remaining({:contract, contract}, parameters["trade_symbol"])
       )}
    else
      _ -> {:error, :recipient_unavailable}
    end
  end

  defp contract_buy_units(agent, %Intent{
         type: "buy",
         parameters: %{
           "market_trade" => %{
             "construction" => %{
               "system" => system,
               "waypoint" => waypoint
             }
           },
           "trade_symbol" => symbol,
           "units" => units
         }
       }) do
    with {:ok, construction} <-
           Agent.handle_game_result(
             agent,
             Evidence.get_construction(AgentTokenReference.new(agent), system, waypoint)
           ) do
      Fleet.record_construction_observation(agent, system, construction, "get_construction")

      case SpaceTraders.FleetConstruction.remaining(construction, symbol) do
        count when is_integer(count) -> {:ok, min(units, count)}
        :unknown -> {:error, :construction_progress_unavailable}
      end
    end
  end

  defp contract_buy_units(_agent, intent), do: {:ok, intent.parameters["units"]}

  defp dispatch_market_cargo_intent_with_units(agent, intent, live_ship) do
    with {:ok, good} <- market_good_for_intent(agent, live_ship, intent),
         {:ok, units, _credits} <- executable_cargo_units(intent, live_ship, good, agent) do
      action = %{
        "kind" => intent.type,
        "trade_symbol" => intent.parameters["trade_symbol"],
        "units" => units,
        "listing_price" => cargo_price(intent.type, good),
        "cargo_before" => Fleet.item_units(live_ship.cargo, intent.parameters["trade_symbol"])
      }

      with {:ok, %{intent: intent}} <- prepare_recorded_action(agent, intent, action) do
        execute_cargo_intent(agent, intent, live_ship, units, good)
      else
        {:error, reason} -> block_preparation_refusal(intent, reason)
      end
    else
      {:error, :listing_missing_trade_good} ->
        block_cargo_intent(
          intent,
          {:listing_missing_trade_good, intent.parameters["trade_symbol"]}
        )

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp market_good_for_intent(_agent, _live_ship, %Intent{
         parameters: %{"market_listing_prevalidated" => true} = parameters
       }) do
    {:ok,
     %{
       symbol: parameters["trade_symbol"],
       sell_price: parameters["sell_price"] || 0,
       trade_volume: parameters["units"]
     }}
  end

  defp market_good_for_intent(agent, live_ship, intent) do
    with {:ok, market} <- Fleet.market_for_ship(agent, live_ship, intent.target_waypoint),
         good when not is_nil(good) <-
           Enum.find(market.trade_goods || [], &(&1.symbol == intent.parameters["trade_symbol"])) do
      {:ok, good}
    else
      nil -> {:error, :listing_missing_trade_good}
      {:error, reason} -> {:error, reason}
    end
  end

  defp executable_cargo_units(
         %Intent{type: "buy", parameters: parameters},
         live_ship,
         good,
         agent
       ) do
    price = good.purchase_price
    max_price = parameters["max_unit_price"] || parameters["max_price"]
    free = max(live_ship.cargo.capacity - live_ship.cargo.units, 0)

    cond do
      is_integer(max_price) and price > max_price ->
        {:error, {:price_constraint, price, max_price}}

      true ->
        with {:ok, overview} <- Agent.agent_overview(agent) do
          available_credits = max(overview.credits - (parameters["reserve_credits"] || 0), 0)

          total_budget =
            parameters["max_total_price"]
            |> then(&if(is_integer(&1), do: min(available_credits, &1), else: available_credits))

          units =
            min(
              parameters["units"],
              min(good.trade_volume, min(free, affordable_cargo_units(total_budget, price)))
            )

          if units > 0, do: {:ok, units, overview.credits}, else: {:error, :buy_unavailable}
        end
    end
  end

  defp executable_cargo_units(
         %Intent{type: "sell", parameters: parameters},
         live_ship,
         good,
         _agent
       ) do
    price = good.sell_price
    min_price = parameters["min_price"]
    held = Fleet.item_units(live_ship, parameters["trade_symbol"])

    cond do
      is_integer(min_price) and price < min_price ->
        {:error, {:price_constraint, price, min_price}}

      good.trade_volume <= 0 ->
        {:error,
         {:market_demand_unavailable, good.symbol, price, good.trade_volume,
          parameters["min_price"]}}

      true ->
        units = min(parameters["units"], min(held, good.trade_volume))

        cond do
          units <= 0 ->
            {:error, :cargo_missing}

          is_integer(parameters["min_total"]) and price * units < parameters["min_total"] ->
            {:error, {:sale_value_constraint, price * units, parameters["min_total"]}}

          true ->
            {:ok, units, nil}
        end
    end
  end

  defp executable_cargo_units(
         %Intent{type: "deliver", parameters: parameters},
         live_ship,
         contract,
         _agent
       ) do
    held = Fleet.item_units(live_ship, parameters["trade_symbol"])
    remaining = fulfillment_remaining(contract, parameters["trade_symbol"])
    units = min(parameters["units"], min(held, remaining))

    if units > 0,
      do: {:ok, units, nil},
      else: {:error, if(remaining <= 0, do: :recipient_rejected_delivery, else: :cargo_missing)}
  end

  @doc false
  def affordable_cargo_units(_credits, 0), do: :infinity
  @doc false
  def affordable_cargo_units(credits, price), do: div(credits, price)

  defp execute_cargo_intent(agent, %Intent{type: "buy"} = intent, _live_ship, units, good) do
    case Agent.handle_game_result(agent, SpaceTraders.API.dispatch_recorded(intent)) do
      {:ok, result} ->
        complete_market_cargo_intent(agent, intent, units, good.purchase_price, result)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp execute_cargo_intent(agent, %Intent{type: "sell"} = intent, _live_ship, units, good) do
    case Agent.handle_game_result(agent, SpaceTraders.API.dispatch_recorded(intent)) do
      {:ok, result} ->
        complete_market_cargo_intent(agent, intent, units, good.sell_price, result)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp cargo_price("buy", good), do: good.purchase_price
  defp cargo_price("sell", good), do: good.sell_price
  defp cargo_price(_, _good), do: nil

  defp bind_intent_claim(intent, %{commitment_id: nil}) do
    if is_nil(intent.fleet_commitment_id) do
      {:ok, %{intent: %{}, action: %{}}}
    else
      {:error, :intent_claim_mismatch}
    end
  end

  defp bind_intent_claim(intent, claim) do
    binding = FleetAllocation.ship_claim_binding(claim)

    current =
      Map.take(intent, [
        :fleet_commitment_id,
        :fleet_commitment_portfolio_id,
        :fleet_commitment_portfolio_version
      ])

    if is_nil(intent.fleet_commitment_id) or current == binding.intent do
      {:ok, binding}
    else
      {:error, :intent_claim_mismatch}
    end
  end

  # Intent callbacks may outlive a pause or preemption. Every durable transition
  # therefore reloads both records under the write lock; manual intents retain
  # their normal unfinished-state behavior.
  @doc false
  def with_current_intent(%Intent{id: id} = expected, fun) do
    case Repo.transaction(fn ->
           case Repo.one(from i in Intent, where: i.id == ^id, lock: "FOR UPDATE") do
             %Intent{} = current ->
               if Intent.unfinished?(current) and
                    intent_owned?(current) and
                    current.in_flight_action == expected.in_flight_action and
                    current.mutation_attempt_id == expected.mutation_attempt_id do
                 fun.(current)
               else
                 Repo.rollback(:intent_no_longer_owned)
               end

             _ ->
               Repo.rollback(:intent_no_longer_owned)
           end
         end) do
      {:ok, result} -> result
      {:error, :intent_no_longer_owned} -> :intent_no_longer_owned
    end
  end

  @doc false
  def transition_intent(intent, attrs) do
    with_current_intent(intent, fn current ->
      updated = update_intent!(Ecto.Changeset.change(current, attrs))
      {:ok, updated}
    end)
  end

  # A withdrawn Claim supersedes the Intent, matching the retired caller seam.
  # Any other refusal keeps the Intent's own blocker and evidence handling.
  defp prepare_recorded_action(agent, intent, action) do
    case RecordedAction.prepare(agent, intent, action) do
      {:error, :no_current_ship_claim} ->
        supersede_for_lost_claim(intent)
        {:error, :no_current_ship_claim}

      result ->
        result
    end
  end

  @doc "Executes a selected outcome through the same progression used on re-entry."
  def execute_action(agent, intent, live_ship, action) do
    with true <- navigation_action?(action) or action["kind"] == "deliver",
         {:ok, %{intent: selected}} <- prepare_recorded_action(agent, intent, action) do
      send_selected_action(agent, selected, live_ship)
    else
      false -> {:error, :unsupported_recorded_action}
      {:error, reason} -> block_preparation_refusal(intent, reason)
    end
  end

  defp navigation_action?(%{"kind" => kind}),
    do: kind in ["navigate", "warp", "orbit", "dock", "set_flight_mode"]

  defp navigation_action?(_), do: false

  defp send_selected_action(agent, selected, live_ship) do
    case Agent.handle_game_result(agent, SpaceTraders.API.dispatch_recorded(selected)) do
      {:ok, result} ->
        continue_selected_response(agent, selected, live_ship, selected.in_flight_action, result)

      {:error, %SpaceTraders.API.GameplayError{type: :insufficient_fuel} = reason} ->
        if selected.in_flight_action["kind"] == "navigate",
          do: recover_insufficient_fuel(agent, selected, live_ship, reason),
          else: block_intents(selected, reason)

      {:error, reason} ->
        block_intents(selected, reason)
    end
  end

  defp block_preparation_refusal(_intent, reason)
       when reason in [:no_current_ship_claim, :intent_dispatch_no_longer_allowed],
       do: :ok

  defp block_preparation_refusal(%Intent{type: type} = intent, reason)
       when type in ["install_module", "remove_module"],
       do: block_module_intent(intent, reason)

  defp block_preparation_refusal(%Intent{type: type} = intent, reason)
       when type in ["buy", "sell", "deliver", "transfer"],
       do: block_cargo_intent(intent, reason)

  defp block_preparation_refusal(intent, reason), do: block_intents(intent, reason)

  defp update_intent!(%Ecto.Changeset{data: intent} = changeset) do
    # A cleared action has no selected attempt. Legacy action replacement must
    # also shed any prior recorded linkage so its own ledger evidence stays
    # discoverable until its caller adopts recorded dispatch (#505).
    changeset =
      if is_nil(Ecto.Changeset.get_field(changeset, :in_flight_action)) or
           Map.has_key?(changeset.changes, :in_flight_action),
         do: Ecto.Changeset.put_change(changeset, :mutation_attempt_id, nil),
         else: changeset

    updated = Repo.update!(changeset)
    emit_intent_transition(intent, updated)
    updated
  end

  defp emit_intent_transition(%Intent{status: state}, %Intent{status: state}), do: :ok

  defp emit_intent_transition(intent, updated),
    do: SpaceTraders.Observability.intent_transition(intent, updated)

  defp intent_owned?(%Intent{}), do: true

  defp complete_market_cargo_intent(
         agent,
         %Intent{type: "buy"} = intent,
         units,
         price,
         %{transaction: transaction} = result
       )
       when is_map(transaction) do
    case validate_market_transaction(intent, transaction, units) do
      :ok ->
        if units == intent.parameters["units"] and
             market_cargo_evidence?(intent, result.cargo, units),
           do: complete_cargo_intent(agent, intent, units, price, result),
           else: block_cargo_intent(intent, :ambiguous_operation_evidence)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp complete_market_cargo_intent(
         agent,
         intent,
         units,
         price,
         %{transaction: transaction} = result
       )
       when is_map(transaction) do
    case validate_market_transaction(intent, transaction, units) do
      :ok ->
        if market_cargo_evidence?(intent, result.cargo, units) do
          complete_cargo_intent(agent, intent, units, price, result)
        else
          block_cargo_intent(intent, :ambiguous_operation_evidence)
        end

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp complete_market_cargo_intent(
         _agent,
         %Intent{parameters: %{"market_listing_prevalidated" => true}} = intent,
         units,
         price,
         %{cargo: cargo} = result
       )
       when is_map(cargo) do
    if market_cargo_evidence?(intent, cargo, units),
      do: complete_cargo_intent_without_transaction(intent, units, price, result),
      else: block_cargo_intent(intent, :ambiguous_operation_evidence)
  end

  defp complete_market_cargo_intent(_agent, intent, _units, _price, _result),
    do: block_cargo_intent(intent, :missing_market_transaction)

  defp complete_cargo_intent_without_transaction(intent, units, price, _result) do
    result = %{"kind" => intent.type, "units" => units, "price" => price}

    transition_intent(intent,
      status: "completed",
      in_flight_action: nil,
      last_action_result: result,
      blocker: nil,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  defp market_cargo_evidence?(%Intent{type: type, in_flight_action: action}, cargo, units)
       when type in ["buy", "sell"] and is_map(action) and is_map(cargo) do
    with cargo_before when is_integer(cargo_before) <- action["cargo_before"],
         trade_symbol when is_binary(trade_symbol) <- Map.get(action, "trade_symbol"),
         cargo_now when is_integer(cargo_now) <- Fleet.item_units(cargo, trade_symbol),
         true <- units > 0 do
      expected_delta = if type == "buy", do: units, else: -units
      cargo_now - cargo_before == expected_delta
    else
      _ -> false
    end
  end

  defp market_cargo_evidence?(_intent, _cargo, _units), do: false

  defp validate_market_transaction(intent, transaction, units) do
    expected_type = if intent.type == "buy", do: "PURCHASE", else: "SELL"
    action = intent.in_flight_action || %{}

    if Map.get(transaction, :type) == expected_type and
         Map.get(transaction, :ship_symbol) == Repo.get!(Ship, intent.ship_id).symbol and
         Map.get(transaction, :waypoint_symbol) == intent.target_waypoint and
         Map.get(transaction, :trade_symbol) == intent.parameters["trade_symbol"] and
         Map.get(transaction, :units) == units and action["units"] == units do
      :ok
    else
      {:error, :unexpected_market_transaction}
    end
  end

  defp complete_cargo_intent(_agent, intent, units, price, response) do
    result = cargo_operation_result(intent, response, units, price)

    case transition_intent(intent,
           status: "completed",
           in_flight_action: nil,
           last_action_result: result,
           blocker: nil,
           finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
         ) do
      {:ok, intent} ->
        if intent.caller == "commitment" and intent.type == "deliver",
          do: FleetAllocation.reconcile_completed_outcomes()

        record_activity_by_intent(
          intent,
          "manual_intent_completed",
          "#{String.capitalize(intent.type)} Goods complete",
          result
        )

        {:ok, intent}

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp dispatch_module_intent(agent, intent, live_ship) do
    cond do
      refit_purchase_needed?(intent, live_ship) ->
        advance_refit_purchase(agent, intent, live_ship)

      true ->
        case module_mutation_allowed?(intent, live_ship) do
          :ok -> dispatch_module_request(agent, intent, live_ship)
          {:error, reason} -> block_module_intent(intent, reason)
        end
    end
  end

  # A purchase-sourced install composes its own supply run: navigate to the
  # Market, dock, buy one module, then prove it in authoritative Cargo before
  # the install mutation may dispatch.
  defp refit_purchase_needed?(
         %Intent{type: "install_module", parameters: %{"refit" => refit}} = intent,
         live_ship
       )
       when is_map(refit) do
    purchased? = intent.parameters["purchased"] == true

    refit["sourcing"] == "purchase" and not purchased? and
      Fleet.item_units(live_ship.cargo, intent.parameters["module_symbol"]) < 1
  end

  defp refit_purchase_needed?(_intent, _live_ship), do: false

  defp advance_refit_purchase(agent, intent, live_ship) do
    cond do
      live_ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_navigation(agent, intent, live_ship)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      not docked?(live_ship) ->
        dock_for_cargo_intent(agent, intent, live_ship)

      true ->
        dispatch_refit_buy(agent, intent, live_ship)
    end
  end

  defp dispatch_refit_buy(agent, intent, live_ship) do
    module_symbol = intent.parameters["module_symbol"]
    max_price = get_in(intent.parameters, ["refit", "max_unit_price"])

    with {:ok, market} <- Fleet.market_for_ship(agent, live_ship, intent.target_waypoint),
         good when not is_nil(good) <-
           Enum.find(market.trade_goods || [], &(&1.symbol == module_symbol)),
         true <-
           (is_nil(max_price) or
              (is_integer(good.purchase_price) and good.purchase_price <= max_price)) ||
             {:error, {:price_constraint, good.purchase_price, max_price}},
         true <-
           live_ship.cargo.capacity - live_ship.cargo.units >= 1 || {:error, :cargo_full},
         {:ok, %{intent: intent}} <-
           prepare_recorded_action(agent, intent, %{
             "kind" => "buy",
             "trade_symbol" => module_symbol,
             "units" => 1,
             "listing_price" => good.purchase_price,
             "cargo_before" => Fleet.item_units(live_ship.cargo, module_symbol)
           }) do
      dispatch_selected_refit_buy(agent, intent, live_ship)
    else
      {:error, %SpaceTraders.API.GameplayError{} = reason} ->
        block_protocol_backpressure(intent, reason)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  # A `with`'s else cannot see its rebound selected Intent. Handle the response
  # with that committed snapshot so a legitimate 429 can persist its durable wait
  # without weakening the stale-selection transition guard.
  defp dispatch_selected_refit_buy(agent, intent, live_ship) do
    case Agent.handle_game_result(agent, SpaceTraders.API.dispatch_recorded(intent)) do
      {:ok, result} ->
        reconcile_refit_buy(agent, intent, live_ship, result)

      {:error, %SpaceTraders.API.GameplayError{} = reason} ->
        block_protocol_backpressure(intent, reason)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  # The purchase outcome is a controlled observation: only a fresh authoritative
  # Cargo read proving the module aboard lets dependent refit work continue.
  defp reconcile_refit_buy(agent, intent, live_ship, _result) do
    with {:ok, fresh} <- fresh_ship(agent, live_ship.symbol, nil),
         module_symbol = intent.parameters["module_symbol"],
         action = intent.in_flight_action,
         cargo_now = Fleet.item_units(fresh.cargo, module_symbol),
         true <-
           cargo_now == action["cargo_before"] + 1 ||
             {:error, {:ambiguous_operation_evidence, "buy"}},
         :ok <- settle_module_attempt(agent, intent, fresh),
         {:ok, intent} <-
           transition_intent(intent,
             in_flight_action: nil,
             parameters:
               intent.parameters
               |> Map.put("purchased", true)
               |> Map.put("purchased_price", action["listing_price"])
           ) do
      dispatch_module_intent(agent, intent, fresh)
    else
      {:error, %SpaceTraders.API.GameplayError{} = reason} ->
        block_protocol_backpressure(intent, reason)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  # ADR 0011: purchase-cargo fences on ship AND agent credits, so the buy
  # attempt's reconciliation must present both authoritative observations.
  defp settle_module_attempt(agent, intent, fresh) do
    case MutationAttempts.unresolved_for_intent(intent) do
      nil ->
        :ok

      attempt ->
        with {:ok, game_agent} <- recovery_agent(agent),
             {:ok, _attempt} <-
               MutationAttempts.reconcile(
                 attempt,
                 :accepted,
                 ship_purchase_observations(agent, attempt, fresh, game_agent)
               ) do
          :ok
        end
    end
  end

  defp ship_purchase_observations(agent, intent, fresh, game_agent) do
    [
      reconciliation_observation(
        "get-my-ship",
        [DependencyKey.ship(agent.id, fresh.symbol)],
        intent,
        :accepted,
        "Authoritative Ship Cargo proves the module purchase",
        %{
          cargo: cargo_evidence(fresh.cargo),
          modules: Enum.map(fresh.modules || [], &module_evidence/1)
        }
      ),
      reconciliation_observation(
        "get-my-agent",
        [DependencyKey.agent_credits(agent.id)],
        intent,
        :accepted,
        "Fresh Agent credits accompany the accepted module purchase",
        %{credits: game_agent.credits}
      )
    ]
  end

  defp dispatch_module_request(agent, intent, live_ship) do
    module_symbol = intent.parameters["module_symbol"]
    installed_before = module_count(live_ship.modules, module_symbol)
    cargo_before = Fleet.item_units(live_ship.cargo, module_symbol)

    action = %{
      "kind" => intent.type,
      "module_symbol" => module_symbol,
      "quantity" => 1,
      "installed_before" => installed_before,
      "cargo_before" => cargo_before
    }

    case prepare_recorded_action(agent, intent, action) do
      {:ok, %{intent: intent}} ->
        result = SpaceTraders.API.dispatch_recorded(intent)

        case Agent.handle_game_result(agent, result) do
          {:ok, result} ->
            if intent.type == "remove_module" do
              # A removal can affect multiple matching modules; the response
              # count alone never decides the outcome. The authoritative
              # post-removal read does.
              confirm_module_mutation(agent, intent, live_ship)
            else
              if module_modification_evidence?(intent, result.modules, result.cargo) do
                with :ok <- settle_module_attempt(agent, intent, live_ship) do
                  complete_module_intent(intent, result)
                end
              else
                confirm_module_mutation(agent, intent, live_ship)
              end
            end

          {:error, %SpaceTraders.API.Error{} = reason} ->
            await_module_reconciliation(intent, reason)

          {:error, %SpaceTraders.API.GameplayError{} = reason} ->
            block_module_intent(intent, reason)

          {:error, reason} ->
            await_module_reconciliation(intent, reason)
        end

      {:error, :intent_dispatch_no_longer_allowed} ->
        :ok

      {:error, reason} ->
        block_preparation_refusal(intent, reason)
    end
  end

  defp module_mutation_allowed?(%Intent{type: type} = intent, live_ship) do
    module_symbol = intent.parameters["module_symbol"]

    cond do
      not docked?(live_ship) ->
        {:error, :module_operation_requires_docked_ship}

      not is_list(live_ship.modules) or not is_map(live_ship.cargo) or
          not is_integer(live_ship.frame && live_ship.frame.module_slots) ->
        {:error, :module_readiness_unavailable}

      true ->
        installed = module_count(live_ship.modules, module_symbol)
        cargo_units = Fleet.item_units(live_ship.cargo, module_symbol)
        cargo_capacity = live_ship.cargo.capacity
        module_slots = live_ship.frame.module_slots

        cond do
          type == "install_module" and cargo_units < 1 ->
            {:error, :module_missing_from_cargo}

          type == "install_module" and installed >= module_slots ->
            {:error, :module_capacity_full}

          type == "remove_module" and installed < 1 ->
            {:error, :module_not_installed}

          type == "remove_module" and not is_integer(cargo_capacity) ->
            {:error, :cargo_capacity_unavailable}

          type == "remove_module" and live_ship.cargo.units >= cargo_capacity ->
            {:error, :cargo_full}

          true ->
            :ok
        end
    end
  end

  # The controlled observation that decides every module mutation: a fresh
  # authoritative Ship read. A removal that could affect multiple matching
  # modules terminates on this read, never on the response count alone.
  defp confirm_module_mutation(agent, intent, live_ship) do
    case fresh_ship(agent, live_ship.symbol, nil) do
      {:ok, fresh} ->
        if module_mutation_evidence?(intent, fresh) do
          with :ok <- settle_module_attempt(agent, intent, fresh) do
            complete_module_intent(intent, %{modules: fresh.modules, cargo: fresh.cargo})
          end
        else
          case MutationAttempts.latest_for_intent(intent) do
            %{state: "rejected"} -> mark_infeasible(intent, :module_mutation_rejected)
            _ -> block_module_intent_preserving_evidence(intent, :ambiguous_module_modification)
          end
        end

      {:error, reason} ->
        await_module_reconciliation(intent, reason)
    end
  end

  defp module_mutation_evidence?(intent, ship) do
    action = intent.in_flight_action
    module_symbol = action["module_symbol"]
    installed_before = action["installed_before"]
    cargo_before = action["cargo_before"]
    installed_now = module_count(ship.modules, module_symbol)
    cargo_now = Fleet.item_units(ship.cargo, module_symbol)

    case intent.type do
      "install_module" ->
        installed_now == installed_before + 1 and cargo_now == cargo_before - 1

      "remove_module" ->
        # Removing one module can remove every matching module while returning
        # only one Cargo unit; the authoritative read decides completion.
        installed_now == 0 and cargo_now >= cargo_before + 1
    end
  end

  defp complete_module_intent(intent, result) do
    module_symbol = intent.parameters["module_symbol"]

    intent =
      update_intent!(
        Ecto.Changeset.change(intent,
          status: "completed",
          blocker: nil,
          in_flight_action: nil,
          last_action_result: module_result(intent.type, module_symbol, result),
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
      )

    record_activity_by_intent(
      intent,
      "manual_intent_completed",
      "#{module_intent_verb(intent.type)} #{module_symbol} complete",
      intent.last_action_result
    )

    {:ok, intent}
  end

  defp module_result(type, module_symbol, nil),
    do: %{"kind" => type, "module_symbol" => module_symbol, "quantity" => 1}

  defp module_result(type, module_symbol, %{modules: modules, cargo: cargo} = result) do
    %{"kind" => type, "module_symbol" => module_symbol, "quantity" => 1}
    |> Map.put("modules", Enum.map(modules, &module_evidence/1))
    |> Map.put("cargo", cargo_evidence(cargo))
    |> maybe_put_module_transaction(Map.get(result, :transaction))
  end

  defp maybe_put_module_transaction(result, nil), do: result

  defp maybe_put_module_transaction(result, transaction),
    do: Map.put(result, "transaction", module_transaction_evidence(transaction))

  defp await_module_reconciliation(intent, reason) do
    intent =
      update_intent!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: Fleet.intent_blocker({:awaiting_reconciliation, reason}),
          last_action_result: %{"kind" => intent.type, "error" => inspect(reason)}
        )
      )

    {:ok, intent}
  end

  defp block_module_intent(intent, %SpaceTraders.API.GameplayError{code: 429}),
    do: defer_for_api_capacity(intent)

  defp block_module_intent(intent, reason) do
    intent =
      update_intent!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: Fleet.intent_blocker(intents_block_reason(reason)),
          in_flight_action: nil,
          last_action_result: %{"kind" => intent.type, "error" => inspect(reason)}
        )
      )

    {:ok, intent}
  end

  defp block_module_intent_preserving_evidence(intent, reason) do
    intent =
      update_intent!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: Fleet.intent_blocker(reason),
          last_action_result: %{"kind" => intent.type, "error" => inspect(reason)}
        )
      )

    {:ok, intent}
  end

  @doc false
  def module_count(modules, symbol), do: Enum.count(modules || [], &(&1.symbol == symbol))
  defp module_intent_verb("install_module"), do: "Install"
  defp module_intent_verb("remove_module"), do: "Remove"

  defp module_modification_evidence?(intent, modules, cargo) do
    action = intent.in_flight_action
    module_symbol = action["module_symbol"]
    installed_before = action["installed_before"]
    cargo_before = action["cargo_before"]
    installed_now = module_count(modules, module_symbol)
    cargo_now = Fleet.item_units(cargo, module_symbol)

    case intent.type do
      "install_module" -> installed_now == installed_before + 1 and cargo_now == cargo_before - 1
      "remove_module" -> installed_now == installed_before - 1 and cargo_now == cargo_before + 1
    end
  end

  defp module_evidence(module) do
    %{
      "symbol" => module.symbol,
      "name" => module.name,
      "capacity" => module.capacity,
      "range" => module.range
    }
  end

  defp cargo_evidence(cargo) do
    %{
      "capacity" => cargo.capacity,
      "units" => cargo.units,
      "inventory" =>
        Enum.map(cargo.inventory || [], fn item ->
          %{
            "symbol" => item.symbol,
            "name" => item.name,
            "description" => item.description,
            "units" => item.units
          }
        end)
    }
  end

  defp module_transaction_evidence(transaction) do
    %{
      "ship_symbol" => transaction.ship_symbol,
      "timestamp" => transaction.timestamp,
      "total_price" => transaction.total_price,
      "trade_symbol" => transaction.trade_symbol,
      "waypoint_symbol" => transaction.waypoint_symbol
    }
  end

  defp maybe_put_price(result, nil), do: result
  defp maybe_put_price(result, price), do: Map.put(result, "price", price)

  # The response is persisted with the request fingerprint. Cargo changes are
  # useful state, but the transaction/recipient response is the operation proof.
  defp cargo_operation_result(%Intent{type: type} = intent, response, units, price) do
    %{"kind" => type, "units" => units, "trade_symbol" => intent.parameters["trade_symbol"]}
    |> maybe_put_price(price)
    |> maybe_put_transaction(response)
    |> maybe_put_delivery(response, type)
    |> maybe_put_cargo(response, type)
    |> maybe_put_external_completion(response)
  end

  defp maybe_put_external_completion(result, %{external_completion: true}),
    do: Map.put(result, "external_completion", true)

  defp maybe_put_external_completion(result, _response), do: result

  defp maybe_put_cargo(result, %{cargo: cargo}, "deliver"),
    do: Map.put(result, "cargo", cargo_evidence(cargo))

  defp maybe_put_cargo(result, _response, _type), do: result

  defp maybe_put_transaction(result, %{transaction: transaction}),
    do: Map.put(result, "transaction", Fleet.transaction_evidence(transaction))

  defp maybe_put_transaction(result, _response), do: result

  defp maybe_put_delivery(result, %{contract: contract}, "deliver") do
    Map.put(
      result,
      "recipient",
      Fleet.contract_delivery_evidence(contract, result["trade_symbol"])
    )
  end

  defp maybe_put_delivery(result, %{construction: construction}, "deliver") do
    Map.put(
      result,
      "recipient",
      Fleet.construction_delivery_evidence(construction, result["trade_symbol"])
    )
  end

  defp maybe_put_delivery(result, _response, _type), do: result

  defp block_cargo_intent(intent, %SpaceTraders.API.GameplayError{code: 429}),
    do: defer_for_api_capacity(intent)

  defp block_cargo_intent(intent, reason) do
    if authoritative_infeasibility?(reason) do
      mark_infeasible(intent, reason)
    else
      do_block_cargo_intent(intent, reason)
    end
  end

  defp do_block_cargo_intent(intent, reason) do
    evidence = %{
      "target" => intent.target_waypoint,
      "trade_good" => intent.parameters["trade_symbol"],
      "constraint" => intent.parameters,
      "observed" => inspect(reason)
    }

    case transition_intent(intent,
           status: "blocked",
           blocker: %{Fleet.intent_blocker(reason) | evidence: inspect(evidence)},
           in_flight_action:
             if(preserve_claim?(reason) and is_map(intent.in_flight_action),
               do: intent.in_flight_action,
               else: nil
             ),
           last_action_result: %{"kind" => intent.type, "error" => cargo_error_message(reason)}
         ) do
      {:ok, intent} -> {:ok, intent}
      :intent_no_longer_owned -> :ok
    end
  end

  @doc false
  def cargo_error_message(%{message: message}) when is_binary(message), do: message
  @doc false
  def cargo_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  @doc false
  def cargo_error_message(reason), do: inspect(reason)

  @doc false
  def ambiguous_cargo_operation_error?(%SpaceTraders.API.Error{}), do: true
  @doc false
  def ambiguous_cargo_operation_error?({:ambiguous_operation_evidence, _type}), do: true

  @doc false
  def ambiguous_cargo_operation_error?(reason)
      when reason in [
             :missing_market_transaction,
             :unexpected_market_transaction,
             :missing_delivery_recipient,
             :unexpected_delivery_recipient
           ],
      do: true

  @doc false
  def ambiguous_cargo_operation_error?(_reason), do: false

  defp delivery_contract_for_intent(agent, intent) do
    with {:ok, %{"contract_id" => contract_id, "waypoint" => waypoint}} <-
           delivery_recipient(intent),
         true <- waypoint == intent.target_waypoint do
      case Contracts.list_contracts(agent) do
        {:ok, contracts} ->
          case Enum.find(contracts, &(&1.id == contract_id)) do
            %Contract{} = contract ->
              if Contracts.fulfillable?(contract) or contract.fulfilled,
                do: {:ok, contract},
                else: {:error, :recipient_unavailable}

            nil ->
              {:error, :recipient_unavailable}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :recipient_conflict}
      _ -> {:error, :recipient_unavailable}
    end
  end

  defp delivery_recipient_for_intent(agent, intent) do
    case delivery_recipient(intent) do
      {:ok, %{"type" => "construction", "system" => system, "waypoint" => waypoint}}
      when is_binary(system) and is_binary(waypoint) and waypoint == intent.target_waypoint ->
        case Agent.handle_game_result(
               agent,
               SpaceTraders.Evidence.get_construction(
                 AgentTokenReference.new(agent),
                 system,
                 waypoint
               )
             ) do
          {:ok, construction} ->
            Fleet.record_construction_observation(agent, system, construction, "get_construction")
            {:ok, {:construction, construction}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        with {:ok, contract} <- delivery_contract_for_intent(agent, intent),
             do: {:ok, {:contract, contract}}
    end
  end

  defp delivery_recipient(%Intent{} = intent) do
    recipient = (intent.in_flight_action || %{})["recipient"] || intent.parameters["recipient"]

    case recipient do
      %{"type" => "construction", "system" => system, "waypoint" => waypoint}
      when is_binary(system) and is_binary(waypoint) ->
        {:ok, recipient}

      %{"type" => "contract", "contract_id" => contract_id, "waypoint" => waypoint}
      when is_binary(contract_id) and is_binary(waypoint) ->
        {:ok, recipient}

      contract_id when is_binary(contract_id) ->
        {:ok, %{"contract_id" => contract_id, "waypoint" => intent.target_waypoint}}

      _ ->
        case intent.parameters["contract_id"] do
          contract_id when is_binary(contract_id) ->
            {:ok, %{"contract_id" => contract_id, "waypoint" => intent.target_waypoint}}

          _ ->
            {:error, :recipient_unavailable}
        end
    end
  end

  defp verify_delivery_result(
         intent,
         contract,
         trade_symbol
       ) do
    with {:ok, %{"contract_id" => contract_id, "waypoint" => waypoint}} <-
           delivery_recipient(intent),
         true <- contract.id == contract_id,
         %{destination_symbol: ^waypoint, trade_symbol: ^trade_symbol} <-
           Fleet.find_deliverable(contract, trade_symbol) do
      :ok
    else
      _ -> {:error, :unexpected_delivery_recipient}
    end
  end

  defp delivery_action_evidence(action, {:construction, construction}, cargo, trade_symbol) do
    action
    |> Map.put("fulfilled_before", construction_fulfilled_units(construction, trade_symbol))
    |> Map.put("cargo_before", Fleet.item_units(cargo, trade_symbol))
  end

  defp delivery_action_evidence(action, {:contract, contract}, cargo, trade_symbol) do
    action
    |> Map.put("fulfilled_before", fulfilled_units(contract, trade_symbol))
    |> Map.put("cargo_before", Fleet.item_units(cargo, trade_symbol))
  end

  defp delivery_action_evidence(action, _recipient, _cargo, _trade_symbol), do: action

  defp construction_fulfilled_units(construction, trade_symbol) do
    case Enum.find(construction.materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: fulfilled} when is_integer(fulfilled) -> fulfilled
      _ -> 0
    end
  end

  defp fulfilled_units(contract, trade_symbol) do
    case Enum.find(contract.terms.deliver || [], &(&1.trade_symbol == trade_symbol)) do
      %{units_fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp reconcile_deliver_cargo_intent(agent, intent, live_ship, action) do
    with fulfilled_before when is_integer(fulfilled_before) <- action["fulfilled_before"],
         {:ok, recipient, binding} <- recovery_delivery_recipient(agent, intent),
         result <-
           reconcile_delivery_evidence(recipient, action, live_ship.cargo, fulfilled_before) do
      case result do
        {:accepted, units} ->
          with {:ok, _} <-
                 settle_delivery_attempt(
                   intent,
                   live_ship,
                   binding,
                   :accepted,
                   "Recipient progress and Ship Cargo prove this delivery"
                 ) do
            complete_cargo_intent(agent, intent, units, nil, %{
              elem(recipient, 0) => elem(recipient, 1)
            })
          else
            {:error, reason} -> block_cargo_intent(intent, reason)
          end

        :external_completion ->
          with {:ok, absent} <-
                 settle_delivery_attempt(
                   intent,
                   live_ship,
                   binding,
                   :absent,
                   "Recipient completed externally while this Ship Cargo is unchanged"
                 ),
               :ok <- retire_external_delivery_retry(absent, live_ship, binding) do
            complete_cargo_intent(agent, intent, 0, nil, %{
              elem(recipient, 0) => elem(recipient, 1),
              external_completion: true
            })
          else
            {:error, reason} -> block_cargo_intent(intent, reason)
          end

        :absent ->
          with {:ok, absent} <-
                 settle_delivery_attempt(
                   intent,
                   live_ship,
                   binding,
                   :absent,
                   "Ship Cargo and recipient progress are unchanged from this selected delivery"
                 ) do
            retry_absent_action(agent, intent, live_ship, action, absent)
          else
            {:error, reason} -> block_cargo_intent(intent, reason)
          end

        :ambiguous ->
          block_cargo_intent(intent, {:ambiguous_operation_evidence, "deliver"})
      end
    else
      _ -> block_cargo_intent(intent, {:ambiguous_operation_evidence, "deliver"})
    end
  end

  defp recovery_delivery_recipient(agent, intent) do
    opts = [bind: true, lane: :safety, owner: "ship_execution"]

    with {:ok, recipient} <- delivery_recipient(intent) do
      case recipient do
        %{"type" => "construction", "system" => system, "waypoint" => waypoint} ->
          with {:ok, binding} <-
                 Agent.handle_game_result(
                   agent,
                   Evidence.get_construction(agent, system, waypoint, opts)
                 ),
               :ok <- validate_delivery_recipient(intent, :construction, binding.value) do
            {:ok, {:construction, binding.value}, binding}
          else
            error -> error
          end

        %{"contract_id" => id} ->
          with {:ok, binding} <-
                 Agent.handle_game_result(agent, Evidence.get_contracts(agent, opts)),
               %Contract{} = contract <- Enum.find(binding.value, &(&1.id == id)),
               :ok <- validate_delivery_recipient(intent, :contract, contract) do
            {:ok, {:contract, contract}, binding}
          else
            nil -> {:error, :missing_delivery_recipient}
            error -> error
          end
      end
    end
  end

  defp delivery_recovery_proof(attempt, live_ship, binding, outcome, basis) do
    case Evidence.recovery_proof(attempt, outcome, basis, [
           Map.get(live_ship, :evidence_binding),
           binding
         ]) do
      {:ok, observations} -> {:ok, observations}
      {:incomplete, gap} -> {:error, {:incomplete_recovery_evidence, gap.missing}}
    end
  end

  defp settle_delivery_attempt(intent, live_ship, binding, outcome, basis) do
    case MutationAttempts.latest_for_intent(intent) do
      nil ->
        {:error, :historical_action_unresolved}

      attempt ->
        with {:ok, observations} <-
               delivery_recovery_proof(attempt, live_ship, binding, outcome, basis) do
          case {attempt.state, outcome} do
            {state, :accepted} when state in ["succeeded", "accepted"] ->
              {:ok, attempt}

            {"absent", :absent} ->
              {:ok, attempt}

            {state, _} when state in ["succeeded", "accepted", "absent"] ->
              {:error, :delivery_outcome_unresolved}

            _ ->
              MutationAttempts.reconcile(attempt, outcome, observations)
          end
        end
    end
  end

  defp retire_external_delivery_retry(%{retry_authorized: false}, _live_ship, _binding), do: :ok

  defp retire_external_delivery_retry(absent, live_ship, binding) do
    with {:ok, observations} <-
           delivery_recovery_proof(
             absent,
             live_ship,
             binding,
             :accepted,
             "External recipient completion satisfies the root outcome; no Fleet delivery attributed"
           ),
         {:ok, _} <- MutationAttempts.withdraw_retry(absent, observations),
         do: :ok
  end

  defp reconcile_delivery_evidence({:construction, construction}, action, cargo, fulfilled_before) do
    with trade_symbol when is_binary(trade_symbol) <- action["trade_symbol"],
         cargo_before when is_integer(cargo_before) <- action["cargo_before"],
         units when is_integer(units) and units > 0 <- action["units"] do
      fulfilled_delta =
        construction_fulfilled_units(construction, trade_symbol) - fulfilled_before

      cargo_delta = cargo_before - Fleet.item_units(cargo, trade_symbol)

      cond do
        (construction.is_complete or
           construction_fulfillment_remaining(construction, trade_symbol) == 0) and
            cargo_delta == 0 ->
          :external_completion

        cargo_delta > 0 and cargo_delta <= units and fulfilled_delta >= cargo_delta ->
          {:accepted, cargo_delta}

        cargo_delta == 0 and fulfilled_delta == 0 ->
          :absent

        true ->
          :ambiguous
      end
    else
      _ -> :ambiguous
    end
  end

  defp reconcile_delivery_evidence(
         {:contract, contract},
         action,
         cargo,
         fulfilled_before
       ) do
    if (contract.fulfilled or
          fulfillment_remaining({:contract, contract}, action["trade_symbol"]) == 0) and
         is_integer(action["cargo_before"]) and
         Fleet.item_units(cargo, action["trade_symbol"]) == action["cargo_before"] and
         Fleet.recipient_fulfilled_units(contract, action["trade_symbol"]) >= fulfilled_before do
      :external_completion
    else
      reconcile_contract_delivery_evidence(contract, action, cargo, fulfilled_before)
    end
  end

  defp reconcile_delivery_evidence({_type, recipient}, action, cargo, fulfilled_before),
    do: reconcile_contract_delivery_evidence(recipient, action, cargo, fulfilled_before)

  defp reconcile_contract_delivery_evidence(recipient, action, cargo, fulfilled_before) do
    accepted =
      Fleet.recipient_fulfilled_units(recipient, action["trade_symbol"]) - fulfilled_before

    cond do
      delivery_evidence?(action, cargo, accepted) ->
        {:accepted, accepted}

      accepted == 0 and Fleet.item_units(cargo, action["trade_symbol"]) == action["cargo_before"] ->
        :absent

      true ->
        :ambiguous
    end
  end

  defp delivery_evidence?(action, cargo, accepted) do
    with units when is_integer(units) <- action["units"],
         cargo_before when is_integer(cargo_before) <- action["cargo_before"],
         trade_symbol when is_binary(trade_symbol) <- action["trade_symbol"] do
      accepted > 0 and accepted <= units and
        Fleet.item_units(cargo, trade_symbol) == cargo_before - accepted
    else
      _ -> false
    end
  end

  defp fulfillment_remaining({:contract, contract}, trade_symbol) do
    case Enum.find(contract.terms.deliver || [], &(&1.trade_symbol == trade_symbol)) do
      %{units_required: required, units_fulfilled: fulfilled}
      when is_integer(required) and is_integer(fulfilled) ->
        max(required - fulfilled, 0)

      _ ->
        0
    end
  end

  defp fulfillment_remaining({:construction, construction}, trade_symbol),
    do: construction_fulfillment_remaining(construction, trade_symbol)

  defp construction_fulfillment_remaining(construction, trade_symbol) do
    case Enum.find(construction.materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{required: required, fulfilled: fulfilled}
      when is_integer(required) and is_integer(fulfilled) ->
        max(required - fulfilled, 0)

      _ ->
        0
    end
  end

  defp complete_intents(agent, intent) do
    result =
      if intent.type == "acquire_intelligence" do
        %{
          "kind" => "acquire_intelligence",
          "subject_type" => intent.parameters["subject_type"],
          "waypoint" => intent.target_waypoint,
          "required_facts" => intent.parameters["required_facts"]
        }
      else
        navigation_completion_result(intent)
      end

    case transition_intent(intent,
           status: "completed",
           blocker: nil,
           in_flight_action: nil,
           last_action_result: result,
           finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
         ) do
      {:ok, intent} ->
        ship = Repo.get!(Ship, intent.ship_id)

        if intent.type == "acquire_intelligence" do
          Phoenix.PubSub.broadcast(
            SpaceTraders.PubSub,
            "fleet_intelligence_evidence",
            {:waypoint_intelligence_observed, agent.id, intent.parameters["system"]}
          )

          if intent.parameters["subject_type"] == "market" do
            Phoenix.PubSub.broadcast(
              SpaceTraders.PubSub,
              "fleet_market_evidence",
              {:market_evidence_observed, agent.id,
               "market:#{intent.parameters["system"]}:#{intent.target_waypoint}"}
            )
          end
        end

        if intent.caller == "manual" do
          Fleet.record_activity(
            agent,
            ship,
            "manual_intent_completed",
            "Navigate complete at #{intent.target_waypoint}",
            %{"waypoint" => intent.target_waypoint}
          )
        end

        {:ok, intent}

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp navigation_completion_result(intent) do
    if jump_evidence?(intent) or warp_evidence?(intent) do
      (intent.last_action_result || %{"kind" => "jump", "waypoint" => intent.target_waypoint})
      |> Map.put("kind", if(warp_evidence?(intent), do: "warp", else: "jump"))
      |> Map.put("completion", "authoritative_ship_state")
    else
      %{"kind" => "navigate", "waypoint" => intent.target_waypoint}
    end
  end

  # The Ship is already travelling — toward the target or elsewhere — so the
  # Intent waits for that authoritative arrival before choosing another step.
  defp wait_for_manual_arrival(agent, intent, live_ship) do
    case schedule_intent_arrival(agent, intent, live_ship.symbol, %{nav: live_ship.nav}) do
      :ok ->
        case transition_intent(intent,
               status: "waiting",
               last_action_result: %{"kind" => "wait", "wait" => "arrival"}
             ) do
          {:ok, intent} ->
            ship = Repo.get!(Ship, intent.ship_id)

            Fleet.record_activity(
              agent,
              ship,
              "manual_intent_waiting",
              "Navigate to #{intent.target_waypoint} waiting for arrival",
              %{"wait" => "arrival"}
            )

            {:ok, intent}

          :intent_no_longer_owned ->
            :ok
        end

      :intent_no_longer_owned ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp wait_for_manual_cooldown(agent, intent, live_ship) do
    due_at =
      Timeline.parse_expiration(
        live_ship.cooldown.expiration,
        live_ship.cooldown.remaining_seconds
      )

    case with_current_intent(intent, fn current ->
           {:ok, event} =
             Timeline.schedule_event(:ship, live_ship.symbol, :cooldown, due_at, %{
               "intent_id" => current.id
             })

           ShipServer.arm(agent, live_ship.symbol, event)
           :ok
         end) do
      :ok ->
        case transition_intent(intent,
               status: "waiting",
               last_action_result: %{"kind" => "wait", "wait" => "cooldown"}
             ) do
          {:ok, intent} ->
            ship = Repo.get!(Ship, intent.ship_id)

            Fleet.record_activity(
              agent,
              ship,
              "manual_intent_waiting",
              "Navigate to #{intent.target_waypoint} waiting for cooldown",
              %{"wait" => "cooldown"}
            )

            {:ok, intent}

          :intent_no_longer_owned ->
            :ok
        end

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp recover_insufficient_fuel(agent, intent, live_ship, reason) do
    with {:ok, intent} <-
           transition_intent(intent,
             in_flight_action: nil,
             last_action_result: %{
               "kind" => "navigate",
               "status" => "rejected",
               "reason" => reason.message
             }
           ),
         {:ok, intent} <-
           transition_intent(intent,
             parameters: Map.put(intent.parameters, "refuel", "to_capacity")
           ) do
      case live_ship.nav.status do
        "DOCKED" -> refuel_for_navigate(agent, intent, live_ship)
        "IN_ORBIT" -> dock_for_navigate(agent, intent, live_ship)
        _ -> block_intents(intent, reason)
      end
    else
      _ -> block_intents(intent, reason)
    end
  end

  defp market_sells_fuel?(%{trade_goods: goods}) when is_list(goods),
    do: Enum.any?(goods, &(&1.symbol == "FUEL"))

  defp market_sells_fuel?(_market), do: false

  defp refuel_for_navigate(agent, intent, live_ship) do
    with {:ok, market} <- fresh_refuel_market(agent, live_ship),
         true <- market_sells_fuel?(market) do
      with {:ok, %{intent: intent}} <-
             prepare_recorded_action(agent, intent, %{
               "kind" => "refuel",
               "waypoint" => live_ship.nav.waypoint_symbol,
               "fuel_before" => live_ship.fuel.current,
               "expected" => %{"fuel_full" => true}
             }) do
        case Agent.handle_game_result(
               agent,
               SpaceTraders.API.dispatch_recorded(intent)
             ) do
          {:ok, %{fuel: fuel} = result} when fuel.current >= fuel.capacity ->
            invalidate_refuel_market(agent, result)

            with {:ok, fresh_ship} <- fresh_ship(agent, live_ship.symbol, nil) do
              case transition_intent(intent,
                     in_flight_action: nil,
                     last_action_result: %{"kind" => "refuel", "fuel" => fuel.current}
                   ) do
                {:ok, intent} -> advance_intents(agent, intent, fresh_ship)
                :intent_no_longer_owned -> :ok
              end
            else
              {:error, reason} -> block_intents(intent, reason)
            end

          {:ok, %{fuel: fuel}} ->
            clear_claim_and_block(intent, {:refuel_incomplete, fuel.current, fuel.capacity})

          {:error, reason} ->
            block_intents(intent, reason)
        end
      else
        {:error, reason} -> block_preparation_refusal(intent, reason)
      end
    else
      {:error, %SpaceTraders.API.GameplayError{}} ->
        route_to_confirmed_fuel_stop(agent, intent, live_ship)

      {:error, reason} ->
        block_intents(intent, reason)

      false ->
        route_to_confirmed_fuel_stop(agent, intent, live_ship)
    end
  end

  defp fresh_refuel_market(agent, live_ship) do
    system = live_ship.nav.system_symbol
    waypoint = live_ship.nav.waypoint_symbol

    case Agent.handle_game_result(
           agent,
           Evidence.get_market(AgentTokenReference.new(agent), system, waypoint,
             required_facts: ["trade_goods", "transactions"],
             freshness_seconds: 0
           )
         ) do
      {:ok, market} = result ->
        Intelligence.observe_market(agent, system, market,
          source: "get_market",
          observing_ship_symbol: live_ship.symbol
        )

        result

      error ->
        error
    end
  end

  defp route_to_confirmed_fuel_stop(agent, intent, live_ship) do
    with {:ok, source} <- current_route_waypoint(live_ship),
         {:ok, system} <- Fleet.system_from_headquarters(intent.target_waypoint),
         {:ok, target} <- navigation_target_waypoint(agent, system, intent.target_waypoint),
         {:ok, target_required} <-
           estimated_navigation_fuel(source, target, live_ship.nav.flight_mode),
         {:ok, waypoint} <-
           confirmed_reachable_fuel_stop(
             agent,
             intent,
             live_ship,
             source,
             target,
             target_required
           ) do
      visited = [waypoint | intent.parameters["visited_fuel_stops"] || []] |> Enum.uniq()

      parameters =
        intent.parameters
        |> Map.delete("refuel")
        |> Map.put("fuel_stop", waypoint)
        |> Map.put("visited_fuel_stops", visited)

      case transition_intent(intent, parameters: parameters) do
        {:ok, intent} -> advance_navigation(agent, intent, live_ship)
        :intent_no_longer_owned -> :ok
      end
    else
      :none -> block_intents(intent, :no_confirmed_reachable_refuel_stop)
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp maybe_update_ship_cargo(live_ship, %{cargo: cargo}) when not is_nil(cargo),
    do: %{live_ship | cargo: cargo}

  defp maybe_update_ship_cargo(live_ship, _result), do: live_ship

  defp invalidate_refuel_market(
         agent,
         %{transaction: %{waypoint_symbol: waypoint_symbol}}
       )
       when is_binary(waypoint_symbol) do
    with {:ok, system_symbol} <- Fleet.system_from_headquarters(waypoint_symbol) do
      SpaceTraders.Intelligence.invalidate(agent, :market, system_symbol, waypoint_symbol, [
        :trade_goods,
        :transactions
      ])
    end
  rescue
    exception ->
      Logger.warning("Could not invalidate market intelligence: #{Exception.message(exception)}")
  end

  defp invalidate_refuel_market(_agent, _result), do: :ok

  defp set_flight_mode_for_navigate(agent, intent, live_ship) do
    flight_mode = navigate_constraint(intent, "flight_mode")

    execute_action(agent, intent, live_ship, %{
      "kind" => "set_flight_mode",
      "waypoint" => live_ship.nav.waypoint_symbol,
      "flight_mode" => flight_mode,
      "expected" => %{"flight_mode" => flight_mode}
    })
  end

  defp dock_for_navigate(agent, intent, live_ship) do
    execute_action(agent, intent, live_ship, %{
      "kind" => "dock",
      "waypoint" => live_ship.nav.waypoint_symbol,
      "expected" => %{"status" => "DOCKED"}
    })
  end

  defp orbit_for_intents(agent, intent, live_ship) do
    execute_action(agent, intent, live_ship, %{
      "kind" => "orbit",
      "waypoint" => live_ship.nav.waypoint_symbol,
      "expected" => %{"status" => "IN_ORBIT"}
    })
  end

  defp advance_manual_jump_route(agent, intent, live_ship) do
    with {:ok, source_system} <- Fleet.system_from_headquarters(live_ship.nav.waypoint_symbol),
         {:ok, {origin_gate, destination_gate}} <-
           jump_route_for_intent(agent, source_system, intent),
         {:ok, destination_system} <- Fleet.system_from_headquarters(destination_gate),
         :ok <-
           validate_jump_route(
             agent,
             source_system,
             origin_gate,
             destination_system,
             destination_gate
           ),
         {:ok, _preflight} <- jump_cost_preflight(agent, source_system, origin_gate) do
      if live_ship.nav.waypoint_symbol == origin_gate do
        dispatch_manual_jump(agent, intent, live_ship, destination_gate)
      else
        dispatch_manual_navigate(agent, intent, live_ship, origin_gate)
      end
    else
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp advance_manual_remote_route(agent, intent, live_ship) do
    allowed = get_in(intent.parameters, ["allowed_methods"]) || ["jump", "warp"]

    cond do
      "jump" in allowed ->
        advance_manual_jump_route(agent, intent, live_ship)

      "warp" in allowed and match?({:ok, _module}, installed_warp_drive(live_ship)) ->
        dispatch_manual_warp(agent, intent, live_ship)

      true ->
        block_intents(intent, :method_not_allowed)
    end
  end

  defp jump_route_for_intent(
         agent,
         source_system,
         %Intent{parameters: parameters} = intent
       ) do
    case get_in(parameters, ["reviewed_jump", "source_waypoint"]) do
      source when is_binary(source) ->
        destination = get_in(parameters, ["reviewed_jump", "destination_waypoint"])

        with destination when is_binary(destination) <- destination,
             {:ok, destination_system} <- Fleet.system_from_headquarters(destination),
             :ok <-
               validate_jump_route(
                 agent,
                 source_system,
                 source,
                 destination_system,
                 destination
               ),
             {:ok, _} <- jump_cost_preflight(agent, source_system, source) do
          {:ok, {source, destination}}
        else
          nil -> jump_route_for(agent, source_system, intent.target_waypoint)
          {:error, _reason} = error -> error
        end

      _ ->
        jump_route_for(agent, source_system, intent.target_waypoint)
    end
  end

  defp jump_route_for(agent, system, destination) do
    with {:ok, destination_system} <- Fleet.system_from_headquarters(destination),
         {:ok, waypoints} <-
           SpaceTraders.Evidence.get_waypoints_paginated(AgentTokenReference.new(agent), system,
             type: "JUMP_GATE"
           ) do
      results =
        Enum.map(waypoints, fn waypoint ->
          case Fleet.waypoint_jump_gate(agent, waypoint) do
            {:ok, %{connections: connections}} -> {:ok, waypoint, connections}
            {:error, reason} -> {:error, reason}
          end
        end)

      case Enum.find(results, fn
             {:ok, _waypoint, connections} ->
               Enum.any?(connections, &(waypoint_system(&1) == {:ok, destination_system}))

             {:error, _reason} ->
               false
           end) do
        {:ok, gate, connections} ->
          destination_gate =
            Enum.find(connections, &(waypoint_system(&1) == {:ok, destination_system}))

          {:ok, {gate.symbol, destination_gate}}

        nil ->
          case Enum.find(results, &match?({:error, _reason}, &1)) do
            {:error, reason} -> {:error, reason}
            nil -> {:error, {:jump_gate_not_connected, system, destination}}
          end
      end
    end
  end

  defp waypoint_system(waypoint), do: Fleet.system_from_headquarters(waypoint)

  defp dispatch_manual_navigate(agent, intent, live_ship, destination \\ nil) do
    destination = destination || intent.target_waypoint

    execute_action(agent, intent, live_ship, %{
      "kind" => "navigate",
      "waypoint" => destination,
      "expected" => %{"status" => "IN_TRANSIT", "destination" => destination}
    })
  end

  defp accept_navigate_result(agent, intent, live_ship, destination, result) do
    case schedule_intent_arrival(agent, intent, live_ship.symbol, result) do
      :ok ->
        persist_destination_history(agent, live_ship.symbol, result.nav.route.destination.symbol)

        case transition_intent(intent,
               status: "waiting",
               last_action_result: %{
                 "kind" => "navigate",
                 "waypoint" => destination,
                 "status" => result.nav.status,
                 "destination" => result.nav.route.destination.symbol
               }
             ) do
          {:ok, intent} ->
            ship = Repo.get!(Ship, intent.ship_id)

            if intent.caller == "manual" do
              Fleet.record_activity(
                agent,
                ship,
                "manual_intent_navigate",
                "#{live_ship.symbol} navigating to #{destination}",
                %{"waypoint" => destination}
              )
            end

            {:ok, intent}

          :intent_no_longer_owned ->
            :ok
        end

      :intent_no_longer_owned ->
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp dispatch_manual_warp(agent, intent, live_ship) do
    with {:ok, module} <- installed_warp_drive(live_ship),
         :ok <- warp_route_preflight(agent, intent, live_ship, module) do
      execute_action(agent, intent, live_ship, %{
        "kind" => "warp",
        "waypoint" => intent.target_waypoint,
        "expected" => %{"status" => "IN_TRANSIT", "destination" => intent.target_waypoint}
      })
    else
      {:refuel, required} ->
        parameters =
          intent.parameters
          |> Map.put("refuel", "to_capacity")
          |> Map.put("estimated_fuel_required", required)

        case transition_intent(intent, parameters: parameters) do
          {:ok, intent} -> advance_navigation(agent, intent, live_ship)
          :intent_no_longer_owned -> :ok
        end

      {:error, reason} ->
        block_intents(intent, reason)
    end
  end

  defp warp_route_preflight(agent, intent, live_ship, module) do
    with {:ok, source} <- current_route_waypoint(live_ship),
         {:ok, system} <- Fleet.system_from_headquarters(intent.target_waypoint),
         {:ok, target} <- navigation_target_waypoint(agent, system, intent.target_waypoint),
         {:ok, required} <- estimated_navigation_fuel(source, target, live_ship.nav.flight_mode),
         true <-
           (is_integer(module.range) and required <= module.range) ||
             {:error, {:warp_range_insufficient, required, module.range}} do
      cond do
        fuel_independent?(live_ship) ->
          :ok

        required > live_ship.fuel.capacity ->
          {:error, {:insufficient_fuel_capacity, required, live_ship.fuel.capacity}}

        required > live_ship.fuel.current ->
          {:refuel, required}

        true ->
          :ok
      end
    else
      {:error, _reason} = error -> error
      _ -> {:error, :warp_route_unavailable}
    end
  end

  defp accept_warp_result(agent, intent, live_ship, result) do
    with :ok <- schedule_intent_arrival(agent, intent, live_ship.symbol, result),
         {:ok, intent} <-
           transition_intent(intent,
             status: "waiting",
             last_action_result: %{
               "kind" => "warp",
               "waypoint" => intent.target_waypoint,
               "status" => result.nav.status,
               "destination" => result.nav.route.destination.symbol,
               "fuel_current" => result.fuel.current
             }
           ) do
      persist_destination_history(agent, live_ship.symbol, result.nav.route.destination.symbol)
      {:ok, intent}
    else
      :intent_no_longer_owned -> :ok
      {:error, _reason} = error -> error
    end
  end

  # A jump response proves execution, not completion. The subsequent Ship read
  # is what proves the requested off-System arrival after a restart or timeout.
  defp dispatch_manual_jump(agent, intent, live_ship, destination) do
    with {:ok, source_system} <- Fleet.system_from_headquarters(live_ship.nav.waypoint_symbol),
         :ok <- reviewed_jump_flight_mode(intent, live_ship.nav.flight_mode),
         {:ok, destination_system} <- Fleet.system_from_headquarters(destination),
         :ok <-
           validate_jump_route(
             agent,
             source_system,
             live_ship.nav.waypoint_symbol,
             destination_system,
             destination
           ),
         {:ok, preflight} <-
           jump_cost_preflight(agent, source_system, live_ship.nav.waypoint_symbol),
         {:ok, %{intent: intent}} <-
           prepare_recorded_action(agent, intent, %{
             "kind" => "jump",
             "waypoint" => destination,
             "credits_before" => preflight.credits,
             "antimatter_cost" => preflight.antimatter_cost,
             "expected" => %{
               "status" => "IN_ORBIT",
               "waypoint" => destination,
               "system" => destination_system
             }
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.dispatch_recorded(intent)
           ) do
        {:ok, result} ->
          accept_jump_result(agent, intent, live_ship, result)

        {:error, %SpaceTraders.API.GameplayError{} = reason} ->
          clear_jump_claim_and_block(intent, reason)

        {:error, reason} ->
          block_intents(intent, reason)
      end
    else
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp accept_jump_result(agent, intent, live_ship, result) do
    destination = intent.in_flight_action["waypoint"]
    schedule_cooldown(agent, live_ship.symbol, result)

    case transition_intent(intent,
           status: "active",
           last_action_result: jump_execution_evidence(destination, result)
         ) do
      {:ok, intent} -> reconcile_intents(agent, intent)
      :intent_no_longer_owned -> :ok
    end
  end

  defp reviewed_jump_flight_mode(%Intent{parameters: parameters}, current_mode) do
    case get_in(parameters, ["reviewed_jump", "flight_mode"]) do
      nil -> :ok
      ^current_mode -> :ok
      _ -> {:error, :jump_preview_stale}
    end
  end

  defp jump_execution_evidence(destination, result) do
    %{
      "kind" => "jump",
      "waypoint" => destination,
      "status" => result.nav.status,
      "transaction" => result.transaction |> Map.from_struct() |> stringify_keys(),
      "credits" => result.agent.credits
    }
  end

  defp schedule_intent_arrival(
         agent,
         intent,
         ship_symbol,
         %{nav: %ShipNav{status: "IN_TRANSIT"} = nav}
       ) do
    case Timeline.parse_arrival(nav.route) do
      {:ok, due_at} ->
        payload = Timeline.arrival_payload(nav) |> Map.put("intent_id", intent.id)

        with_current_intent(intent, fn _current ->
          {:ok, event} = Timeline.schedule_event(:ship, ship_symbol, :arrival, due_at, payload)
          ShipServer.arm(agent, ship_symbol, event)
          :ok
        end)

      :error ->
        block_intents(intent, :unreadable_arrival)
        {:error, :unreadable_arrival}
    end
  end

  defp schedule_intent_arrival(_agent, _intent, _ship_symbol, _result), do: :ok

  defp block_intents(intent, %SpaceTraders.API.GameplayError{code: 429}),
    do: defer_for_api_capacity(intent)

  defp block_intents(intent, reason) do
    if authoritative_infeasibility?(reason) do
      mark_infeasible(intent, reason)
    else
      do_block_intents(intent, reason)
    end
  end

  defp do_block_intents(intent, reason) do
    current = Repo.get(Intent, intent.id)
    already_blocked? = match?(%Intent{status: "blocked"}, current)
    blocker = Fleet.intent_blocker(intents_block_reason(reason))

    in_flight_action =
      if(preserve_claim?(reason) and is_map(intent.in_flight_action),
        do: intent.in_flight_action,
        else: nil
      )

    result =
      with_current_intent(intent, fn current ->
        blocker_changeset =
          case current.blocker do
            nil -> Ecto.Changeset.change(blocker)
            existing -> Ecto.Changeset.change(existing, Map.from_struct(blocker))
          end

        updated =
          current
          |> Ecto.Changeset.change(status: "blocked", in_flight_action: in_flight_action)
          |> Ecto.Changeset.put_embed(:blocker, blocker_changeset)
          |> update_intent!()

        {:ok, updated}
      end)

    case result do
      {:ok, intent} ->
        unless already_blocked? do
          record_activity_by_intent(
            intent,
            "manual_intent_blocked",
            "Navigate to #{intent.target_waypoint} blocked: #{inspect(reason)}",
            %{"block" => inspect(reason)}
          )
        end

        {:ok, intent}

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp continue_after_reconciled_action(
         _agent,
         intent,
         live_ship,
         %{"kind" => "refuel"}
       )
       when live_ship.fuel.current < live_ship.fuel.capacity,
       do:
         clear_claim_and_block(
           intent,
           {:refuel_incomplete, live_ship.fuel.current, live_ship.fuel.capacity}
         )

  defp continue_after_reconciled_action(agent, intent, live_ship, _action) do
    case transition_intent(intent, in_flight_action: nil) do
      {:ok, intent} -> advance_intents(agent, intent, live_ship)
      :intent_no_longer_owned -> :ok
    end
  end

  defp clear_jump_claim_and_block(intent, reason) do
    case transition_intent(intent, in_flight_action: nil) do
      {:ok, intent} -> block_intents(intent, reason)
      :intent_no_longer_owned -> :ok
    end
  end

  defp clear_claim_and_block(intent, reason) do
    case transition_intent(intent, in_flight_action: nil) do
      {:ok, intent} -> block_intents(intent, reason)
      :intent_no_longer_owned -> :ok
    end
  end

  defp reconcile_accepted_attempt(agent, intent, live_ship, basis) do
    case MutationAttempts.unresolved_for_intent(intent) do
      nil ->
        case MutationAttempts.latest_for_intent(intent) do
          %{state: state} when state in ["accepted", "succeeded", "not_sent"] -> :ok
          %{state: "absent", retry_authorized: false} -> :ok
          _ -> {:error, :historical_action_unresolved}
        end

      attempt ->
        with {:ok, observations} <-
               accepted_observations(agent, live_ship, attempt, intent.in_flight_action, basis),
             {:ok, _attempt} <- MutationAttempts.reconcile(attempt, :accepted, observations) do
          :ok
        end
    end
  end

  defp accepted_observations(agent, live_ship, attempt, %{"kind" => "refuel"}, basis) do
    ship_and_credit_observations(
      agent,
      live_ship,
      attempt,
      :accepted,
      basis,
      %{fuel: %{current: live_ship.fuel.current, capacity: live_ship.fuel.capacity}},
      "Fresh Agent credits accompany the accepted refuel outcome"
    )
  end

  defp accepted_observations(agent, live_ship, attempt, %{"kind" => "jump"}, basis) do
    ship_and_credit_observations(
      agent,
      live_ship,
      attempt,
      :accepted,
      basis,
      %{nav: ship_nav_facts(live_ship.nav)},
      "Fresh Agent credits accompany the accepted jump outcome"
    )
  end

  defp accepted_observations(agent, live_ship, attempt, _action, basis) do
    ship_recovery_proof(agent, live_ship, attempt, :accepted, basis)
  end

  defp reconcile_absent_and_retry(agent, intent, live_ship, action) do
    case MutationAttempts.unresolved_for_intent(intent) do
      nil ->
        block_intents(intent, {:ambiguous_operation_evidence, action["kind"]})

      attempt ->
        with {:ok, observations} <- absence_observations(agent, live_ship, attempt, action),
             {:ok, absent} <- MutationAttempts.reconcile(attempt, :absent, observations) do
          retry_absent_action(agent, intent, live_ship, action, absent)
        else
          {:error, reason} -> block_intents(intent, {:awaiting_reconciliation, reason})
        end
    end
  end

  defp retry_absent_action(agent, intent, live_ship, action, absent) do
    with {:ok, %{intent: selected, result: result}} <-
           retry_under_current_claim(agent, intent, live_ship, action, absent),
         {:ok, result} <- Agent.handle_game_result(agent, result) do
      # Carry the admitted retry's identity; never substitute a newer callback owner.
      continue_selected_response(agent, selected, live_ship, action, result)
    else
      {:error, :no_current_ship_claim} -> supersede_for_lost_claim(intent, true)
      {:error, :emergency_stopped} -> retire_stopped_absence(intent, absent)
      {:error, reason} -> block_intents(intent, {:awaiting_reconciliation, reason})
    end
  end

  defp retire_stopped_absence(intent, absent) do
    with_current_intent(intent, fn current ->
      with {:ok, _} <- MutationAttempts.retire_stopped_retry(absent) do
        {:ok, update_intent!(Ecto.Changeset.change(current, in_flight_action: nil))}
      else
        {:error, _reason} -> Repo.rollback(:intent_no_longer_owned)
      end
    end)
  end

  defp retry_under_current_claim(agent, intent, _live_ship, _action, absent) do
    with {:ok, retry} <- RecordedAction.prepare_retry(agent, intent, absent) do
      selected = %{intent | mutation_attempt_id: retry.id}
      {:ok, %{intent: selected, result: SpaceTraders.API.dispatch_recorded(retry)}}
    end
  end

  defp absence_observations(agent, live_ship, attempt, %{"kind" => "refuel"}) do
    with fuel_before when is_integer(fuel_before) <- intent_fuel_before(attempt),
         true <- live_ship.fuel.current == fuel_before,
         {:ok, game_agent} <- recovery_agent(agent) do
      {:ok,
       [
         reconciliation_observation(
           "get-my-ship",
           [DependencyKey.ship(agent.id, live_ship.symbol)],
           attempt,
           :absent,
           "Ship fuel is unchanged from the pre-dispatch observation",
           %{fuel: %{current: live_ship.fuel.current, capacity: live_ship.fuel.capacity}}
         ),
         reconciliation_observation(
           "get-my-agent",
           [DependencyKey.agent_credits(agent.id)],
           attempt,
           :absent,
           "Fresh Agent credits accompany the unchanged Ship fuel",
           %{credits: game_agent.credits}
         )
       ]}
    else
      false -> {:error, :refuel_outcome_unresolved}
      nil -> {:error, :refuel_outcome_unresolved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp absence_observations(agent, live_ship, attempt, %{"kind" => "jump"} = action) do
    with credits_before when is_integer(credits_before) <- action["credits_before"],
         {:ok, observations} <-
           ship_and_credit_observations(
             agent,
             live_ship,
             attempt,
             :absent,
             "Ship navigation does not contain the expected jump effect",
             %{nav: ship_nav_facts(live_ship.nav)},
             "Agent credits are unchanged from the jump preflight"
           ),
         true <- observed_credits_unchanged?(observations, credits_before) do
      {:ok, observations}
    else
      _ -> {:error, :jump_outcome_unresolved}
    end
  end

  defp absence_observations(agent, live_ship, attempt, action) do
    ship_recovery_proof(
      agent,
      live_ship,
      attempt,
      :absent,
      "Fresh Ship state does not contain the expected #{action["kind"]} effect"
    )
  end

  defp ship_recovery_proof(_agent, live_ship, attempt, outcome, basis) do
    case Evidence.recovery_proof(attempt, outcome, basis, [Map.get(live_ship, :evidence_binding)]) do
      {:ok, observations} -> {:ok, observations}
      {:incomplete, gap} -> {:error, {:incomplete_recovery_evidence, gap.missing}}
    end
  end

  defp ship_and_credit_observations(
         agent,
         live_ship,
         attempt,
         outcome,
         ship_basis,
         ship_facts,
         credit_basis
       ) do
    with {:ok, game_agent} <- recovery_agent(agent) do
      {:ok,
       [
         reconciliation_observation(
           "get-my-ship",
           [DependencyKey.ship(agent.id, live_ship.symbol)],
           attempt,
           outcome,
           ship_basis,
           ship_facts
         ),
         reconciliation_observation(
           "get-my-agent",
           [DependencyKey.agent_credits(agent.id)],
           attempt,
           outcome,
           credit_basis,
           %{credits: game_agent.credits}
         )
       ]}
    end
  end

  defp observed_credits_unchanged?(observations, credits_before) do
    Enum.any?(observations, fn facts ->
      match?(%{credits: ^credits_before}, Map.get(facts, :facts))
    end)
  end

  defp recovery_agent(agent) do
    with {:ok, game_agent} <-
           Agent.handle_game_result(
             agent,
             Evidence.get_agent(AgentTokenReference.new(agent), lane: :safety)
           ),
         true <-
           game_agent.symbol == agent.symbol and is_integer(game_agent.credits) and
             game_agent.credits >= 0 do
      {:ok, game_agent}
    else
      false -> {:error, :authoritative_credit_facts_required}
      error -> error
    end
  end

  defp intent_fuel_before(attempt) do
    with intent_id when is_integer(intent_id) <- attempt.provenance["intent_id"],
         %Intent{in_flight_action: action} when is_map(action) <- Repo.get(Intent, intent_id) do
      action["fuel_before"]
    end
  end

  defp ship_nav_facts(nav) do
    %{
      status: nav.status,
      waypoint_symbol: nav.waypoint_symbol,
      system_symbol: nav.system_symbol,
      flight_mode: nav.flight_mode,
      destination:
        get_in(nav, [Access.key(:route), Access.key(:destination), Access.key(:symbol)])
    }
  end

  defp reconciliation_observation(operation_id, dependency_keys, attempt, outcome, basis, facts) do
    Evidence.authoritative_observation(
      operation_id,
      dependency_keys,
      Map.put(facts, :reconciliation, %{
        mutation_attempt_id: attempt.id,
        request_fingerprint: attempt.request_fingerprint,
        outcome: Atom.to_string(outcome),
        basis: basis
      }),
      Evidence.recovery_observed_at(
        attempt.agent_id,
        operation_id,
        dependency_keys,
        attempt.prepared_at
      )
    )
  end

  defp continue_selected_response(
         agent,
         intent,
         live_ship,
         %{"kind" => "deliver", "recipient" => recipient} = action,
         result
       ) do
    result =
      if recipient["type"] == "construction",
        do:
          Fleet.record_construction_result(
            {:ok, result},
            agent,
            recipient["system"],
            recipient["waypoint"],
            live_ship.symbol
          ),
        else: {:ok, result}

    with {:ok, response} <- result,
         {type, resource} <-
           if(recipient["type"] == "construction",
             do: {:construction, Map.get(response, :construction)},
             else: {:contract, Map.get(response, :contract)}
           ),
         true <- is_map(resource) and is_map(Map.get(response, :cargo)),
         :ok <- validate_delivery_recipient(intent, type, resource),
         {:accepted, units} <-
           reconcile_delivery_evidence(
             {type, resource},
             action,
             response.cargo,
             action["fulfilled_before"]
           ) do
      complete_cargo_intent(agent, intent, units, nil, response)
    else
      _ -> block_cargo_intent(intent, {:ambiguous_operation_evidence, "deliver"})
    end
  end

  defp continue_selected_response(
         agent,
         intent,
         live_ship,
         %{"kind" => "navigate", "waypoint" => destination},
         result
       ),
       do: accept_navigate_result(agent, intent, live_ship, destination, result)

  defp continue_selected_response(agent, intent, live_ship, %{"kind" => "warp"}, result),
    do: accept_warp_result(agent, intent, live_ship, result)

  defp continue_selected_response(agent, intent, live_ship, %{"kind" => "jump"}, result),
    do: accept_jump_result(agent, intent, live_ship, result)

  defp continue_selected_response(agent, intent, live_ship, %{"kind" => kind}, %{nav: nav})
       when kind in ["orbit", "dock"] do
    case transition_intent(intent,
           in_flight_action: nil,
           last_action_result: %{"kind" => kind, "status" => nav.status}
         ) do
      {:ok, intent} -> advance_intents(agent, intent, %{live_ship | nav: nav})
      :intent_no_longer_owned -> :ok
    end
  end

  defp continue_selected_response(
         agent,
         intent,
         live_ship,
         %{"kind" => "set_flight_mode", "flight_mode" => flight_mode},
         %{nav: nav, fuel: fuel}
       ) do
    case transition_intent(intent,
           in_flight_action: nil,
           last_action_result: %{"kind" => "set_flight_mode", "flight_mode" => flight_mode}
         ) do
      {:ok, intent} -> advance_intents(agent, intent, %{live_ship | nav: nav, fuel: fuel})
      :intent_no_longer_owned -> :ok
    end
  end

  defp continue_selected_response(
         agent,
         intent,
         live_ship,
         %{"kind" => "refuel"},
         %{fuel: fuel} = result
       )
       when fuel.current >= fuel.capacity do
    invalidate_refuel_market(agent, result)

    case transition_intent(intent,
           in_flight_action: nil,
           last_action_result: %{"kind" => "refuel", "fuel" => fuel.current}
         ) do
      {:ok, intent} ->
        live_ship = live_ship |> Map.put(:fuel, fuel) |> maybe_update_ship_cargo(result)
        advance_intents(agent, intent, live_ship)

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp continue_selected_response(_agent, intent, _live_ship, %{"kind" => "refuel"}, %{fuel: fuel}),
       do: clear_claim_and_block(intent, {:refuel_incomplete, fuel.current, fuel.capacity})

  defp validate_delivery_recipient(intent, :contract, contract) do
    if is_boolean(contract.accepted) and is_boolean(contract.fulfilled),
      do: verify_delivery_result(intent, contract, intent.parameters["trade_symbol"]),
      else: {:error, :authoritative_recipient_progress_required}
  end

  defp validate_delivery_recipient(intent, :construction, construction) do
    symbol = intent.parameters["trade_symbol"]

    with true <- is_boolean(construction.is_complete),
         true <- construction.symbol == get_in(intent.parameters, ["recipient", "waypoint"]),
         %{required: required, fulfilled: fulfilled} <-
           Enum.find(construction.materials || [], &(&1.trade_symbol == symbol)),
         true <-
           is_integer(required) and required >= 0 and is_integer(fulfilled) and fulfilled >= 0 and
             fulfilled <= required do
      :ok
    else
      _ -> {:error, :authoritative_recipient_progress_required}
    end
  end

  # Typed game rejections become stable blocker reasons; transport failures
  # keep their struct evidence.
  defp intents_block_reason(%SpaceTraders.API.GameplayError{type: type})
       when is_atom(type) and type != :other,
       do: type

  defp intents_block_reason(%SpaceTraders.API.GameplayError{code: 429}),
    do: :api_capacity_deferred

  defp intents_block_reason({:refuel_incomplete, _current, _capacity}), do: :refuel_incomplete

  defp intents_block_reason(reason), do: reason

  # A 429 is a durable wait. On wake the shared engine revalidates authority and
  # observes game state before selecting another recorded action. Only the ledger
  # can prove that the selected mutation was rejected: a read's 429 must not clear
  # a successful or unresolved mutation awaiting its authoritative observation.
  defp block_protocol_backpressure(intent, %SpaceTraders.API.GameplayError{code: 429}),
    do: defer_for_api_capacity(intent)

  defp block_protocol_backpressure(intent, reason), do: mark_infeasible(intent, reason)

  defp defer_for_api_capacity(intent) do
    earliest = DateTime.add(Clock.utc_now(), 1, :second)

    due_at =
      case SpaceTraders.API.CapacityGovernor.snapshot() do
        %{ordinary_delayed_until: %DateTime{} = until} -> Enum.max([earliest, until], DateTime)
        _ -> earliest
      end

    ship = Repo.get!(Ship, intent.ship_id)
    agent = Repo.get!(AgentRecord, ship.agent_id)

    result =
      with_current_intent(intent, fn current ->
        attrs = %{
          status: "waiting",
          blocker: Fleet.intent_blocker(:api_capacity_deferred)
        }

        attrs =
          case MutationAttempts.latest_for_intent(current) do
            %{id: id, state: "rejected"} when id == current.mutation_attempt_id ->
              Map.put(attrs, :in_flight_action, nil)

            _ ->
              attrs
          end

        updated = update_intent!(Ecto.Changeset.change(current, attrs))

        {:ok, event} =
          Timeline.schedule_event(:ship, ship.symbol, :intent_retry, due_at, %{
            "intent_id" => updated.id
          })

        {:ok, updated, event}
      end)

    case result do
      {:ok, updated, event} ->
        ShipServer.arm(agent, ship.symbol, event)
        {:ok, updated}

      :intent_no_longer_owned ->
        :ok
    end
  end

  defp authoritative_infeasibility?(%SpaceTraders.API.GameplayError{type: :contract_expired}),
    do: true

  defp authoritative_infeasibility?({:jump_gate_not_connected, _source, _destination}), do: true

  defp authoritative_infeasibility?({:jump_gate_incomplete, _waypoint}), do: true

  defp authoritative_infeasibility?({:insufficient_fuel, _waypoint}), do: true

  defp authoritative_infeasibility?({:insufficient_fuel_capacity, _required, _capacity}), do: true

  defp authoritative_infeasibility?({:warp_range_insufficient, _required, _range}), do: true

  defp authoritative_infeasibility?({:insufficient_credits, _required}), do: true

  defp authoritative_infeasibility?(:antimatter_unavailable), do: true

  defp authoritative_infeasibility?(:fuel_unavailable), do: true

  defp authoritative_infeasibility?(:no_confirmed_reachable_refuel_stop), do: true

  defp authoritative_infeasibility?(:method_not_allowed), do: true

  defp authoritative_infeasibility?(:jump_route_unavailable),
    do: true

  defp authoritative_infeasibility?(_reason), do: false

  defp mark_infeasible(intent, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    evidence = %{
      "intent_id" => intent.id,
      "intent_type" => intent.type,
      "reason" => infeasibility_reason(reason),
      "details" => inspect(reason),
      "target_waypoint" => intent.target_waypoint,
      "commitment_id" => intent.fleet_commitment_id,
      "portfolio_id" => intent.fleet_commitment_portfolio_id,
      "portfolio_version" => intent.fleet_commitment_portfolio_version,
      "observed_at" => DateTime.to_iso8601(now)
    }

    ship = Repo.get!(Ship, intent.ship_id)
    agent = Repo.get!(AgentRecord, ship.agent_id)

    FleetAllocation.report_infeasibility(agent, ship.symbol, evidence, fn ->
      case transition_intent(intent,
             status: "infeasible",
             blocker: nil,
             in_flight_action: nil,
             last_action_result: %{"outcome" => "infeasible", "evidence" => evidence},
             finished_at: now
           ) do
        {:ok, intent} -> intent
        :intent_no_longer_owned -> Repo.rollback(:intent_no_longer_owned)
      end
    end)
  end

  defp supersede_for_lost_claim(intent, outcome_reconciled? \\ false) do
    if outcome_reconciled? or not unresolved_intent_evidence?(intent) do
      do_supersede_for_lost_claim(intent)
    else
      block_intents(intent, :claim_withdrawn_pending_reconciliation)
    end
  end

  defp do_supersede_for_lost_claim(intent) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    transition_intent(intent,
      status: "superseded",
      blocker: nil,
      in_flight_action: nil,
      last_action_result: %{
        "outcome" => "authority_refused",
        "reason" => "no_current_ship_claim"
      },
      finished_at: now
    )
  end

  defp infeasibility_reason(reason) do
    case intents_block_reason(reason) do
      reason when is_atom(reason) -> Atom.to_string(reason)
      {reason, _details} when is_atom(reason) -> Atom.to_string(reason)
      {reason, _source, _destination} when is_atom(reason) -> Atom.to_string(reason)
      reason -> inspect(reason)
    end
  end

  defp preserve_claim?(%SpaceTraders.API.GameplayError{}), do: false
  defp preserve_claim?(:stale_agent), do: false
  defp preserve_claim?(_reason), do: true

  defp arrived_at_target?(%{nav: %{status: status, waypoint_symbol: waypoint}}, target)
       when status in ["DOCKED", "IN_ORBIT"],
       do: waypoint == target

  defp arrived_at_target?(_, _), do: false

  defp in_transit?(%{nav: %{status: "IN_TRANSIT"}}), do: true
  defp in_transit?(_), do: false

  defp docked?(%{nav: %{status: "DOCKED"}}), do: true
  defp docked?(_), do: false

  defp fuel_independent?(%{fuel: %{capacity: capacity}})
       when is_integer(capacity) and capacity <= 0,
       do: true

  defp fuel_independent?(_live_ship), do: false

  defp fuel_full?(%{fuel: %{current: current, capacity: capacity}})
       when is_integer(current) and is_integer(capacity),
       do: current >= capacity

  defp fuel_full?(_live_ship), do: false

  defp refuel_required?(intent, live_ship) do
    navigate_constraint(intent, "refuel") == "to_capacity" and
      not fuel_independent?(live_ship) and not fuel_full?(live_ship)
  end

  defp local_leg_fuel_preflight(_agent, %Intent{caller: "intervention"}, _live_ship), do: :ok

  defp local_leg_fuel_preflight(_agent, _intent, live_ship)
       when live_ship.fuel.capacity <= 0,
       do: :ok

  defp local_leg_fuel_preflight(agent, intent, live_ship) do
    if remote_waypoint?(live_ship.nav.waypoint_symbol, intent.target_waypoint) do
      :ok
    else
      fuel_stop = intent.parameters["fuel_stop"]

      destination =
        if is_binary(fuel_stop) and fuel_stop != live_ship.nav.waypoint_symbol,
          do: fuel_stop,
          else: intent.target_waypoint

      with {:ok, source} <- current_route_waypoint(live_ship),
           {:ok, system} <- Fleet.system_from_headquarters(destination),
           {:ok, target} <- navigation_target_waypoint(agent, system, destination),
           {:ok, required} <- estimated_navigation_fuel(source, target, live_ship.nav.flight_mode) do
        cond do
          live_ship.fuel.current >= required and destination == intent.target_waypoint ->
            :ok

          live_ship.fuel.current >= required ->
            {:navigate_fuel_stop, destination}

          required > live_ship.fuel.capacity and destination == intent.target_waypoint ->
            case confirmed_reachable_fuel_stop(agent, intent, live_ship, source, target, required) do
              {:ok, waypoint} -> {:navigate_fuel_stop, waypoint}
              :none -> {:error, :no_confirmed_reachable_refuel_stop}
            end

          required <= live_ship.fuel.capacity ->
            {:refuel, required}

          true ->
            {:error, {:insufficient_fuel_capacity, required, live_ship.fuel.capacity}}
        end
      else
        {:error, reason} -> {:error, {:navigation_intelligence_unavailable, reason}}
        _ -> {:error, :navigation_intelligence_unavailable}
      end
    end
  end

  defp confirmed_reachable_fuel_stop(agent, intent, live_ship, source, target, target_required) do
    {:ok, system} = Fleet.system_from_headquarters(live_ship.nav.waypoint_symbol)
    visited = MapSet.new(intent.parameters["visited_fuel_stops"] || [])

    candidates =
      agent
      |> World.waypoints(system, DateTime.utc_now(), 300)
      |> Enum.flat_map(fn waypoint ->
        with false <- waypoint.symbol == live_ship.nav.waypoint_symbol,
             false <- MapSet.member?(visited, waypoint.symbol),
             %{freshness: :fresh, value: x} when is_integer(x) <- waypoint.facts["x"],
             %{freshness: :fresh, value: y} when is_integer(y) <- waypoint.facts["y"],
             %{freshness: :fresh, value: goods} when is_list(goods) <-
               waypoint.market.facts["trade_goods"],
             true <- Enum.any?(goods, &(Map.get(&1, "symbol") == "FUEL")),
             candidate = %{symbol: waypoint.symbol, x: x, y: y},
             {:ok, fuel_required} <-
               estimated_navigation_fuel(source, candidate, live_ship.nav.flight_mode),
             true <- fuel_required <= live_ship.fuel.current,
             {:ok, remaining_required} <-
               estimated_navigation_fuel(candidate, target, live_ship.nav.flight_mode),
             true <- remaining_required < target_required do
          [{fuel_required, waypoint.symbol}]
        else
          _ -> []
        end
      end)

    case Enum.min_by(candidates, & &1, fn -> nil end) do
      {_required, waypoint} -> {:ok, waypoint}
      nil -> :none
    end
  end

  defp navigation_target_waypoint(agent, system, waypoint) do
    facts = Intelligence.subject(agent, :waypoint, system, waypoint)

    with %{state: "known", value: x} when is_integer(x) <- facts["x"],
         %{state: "known", value: y} when is_integer(y) <- facts["y"] do
      {:ok, %{symbol: waypoint, system_symbol: system, x: x, y: y}}
    else
      _ ->
        with {:ok, target} <-
               Agent.handle_game_result(
                 agent,
                 Evidence.get_waypoint(
                   AgentTokenReference.new(agent),
                   system,
                   waypoint,
                   required_facts: ["x", "y"]
                 )
               ),
             {:ok, _observation} <-
               Intelligence.observe_waypoint(agent, target, source: "get_waypoint") do
          {:ok, target}
        end
    end
  end

  defp current_route_waypoint(%{nav: %{waypoint_symbol: waypoint, route: route}}) do
    case Enum.find([route.destination, route.origin], &(&1.symbol == waypoint)) do
      %{x: x, y: y} = current when is_integer(x) and is_integer(y) -> {:ok, current}
      _ -> {:error, :current_coordinates_unavailable}
    end
  end

  defp estimated_navigation_fuel(%{x: x1, y: y1}, %{x: x2, y: y2}, flight_mode)
       when is_integer(x1) and is_integer(y1) and is_integer(x2) and is_integer(y2) do
    distance = :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2)) |> round()

    case flight_mode do
      mode when mode in ["CRUISE", "STEALTH"] -> {:ok, max(1, distance)}
      "DRIFT" -> {:ok, 1}
      "BURN" -> {:ok, max(2, distance * 2)}
      _ -> {:error, :flight_mode_unavailable}
    end
  end

  defp estimated_navigation_fuel(_source, _target, _flight_mode),
    do: {:error, :navigation_coordinates_unavailable}

  @doc false
  def navigation_fuel_estimate(source, target, flight_mode),
    do: estimated_navigation_fuel(source, target, flight_mode)

  defp flight_mode_mismatch?(intent, live_ship) do
    case navigate_constraint(intent, "flight_mode") do
      nil -> false
      flight_mode -> live_ship.nav.flight_mode != flight_mode
    end
  end

  defp navigate_constraint(intent, key),
    do: intent.parameters[key] || intent.parameters[String.to_existing_atom(key)]

  defp remote_waypoint?(source, destination) do
    with {:ok, source_system} <- Fleet.system_from_headquarters(source),
         {:ok, destination_system} <- Fleet.system_from_headquarters(destination) do
      source_system != destination_system
    else
      _ -> false
    end
  end

  defp arrived_at_intermediate_waypoint?(%Intent{in_flight_action: action}, live_ship)
       when is_map(action) do
    action["kind"] == "navigate" and action["waypoint"] == live_ship.nav.waypoint_symbol and
      not in_transit?(live_ship)
  end

  defp arrived_at_intermediate_waypoint?(_intent, _live_ship), do: false

  defp jump_evidence?(intent) do
    get_in(intent.last_action_result || %{}, ["kind"]) == "jump" or
      unresolved_jump_action?(intent)
  end

  defp warp_evidence?(intent) do
    get_in(intent.last_action_result || %{}, ["kind"]) == "warp" or
      unresolved_warp_action?(intent)
  end

  defp intent_recovery_retry_or_block(ship, intent, agent_id, reason) do
    ship_symbol = ship.symbol

    if intent.recovery_attempts < 3 do
      Repo.update!(Ecto.Changeset.change(intent, recovery_attempts: intent.recovery_attempts + 1))

      Fleet.record_activity_by_id(
        agent_id,
        ship,
        "owned_intent_recovery",
        "Authoritative recovery read failed; retrying",
        "transport_error"
      )

      recover_owned_intent_on_boot(ship_symbol, agent_id)
    else
      case Repo.transaction(fn ->
             current = Repo.get!(Intent, intent.id)

             if Intent.unfinished?(current) do
               update_intent!(
                 Ecto.Changeset.change(current,
                   status: "blocked",
                   blocker: Fleet.intent_blocker({:retry_exhausted, reason}),
                   in_flight_action: current.in_flight_action
                 )
               )
             else
               Repo.rollback(:intent_no_longer_unfinished)
             end
           end) do
        {:ok, blocked_intent} ->
          record_activity_by_intent(
            blocked_intent,
            "owned_intent_recovery",
            "Owned Intent recovery blocked after retry exhaustion",
            %{"outcome" => "retry_exhausted"}
          )

          {:error, :intents_recovery_blocked}

        {:error, :intent_no_longer_unfinished} ->
          :ok
      end
    end
  end

  defp record_activity_by_intent(intent, kind, message, metadata) do
    ship = Repo.get!(Ship, intent.ship_id)

    Fleet.record_activity(
      Repo.get!(AgentRecord, ship.agent_id),
      ship,
      kind,
      message,
      metadata
    )
  end

  defp schedule_cooldown(agent, ship_symbol, %{
         cooldown: %{remaining_seconds: seconds, expiration: expiration}
       })
       when is_integer(seconds) and seconds > 0 do
    due_at = Timeline.parse_expiration(expiration, seconds)
    {:ok, event} = Timeline.schedule_event(:ship, ship_symbol, :cooldown, due_at)
    ShipServer.arm(agent, ship_symbol, event)
  end

  defp schedule_cooldown(_agent, _ship_symbol, _result), do: :ok

  defp persist_destination_history(agent, ship_symbol, waypoint_symbol) do
    try do
      case Fleet.record_destination(agent, ship_symbol, waypoint_symbol) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not persist destination history: #{inspect(reason)}")

        other ->
          Logger.warning("Could not persist destination history: #{inspect(other)}")
      end
    rescue
      exception ->
        Logger.warning("Could not persist destination history: #{Exception.message(exception)}")
    end
  end

  defp validate_jump_route(agent, source_system, source, destination_system, destination) do
    source_waypoint = %{system_symbol: source_system, symbol: source}
    destination_waypoint = %{system_symbol: destination_system, symbol: destination}

    with {:ok, source_construction} <- Fleet.waypoint_construction(agent, source_waypoint),
         true <- source_construction.is_complete || {:error, {:jump_gate_incomplete, source}},
         {:ok, source_gate} <- Fleet.waypoint_jump_gate(agent, source_waypoint),
         true <-
           destination in source_gate.connections ||
             {:error, {:jump_gate_not_connected, source, destination}},
         {:ok, destination_construction} <-
           Fleet.waypoint_construction(agent, destination_waypoint),
         true <-
           destination_construction.is_complete || {:error, {:jump_gate_incomplete, destination}},
         {:ok, destination_gate} <- Fleet.waypoint_jump_gate(agent, destination_waypoint),
         true <-
           source in destination_gate.connections ||
             {:error, {:jump_gate_not_connected, destination, source}} do
      :ok
    else
      false -> {:error, :jump_route_unavailable}
      {:error, _reason} = error -> error
      error -> {:error, error}
    end
  end

  defp jump_cost_preflight(agent, source_system, source_waypoint) do
    with {:ok, overview} <- Agent.agent_overview(agent),
         {:ok, market} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.Evidence.get_market(
               AgentTokenReference.new(agent),
               source_system,
               source_waypoint
             )
           ),
         antimatter when not is_nil(antimatter) <-
           Enum.find(market.trade_goods || [], &(&1.symbol == "ANTIMATTER")),
         price when is_integer(price) and price >= 0 <- antimatter.purchase_price,
         true <- overview.credits >= price || {:error, {:insufficient_credits, price}} do
      {:ok, %{credits: overview.credits, antimatter_cost: price}}
    else
      nil -> {:error, :antimatter_unavailable}
      {:error, _reason} = error -> error
      _ -> {:error, :antimatter_unavailable}
    end
  end

  # A restarted owned Intent re-enters the same reconciliation from boot's fresh
  # observation; recovery never replays a stored mutation.
  defp recover_owned_intent_on_boot(ship_symbol, agent_id) do
    reconcile(agent_id, ship_symbol, nil, :boot, nil)
  end
end
