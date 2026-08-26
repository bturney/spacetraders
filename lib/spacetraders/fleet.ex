defmodule SpaceTraders.Fleet do
  @moduledoc """
  The Fleet context: the ships an Agent owns and their live state.

  A ship's live state — location, fuel, cargo, cooldown, nav status — is pulled
  from the game through `SpaceTraders.API`. The server is the source of truth;
  the local `ships` table is the app's registry of owned ships (seeded with the
  starter fleet) and carries no live state. The dashboard reads the live fleet
  through this context so it stays a thin consumer with no game logic of its own.

  Ship actions here orchestrate the game call and the app's async model: after a
  successful navigate the pending arrival is persisted to the timeline and armed
  on the ship's GenServer, so the ship stays busy until it actually arrives
  (ADR 0005).
  """

  import Ecto.Query, warn: false
  require Logger

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model.{Market, ShipNav, ShipNavRoute}
  alias SpaceTraders.Fleet.{Activity, Job, JobBlocker, ManualIntent, Ship, ShipDestination}
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Repo
  alias SpaceTraders.{Agent, Contracts, Intelligence, Listing, Shipyard}
  alias SpaceTraders.Timeline

  @gather_kinds ["extract", "siphon"]
  @terminal_job_states Job.terminal_states()
  @running_job_states Job.running_states()
  @max_recovery_attempts 5
  @recovery_window_seconds 15 * 60
  @unfinished_intent_states ManualIntent.unfinished_states()
  @terminal_intent_states ManualIntent.terminal_states()

  @doc """
  Pulls the agent's live fleet from the game API.

  Each ship carries its current nav (location + docked/orbiting/transit state),
  fuel, cargo and cooldown — the data the fleet cards render.

  Returns `{:ok, [%SpaceTraders.API.Model.Ship{}]}` or an API error. An agent
  without a stored AgentToken returns `{:error, :agent_token_missing}`.
  """
  def list_ships(%AgentRecord{agent_token: agent_token})
      when is_binary(agent_token) and agent_token != "" do
    SpaceTraders.API.get_ships(agent_token)
  end

  def list_ships(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc """
  Reads everything the Fleet command panel displays for an Agent.

  Each live read remains independent: an unavailable Agent overview or Shipyard
  does not hide the rest of the Agent's Fleet. The game remains the source of
  truth, so every call assembles fresh data.
  """
  def command_snapshot(%AgentRecord{} = agent) do
    if Agent.stale?(agent) do
      stale_snapshot(agent)
    else
      overview = Agent.agent_overview(agent)

      if overview == {:error, :stale_agent} do
        stale_snapshot(agent)
      else
        ships = list_ships(agent) |> annotate_jobs(agent)
        ships = annotate_actions(ships)
        waypoints = list_waypoints(agent)

        listings =
          snapshot_listings(agent, ships, waypoints) |> annotate_listing_actions(overview)

        %{
          agent: agent,
          stale?: false,
          overview: overview,
          ships: ships,
          contracts: Contracts.list_contracts(agent),
          shipyards: listings.shipyards,
          markets: listings.markets,
          waypoints: waypoints,
          activity: recent_activity(agent)
        }
      end
    end
  end

  defp stale_snapshot(agent) do
    %{
      agent: agent,
      stale?: true,
      overview: {:error, :stale_agent},
      ships: {:error, :stale_agent},
      contracts: {:error, :stale_agent},
      shipyards: {:error, :stale_agent},
      markets: {:error, :stale_agent},
      waypoints: {:error, :stale_agent},
      activity: []
    }
  end

  @doc "Reads Market data for a selected Waypoint when it is a Marketplace."
  def waypoint_market(%AgentRecord{agent_token: token} = agent, waypoint)
      when is_binary(token) and token != "" do
    with :ok <- market_waypoint?(waypoint),
         %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      case SpaceTraders.API.get_market(token, system, symbol) do
        {:ok, market} = result ->
          record_market_observation(agent, system, market, "get_market")
          result

        result ->
          result
      end
    else
      {:error, :invalid_market_waypoint} -> :not_a_marketplace
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_market(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Returns recent local events for an Agent, newest first."
  def recent_activity(%AgentRecord{} = agent) do
    Activity
    |> where([a], a.agent_id == ^agent.id)
    |> order_by([a], desc: a.inserted_at)
    # The dashboard removes retry/polling noise before selecting its latest ten.
    |> limit(100)
    |> preload(:ship)
    |> Repo.all()
  end

  defp annotate_jobs({:ok, ships}, agent) do
    ship_records = Enum.map(ships, &ensure_ship_record(agent, &1))
    jobs_by_ship = jobs_for_ships(ship_records)
    intents_by_ship = manual_intents_for_ships(ship_records)
    intent_history_by_ship = manual_intent_history_for_ships(ship_records)

    {:ok,
     Enum.map(ships, fn ship ->
       ship_record = Enum.find(ship_records, &(&1.symbol == ship.symbol))
       {job, history} = job_and_history(Map.get(jobs_by_ship, ship_record.id, []))

       ship
       |> Map.put(:job, job)
       |> Map.put(:job_history, history)
       |> Map.put(:manual_intent, Map.get(intents_by_ship, ship_record.id))
       |> Map.put(:manual_intent_history, Map.get(intent_history_by_ship, ship_record.id, []))
       |> Map.put(:destination_history, destination_history(agent, ship.symbol))
     end)}
  end

  defp annotate_jobs(result, _agent), do: result

  defp manual_intents_for_ships(ship_records) do
    ship_ids = Enum.map(ship_records, & &1.id)

    ManualIntent
    |> where(
      [intent],
      intent.ship_id in ^ship_ids and intent.status in ^@unfinished_intent_states
    )
    |> Repo.all()
    |> Map.new(&{&1.ship_id, &1})
  end

  defp manual_intent_history_for_ships(ship_records) do
    ship_ids = Enum.map(ship_records, & &1.id)

    ManualIntent
    |> where([intent], intent.ship_id in ^ship_ids and intent.status in ^@terminal_intent_states)
    |> order_by([intent], desc: intent.finished_at, desc: intent.id)
    |> Repo.all()
    |> Enum.group_by(& &1.ship_id)
  end

  defp annotate_actions({:ok, ships}) do
    {:ok, Enum.map(ships, &Map.put(&1, :actions, ship_actions(&1)))}
  end

  defp annotate_actions(result), do: result

  # Outcome-level Navigate is always dispatchable: its Intent reconciles
  # authoritative location, transit, posture, fuel, arrival, and cooldown
  # instead of refusing while the Ship is busy.
  defp ship_actions(ship) do
    cooldown = cooldown_active?(ship)
    status = ship_status(ship)

    %{
      navigate: action_state(true, nil),
      set_flight_mode:
        action_state(
          status != "IN_TRANSIT",
          :ship_in_transit
        ),
      dock:
        action_state(
          not cooldown and status == "IN_ORBIT",
          cooldown_reason(cooldown, :ship_not_in_orbit)
        ),
      orbit:
        action_state(
          not cooldown and status == "DOCKED",
          cooldown_reason(cooldown, :ship_not_docked)
        ),
      extract:
        action_state(
          not cooldown and status == "IN_ORBIT",
          cooldown_reason(cooldown, :ship_not_in_orbit)
        ),
      siphon:
        action_state(
          not cooldown and status == "IN_ORBIT" and match?(:ok, siphon_capability?(ship)),
          siphon_reason(cooldown, status, ship)
        ),
      refuel:
        action_state(
          not cooldown and status == "DOCKED",
          cooldown_reason(cooldown, :ship_not_docked)
        )
    }
  end

  defp ship_status(%{nav: %{status: status}}) when is_binary(status), do: status
  defp ship_status(_), do: "UNKNOWN"

  defp cooldown_reason(true, _reason), do: :cooldown_active
  defp cooldown_reason(false, reason), do: reason

  defp siphon_reason(true, _status, _ship), do: :cooldown_active

  defp siphon_reason(false, "IN_ORBIT", ship) do
    case siphon_capability?(ship) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp siphon_reason(false, _status, _ship), do: :ship_not_in_orbit

  defp action_state(true, _reason), do: %{allowed?: true, reason: nil}
  defp action_state(false, reason), do: %{allowed?: false, reason: reason}

  defp ensure_ship_record(agent, %{symbol: symbol}) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: symbol) do
      %Ship{} = ship ->
        ship

      nil ->
        case record_ship(agent, symbol, "UNKNOWN") do
          {:ok, %Ship{id: id} = ship} when is_integer(id) ->
            ship

          {:ok, _conflict} ->
            Repo.get_by!(Ship, agent_id: agent.id, symbol: symbol)

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  @doc "Saves a Miner Job configuration without activating it."
  def configure_miner_job(%AgentRecord{} = agent, ship_symbol, attrs) when is_map(attrs) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         nil <- unfinished_job(ship.id),
         {:ok, job} <- insert_miner_job(ship, attrs) do
      record_activity(agent, ship, "configuration", "Miner Job configuration changed")
      {:ok, job}
    else
      %Job{} -> {:error, :unfinished_job_already_assigned}
      error -> error
    end
  end

  @doc "Replaces a Ship's unfinished Job and preserves the predecessor as terminal history."
  def replace_miner_job(%AgentRecord{} = agent, ship_symbol, attrs) when is_map(attrs) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol) do
      case Repo.transaction(fn -> replace_miner_job_transaction(ship, attrs) end) do
        {:ok, job} ->
          record_activity(agent, ship, "configuration", "Miner Job replaced")
          {:ok, job}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Pauses an active Miner Job while retaining its configuration."
  def pause_miner_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{} = job <- unfinished_job(ship.id) do
      in_flight_action =
        case job.in_flight_action do
          %{"kind" => "navigate"} = action -> action
          _ -> nil
        end

      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "paused",
            in_flight_action: in_flight_action,
            blocker: nil,
            blocked_reason: "Paused by Operator"
          )
        )

      record_activity(agent, ship, "pause", "Miner Job paused by Operator")
      {:ok, job}
    else
      nil -> {:error, :miner_job_not_configured}
      error -> error
    end
  end

  @doc "Resumes a Miner Job only after a complete authoritative validation."
  def resume_miner_job(%AgentRecord{} = agent, ship_symbol),
    do: start_miner_job(agent, ship_symbol)

  @doc "Stops a Miner Job, cancels pending work, and preserves its terminal history."
  def stop_miner_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{} = job <- unfinished_job(ship.id) do
      terminalize_job!(job, "stopped")
      record_activity(agent, ship, "stop", "Miner Job stopped; Ship returned to Manual")
      :ok
    else
      nil -> {:error, :miner_job_not_configured}
      error -> error
    end
  end

  @doc """
  Issues a same-System Navigate Intent through Manual Control.

  Manual Control durably pauses the assigned Job before the Intent may dispatch
  a mutating game request, persists the intent chain and in-flight evidence,
  and reconciles authoritative location, navigation state, posture, fuel,
  arrival, and cooldown instead of persisting a fixed action script. Issuing a
  new Navigate explicitly replaces a pending one without cancelling an action
  the game already accepted. Completion requires authoritative Ship state at
  the requested Waypoint; the preempted Job remains paused until an explicit
  resume.

  Returns `{:ok, %ManualIntent{}}` with its current status (`active`,
  `waiting`, `blocked`, or `completed`), or an error.
  """
  def navigate_intent(%AgentRecord{agent_token: agent_token} = agent, ship_symbol, waypoint)
      when is_binary(agent_token) and agent_token != "" do
    waypoint = String.trim(waypoint || "")

    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "navigation"}),
         {:ok, intent} <- replace_manual_intent(ship, waypoint) do
      reconcile_manual_intent(agent, intent)
    else
      {:error, %Ecto.Changeset{}} -> {:error, :manual_intent_conflict}
      error -> error
    end
  end

  def navigate_intent(%AgentRecord{}, _ship_symbol, _waypoint),
    do: {:error, :agent_token_missing}

  @doc "Returns a Ship's unfinished Manual Control Intent, or nil."
  def ship_manual_intent(%AgentRecord{} = agent, ship_symbol) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} -> unfinished_manual_intent(ship.id)
      _ -> nil
    end
  end

  @doc "Stops a Ship's unfinished Manual Control Intent; the assigned Job remains paused."
  def stop_manual_intent(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %ManualIntent{target_waypoint: target} = intent <- unfinished_manual_intent(ship.id) do
      terminalize_manual_intent!(intent, "stopped")
      record_activity(agent, ship, "manual_intent_stopped", "Navigate to #{target} stopped")
      :ok
    else
      nil -> {:error, :manual_intent_not_active}
      error -> error
    end
  end

  @doc "Reconciles the Ship's Manual Control Intent after an authoritative arrival."
  def revalidate_manual_intent_arrival(agent_id, ship_symbol, live_ship, expected_intent_id) do
    revalidate_manual_intent(agent_id, ship_symbol, live_ship, expected_intent_id)
  end

  @doc "Reconciles the Ship's Manual Control Intent after an authoritative cooldown."
  def revalidate_manual_intent_cooldown(agent_id, ship_symbol, live_ship, expected_intent_id) do
    revalidate_manual_intent(agent_id, ship_symbol, live_ship, expected_intent_id)
  end

  # The Navigate Intent reconcile loop. Every step derives the next API action
  # from authoritative Ship state — location, navigation state, posture, fuel,
  # arrival, and cooldown — so recovery can resume from game truth instead of
  # replaying a fixed script.
  defp advance_manual_intent(
         agent,
         %ManualIntent{recovery_attempts: attempts} = intent,
         live_ship
       )
       when attempts > 0 do
    intent = Repo.update!(Ecto.Changeset.change(intent, recovery_attempts: 0))
    advance_manual_intent(agent, intent, live_ship)
  end

  defp advance_manual_intent(agent, %ManualIntent{} = intent, live_ship) do
    cond do
      arrived_at_target?(live_ship, intent.target_waypoint) ->
        complete_manual_intent(agent, intent)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      docked?(live_ship) ->
        orbit_for_manual_intent(agent, intent, live_ship)

      fuel_empty?(live_ship) ->
        block_manual_intent(intent, {:insufficient_fuel, intent.target_waypoint})

      true ->
        dispatch_manual_navigate(agent, intent, live_ship)
    end
  end

  defp reconcile_manual_intent(agent, intent) do
    ship = Repo.get!(Ship, intent.ship_id)

    case SpaceTraders.API.get_ship(agent.agent_token, ship.symbol) do
      {:ok, live_ship} -> advance_manual_intent(agent, intent, live_ship)
      {:error, reason} -> block_manual_intent(intent, reason)
    end
  end

  defp revalidate_manual_intent(agent_id, ship_symbol, live_ship, expected_intent_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %ManualIntent{} = intent <- unfinished_manual_intent(ship.id),
         true <- intent_matches_event?(intent, expected_intent_id) do
      advance_manual_intent(Repo.get!(AgentRecord, agent_id), intent, live_ship)
    else
      _ -> :ok
    end
  end

  defp intent_matches_event?(_intent, nil), do: false
  defp intent_matches_event?(%ManualIntent{id: id}, id), do: true
  defp intent_matches_event?(_intent, _expected_intent_id), do: false

  defp validate_intent_waypoint(""), do: {:error, :invalid_waypoint}
  defp validate_intent_waypoint(_waypoint), do: :ok

  # Replacing a pending manual outcome is explicit; it cannot cancel an action
  # the game already accepted, which reconciliation below accounts for.
  defp replace_manual_intent(ship, waypoint) do
    Repo.transaction(fn ->
      case unfinished_manual_intent(ship.id) do
        %ManualIntent{} = predecessor -> terminalize_manual_intent!(predecessor, "stopped")
        nil -> :ok
      end

      {:ok, intent} =
        %ManualIntent{ship_id: ship.id}
        |> ManualIntent.changeset(%{target_waypoint: waypoint})
        |> Ecto.Changeset.put_change(:status, "active")
        |> Repo.insert()

      intent
    end)
  end

  defp unfinished_manual_intent(ship_id) do
    Repo.one(
      from intent in ManualIntent,
        where: intent.ship_id == ^ship_id and intent.status in ^@unfinished_intent_states
    )
  end

  defp terminalize_manual_intent!(intent, status) when status in @terminal_intent_states do
    Repo.update!(
      Ecto.Changeset.change(intent,
        status: status,
        in_flight_action: nil,
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    )
  end

  defp complete_manual_intent(agent, intent) do
    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "completed",
          blocker: nil,
          in_flight_action: nil,
          last_action_result: %{"kind" => "navigate", "waypoint" => intent.target_waypoint},
          finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
      )

    ship = Repo.get!(Ship, intent.ship_id)

    record_activity(
      agent,
      ship,
      "manual_intent_completed",
      "Navigate complete at #{intent.target_waypoint}",
      %{"waypoint" => intent.target_waypoint}
    )

    {:ok, intent}
  end

  # The Ship is already travelling — toward the target or elsewhere — so the
  # Intent waits for that authoritative arrival before choosing another step.
  defp wait_for_manual_arrival(agent, intent, live_ship) do
    case schedule_intent_arrival(agent, intent, live_ship.symbol, %{nav: live_ship.nav}) do
      :ok ->
        intent =
          Repo.update!(
            Ecto.Changeset.change(intent,
              status: "waiting",
              last_action_result: %{"kind" => "wait", "wait" => "arrival"}
            )
          )

        ship = Repo.get!(Ship, intent.ship_id)

        record_activity(
          agent,
          ship,
          "manual_intent_waiting",
          "Navigate to #{intent.target_waypoint} waiting for arrival",
          %{"wait" => "arrival"}
        )

        {:ok, intent}

      {:error, _reason} = error ->
        error
    end
  end

  defp wait_for_manual_cooldown(agent, intent, live_ship) do
    due_at = parse_expiration(live_ship.cooldown.expiration, live_ship.cooldown.remaining_seconds)

    {:ok, event} =
      Timeline.schedule_event(:ship, live_ship.symbol, :cooldown, due_at, %{
        "intent_id" => intent.id
      })

    ShipServer.arm(agent, live_ship.symbol, event)

    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "waiting",
          last_action_result: %{"kind" => "wait", "wait" => "cooldown"}
        )
      )

    ship = Repo.get!(Ship, intent.ship_id)

    record_activity(
      agent,
      ship,
      "manual_intent_waiting",
      "Navigate to #{intent.target_waypoint} waiting for cooldown",
      %{"wait" => "cooldown"}
    )

    {:ok, intent}
  end

  defp orbit_for_manual_intent(agent, intent, live_ship) do
    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "active",
          in_flight_action: %{
            "kind" => "orbit",
            "waypoint" => live_ship.nav.waypoint_symbol,
            "expected" => %{"status" => "IN_ORBIT"}
          }
        )
      )

    case SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol) do
      {:ok, result} ->
        intent =
          Repo.update!(
            Ecto.Changeset.change(intent,
              in_flight_action: nil,
              last_action_result: %{"kind" => "orbit", "status" => result.nav.status}
            )
          )

        advance_manual_intent(agent, intent, %{live_ship | nav: result.nav})

      {:error, reason} ->
        block_manual_intent(intent, reason)
    end
  end

  defp dispatch_manual_navigate(agent, intent, live_ship) do
    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "active",
          in_flight_action: %{
            "kind" => "navigate",
            "waypoint" => intent.target_waypoint,
            "expected" => %{"status" => "IN_TRANSIT", "destination" => intent.target_waypoint}
          }
        )
      )

    case SpaceTraders.API.navigate_ship(
           agent.agent_token,
           live_ship.symbol,
           intent.target_waypoint
         ) do
      {:ok, result} ->
        schedule_intent_arrival(agent, intent, live_ship.symbol, result)
        persist_destination_history(agent, live_ship.symbol, result.nav.route.destination.symbol)

        intent =
          Repo.update!(
            Ecto.Changeset.change(intent,
              status: "waiting",
              last_action_result: %{
                "kind" => "navigate",
                "waypoint" => intent.target_waypoint,
                "status" => result.nav.status,
                "destination" => result.nav.route.destination.symbol
              }
            )
          )

        ship = Repo.get!(Ship, intent.ship_id)

        record_activity(
          agent,
          ship,
          "manual_intent_navigate",
          "#{live_ship.symbol} navigating to #{intent.target_waypoint}",
          %{"waypoint" => intent.target_waypoint}
        )

        {:ok, intent}

      {:error, reason} ->
        block_manual_intent(intent, reason)
    end
  end

  defp schedule_intent_arrival(
         agent,
         intent,
         ship_symbol,
         %{nav: %ShipNav{status: "IN_TRANSIT"} = nav}
       ) do
    case parse_arrival(nav.route) do
      {:ok, due_at} ->
        payload = arrival_payload(nav) |> Map.put("intent_id", intent.id)

        {:ok, event} = Timeline.schedule_event(:ship, ship_symbol, :arrival, due_at, payload)

        ShipServer.arm(agent, ship_symbol, event)
        :ok

      :error ->
        block_manual_intent(intent, :unreadable_arrival)
        {:error, :unreadable_arrival}
    end
  end

  defp schedule_intent_arrival(_agent, _intent, _ship_symbol, _result), do: :ok

  defp block_manual_intent(intent, reason) do
    already_blocked? = Repo.get!(ManualIntent, intent.id).status == "blocked"

    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: job_blocker(manual_intent_block_reason(reason)),
          in_flight_action: nil
        )
      )

    unless already_blocked? do
      record_activity_by_intent(
        intent,
        "manual_intent_blocked",
        "Navigate to #{intent.target_waypoint} blocked: #{inspect(reason)}",
        %{"block" => inspect(reason)}
      )
    end

    {:ok, intent}
  end

  # Typed game rejections become stable blocker reasons; transport failures
  # keep their struct evidence.
  defp manual_intent_block_reason(%SpaceTraders.API.GameplayError{type: type})
       when is_atom(type) and type != :other,
       do: type

  defp manual_intent_block_reason(reason), do: reason

  defp arrived_at_target?(%{nav: %{status: status, waypoint_symbol: waypoint}}, target)
       when status in ["DOCKED", "IN_ORBIT"],
       do: waypoint == target

  defp arrived_at_target?(_, _), do: false

  defp in_transit?(%{nav: %{status: "IN_TRANSIT"}}), do: true
  defp in_transit?(_), do: false

  defp docked?(%{nav: %{status: "DOCKED"}}), do: true
  defp docked?(_), do: false

  # A fuel-independent Ship is recognized from authoritative capacity; zero
  # current fuel only blocks Ships that actually burn fuel.
  defp fuel_empty?(%{fuel: %{capacity: capacity}}) when is_integer(capacity) and capacity <= 0,
    do: false

  defp fuel_empty?(%{fuel: %{current: current}}) when is_integer(current), do: current <= 0
  defp fuel_empty?(_), do: false

  @doc "Reconciles a persisted Manual Control Intent after a process restart."
  def recover_manual_intent_on_boot(ship_symbol, agent_id, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %ManualIntent{} = intent <- unfinished_manual_intent(ship.id) do
      case SpaceTraders.API.get_ship(agent_token, ship_symbol) do
        {:ok, live_ship} ->
          advance_manual_intent(Repo.get!(AgentRecord, agent_id), intent, live_ship)

        {:error, reason} ->
          intent_recovery_retry_or_block(ship, intent, agent_id, agent_token, reason)
      end
    else
      _ -> :ok
    end
  end

  defp intent_recovery_retry_or_block(ship, intent, agent_id, agent_token, reason) do
    ship_symbol = ship.symbol

    if intent.recovery_attempts < 3 do
      Repo.update!(Ecto.Changeset.change(intent, recovery_attempts: intent.recovery_attempts + 1))

      record_activity_by_id(
        agent_id,
        ship,
        "manual_intent_recovery",
        "Authoritative recovery read failed; retrying",
        "transport_error"
      )

      recover_manual_intent_on_boot(ship_symbol, agent_id, agent_token)
    else
      intent =
        Repo.update!(
          Ecto.Changeset.change(intent,
            status: "blocked",
            blocker: job_blocker({:retry_exhausted, reason}),
            in_flight_action: nil
          )
        )

      record_activity_by_intent(
        intent,
        "manual_intent_recovery",
        "Manual navigate recovery blocked after retry exhaustion",
        %{"outcome" => "retry_exhausted"}
      )

      {:error, :manual_intent_recovery_blocked}
    end
  end

  defp record_activity_by_intent(intent, kind, message, metadata) do
    ship = Repo.get!(Ship, intent.ship_id)

    record_activity(
      Repo.get!(AgentRecord, ship.agent_id),
      ship,
      kind,
      message,
      metadata
    )
  end

  @doc "Returns a Ship's durable Job, or nil."
  def ship_job(%AgentRecord{} = agent, ship_symbol) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} -> unfinished_job(ship.id)
      _ -> nil
    end
  end

  @doc "Returns a Ship's immutable terminal Job history, newest first."
  def ship_job_history(%AgentRecord{} = agent, ship_symbol) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} ->
        Job
        |> where([job], job.ship_id == ^ship.id and job.status in ^@terminal_job_states)
        |> order_by([job], desc: job.finished_at, desc: job.id)
        |> Repo.all()

      _ ->
        []
    end
  end

  defp jobs_for_ships(ship_records) do
    ship_ids = Enum.map(ship_records, & &1.id)

    Job
    |> where([job], job.ship_id in ^ship_ids)
    |> Repo.all()
    |> Enum.group_by(& &1.ship_id)
  end

  defp job_and_history(jobs) do
    job = Enum.find(jobs, &(&1.status not in @terminal_job_states))

    history =
      jobs
      |> Enum.filter(&(&1.status in @terminal_job_states))
      |> Enum.sort_by(&{&1.finished_at, &1.id}, :desc)

    successors = Map.new(jobs, &{&1.predecessor_job_id, &1.id})

    history = Enum.map(history, &Map.put(&1, :successor_job_id, Map.get(successors, &1.id)))

    {job, history}
  end

  @doc "Starts a configured Miner Job after authoritative validation."
  def start_miner_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{} = job <- unfinished_job(ship.id),
         nil <- unfinished_manual_intent(ship.id),
         {:ok, live_ship, sellable_goods, deliverables} <- validate_miner_job(agent, ship, job) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "active",
            blocked_reason: nil,
            blocker: nil,
            sellable_goods: sellable_goods,
            contract_deliverables: deliverables,
            last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
        )

      case advance_miner_job(agent, job, live_ship) do
        {:ok, job} -> {:ok, job}
        {:error, reason} -> {:error, {:miner_job_blocked, reason}}
      end
    else
      nil -> {:error, :miner_job_not_configured}
      %ManualIntent{} -> {:error, :manual_intent_active}
      {:error, reason} -> block_miner_job(agent, ship_symbol, reason)
    end
  end

  defp owned_ship(agent, symbol) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: symbol) do
      nil -> {:error, :ship_not_owned}
      ship -> {:ok, ship}
    end
  end

  defp insert_miner_job(ship, attrs) do
    %Job{ship_id: ship.id}
    |> Job.changeset(attrs)
    |> Ecto.Changeset.put_change(:status, "paused")
    |> Ecto.Changeset.put_change(:blocked_reason, "Awaiting Operator resume")
    |> Ecto.Changeset.put_change(:blocker, nil)
    |> Ecto.Changeset.put_change(:sellable_goods, [])
    |> Repo.insert()
  end

  defp replace_miner_job_transaction(ship, attrs) do
    case unfinished_job(ship.id) do
      %Job{} = predecessor ->
        predecessor = terminalize_job!(predecessor, "replaced")

        case insert_miner_job(ship, Map.put(attrs, :predecessor_job_id, predecessor.id)) do
          {:ok, successor} -> successor
          {:error, changeset} -> Repo.rollback(changeset)
        end

      nil ->
        Repo.rollback(:miner_job_not_configured)
    end
  end

  defp terminalize_job!(job, status) when status in @terminal_job_states do
    Repo.update!(
      Ecto.Changeset.change(job,
        status: status,
        in_flight_action: nil,
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    )
  end

  defp unfinished_job(ship_id) do
    Repo.one(
      from job in Job,
        where: job.ship_id == ^ship_id and job.status not in ^@terminal_job_states
    )
  end

  defp preempt_miner_job(agent, ship, reason) do
    case unfinished_job(ship.id) do
      %Job{status: status} = config when status in @running_job_states ->
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "paused",
            in_flight_action: nil,
            blocker: nil,
            blocked_reason: preemption_message(reason)
          )
        )

        message = preemption_message(reason)
        record_activity(agent, ship, "manual_override", message, %{"recovery" => "resume"})
        :ok

      _ ->
        :ok
    end
  end

  defp preemption_message({:manual_override, action}), do: "Paused by direct #{action}"
  defp preemption_message(:manual_override), do: "Paused by a direct Ship action"
  defp preemption_message(:configuration_changed), do: "Paused because configuration changed"
  defp preemption_message(reason), do: "Paused: #{inspect(reason)}"

  defp preempt_miner_job_for(agent, ship_symbol, reason) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
      %Ship{} = ship -> preempt_miner_job(agent, ship, reason)
      nil -> :ok
    end
  end

  defp record_activity(agent, ship, kind, message, metadata \\ %{}) do
    Repo.insert!(%Activity{
      agent_id: agent.id,
      ship_id: ship.id,
      kind: kind,
      message: message,
      metadata: metadata
    })

    :ok
  end

  defp record_command_result(agent, ship_symbol, kind, {:ok, _result} = result) do
    record_command_activity(agent, ship_symbol, kind, "#{command_label(kind)} command completed")
    result
  end

  defp record_command_result(_agent, _ship_symbol, _kind, result), do: result

  defp record_command_activity(agent, ship_symbol, kind, message) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
      record_activity(agent, ship, kind, message)
    end
  end

  defp command_label(kind), do: String.replace(kind, "_", " ") |> String.capitalize()

  defp record_miner_job_activity(agent, live_ship, kind, message, metadata) do
    ship = Repo.get_by!(Ship, agent_id: agent.id, symbol: live_ship.symbol)
    record_activity(agent, ship, kind, message, metadata)
  end

  defp validate_miner_job(%AgentRecord{agent_token: token} = agent, ship, config)
       when is_binary(token) and token != "" do
    with {:ok, live_ship} <- SpaceTraders.API.get_ship(token, ship.symbol),
         {:ok, gather} <-
           waypoint(token, live_ship.nav.system_symbol, config.extraction_waypoint),
         :ok <- gather_waypoint?(config.gather_mode, gather),
         {:ok, market_waypoint} <-
           waypoint(token, live_ship.nav.system_symbol, config.market_waypoint),
         :ok <- market_waypoint?(market_waypoint),
         {:ok, market} <- market_for_ship(agent, live_ship, config.market_waypoint),
         :ok <- market_available?(market),
         :ok <- cargo_policy?(live_ship, config.cargo_threshold),
         :ok <- gather_capability?(config.gather_mode, live_ship) do
      deliverables =
        case Contracts.active_deliverables(agent) do
          {:ok, entries} -> entries
          {:error, _reason} -> config.contract_deliverables || []
        end

      {:ok, live_ship, accepted_sellable_goods(market), deliverables}
    end
  end

  defp validate_miner_job(_, _, _), do: {:error, :agent_token_missing}

  defp waypoint(token, system, symbol), do: SpaceTraders.API.get_waypoint(token, system, symbol)

  # The gather mode's Waypoint capability is checked against the game's
  # authoritative Waypoint state, not persisted trust; the game's action
  # response remains the binding check once the loop runs.
  defp gather_waypoint?("siphon", %{type: "GAS_GIANT"}), do: :ok
  defp gather_waypoint?("siphon", _), do: {:error, :invalid_siphon_waypoint}

  defp gather_waypoint?(_mode, %{type: type})
       when type in ["ASTEROID_FIELD", "ENGINEERED_ASTEROID"],
       do: :ok

  defp gather_waypoint?(_mode, _), do: {:error, :invalid_extraction_waypoint}

  defp gather_capability?("siphon", ship), do: siphon_capability?(ship)
  defp gather_capability?(_mode, ship), do: mining_capability?(ship)

  defp market_waypoint?(%{traits: traits}) do
    if Enum.any?(traits || [], &(&1.symbol == "MARKETPLACE")),
      do: :ok,
      else: {:error, :invalid_market_waypoint}
  end

  defp market_waypoint?(_), do: {:error, :invalid_market_waypoint}
  defp market_available?(%{symbol: symbol}) when is_binary(symbol), do: :ok
  defp market_available?(_), do: {:error, :market_unavailable}

  defp cargo_policy?(%{cargo: %{capacity: capacity}}, threshold) when threshold <= capacity,
    do: :ok

  defp cargo_policy?(_, _), do: {:error, :cargo_threshold_exceeds_capacity}

  defp mining_capability?(%{mounts: mounts}) do
    if Enum.any?(mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_MINING_LASER")),
      do: :ok,
      else: {:error, :mining_capability_missing}
  end

  defp mining_capability?(_), do: {:error, :mining_capability_missing}

  defp block_miner_job(agent, ship_symbol, reason) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} ->
        case unfinished_job(ship.id) do
          %Job{} = config ->
            mark_miner_job_blocked(config, reason)
            {:error, {:miner_job_blocked, reason}}

          nil ->
            {:error, :miner_job_not_configured}
        end

      error ->
        error
    end
  end

  @doc "Reconciles a ready Miner Job and dispatches its next loop leg."
  def advance_miner_job(%AgentRecord{} = agent, %Job{} = config, live_ship) do
    advance_miner_job(agent, config, live_ship, :normal)
  end

  defp advance_miner_job(%AgentRecord{} = agent, %Job{} = config, live_ship, mode) do
    cond do
      in_flight_arrival?(config, live_ship) ->
        maybe_schedule_arrival(agent, live_ship.symbol, %{nav: live_ship.nav}, config.id)

        record_miner_job_activity(
          agent,
          live_ship,
          "miner_job_waiting",
          "Miner Job waiting for arrival",
          %{
            "wait" => "arrival"
          }
        )

        {:ok, Repo.update!(Ecto.Changeset.change(config, status: "waiting"))}

      pending_navigation?(config) ->
        {:ok, config}

      at_extraction_waypoint?(live_ship, config.extraction_waypoint) ->
        extract_if_below_threshold(agent, config, live_ship, mode)

      at_market_waypoint?(live_ship, config.market_waypoint) and market_leg?(config) ->
        sell_at_market(agent, config, live_ship)

      true ->
        navigate_miner_job(agent, config, live_ship, config.extraction_waypoint)
    end
  end

  @doc "Marks Miner Job extraction complete after authoritative cooldown revalidation."
  def revalidate_miner_job_cooldown(agent_id, ship_symbol, live_ship) do
    revalidate_miner_job_cooldown(agent_id, ship_symbol, live_ship, nil)
  end

  def revalidate_miner_job_cooldown(agent_id, ship_symbol, live_ship, expected_job_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %Job{} = config <- unfinished_job(ship.id),
         true <- job_matches_event?(config, expected_job_id),
         true <- config.status in @running_job_states,
         true <- cooldown_ready?(live_ship),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id) do
      case config.in_flight_action do
        %{"kind" => kind} when kind in @gather_kinds ->
          config =
            Repo.update!(
              Ecto.Changeset.change(config,
                status: "active",
                in_flight_action: nil,
                progress: Map.merge(config.progress || %{}, %{"last_completed" => kind})
              )
            )

          advance_miner_job(agent, config, live_ship, :timeline)

        %{"kind" => "cooldown"} ->
          config =
            Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: nil))

          advance_miner_job(agent, config, live_ship, :timeline)

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc "Marks Miner Job navigation complete after authoritative Arrival revalidation."
  def revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship) do
    revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship, nil)
  end

  def revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship, expected_job_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %Job{} = config <- unfinished_job(ship.id),
         true <- job_matches_event?(config, expected_job_id),
         true <- config.status in @running_job_states,
         true <- arrived_at_configured_waypoint?(live_ship, config) do
      agent = Repo.get!(AgentRecord, agent_id)
      waypoint = get_in(config.in_flight_action, ["waypoint"])

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "active",
            in_flight_action: nil,
            progress: %{"waypoint" => waypoint, "last_completed" => "navigate"}
          )
        )

      advance_miner_job(agent, config, live_ship, :timeline)
    else
      _ -> :ok
    end
  end

  defp job_matches_event?(_job, nil), do: true
  defp job_matches_event?(%Job{id: id}, id), do: true
  defp job_matches_event?(_job, _expected_job_id), do: false

  defp at_extraction_waypoint?(
         %{nav: %{status: status, waypoint_symbol: waypoint}},
         extraction_waypoint
       )
       when status in ["DOCKED", "IN_ORBIT"],
       do: waypoint == extraction_waypoint

  defp at_extraction_waypoint?(_, _), do: false

  defp at_market_waypoint?(
         %{nav: %{status: status, waypoint_symbol: waypoint}},
         market_waypoint
       )
       when status in ["DOCKED", "IN_ORBIT"],
       do: waypoint == market_waypoint

  defp at_market_waypoint?(_, _), do: false

  defp arrived_at_configured_waypoint?(live_ship, %Job{
         in_flight_action: %{"waypoint" => waypoint}
       }) do
    at_extraction_waypoint?(live_ship, waypoint) or at_market_waypoint?(live_ship, waypoint)
  end

  defp arrived_at_configured_waypoint?(_, _), do: false

  defp extract_if_below_threshold(agent, config, live_ship, mode) do
    cond do
      live_ship.nav.status == "DOCKED" ->
        case SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol) do
          {:ok, result} -> advance_miner_job(agent, config, %{live_ship | nav: result.nav}, mode)
          {:error, reason} -> mark_miner_job_blocked(config, reason)
        end

      cooldown_active?(live_ship) ->
        maybe_schedule_live_cooldown(agent, live_ship, config.id)

        record_miner_job_activity(
          agent,
          live_ship,
          "miner_job_waiting",
          "Miner Job waiting for cooldown",
          %{"wait" => "cooldown"}
        )

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(config,
             status: "waiting",
             in_flight_action: %{"kind" => "cooldown", "waypoint" => config.extraction_waypoint}
           )
         )}

      true ->
        evaluate_extraction_cargo(agent, config, live_ship, mode)
    end
  end

  # Idle at the extraction Waypoint: when the configured Market's accepted
  # sellable goods are known, unsellable holdings are jettisoned in bounded
  # batches and the Ship only departs once sellable cargo reaches the threshold.
  # Missing market goods degrade to today's total-cargo loop and never block.
  defp evaluate_extraction_cargo(agent, config, live_ship, mode) do
    case configured_sellable_goods(config) do
      :unknown ->
        extract_or_depart_by_total(agent, config, live_ship, mode)

      {:ok, accepted} ->
        evaluate_hold(agent, config, live_ship, accepted, :revalidate, mode)
    end
  end

  defp configured_sellable_goods(%Job{sellable_goods: goods}) when is_list(goods) and goods != [],
    do: {:ok, MapSet.new(goods)}

  defp configured_sellable_goods(_config), do: :unknown

  # One hold evaluator shared by the persisted accepted goods and a freshly
  # revalidated departure set: jettison unsellable holdings first (one bounded
  # batch at a time against the authoritative cargo response), then either keep
  # gathering below the sellable threshold or depart. Jettison carries no
  # cooldown in this API version, so a batch re-enters the loop immediately.
  defp evaluate_hold(agent, config, live_ship, accepted, departure, mode) do
    case first_non_sellable_item(live_ship, accepted) do
      nil ->
        if sellable_units(live_ship, accepted) < config.cargo_threshold do
          gather_miner_job(agent, config, live_ship, mode)
        else
          depart_for(agent, config, live_ship, mode, departure)
        end

      item ->
        case jettison_unsellable_at_extraction(agent, config, live_ship, item) do
          {:ok, live_ship, config} ->
            advance_miner_job(agent, config, live_ship, mode)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # A `:fresh` departure set comes from the just-revalidated Market, so the Ship
  # navigates directly; a `:revalidate` departure must check the Market again
  # first so it never departs on stale accepted goods.
  defp depart_for(agent, config, live_ship, _mode, :fresh),
    do: navigate_miner_job(agent, config, live_ship, config.market_waypoint)

  defp depart_for(agent, config, live_ship, mode, :revalidate),
    do: revalidate_market_before_departure(agent, config, live_ship, mode)

  defp jettison_unsellable_at_extraction(agent, config, live_ship, item) do
    action = %{
      "kind" => "jettison",
      "waypoint" => config.extraction_waypoint,
      "trade_symbol" => item.symbol,
      "expected" => %{"units_at_most" => item_units(live_ship, item.symbol) - item.units}
    }

    config =
      Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: action))

    case jettison_cargo_for_miner_job(agent, live_ship.symbol, item.symbol, item.units) do
      {:ok, %{cargo: cargo}} ->
        config =
          Repo.update!(
            Ecto.Changeset.change(config,
              status: "active",
              in_flight_action: nil,
              last_action_result: %{"kind" => "jettison", "trade_symbol" => item.symbol}
            )
          )

        record_miner_job_activity(
          agent,
          live_ship,
          "miner_job_jettison",
          "Jettisoned #{item.units} #{item.symbol} at #{config.extraction_waypoint} (#{config.market_waypoint} will not buy it)",
          %{"jettison" => "#{item.symbol} #{item.units}"}
        )

        {:ok, %{live_ship | cargo: cargo}, config}

      {:error, reason} ->
        mark_miner_job_blocked(config, {:jettison_unsellable_failed, item.symbol, reason})
    end
  end

  # Revalidates the configured Market's accepted goods before departing. A good
  # the Market no longer accepts is jettisoned at the mining Waypoint first, so
  # the Ship never hauls it to the Market on stale data; an unavailable Market
  # degrades to today's behavior (depart and let the Market leg sort the hold).
  defp revalidate_market_before_departure(agent, config, live_ship, mode) do
    case fetch_configured_market(agent, live_ship, config) do
      {:ok, market} ->
        fresh = accepted_sellable_goods(market)
        config = Repo.update!(Ecto.Changeset.change(config, sellable_goods: fresh))

        if fresh == [] do
          navigate_miner_job(agent, config, live_ship, config.market_waypoint)
        else
          evaluate_hold(agent, config, live_ship, MapSet.new(fresh), :fresh, mode)
        end

      {:error, _reason} ->
        navigate_miner_job(agent, config, live_ship, config.market_waypoint)
    end
  end

  defp fetch_configured_market(%AgentRecord{agent_token: token} = agent, live_ship, config)
       when is_binary(token) and token != "" do
    market_for_ship(agent, live_ship, config.market_waypoint)
  end

  defp fetch_configured_market(_agent, _live_ship, _config), do: {:error, :agent_token_missing}

  # The configured Market's authoritative accepted sellable goods (its imports
  # and exchange lists) as a sorted list of trade symbols. An empty list means
  # market-goods information is unavailable and the loop falls back to the
  # total-cargo behavior.
  defp accepted_sellable_goods(%Market{} = market) do
    ((market.imports || []) ++ (market.exchange || []))
    |> Enum.map(& &1.symbol)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp sellable_units(%{cargo: %{inventory: inventory}}, accepted) do
    Enum.reduce(inventory || [], 0, fn item, acc ->
      if MapSet.member?(accepted, item.symbol), do: acc + item.units, else: acc
    end)
  end

  defp first_non_sellable_item(%{cargo: %{inventory: inventory}}, accepted) do
    Enum.find(inventory || [], &(not MapSet.member?(accepted, &1.symbol)))
  end

  # The total-cargo loop, used only when market-goods information is unavailable
  # so an unreadable Market never blocks or pauses the Miner Job.
  defp extract_or_depart_by_total(agent, config, live_ship, mode) do
    if cargo_units(live_ship) < config.cargo_threshold do
      gather_miner_job(agent, config, live_ship, mode)
    else
      navigate_miner_job(agent, config, live_ship, config.market_waypoint)
    end
  end

  # The gather leg: extract or siphon per the configured gather mode. The
  # authoritative action response is the binding check that the action is
  # allowed, mirroring the manual action's gates.
  defp gather_miner_job(agent, config, live_ship, mode) do
    case config.gather_mode do
      "siphon" -> perform_gather_action(agent, config, live_ship, mode, "siphon")
      _ -> perform_gather_action(agent, config, live_ship, mode, "extract")
    end
  end

  defp perform_gather_action(agent, config, live_ship, mode, kind) do
    action = %{
      "kind" => kind,
      "waypoint" => config.extraction_waypoint,
      "expected" => %{"cargo_units_at_least" => cargo_units(live_ship) + 1}
    }

    config =
      Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: action))

    gather =
      case {kind, mode} do
        {"siphon", :timeline} -> &siphon_resources_for_miner_job/3
        {"siphon", :normal} -> &siphon_resources_for_miner_job/3
        {"extract", :timeline} -> &extract_resources_for_miner_job/3
        {"extract", :normal} -> &extract_resources_for_miner_job/3
      end

    case gather.(agent, live_ship.symbol, config.id) do
      {:ok, result} ->
        result_snapshot = %{
          "kind" => kind,
          "yield" => gather_yield(kind, result)
        }

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(config,
             status: "waiting",
             last_action_result: result_snapshot
           )
         )}

      {:error, reason} ->
        mark_miner_job_blocked(config, reason)
    end
  end

  defp gather_yield("siphon", %{siphon: %{yield: %{symbol: symbol, units: units}}}),
    do: %{"symbol" => symbol, "units" => units}

  defp gather_yield(_kind, result), do: extraction_yield(result)

  defp sell_at_market(%AgentRecord{agent_token: token} = agent, config, live_ship)
       when is_binary(token) and token != "" do
    with {:ok, live_ship} <- dock_for_market(agent, live_ship),
         {:ok, market} <- market_for_ship(agent, live_ship, config.market_waypoint),
         {:ok, live_ship, config} <- settle_market_cargo(agent, config, live_ship, market),
         {:ok, live_ship} <- refuel_for_market_departure(agent, config, live_ship, market) do
      navigate_miner_job(agent, config, live_ship, config.extraction_waypoint)
    else
      {:error, reason} -> mark_miner_job_blocked(config, reason)
    end
  end

  defp sell_at_market(_agent, _config, _live_ship), do: {:error, :agent_token_missing}

  defp dock_for_market(_agent, %{nav: %{status: "DOCKED"}} = live_ship), do: {:ok, live_ship}

  defp dock_for_market(agent, live_ship) do
    with {:ok, result} <- SpaceTraders.API.dock_ship(agent.agent_token, live_ship.symbol) do
      {:ok, %{live_ship | nav: result.nav}}
    end
  end

  # Settles the hold at the configured Market. An active contract the Ship can
  # satisfy at this Waypoint is delivered first: each stood deliverable is
  # delivered up to its remaining requirement before the rest is sold or
  # jettisoned, so delivery is never crowded out by selling. The authoritative
  # contract state is refreshed just before the sales below; when that refresh is
  # unavailable the Job's last-revalidated deliverables still prevent an owed
  # good from being sold.
  defp settle_market_cargo(agent, config, live_ship, market) do
    accepted = MapSet.new((market.imports || []) ++ (market.exchange || []), & &1.symbol)

    with {:ok, pending, config} <- pending_market_deliverables(agent, config, live_ship) do
      case settle_cargo_items(agent, config, live_ship, accepted, pending) do
        {:ok, live_ship, _config} -> {:ok, live_ship, Repo.get!(Job, config.id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp pending_market_deliverables(agent, config, live_ship) do
    waypoint = live_ship.nav.waypoint_symbol

    case Contracts.active_deliverables(agent) do
      {:ok, entries} ->
        config = Repo.update!(Ecto.Changeset.change(config, contract_deliverables: entries))
        {:ok, Contracts.pending_deliverables(entries, waypoint), config}

      {:error, _reason} ->
        {:ok, Contracts.pending_deliverables(config.contract_deliverables || [], waypoint),
         config}
    end
  end

  defp settle_cargo_items(agent, config, live_ship, accepted, pending) do
    Enum.reduce_while(
      live_ship.cargo.inventory || [],
      {:ok, live_ship, config},
      fn item, {:ok, ship, config} ->
        case settle_cargo_item(agent, config, ship, item, accepted, pending) do
          {:ok, ship, config} -> {:cont, {:ok, ship, config}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  # One cargo item: deliver every contract-stood unit the Ship holds at this
  # Waypoint, then sell or jettison whatever remains.
  defp settle_cargo_item(agent, config, live_ship, item, accepted, pending) do
    owed = Enum.filter(pending, &(Map.get(&1, "trade_symbol") == item.symbol))

    with {:ok, live_ship, config} <- deliver_owed_units(agent, config, live_ship, owed),
         {:ok, live_ship} <-
           dispose_market_remainder(agent, config, live_ship, item, accepted) do
      {:ok, live_ship, config}
    end
  end

  defp deliver_owed_units(_agent, config, live_ship, []), do: {:ok, live_ship, config}

  defp deliver_owed_units(agent, config, live_ship, [entry | rest]) do
    held = item_units(live_ship, entry["trade_symbol"])
    remaining = Map.get(entry, "units_remaining", 0)

    if held <= 0 or remaining <= 0 do
      deliver_owed_units(agent, config, live_ship, rest)
    else
      units = min(held, remaining)

      case deliver_for_miner_job(agent, config, live_ship, entry, units) do
        {:ok, %{ship: ship, config: config}} ->
          deliver_owed_units(agent, config, ship, rest)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp deliver_for_miner_job(agent, config, live_ship, entry, units) do
    contract_id = entry["contract_id"]
    trade_symbol = entry["trade_symbol"]
    waypoint = entry["destination_symbol"]

    action = %{
      "kind" => "deliver",
      "waypoint" => waypoint,
      "trade_symbol" => trade_symbol,
      "expected" => %{"units_at_most" => item_units(live_ship, trade_symbol) - units}
    }

    config =
      Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: action))

    case Contracts.deliver_goods(agent, contract_id, live_ship.symbol, trade_symbol, units) do
      {:ok, %{cargo: cargo, contract: contract}} ->
        config = refresh_contract_deliverables(config, contract_id, trade_symbol, contract)

        config =
          Repo.update!(
            Ecto.Changeset.change(config,
              status: "active",
              in_flight_action: nil,
              last_action_result: %{
                "kind" => "deliver",
                "trade_symbol" => trade_symbol,
                "units" => units
              }
            )
          )

        remaining = remaining_after(config, contract_id, trade_symbol)

        record_miner_job_activity(
          agent,
          live_ship,
          "miner_job_deliver",
          "Delivered #{units} #{trade_symbol} to contract #{contract_id} at #{waypoint}; " <>
            "#{remaining} remain",
          %{"deliver" => "#{trade_symbol} #{units}", "remaining" => "#{remaining} remain"}
        )

        {:ok, %{ship: %{live_ship | cargo: cargo}, config: config}}

      {:error, reason} ->
        mark_miner_job_blocked(config, {:deliver_failed, contract_id, trade_symbol, reason})
    end
  end

  defp refresh_contract_deliverables(config, contract_id, trade_symbol, contract) do
    delivered = find_deliverable(contract, trade_symbol)

    entries =
      Enum.map(config.contract_deliverables || [], fn entry ->
        if entry["contract_id"] == contract_id and entry["trade_symbol"] == trade_symbol and
             delivered do
          Contracts.refresh_deliverable(
            entry,
            delivered.units_required,
            delivered.units_fulfilled
          )
        else
          entry
        end
      end)

    Repo.update!(Ecto.Changeset.change(config, contract_deliverables: entries))
  end

  defp find_deliverable(%{terms: %{deliver: deliver}}, trade_symbol) do
    Enum.find(deliver || [], &(&1.trade_symbol == trade_symbol))
  end

  defp find_deliverable(_contract, _trade_symbol), do: nil

  defp remaining_after(config, contract_id, trade_symbol) do
    case Enum.find(
           config.contract_deliverables || [],
           &(&1["contract_id"] == contract_id and &1["trade_symbol"] == trade_symbol)
         ) do
      %{"units_remaining" => remaining} -> remaining
      _ -> 0
    end
  end

  defp dispose_market_remainder(agent, config, live_ship, item, accepted) do
    held = item_units(live_ship, item.symbol)

    if held <= 0 do
      {:ok, live_ship}
    else
      kind = if MapSet.member?(accepted, item.symbol), do: "sell", else: "jettison"
      perform_market_cargo_action(agent, config, live_ship, %{item | units: held}, kind)
    end
  end

  defp perform_market_cargo_action(agent, config, live_ship, item, kind) do
    action = %{
      "kind" => kind,
      "waypoint" => config.market_waypoint,
      "trade_symbol" => item.symbol,
      "expected" => %{"units_at_most" => item_units(live_ship, item.symbol) - item.units}
    }

    config =
      Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: action))

    request =
      if kind == "sell" do
        sell_cargo_for_miner_job(agent, live_ship.symbol, item.symbol, item.units)
      else
        jettison_cargo_for_miner_job(agent, live_ship.symbol, item.symbol, item.units)
      end

    case request do
      {:ok, %{cargo: cargo}} ->
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "active",
            in_flight_action: nil,
            last_action_result: %{"kind" => kind, "trade_symbol" => item.symbol}
          )
        )

        {:ok, %{live_ship | cargo: cargo}}

      {:error, reason} ->
        mark_miner_job_blocked(config, {:market_cargo_action_failed, kind, item.symbol, reason})
    end
  end

  defp sell_cargo_for_miner_job(
         %AgentRecord{agent_token: token} = agent,
         ship_symbol,
         trade_symbol,
         units
       ) do
    invalidate_market_after(
      SpaceTraders.API.sell_cargo(token, ship_symbol, trade_symbol, units),
      agent
    )
  end

  defp jettison_cargo_for_miner_job(
         %AgentRecord{agent_token: token},
         ship_symbol,
         trade_symbol,
         units
       ) do
    SpaceTraders.API.jettison_cargo(token, ship_symbol, trade_symbol, units)
  end

  defp refuel_for_market_departure(agent, config, live_ship, market) do
    if fuel_full?(live_ship) do
      {:ok, live_ship}
    else
      with :ok <- fuel_available?(market),
           {:ok, live_ship} <- refuel_for_miner_job(agent, config, live_ship) do
        {:ok, live_ship}
      else
        {:error, reason} -> mark_miner_job_blocked(config, reason)
      end
    end
  end

  defp fuel_available?(market) do
    if Enum.any?(market.trade_goods || [], &(&1.symbol == "FUEL")) do
      :ok
    else
      {:error, {:market_fuel_unavailable, market.symbol}}
    end
  end

  defp fuel_full?(%{fuel: %{current: current, capacity: capacity}})
       when is_integer(current) and is_integer(capacity),
       do: current >= capacity

  defp fuel_full?(_), do: false

  defp refuel_for_miner_job(agent, config, live_ship) do
    action = %{
      "kind" => "refuel",
      "waypoint" => config.market_waypoint,
      "expected" => %{"fuel_full" => true}
    }

    config =
      Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: action))

    case invalidate_market_after(
           SpaceTraders.API.refuel_ship(agent.agent_token, live_ship.symbol),
           agent
         ) do
      {:ok, %{fuel: fuel}} when fuel.current >= fuel.capacity ->
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "active",
            in_flight_action: nil,
            last_action_result: %{"kind" => "refuel", "fuel" => fuel.current}
          )
        )

        {:ok, %{live_ship | fuel: fuel}}

      {:ok, %{fuel: fuel}} ->
        mark_miner_job_blocked(
          config,
          {:market_fuel_insufficient, config.market_waypoint, fuel.current, fuel.capacity}
        )

      {:error, reason} ->
        mark_miner_job_blocked(config, {:market_refuel_failed, config.market_waypoint, reason})
    end
  end

  defp navigate_miner_job(agent, config, live_ship, waypoint) do
    if live_ship.nav.status == "DOCKED" do
      case SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol) do
        {:ok, result} ->
          navigate_miner_job(agent, config, %{live_ship | nav: result.nav}, waypoint)

        {:error, reason} ->
          mark_miner_job_blocked(config, reason)
      end
    else
      do_navigate_miner_job(agent, config, live_ship, waypoint)
    end
  end

  defp do_navigate_miner_job(agent, config, live_ship, waypoint) do
    action = %{
      "kind" => "navigate",
      "waypoint" => waypoint,
      "expected" => %{"status" => "IN_TRANSIT", "destination" => waypoint}
    }

    config =
      Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: action))

    case SpaceTraders.API.navigate_ship(agent.agent_token, live_ship.symbol, waypoint) do
      {:ok, result} ->
        maybe_schedule_arrival(agent, live_ship.symbol, result, config.id)

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(config,
             status: "waiting",
             last_action_result: %{
               "kind" => "navigate",
               "waypoint" => waypoint,
               "status" => result.nav.status,
               "destination" => result.nav.route.destination.symbol
             },
             progress: Map.put(config.progress || %{}, "waypoint", waypoint)
           )
         )}

      {:error, reason} ->
        mark_miner_job_blocked(config, reason)
    end
  end

  defp market_leg?(%Job{
         in_flight_action: %{"waypoint" => waypoint},
         market_waypoint: waypoint
       }),
       do: true

  defp market_leg?(%Job{
         progress: %{"waypoint" => waypoint},
         market_waypoint: waypoint
       }),
       do: true

  defp market_leg?(_), do: false

  defp pending_navigation?(%Job{
         status: "waiting",
         in_flight_action: %{"kind" => "navigate"}
       }),
       do: true

  defp pending_navigation?(_), do: false

  defp mark_miner_job_blocked(config, reason) do
    already_blocked? = Repo.get!(Job, config.id).status == "blocked"

    Repo.update!(
      Ecto.Changeset.change(config,
        status: "blocked",
        blocked_reason: nil,
        blocker: job_blocker(reason)
      )
    )

    unless already_blocked? do
      record_activity_by_config(
        config,
        "miner_job_blocked",
        "Miner Job blocked: #{inspect(reason)}",
        %{
          "block" => inspect(reason),
          "recovery" => "resume"
        }
      )
    end

    {:error, reason}
  end

  defp record_activity_by_config(config, kind, message, metadata) do
    ship = Repo.get!(Ship, config.ship_id)
    record_activity(Repo.get!(AgentRecord, ship.agent_id), ship, kind, message, metadata)
  end

  defp extract_resources_for_miner_job(
         %AgentRecord{agent_token: token} = agent,
         ship_symbol,
         job_id
       )
       when is_binary(token) and token != "" do
    with {:ok, result} <- SpaceTraders.API.extract_resources(token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result, job_id) do
      {:ok, result}
    end
  end

  defp siphon_resources_for_miner_job(
         %AgentRecord{agent_token: token} = agent,
         ship_symbol,
         job_id
       )
       when is_binary(token) and token != "" do
    with {:ok, result} <- SpaceTraders.API.siphon_resources(token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result, job_id) do
      {:ok, result}
    end
  end

  defp maybe_schedule_live_cooldown(agent, %{symbol: ship_symbol, cooldown: cooldown}, job_id) do
    due_at = parse_expiration(cooldown.expiration, cooldown.remaining_seconds)
    schedule_cooldown_event(agent, ship_symbol, due_at, %{"job_id" => job_id})
  end

  defp cooldown_active?(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds),
       do: seconds > 0

  defp cooldown_active?(_), do: false

  defp cargo_units(%{cargo: %{units: units}}) when is_integer(units), do: units
  defp cargo_units(_), do: 0

  defp item_units(%{cargo: %{inventory: inventory}}, symbol) do
    case Enum.find(inventory || [], &(&1.symbol == symbol)) do
      %{units: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp extraction_yield(%{extraction: %{yield: %{symbol: symbol, units: units}}}) do
    %{"symbol" => symbol, "units" => units}
  end

  defp extraction_yield(_), do: nil

  defp cooldown_ready?(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds),
       do: seconds <= 0

  defp cooldown_ready?(_), do: true

  defp in_flight_arrival?(
         %Job{in_flight_action: %{"expected" => %{"destination" => destination}}},
         %{nav: %{status: "IN_TRANSIT", route: %{destination: %{symbol: destination}}}}
       ),
       do: true

  defp in_flight_arrival?(_, _), do: false

  @doc """
  Lists the waypoints of the Agent's headquarters system.

  The game paginates waypoint responses, so pages are fetched until the system
  is fully collected. Returns
  `{:ok, [%SpaceTraders.API.Model.Waypoint{}]}` or an API error.
  """
  def list_waypoints(%AgentRecord{agent_token: agent_token, headquarters: headquarters} = agent)
      when is_binary(agent_token) and agent_token != "" and is_binary(headquarters) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      case fetch_waypoint_pages(agent_token, system) do
        {:ok, waypoints} = result ->
          Enum.each(waypoints, &record_waypoint_observation(agent, &1, "get_waypoints"))
          result

        result ->
          result
      end
    end
  end

  def list_waypoints(%AgentRecord{}), do: {:error, :agent_token_missing}

  defp fetch_waypoint_pages(agent_token, system) do
    case SpaceTraders.API.get_waypoints_paginated(agent_token, system) do
      {:ok, waypoints} -> {:ok, waypoints}
      {:error, reason, _collected} -> {:error, reason}
    end
  end

  defp record_waypoint_observation(%AgentRecord{id: id} = agent, waypoint, source)
       when is_integer(id) do
    Intelligence.observe_waypoint(agent, waypoint, source: source)
  rescue
    exception ->
      Logger.warning("Could not persist waypoint intelligence: #{Exception.message(exception)}")
  end

  defp record_waypoint_observation(_agent, _waypoint, _source), do: :ok

  defp record_market_observation(%AgentRecord{id: id} = agent, system, market, source)
       when is_integer(id) do
    record_market_observation(agent, system, market, source, nil)
  end

  defp record_market_observation(_agent, _system, _market, _source), do: :ok

  defp record_market_observation(%AgentRecord{id: id} = agent, system, market, source, observer)
       when is_integer(id) do
    Intelligence.observe_market(agent, system, market,
      source: source,
      observing_ship_symbol: observer
    )
  rescue
    exception ->
      Logger.warning("Could not persist market intelligence: #{Exception.message(exception)}")
  end

  defp record_market_observation(_agent, _system, _market, _source, _observer), do: :ok

  defp system_from_headquarters(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end

  @doc """
  Purchases a Ship offered by an on-site Shipyard in a Fleet command snapshot.

  The snapshot determines local purchase eligibility; the game remains the
  authoritative backstop if its listing changed after the snapshot was read.
  A successful purchase is returned even if its local restart-recovery record
  cannot be stored, with the persistence error in `:warning`.
  """
  def purchase_ship(%{agent: %AgentRecord{} = agent, shipyards: shipyards}, ship_type, waypoint) do
    with :ok <- offered_at?(shipyards, ship_type, waypoint),
         {:ok, result} <- Shipyard.purchase(agent, ship_type, waypoint) do
      {:ok, Map.put(result, :warning, record_purchase(agent, result.ship, ship_type))}
    end
  end

  @doc "Records a newly purchased ship so it can be re-armed after a restart."
  def record_ship(%AgentRecord{} = agent, ship_symbol, ship_type) do
    %Ship{}
    |> Ecto.Changeset.change(symbol: ship_symbol, ship_type: ship_type, agent_id: agent.id)
    |> Ecto.Changeset.validate_required([:symbol, :ship_type, :agent_id])
    |> Repo.insert(on_conflict: :nothing, conflict_target: :symbol)
  end

  @doc "Returns a Ship's five most recent successful navigation destinations."
  def destination_history(%AgentRecord{} = agent, ship_symbol) do
    ShipDestination
    |> join(:inner, [destination], ship in Ship, on: ship.id == destination.ship_id)
    |> where([destination, ship], ship.agent_id == ^agent.id and ship.symbol == ^ship_symbol)
    |> order_by([destination], asc: destination.position)
    |> limit(5)
    |> select([destination], destination.waypoint_symbol)
    |> Repo.all()
  end

  @doc """
  Navigates a ship to a waypoint.

  The ship is refused while a local arrival or cooldown is pending (the game
  API remains the backstop for anything the app hasn't seen). On success the
  returned nav shows `IN_TRANSIT` and the arrival is persisted to the timeline
  and armed on the ship's GenServer, so the card can show the arrival time and
  further actions stay blocked until the ship re-pulls its real state on
  arrival.

  Returns `{:ok, %{fuel: ..., nav: ...}}`, or one of:

    * `{:error, :ship_in_transit}` — the ship already has a pending arrival
    * `{:error, :cooldown_active}` — the ship has a pending cooldown
    * `{:error, :agent_token_missing}` — the agent has no stored AgentToken
    * `{:error, %SpaceTraders.API.Error{} | %SpaceTraders.API.GameplayError{}}` — API failure
  """
  def navigate_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol, waypoint_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "navigation"}),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <-
           SpaceTraders.API.navigate_ship(agent_token, ship_symbol, waypoint_symbol) do
      maybe_schedule_arrival(agent, ship_symbol, result)
      persist_destination_history(agent, ship_symbol, result.nav.route.destination.symbol)
      record_command_activity(agent, ship_symbol, "navigate", "Navigate command accepted")
      {:ok, result}
    end
  end

  def navigate_ship(%AgentRecord{}, _ship_symbol, _waypoint_symbol) do
    {:error, :agent_token_missing}
  end

  @doc "Sets a ship's flight mode before navigation."
  def set_ship_flight_mode(
        %AgentRecord{agent_token: agent_token} = agent,
        ship_symbol,
        flight_mode
      )
      when is_binary(agent_token) and agent_token != "" and
             flight_mode in ["DRIFT", "STEALTH", "CRUISE", "BURN"] do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "flight mode"}),
         :ok <- flight_mode_change_allowed?(ship_symbol) do
      SpaceTraders.API.set_ship_flight_mode(agent_token, ship_symbol, flight_mode)
      |> then(&record_command_result(agent, ship_symbol, "flight_mode", &1))
    end
  end

  def set_ship_flight_mode(%AgentRecord{agent_token: token}, _ship_symbol, _flight_mode)
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def set_ship_flight_mode(%AgentRecord{}, _ship_symbol, _flight_mode),
    do: {:error, :invalid_flight_mode}

  defp flight_mode_change_allowed?(ship_symbol) do
    case ShipServer.ensure_ready(ship_symbol) do
      :ok -> :ok
      {:error, :cooldown_active} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_destination(agent, ship_symbol, waypoint_symbol) do
    with {:ok, ship} <- ensure_ship_record_for_history(agent, ship_symbol) do
      Repo.transaction(fn ->
        existing =
          Repo.get_by(ShipDestination, ship_id: ship.id, waypoint_symbol: waypoint_symbol)

        if existing do
          Repo.delete!(existing)

          Repo.update_all(
            from(destination in ShipDestination,
              where: destination.ship_id == ^ship.id and destination.position > ^existing.position
            ),
            inc: [position: -1]
          )
        end

        Repo.update_all(
          from(destination in ShipDestination, where: destination.ship_id == ^ship.id),
          inc: [position: 1]
        )

        Repo.insert!(%ShipDestination{
          ship_id: ship.id,
          waypoint_symbol: waypoint_symbol,
          position: 0
        })

        Repo.delete_all(
          from destination in ShipDestination,
            where: destination.ship_id == ^ship.id and destination.position > 4
        )
      end)
    end
  end

  defp ensure_ship_record_for_history(agent, ship_symbol) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
      %Ship{} = ship -> {:ok, ship}
      nil -> record_ship(agent, ship_symbol, "UNKNOWN")
    end
  end

  defp persist_destination_history(agent, ship_symbol, waypoint_symbol) do
    try do
      case record_destination(agent, ship_symbol, waypoint_symbol) do
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

  @doc "Docks a ship at its current waypoint."
  def dock_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "docking"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.dock_ship(agent_token, ship_symbol)
      |> then(&record_command_result(agent, ship_symbol, "dock", &1))
    end
  end

  def dock_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Puts a ship into orbit at its current waypoint."
  def orbit_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "orbit"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.orbit_ship(agent_token, ship_symbol)
      |> then(&record_command_result(agent, ship_symbol, "orbit", &1))
    end
  end

  def orbit_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Extracts resources and persists the returned cooldown on the timeline."
  def extract_resources(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "extraction"}),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <- SpaceTraders.API.extract_resources(agent_token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result) do
      record_command_activity(agent, ship_symbol, "extract", "Extract command completed")
      {:ok, result}
    end
  end

  def extract_resources(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Siphons gas and persists the returned cooldown on the timeline."
  def siphon_resources(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "siphoning"}),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, live_ship} <- SpaceTraders.API.get_ship(agent_token, ship_symbol),
         {:ok, waypoint} <-
           SpaceTraders.API.get_waypoint(
             agent_token,
             live_ship.nav.system_symbol,
             live_ship.nav.waypoint_symbol
           ),
         :ok <- siphon_location?(waypoint),
         :ok <- siphon_capability?(live_ship),
         {:ok, result} <- SpaceTraders.API.siphon_resources(agent_token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result) do
      record_command_activity(agent, ship_symbol, "siphon", "Siphon command completed")
      {:ok, result}
    end
  end

  def siphon_resources(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  defp siphon_capability?(%{modules: modules, mounts: mounts}) do
    if Enum.any?(mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_GAS_SIPHON_")) and
         Enum.any?(modules || [], &(&1.symbol == "MODULE_GAS_PROCESSOR_I")),
       do: :ok,
       else: {:error, :siphon_capability_missing}
  end

  defp siphon_capability?(_), do: {:error, :siphon_capability_missing}

  defp siphon_location?(%{type: "GAS_GIANT"}), do: :ok
  defp siphon_location?(_), do: {:error, :invalid_siphon_waypoint}

  @doc "Sells cargo from a ship and returns the updated cargo and transaction."
  def sell_cargo(%AgentRecord{agent_token: agent_token} = agent, ship_symbol, trade_symbol, units)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "selling cargo"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      invalidate_market_after(
        SpaceTraders.API.sell_cargo(agent_token, ship_symbol, trade_symbol, units),
        agent
      )
      |> then(&record_command_result(agent, ship_symbol, "sell", &1))
    end
  end

  def sell_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :agent_token_missing}

  @doc "Purchases cargo from a market the ship is docked at."
  def purchase_cargo(
        %AgentRecord{agent_token: agent_token} = agent,
        ship_symbol,
        trade_symbol,
        units
      )
      when is_binary(agent_token) and agent_token != "" and is_integer(units) and units > 0 do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "purchasing cargo"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      invalidate_market_after(
        SpaceTraders.API.purchase_cargo(agent_token, ship_symbol, trade_symbol, units),
        agent
      )
      |> then(&record_command_result(agent, ship_symbol, "purchase", &1))
    end
  end

  def purchase_cargo(%AgentRecord{agent_token: token}, _ship_symbol, _trade_symbol, _units)
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def purchase_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :invalid_units}

  @doc "Refuels a ship at a marketplace that sells fuel."
  def refuel_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "refueling"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      invalidate_market_after(SpaceTraders.API.refuel_ship(agent_token, ship_symbol), agent)
      |> then(&record_command_result(agent, ship_symbol, "refuel", &1))
    end
  end

  def refuel_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  defp invalidate_market_after(
         {:ok, %{transaction: %{waypoint_symbol: waypoint_symbol}}} = result,
         agent
       )
       when is_binary(waypoint_symbol) do
    with {:ok, system_symbol} <- system_from_headquarters(waypoint_symbol) do
      invalidate_market_facts(agent, system_symbol, waypoint_symbol)
    end

    result
  end

  defp invalidate_market_after(result, _agent), do: result

  # Intelligence must never make a confirmed game mutation look failed. A later
  # read will still refresh this Listing if local persistence is unavailable.
  defp invalidate_market_facts(agent, system_symbol, waypoint_symbol) do
    Intelligence.invalidate(agent, :market, system_symbol, waypoint_symbol, [
      :trade_goods,
      :transactions
    ])
  rescue
    exception ->
      Logger.warning("Could not invalidate market intelligence: #{Exception.message(exception)}")
  end

  defp market_for_ship(%AgentRecord{agent_token: token} = agent, live_ship, waypoint_symbol) do
    system_symbol = live_ship.nav.system_symbol

    case SpaceTraders.API.get_market(token, system_symbol, waypoint_symbol) do
      {:ok, market} = result ->
        observer = if live_ship.nav.waypoint_symbol == waypoint_symbol, do: live_ship.symbol
        record_market_observation(agent, system_symbol, market, "get_market", observer)
        result

      {:error, %SpaceTraders.API.GameplayError{}} = result ->
        invalidate_market_facts(agent, system_symbol, waypoint_symbol)
        result

      result ->
        result
    end
  end

  @doc "Jettisons cargo from a ship's hold and returns the updated cargo."
  def jettison_cargo(
        %AgentRecord{agent_token: agent_token} = agent,
        ship_symbol,
        trade_symbol,
        units
      )
      when is_binary(agent_token) and agent_token != "" and is_integer(units) and units > 0 do
    with :ok <-
           preempt_miner_job_for(agent, ship_symbol, {:manual_override, "jettisoning cargo"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.jettison_cargo(agent_token, ship_symbol, trade_symbol, units)
      |> then(&record_command_result(agent, ship_symbol, "jettison", &1))
    end
  end

  def jettison_cargo(%AgentRecord{agent_token: token}, _ship_symbol, _trade_symbol, _units)
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def jettison_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :invalid_units}

  @doc "Transfers cargo to another ship after validating both live ship states."
  def transfer_cargo(
        %AgentRecord{agent_token: token} = agent,
        from_ship,
        to_ship,
        trade_symbol,
        units
      )
      when is_binary(token) and token != "" and is_integer(units) and units > 0 do
    with :ok <- different_transfer_ships?(from_ship, to_ship),
         {:ok, source} <- SpaceTraders.API.get_ship(token, from_ship),
         {:ok, target} <- SpaceTraders.API.get_ship(token, to_ship),
         :ok <- transfer_preflight(source, target, trade_symbol, units),
         :ok <- preempt_miner_job_for(agent, from_ship, {:manual_override, "cargo transfer"}),
         :ok <- ShipServer.ensure_ready(from_ship) do
      SpaceTraders.API.transfer_cargo(token, from_ship, trade_symbol, units, to_ship)
      |> then(&record_command_result(agent, from_ship, "transfer", &1))
    end
  end

  def transfer_cargo(
        %AgentRecord{agent_token: token},
        _from_ship,
        _to_ship,
        _trade_symbol,
        _units
      )
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def transfer_cargo(%AgentRecord{}, _from_ship, _to_ship, _trade_symbol, _units),
    do: {:error, :invalid_units}

  defp transfer_preflight(source, target, trade_symbol, units) do
    cond do
      source.nav.waypoint_symbol != target.nav.waypoint_symbol ->
        {:error, :transfer_waypoint_mismatch}

      source.nav.status not in ["DOCKED", "IN_ORBIT"] or
          source.nav.status != target.nav.status ->
        {:error, :transfer_state_mismatch}

      item_units(source, trade_symbol) < units ->
        {:error, :transfer_cargo_missing}

      cargo_units(target) + units > target.cargo.capacity ->
        {:error, :transfer_target_cargo_full}

      true ->
        :ok
    end
  end

  defp different_transfer_ships?(ship, ship), do: {:error, :transfer_same_ship}
  defp different_transfer_ships?(_from_ship, _to_ship), do: :ok

  @doc """
  Re-arms ship servers for every ship with a pending timeline event.

  Called once on boot by `SpaceTraders.Fleet.ShipServerBoot`: each started
  server re-arms its own timers and immediately catches up events that came due
  while the app was down (ADR 0005). Ships without stored credentials are
  skipped with a warning. Returns `:ok`.
  """
  def rearm_ships_on_boot do
    timeline_symbols = Timeline.pending_owners(:ship) |> Enum.map(& &1.owner_id)

    job_symbols =
      Job
      |> join(:inner, [c], s in Ship, on: c.ship_id == s.id)
      |> where([c, _s], c.status in ^@running_job_states)
      |> select([_c, s], s.symbol)
      |> Repo.all()

    intent_symbols =
      ManualIntent
      |> join(:inner, [i], s in Ship, on: i.ship_id == s.id)
      |> where([i, _s], i.status in ^@unfinished_intent_states)
      |> select([_i, s], s.symbol)
      |> Repo.all()

    (timeline_symbols ++ job_symbols ++ intent_symbols)
    |> Enum.uniq()
    |> Enum.each(fn ship_symbol ->
      case ship_credentials(ship_symbol) do
        {:ok, agent_id, agent_token} ->
          ShipServer.ensure_started(ship_symbol, agent_id, agent_token)

          unless ship_symbol in timeline_symbols do
            recover_job_on_boot(ship_symbol, agent_id, agent_token)
            recover_manual_intent_on_boot(ship_symbol, agent_id, agent_token)
          end

        :error ->
          Logger.warning(
            "ship #{ship_symbol}: no stored credentials, not re-arming timeline events"
          )
      end
    end)

    :ok
  end

  @doc "Reconciles a persisted Miner Job's in-flight action after a process restart."
  def recover_job_on_boot(ship_symbol, agent_id, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %Job{} = config <- unfinished_job(ship.id) do
      if config.status in @running_job_states do
        # Recovery owns its own persisted attempt budget. Avoid nested client
        # retries so one authoritative read counts as one recovery attempt.
        case SpaceTraders.API.get_ship(agent_token, ship_symbol, retry: false) do
          {:ok, live_ship} when config.status == "active" and is_nil(config.in_flight_action) ->
            advance_miner_job(Repo.get!(AgentRecord, agent_id), config, live_ship)

          {:ok, live_ship}
          when config.status in ["active", "waiting"] and is_map(config.in_flight_action) ->
            reconcile_in_flight(agent_id, ship, config, live_ship)

          {:ok, _live_ship} ->
            :ok

          {:error, reason} ->
            recovery_retry_or_block(agent_id, ship_symbol, reason, agent_token)
        end
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  @doc "Reconciles a blocked in-flight Miner Job before explicitly retrying it."
  def reconcile_miner_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{status: "blocked", blocker: %JobBlocker{}, in_flight_action: action} = config
         when is_map(action) <-
           unfinished_job(ship.id),
         {:ok, live_ship} <-
           SpaceTraders.API.get_ship(agent.agent_token, ship_symbol, retry: false) do
      reconcile_in_flight(agent.id, ship, config, live_ship)
    else
      %Job{} -> {:error, :miner_job_not_blocked}
      nil -> {:error, :miner_job_not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_in_flight(agent_id, ship, config, live_ship) do
    case action_outcome(config.in_flight_action, live_ship) do
      :confirmed ->
        recovered_config = confirm_recovery(config, live_ship)

        record_activity_by_id(
          agent_id,
          ship,
          "miner_job_recovery",
          "Miner Job action confirmed after restart",
          "confirmed"
        )

        if live_ship.nav.status == "IN_TRANSIT" do
          maybe_schedule_arrival(
            Repo.get!(AgentRecord, agent_id),
            live_ship.symbol,
            %{nav: live_ship.nav},
            recovered_config.id
          )

          {:ok, recovered_config}
        else
          advance_miner_job(
            Repo.get!(AgentRecord, agent_id),
            recovered_config,
            live_ship,
            :timeline
          )
        end

      :absent ->
        if recovery_available?(config) do
          retry_recovery(agent_id, ship, config, live_ship)
        else
          block_recovery(agent_id, ship, config, "retry_exhausted")
        end

      :ambiguous ->
        block_recovery(agent_id, ship, config, "ambiguous")
    end
  end

  defp action_outcome(%{"kind" => "navigate", "waypoint" => waypoint}, live_ship) do
    cond do
      live_ship.nav.status == "IN_TRANSIT" and live_ship.nav.route.destination.symbol == waypoint ->
        :confirmed

      at_extraction_waypoint?(live_ship, waypoint) or at_market_waypoint?(live_ship, waypoint) ->
        :confirmed

      true ->
        :absent
    end
  end

  defp action_outcome(
         %{"kind" => kind, "expected" => %{"cargo_units_at_least" => units}},
         live_ship
       )
       when kind in @gather_kinds do
    if cargo_units(live_ship) >= units, do: :confirmed, else: :absent
  end

  defp action_outcome(
         %{"kind" => kind, "trade_symbol" => symbol, "expected" => %{"units_at_most" => units}},
         live_ship
       )
       when kind in ["sell", "jettison", "deliver"] do
    if item_units(live_ship, symbol) <= units, do: :confirmed, else: :absent
  end

  defp action_outcome(%{"kind" => "refuel", "expected" => %{"fuel_full" => true}}, live_ship) do
    if fuel_full?(live_ship), do: :confirmed, else: :absent
  end

  defp action_outcome(_action, _live_ship), do: :ambiguous

  defp confirm_recovery(config, live_ship) do
    action = config.in_flight_action

    progress =
      if action["kind"] == "navigate" do
        Map.put(config.progress || %{}, "waypoint", action["waypoint"])
      else
        config.progress || %{}
      end

    Repo.update!(
      Ecto.Changeset.change(config,
        status: if(live_ship.nav.status == "IN_TRANSIT", do: "waiting", else: "active"),
        blocked_reason: nil,
        blocker: nil,
        recovery_attempts: 0,
        recovery_started_at: nil,
        last_action_result: %{"kind" => "recovery", "outcome" => "confirmed"},
        progress: progress,
        in_flight_action:
          if(live_ship.nav.status == "IN_TRANSIT", do: config.in_flight_action, else: nil)
      )
    )
  end

  defp retry_recovery(agent_id, ship, config, live_ship) do
    attempts = config.recovery_attempts + 1

    config =
      Repo.update!(
        Ecto.Changeset.change(config,
          status: "active",
          blocked_reason: nil,
          blocker: nil,
          recovery_attempts: attempts,
          recovery_started_at:
            config.recovery_started_at || DateTime.utc_now() |> DateTime.truncate(:second)
        )
      )

    record_activity_by_id(
      agent_id,
      ship,
      "miner_job_recovery",
      "Miner Job action absent; retrying",
      "absent"
    )

    case advance_miner_job(Repo.get!(AgentRecord, agent_id), config, live_ship, :timeline) do
      {:ok, recovered_config} ->
        {:ok,
         Repo.update!(
           Ecto.Changeset.change(recovered_config, recovery_attempts: 0, recovery_started_at: nil)
         )}

      error ->
        error
    end
  end

  defp recovery_retry_or_block(agent_id, ship_symbol, reason, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %Job{status: status} = config when status in @running_job_states <-
           unfinished_job(ship.id) do
      if recovery_available?(config) do
        Repo.update!(
          Ecto.Changeset.change(config,
            recovery_attempts: config.recovery_attempts + 1,
            recovery_started_at:
              config.recovery_started_at || DateTime.utc_now() |> DateTime.truncate(:second)
          )
        )

        record_activity_by_id(
          agent_id,
          ship,
          "miner_job_recovery",
          "Authoritative recovery read failed; retrying",
          "transport_error"
        )

        recover_job_on_boot(ship_symbol, agent_id, agent_token)
      else
        block_recovery(agent_id, ship, config, "retry_exhausted: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp recovery_available?(config) do
    config.recovery_attempts < @max_recovery_attempts and
      recovery_within_window?(config.recovery_started_at)
  end

  defp recovery_within_window?(nil), do: true

  defp recovery_within_window?(%DateTime{} = started_at) do
    DateTime.diff(DateTime.utc_now(), started_at, :second) < @recovery_window_seconds
  end

  defp block_recovery(agent_id, ship, config, outcome) do
    Repo.update!(
      Ecto.Changeset.change(config,
        status: "blocked",
        blocker: job_blocker(outcome),
        last_action_result: %{"kind" => "recovery", "outcome" => outcome}
      )
    )

    record_activity_by_id(
      agent_id,
      ship,
      "miner_job_recovery",
      "Miner Job recovery blocked: #{outcome}",
      outcome
    )

    {:error, :miner_job_recovery_blocked}
  end

  defp record_activity_by_id(agent_id, ship, kind, message, outcome) do
    record_activity(Repo.get!(AgentRecord, agent_id), ship, kind, message, %{"outcome" => outcome})
  end

  defp job_blocker(reason) do
    {resolver, retry_condition, corrective_actions} = blocker_resolution(reason)

    %JobBlocker{
      reason: blocker_reason(reason),
      summary: blocker_summary(reason),
      evidence: inspect(reason),
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      resolver: resolver,
      retry_condition: retry_condition,
      corrective_actions: corrective_actions
    }
  end

  defp blocker_summary("ambiguous"),
    do: "The game did not confirm whether the in-flight action completed."

  defp blocker_summary("retry_exhausted" <> _),
    do: "Authoritative recovery could not complete within its retry budget."

  defp blocker_summary(reason), do: "Miner Job cannot progress: #{blocker_reason(reason)}."

  defp blocker_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp blocker_reason(reason) when is_tuple(reason), do: reason |> elem(0) |> blocker_reason()
  defp blocker_reason(%{__struct__: module}), do: module |> Module.split() |> List.last()

  defp blocker_reason("retry_exhausted:" <> _evidence), do: "retry_exhausted"
  defp blocker_reason(reason) when is_binary(reason), do: reason
  defp blocker_reason(_reason), do: "miner_job_action_blocked"

  defp blocker_resolution(reason) do
    case {blocker_reason(reason), reason} do
      {code, _reason}
      when code in [
             "invalid_extraction_waypoint",
             "invalid_siphon_waypoint",
             "invalid_market_waypoint",
             "cargo_threshold_exceeds_capacity"
           ] ->
        {"operator", "configuration_changed", ["replace_job", "resume"]}

      {code, _reason} when code in ["siphon_capability_missing", "mining_capability_missing"] ->
        {"operator", "ship_capability_changed", ["outfit_ship", "resume"]}

      {"agent_token_missing", _reason} ->
        {"operator", "agent_credentials_restored", ["restore_credentials", "resume"]}

      {"insufficient_fuel", _reason} ->
        {"operator", "ship_refueled", ["refuel"]}

      {"outside_system", _reason} ->
        {"operator", "cross_system_navigate_available", []}

      {"unreadable_arrival", _reason} ->
        {"game_state", "authoritative_state_changed", ["resume"]}

      {"ambiguous", _reason} ->
        {"game_state", "authoritative_action_outcome_available",
         ["inspect_activity", "reconcile_and_retry"]}

      {"retry_exhausted", _reason} ->
        {"game_state", "authoritative_read_succeeds", ["reconcile"]}

      {_code, reason} when is_struct(reason) ->
        {"game_state", "authoritative_read_succeeds", ["resume"]}

      {_code, _reason} ->
        {"game_state", "authoritative_state_changed", ["resume"]}
    end
  end

  defp maybe_schedule_arrival(agent, ship_symbol, result),
    do: maybe_schedule_arrival(agent, ship_symbol, result, nil)

  defp maybe_schedule_arrival(
         agent,
         ship_symbol,
         %{nav: %ShipNav{status: "IN_TRANSIT"} = nav},
         job_id
       ) do
    with {:ok, due_at} <- parse_arrival(nav.route) do
      payload = arrival_payload(nav) |> maybe_put_job_id(job_id)

      {:ok, event} =
        Timeline.schedule_event(:ship, ship_symbol, :arrival, due_at, payload)

      ShipServer.arm(agent, ship_symbol, event)
    end
  end

  defp maybe_schedule_arrival(_agent, _ship_symbol, _result, _job_id), do: :ok

  defp schedule_cooldown(agent, ship_symbol, %{
         cooldown: %{remaining_seconds: seconds, expiration: expiration}
       })
       when is_integer(seconds) and seconds > 0 do
    due_at = parse_expiration(expiration, seconds)
    schedule_cooldown_event(agent, ship_symbol, due_at)
  end

  defp schedule_cooldown(_agent, _ship_symbol, _result), do: :ok

  defp schedule_cooldown(agent, ship_symbol, result, job_id) do
    case result do
      %{cooldown: %{remaining_seconds: seconds, expiration: expiration}}
      when is_integer(seconds) and seconds > 0 ->
        due_at = parse_expiration(expiration, seconds)
        schedule_cooldown_event(agent, ship_symbol, due_at, %{"job_id" => job_id})

      _ ->
        :ok
    end
  end

  defp parse_expiration(expiration, seconds) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, due_at, _offset} -> due_at
      _ -> DateTime.add(DateTime.utc_now(), seconds, :second)
    end
  end

  defp parse_expiration(_expiration, seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp schedule_cooldown_event(agent, ship_symbol, due_at, payload \\ %{}) do
    {:ok, event} = Timeline.schedule_event(:ship, ship_symbol, :cooldown, due_at, payload)
    ShipServer.arm(agent, ship_symbol, event)
  end

  defp maybe_put_job_id(payload, nil), do: payload
  defp maybe_put_job_id(payload, job_id), do: Map.put(payload, "job_id", job_id)

  defp parse_arrival(%ShipNavRoute{arrival: arrival}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} ->
        {:ok, due_at}

      _ ->
        Logger.warning("ship arrival #{arrival} is not a parseable timestamp")
        :error
    end
  end

  defp parse_arrival(_route), do: :error

  defp arrival_payload(%ShipNav{route: %{destination: %{symbol: destination}}})
       when is_binary(destination),
       do: %{destination: destination}

  defp arrival_payload(_nav), do: %{}

  defp snapshot_listings(agent, {:ok, ships}, waypoints),
    do: Listing.for_ships(agent, ships, waypoints)

  defp snapshot_listings(_agent, _ships, _waypoints),
    do: %{shipyards: {:ok, []}, markets: {:ok, []}}

  defp annotate_listing_actions(%{markets: markets, shipyards: shipyards}, overview) do
    %{
      markets: annotate_market_actions(markets),
      shipyards: annotate_purchase_actions(shipyards, overview)
    }
  end

  defp annotate_market_actions({status, listings}) when status in [:ok, :partial] do
    {status,
     Enum.map(listings, fn %{market: market, ships: ships} = listing ->
       ships = Enum.map(ships, &Map.put(&1, :trade_actions, trade_actions(&1, market)))
       %{listing | ships: ships}
     end)}
  end

  defp annotate_market_actions(result), do: result

  defp trade_actions(ship, %{trade_goods: goods}) do
    Map.new(goods || [], fn good ->
      {good.symbol,
       %{
         sell: action_state(item_units(ship, good.symbol) > 0, :cargo_missing),
         buy: purchase_cargo_state(ship, good)
       }}
    end)
  end

  defp trade_actions(_ship, _market), do: %{}

  defp purchase_cargo_state(ship, good) do
    available_space = cargo_capacity(ship) - cargo_units(ship)
    available? = (good.purchase_price || 0) > 0 and available_space > 0
    reason = if (good.purchase_price || 0) > 0, do: :cargo_full, else: :trade_unavailable
    action_state(available?, reason)
  end

  defp cargo_capacity(%{cargo: %{capacity: capacity}}) when is_integer(capacity), do: capacity
  defp cargo_capacity(_), do: 0

  defp annotate_purchase_actions({status, listings}, overview) when status in [:ok, :partial] do
    {status,
     Enum.map(listings, fn %{shipyard: %{ships: ships}} = listing ->
       actions =
         Map.new(ships || [], fn ship ->
           {ship.type, purchase_ship_state(overview, ship.purchase_price)}
         end)

       Map.put(listing, :purchase_actions, actions)
     end)}
  end

  defp annotate_purchase_actions(result, _overview), do: result

  defp purchase_ship_state({:ok, %{credits: credits}}, price)
       when is_integer(credits) and is_integer(price),
       do: action_state(credits >= price, :insufficient_credits)

  defp purchase_ship_state(_overview, _price), do: action_state(true, nil)

  defp offered_at?({status, listings}, ship_type, waypoint) when status in [:ok, :partial] do
    if Enum.any?(listings, &offered_in_listing?(&1, ship_type, waypoint)) do
      :ok
    else
      {:error, :shipyard_unavailable}
    end
  end

  defp offered_at?(_, _ship_type, _waypoint), do: {:error, :shipyard_unavailable}

  defp offered_in_listing?(%{waypoint: waypoint, shipyard: %{ships: ships}}, ship_type, waypoint) do
    Enum.any?(ships || [], &(&1.type == ship_type))
  end

  defp offered_in_listing?(_, _ship_type, _waypoint), do: false

  defp record_purchase(agent, ship, ship_type) do
    case record_ship(agent, ship.symbol, ship_type) do
      {:ok, _ship} -> nil
      {:error, reason} -> {:ship_record_failed, reason}
    end
  end

  defp ship_credentials(ship_symbol) do
    query =
      from(s in Ship,
        join: a in assoc(s, :agent),
        where: s.symbol == ^ship_symbol,
        select: {a.id, a.agent_token}
      )

    case Repo.one(query) do
      {agent_id, agent_token} when is_binary(agent_token) and agent_token != "" ->
        {:ok, agent_id, agent_token}

      _ ->
        :error
    end
  end
end
