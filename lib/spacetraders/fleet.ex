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
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model.{Market, ShipCargo, ShipNav}

  alias SpaceTraders.Fleet.{
    Activity,
    Job,
    JobBlocker,
    Intent,
    MarketTradingPolicy,
    Ship,
    ShipDestination
  }

  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.Repo
  alias SpaceTraders.{Agent, Contracts, Intelligence, Listing, Shipyard}
  alias SpaceTraders.Timeline

  @gather_kinds ["extract", "siphon"]
  @terminal_job_states Job.terminal_states()
  @running_job_states Job.running_states()
  @max_recovery_attempts 5
  @recovery_window_seconds 15 * 60

  @doc """
  Pulls the agent's live fleet from the game API.

  Each ship carries its current nav (location + docked/orbiting/transit state),
  fuel, cargo and cooldown — the data the fleet cards render.

  Returns `{:ok, [%SpaceTraders.API.Model.Ship{}]}` or an API error. An agent
  without a stored AgentToken returns `{:error, :agent_token_missing}`.
  """
  def list_ships(%AgentRecord{agent_token: agent_token} = agent)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- Agent.execution_allowed?(agent) do
      Agent.handle_game_result(agent, SpaceTraders.API.get_ships(agent_token))
    end
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

  @doc "Reads and records authoritative Construction facts for a selected Waypoint."
  def waypoint_construction(%AgentRecord{agent_token: token} = agent, waypoint)
      when is_binary(token) and token != "" do
    with %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      case SpaceTraders.API.get_construction(token, system, symbol) do
        {:ok, construction} = result ->
          record_construction_observation(agent, system, construction, "get_construction")
          result

        {:error, %SpaceTraders.API.GameplayError{}} = result ->
          Intelligence.mark_unavailable(agent, :construction, system, symbol, [:complete],
            source: "get_construction"
          )

          result

        result ->
          result
      end
    else
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_construction(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Reads and records a Jump Gate's connections without inferring Construction readiness."
  def waypoint_jump_gate(%AgentRecord{agent_token: token} = agent, waypoint)
      when is_binary(token) and token != "" do
    with %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      case SpaceTraders.API.get_jump_gate(token, system, symbol) do
        {:ok, gate} = result ->
          record_jump_gate_observation(agent, system, gate, "get_jump_gate")
          result

        {:error, %SpaceTraders.API.GameplayError{}} = result ->
          Intelligence.mark_unavailable(agent, :jump_gate, system, symbol, [:connections],
            source: "get_jump_gate"
          )

          result

        result ->
          result
      end
    else
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_jump_gate(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Supplies a Construction project and refreshes or invalidates its authoritative facts."
  def supply_construction(
        %AgentRecord{agent_token: token} = agent,
        system_symbol,
        waypoint_symbol,
        ship_symbol,
        trade_symbol,
        units
      )
      when is_binary(token) and token != "" and is_integer(units) and units > 0 do
    agent
    |> Agent.handle_game_result(
      SpaceTraders.API.supply_construction(
        token,
        system_symbol,
        waypoint_symbol,
        ship_symbol,
        trade_symbol,
        units
      )
    )
    |> refresh_construction_after(agent, system_symbol, waypoint_symbol, ship_symbol)
  end

  def supply_construction(
        %AgentRecord{agent_token: token},
        _system,
        _waypoint,
        _ship,
        _trade,
        _units
      )
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def supply_construction(%AgentRecord{}, _system, _waypoint, _ship, _trade, _units),
    do: {:error, :invalid_units}

  @doc "Returns recent local events for an Agent, newest first."
  def recent_activity(%AgentRecord{} = agent) do
    Activity
    |> where([a], a.agent_id == ^agent.id)
    |> order_by([a], desc: a.inserted_at)
    |> preload(:ship)
    |> Repo.all()
  end

  defp annotate_jobs({:ok, ships}, agent) do
    ship_records = Enum.map(ships, &ensure_ship_record(agent, &1))
    jobs_by_ship = jobs_for_ships(ship_records)
    intents_by_ship = intents_for_ships(agent)
    intent_history_by_ship = intents_history_for_ships(agent)

    {:ok,
     Enum.map(ships, fn ship ->
       ship_record = Enum.find(ship_records, &(&1.symbol == ship.symbol))
       {job, history} = job_and_history(Map.get(jobs_by_ship, ship_record.id, []))

       ship
       |> Map.put(:job, job)
       |> Map.put(:job_history, history)
       |> Map.put(:intents, Map.get(intents_by_ship, ship_record.id))
       |> Map.put(:intents_history, Map.get(intent_history_by_ship, ship_record.id, []))
       |> Map.put(:destination_history, destination_history(agent, ship.symbol))
     end)}
  end

  defp annotate_jobs(result, _agent), do: result

  defp intents_for_ships(agent) do
    %SpaceTraders.Agent.Scope{operator: %{id: agent.operator_id}}
    |> SpaceTraders.Fleet.Intents.list(agent, :current)
    |> Enum.filter(&(&1.caller == "manual"))
    |> Map.new(&{&1.ship_id, &1})
  end

  defp intents_history_for_ships(agent) do
    %SpaceTraders.Agent.Scope{operator: %{id: agent.operator_id}}
    |> SpaceTraders.Fleet.Intents.list(agent, :history)
    |> Enum.filter(&(&1.caller == "manual"))
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

  @doc "Captures a Ship's authoritative current System as a paused System Exploration Job."
  def configure_explorer_job(%AgentRecord{agent_token: token} = agent, ship_symbol)
      when is_binary(token) and token != "" do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         nil <- unfinished_job(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship_symbol)),
         system when is_binary(system) <- live_ship.nav.system_symbol,
         {:ok, waypoints} <- fetch_waypoint_pages(token, system) do
      Enum.each(waypoints, &record_waypoint_observation(agent, &1, "get_waypoints"))

      job =
        %Job{ship_id: ship.id}
        # The original Miner schema keeps these columns non-null. Explorer
        # policy never reads them; its fixed target belongs in progress.
        |> Job.changeset(%{
          type: "explorer",
          extraction_waypoint: "EXPLORER-NONE",
          market_waypoint: "EXPLORER-NONE",
          cargo_threshold: 1
        })
        |> Ecto.Changeset.put_change(:status, "paused")
        |> Ecto.Changeset.put_change(:blocked_reason, "Awaiting Operator resume")
        |> Ecto.Changeset.put_change(:progress, %{"target_system" => system})
        |> Repo.insert!()

      record_activity(
        agent,
        ship,
        "configuration",
        "System Exploration Job configured for #{system}"
      )

      {:ok, job}
    else
      %Job{} -> {:error, :unfinished_job_already_assigned}
      nil -> {:error, :current_system_unavailable}
      error -> error
    end
  end

  def configure_explorer_job(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Captures a paused Procurement Job for one Contract, Construction, or Market recipient."
  def configure_procurement_job(%AgentRecord{agent_token: token} = agent, ship_symbol, attrs)
      when is_binary(token) and token != "" and is_map(attrs) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         nil <- unfinished_job(ship.id),
         :ok <- validate_procurement_attrs(attrs),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship_symbol)),
         system when is_binary(system) <- live_ship.nav.system_symbol,
         {:ok, progress} <- procurement_progress(attrs, system) do
      job =
        %Job{ship_id: ship.id}
        |> Job.changeset(%{
          type: "procurement",
          # Legacy Miner columns remain non-null while policies own their config.
          extraction_waypoint: "PROCUREMENT-NONE",
          market_waypoint: "PROCUREMENT-NONE",
          cargo_threshold: 1
        })
        |> Ecto.Changeset.put_change(:status, "paused")
        |> Ecto.Changeset.put_change(:blocked_reason, "Awaiting Operator resume")
        |> Ecto.Changeset.put_change(:progress, progress)
        |> Repo.insert!()

      record_activity(agent, ship, "configuration", "Procurement Job configured")
      {:ok, job}
    else
      %Job{} -> {:error, :unfinished_job_already_assigned}
      error -> error
    end
  end

  def configure_procurement_job(%AgentRecord{}, _ship_symbol, _attrs),
    do: {:error, :agent_token_missing}

  @doc "Captures a paused Construction Supply Job for every material of one fixed project."
  def configure_construction_supply_job(
        %AgentRecord{agent_token: token} = agent,
        ship_symbol,
        attrs
      )
      when is_binary(token) and token != "" and is_map(attrs) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         nil <- unfinished_job(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship_symbol)),
         system when is_binary(system) <- live_ship.nav.system_symbol,
         {:ok, progress} <- construction_supply_progress(attrs, system) do
      job =
        %Job{ship_id: ship.id}
        |> Job.changeset(%{
          type: "construction_supply",
          extraction_waypoint: "CONSTRUCTION-SUPPLY-NONE",
          market_waypoint: "CONSTRUCTION-SUPPLY-NONE",
          cargo_threshold: 1
        })
        |> Ecto.Changeset.put_change(:status, "paused")
        |> Ecto.Changeset.put_change(:blocked_reason, "Awaiting Operator resume")
        |> Ecto.Changeset.put_change(:progress, progress)
        |> Repo.insert!()

      record_activity(agent, ship, "configuration", "Construction Supply Job configured")
      {:ok, job}
    else
      %Job{} -> {:error, :unfinished_job_already_assigned}
      nil -> {:error, :current_system_unavailable}
      error -> error
    end
  end

  def configure_construction_supply_job(%AgentRecord{}, _ship_symbol, _attrs),
    do: {:error, :agent_token_missing}

  @doc "Captures a paused Ship Outfitting Job with its explicit readiness target and removal authority."
  def configure_outfitting_job(%AgentRecord{agent_token: token} = agent, ship_symbol, attrs)
      when is_binary(token) and token != "" and is_map(attrs) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         nil <- unfinished_job(ship.id),
         {:ok, system} <- outfitting_source_system(agent, ship_symbol, attrs),
         {:ok, progress} <- outfitting_progress(attrs, system) do
      %Job{ship_id: ship.id}
      |> Job.changeset(%{
        type: "outfitting",
        extraction_waypoint: "OUTFITTING-NONE",
        market_waypoint: "OUTFITTING-NONE",
        cargo_threshold: 1
      })
      |> Ecto.Changeset.put_change(:status, "paused")
      |> Ecto.Changeset.put_change(:blocked_reason, "Awaiting Operator resume")
      |> Ecto.Changeset.put_change(:progress, progress)
      |> Repo.insert()
    else
      %Job{} -> {:error, :unfinished_job_already_assigned}
      error -> error
    end
  end

  def configure_outfitting_job(%AgentRecord{}, _ship_symbol, _attrs),
    do: {:error, :agent_token_missing}

  # Cargo-only Outfitting Jobs from the prior capability do not source or spend.
  # Sourcing configurations always capture the Ship's current System up front.
  defp outfitting_source_system(_agent, _ship_symbol, attrs)
       when not is_map_key(attrs, :maximum_total_cost) and
              not is_map_key(attrs, "maximum_total_cost"),
       do: {:ok, nil}

  defp outfitting_source_system(agent, ship_symbol, _attrs) do
    with {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ),
         system when is_binary(system) <- live_ship.nav.system_symbol do
      {:ok, system}
    else
      _ -> {:error, :current_system_unavailable}
    end
  end

  defp outfitting_progress(attrs, source_system) do
    capability = attrs[:requested_capability] || attrs["requested_capability"]
    acceptable = attrs[:acceptable_modules] || attrs["acceptable_modules"]
    removals = attrs[:authorized_removals] || attrs["authorized_removals"] || %{}
    source_waypoints = attrs[:source_waypoints] || attrs["source_waypoints"] || []
    reserve_credits = attrs[:reserve_credits] || attrs["reserve_credits"] || 0
    maximum_total_cost = attrs[:maximum_total_cost] || attrs["maximum_total_cost"]

    if is_binary(capability) and capability != "" and is_list(acceptable) and acceptable != [] and
         Enum.all?(acceptable, &(is_binary(&1) and &1 != "")) and is_map(removals) and
         Enum.all?(removals, fn {symbol, count} ->
           is_binary(symbol) and symbol != "" and is_integer(count) and count > 0
         end) and is_list(source_waypoints) and
         Enum.all?(source_waypoints, &(is_binary(&1) and &1 != "")) and
         Enum.all?(source_waypoints, &waypoint_in_system?(&1, source_system)) and
         is_integer(reserve_credits) and reserve_credits >= 0 and
         ((is_nil(source_system) and is_nil(maximum_total_cost)) or
            (is_integer(maximum_total_cost) and maximum_total_cost > 0)) do
      {:ok,
       %{
         "requested_capability" => capability,
         "acceptable_modules" => Enum.uniq(acceptable),
         "authorized_removals" => removals,
         "source_system" => source_system,
         "source_waypoints" => Enum.uniq(source_waypoints),
         "reserve_credits" => reserve_credits,
         "maximum_total_cost" => maximum_total_cost,
         "spent" => 0,
         "removed_modules" => %{},
         "installed_modules" => [],
         "cargo_candidate" => nil,
         "active_operation" => nil,
         "evidence" => []
       }}
    else
      {:error, :invalid_outfitting_configuration}
    end
  end

  @doc "Starts or resumes a Ship Outfitting Job from authoritative installed modules and Cargo."
  def start_outfitting_job(%AgentRecord{} = agent, ship_symbol) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "outfitting"} = job <- unfinished_job(ship.id),
         nil <- unfinished_manual_intent(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ) do
      job = apply_unapplied_outfitting_purchase!(job)

      job =
        Repo.update!(
          Ecto.Changeset.change(job, status: "active", blocker: nil, blocked_reason: nil)
        )

      advance_outfitting_job(agent, job, live_ship)
    else
      nil -> {:error, :outfitting_job_not_configured}
      %Job{} -> {:error, :outfitting_job_not_configured}
      %Intent{} -> {:error, :intents_active}
      {:error, reason} -> block_outfitting_job(agent, ship_symbol, reason)
    end
  end

  def resume_outfitting_job(agent, ship_symbol), do: start_outfitting_job(agent, ship_symbol)

  def pause_outfitting_job(%AgentRecord{} = agent, ship_symbol),
    do: pause_job_type(agent, ship_symbol, "outfitting", "Ship Outfitting Job")

  def stop_outfitting_job(%AgentRecord{} = agent, ship_symbol),
    do: stop_job_type(agent, ship_symbol, "outfitting", "Ship Outfitting Job")

  defp advance_outfitting_job(agent, job, live_ship) do
    module_slots = live_ship.frame && live_ship.frame.module_slots
    candidate = Enum.find(job.progress["acceptable_modules"], &(item_units(live_ship, &1) > 0))
    intent = unfinished_job_intent(job.id)

    progress =
      job.progress
      |> Map.put("installed_modules", Enum.map(live_ship.modules || [], & &1.symbol))
      |> Map.put("active_operation", outfitting_operation(intent))

    job =
      Repo.update!(
        Ecto.Changeset.change(job,
          progress: progress,
          last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )
      )

    cond do
      Enum.any?(progress["acceptable_modules"], &(&1 in progress["installed_modules"])) ->
        evidence = %{"installed_modules" => progress["installed_modules"], "outcome" => "ready"}

        {:ok,
         terminalize_job!(
           Repo.update!(
             Ecto.Changeset.change(job,
               progress: Map.update!(progress, "evidence", &(&1 ++ [evidence]))
             )
           ),
           "completed"
         )}

      is_struct(intent, Intent) ->
        reconcile_outfitting_intent(agent, job, intent, live_ship)

      is_binary(candidate) and
          (not is_integer(module_slots) or module_slots > length(live_ship.modules || [])) ->
        start_outfitting_operation(agent, job, live_ship, "install_module", candidate)

      is_binary(candidate) and is_integer(module_slots) and
          module_slots <= length(live_ship.modules || []) ->
        case authorized_removal(progress, live_ship) do
          nil -> mark_outfitting_job_blocked(job, :module_slot_removal_not_authorized)
          symbol -> start_outfitting_operation(agent, job, live_ship, "remove_module", symbol)
        end

      is_binary(progress["source_system"]) ->
        start_outfitting_purchase(agent, job, live_ship)

      true ->
        mark_outfitting_job_blocked(
          job,
          {:acceptable_module_missing_from_cargo, progress["acceptable_modules"]}
        )
    end
  end

  defp outfitting_operation(%Intent{} = intent) do
    %{"kind" => intent.type, "module_symbol" => intent.parameters["module_symbol"]}
  end

  defp outfitting_operation(_intent), do: nil

  defp start_outfitting_operation(agent, job, live_ship, type, module_symbol) do
    progress =
      job.progress
      |> Map.put(
        "cargo_candidate",
        if(type == "install_module", do: module_symbol, else: job.progress["cargo_candidate"])
      )
      |> Map.put("active_operation", %{"kind" => type, "module_symbol" => module_symbol})

    job = Repo.update!(Ecto.Changeset.change(job, progress: progress))

    with {:ok, intent} <-
           SpaceTraders.Fleet.Intents.request(
             job_scope(agent),
             agent,
             %SpaceTraders.Fleet.Intents.JobOwner{job: job},
             live_ship.symbol,
             if(type == "install_module",
               do: %SpaceTraders.Fleet.Intents.InstallModule{module_symbol: module_symbol},
               else: %SpaceTraders.Fleet.Intents.RemoveModule{
                 module_symbol: module_symbol,
                 authorized_removals: job.progress["authorized_removals"]
               }
             )
           ) do
      advance_outfitting_after_intent(agent, job, intent)
    else
      {:error, reason} -> mark_outfitting_job_blocked(job, reason)
      :ok -> :ok
    end
  end

  defp start_outfitting_purchase(agent, job, live_ship) do
    with :ok <- outfitting_system_matches?(job.progress, live_ship),
         {:ok, source} <- outfitting_market_source(agent, live_ship, job.progress),
         :ok <- outfitting_price_allowed?(source.good, job.progress),
         {:ok, intent} <-
           request_job_intent(agent, job, live_ship, %{
             type: "buy",
             target_waypoint: source.waypoint,
             parameters: %{
               "trade_symbol" => source.good.symbol,
               "units" => 1,
               "max_price" => outfitting_remaining_budget(job.progress),
               "reserve_credits" => job.progress["reserve_credits"],
               "source_waypoint" => source.waypoint
             }
           }) do
      advance_outfitting_after_intent(agent, job, intent)
    else
      {:error, reason} -> mark_outfitting_job_blocked(job, reason)
      :ok -> :ok
    end
  end

  defp reconcile_outfitting_intent(agent, job, intent, live_ship) do
    case Intents.reconcile_internal(
           agent.id,
           live_ship.symbol,
           live_ship,
           :job,
           intent.id,
           job.id
         ) do
      {:ok, intent} -> advance_outfitting_after_intent(agent, job, intent)
      :ok -> :ok
      {:error, reason} -> mark_outfitting_job_blocked(job, reason)
    end
  end

  defp advance_outfitting_after_intent(agent, job, %Intent{status: "completed"} = intent) do
    with %Job{} = current <- Repo.get(Job, job.id),
         true <- Job.running?(current),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, Repo.get!(Ship, current.ship_id).symbol)
           ) do
      evidence = %{"operation" => intent.last_action_result, "outcome" => "confirmed"}

      progress =
        current.progress
        |> Map.update!("evidence", &(&1 ++ [evidence]))
        |> apply_outfitting_purchase(intent)
        |> mark_outfitting_purchase_applied(intent)
        |> apply_outfitting_removal(intent)

      advance_outfitting_job(
        agent,
        Repo.update!(Ecto.Changeset.change(current, progress: progress)),
        live_ship
      )
    else
      false -> {:ok, job}
      {:error, reason} -> mark_outfitting_job_blocked(job, reason)
    end
  end

  defp advance_outfitting_after_intent(_agent, job, %Intent{status: "waiting"} = intent) do
    {:ok,
     Repo.update!(
       Ecto.Changeset.change(job,
         status: "waiting",
         progress: Map.put(job.progress, "active_operation", outfitting_operation(intent))
       )
     )}
  end

  defp advance_outfitting_after_intent(_agent, job, %Intent{} = intent),
    do: mark_outfitting_job_blocked(job, intent.blocker || :outfitting_operation_blocked)

  defp authorized_removal(progress, live_ship) do
    Enum.find_value(progress["authorized_removals"], fn {symbol, count} ->
      removed = get_in(progress, ["removed_modules", symbol]) || 0

      if count > removed and module_count(live_ship.modules, symbol) > 0, do: symbol
    end)
  end

  defp apply_outfitting_purchase(progress, %Intent{type: "buy", last_action_result: result}) do
    Map.update(
      progress,
      "spent",
      get_in(result, ["transaction", "total_price"]) || 0,
      &(&1 + (get_in(result, ["transaction", "total_price"]) || 0))
    )
  end

  defp apply_outfitting_purchase(progress, _intent), do: progress

  defp mark_outfitting_purchase_applied(progress, %Intent{type: "buy", id: id}),
    do: Map.put(progress, "last_applied_purchase_intent_id", id)

  defp mark_outfitting_purchase_applied(progress, _intent), do: progress

  defp apply_outfitting_removal(progress, %Intent{type: "remove_module"} = intent) do
    symbol = intent.parameters["module_symbol"]

    Map.update(progress, "removed_modules", %{symbol => 1}, fn removed ->
      Map.update(removed, symbol, 1, &(&1 + 1))
    end)
  end

  defp apply_outfitting_removal(progress, _intent), do: progress

  defp apply_unapplied_outfitting_purchase!(job) do
    intent = last_completed_job_intent(job.id, "buy")

    if intent && job.progress["last_applied_purchase_intent_id"] != intent.id do
      progress =
        job.progress
        |> apply_outfitting_purchase(intent)
        |> Map.put("last_applied_purchase_intent_id", intent.id)

      Repo.update!(Ecto.Changeset.change(job, progress: progress))
    else
      job
    end
  end

  defp outfitting_system_matches?(%{"source_system" => system}, live_ship)
       when system == live_ship.nav.system_symbol,
       do: :ok

  defp outfitting_system_matches?(%{"source_system" => nil}, _live_ship), do: :ok

  defp outfitting_system_matches?(%{"source_system" => system}, live_ship) do
    {:error,
     {:fixed_system_changed,
      %{configured_system: system, current_system: live_ship.nav.system_symbol}}}
  end

  defp outfitting_system_matches?(_progress, _live_ship),
    do: {:error, :current_system_unavailable}

  defp outfitting_market_source(agent, live_ship, progress) do
    with :ok <- outfitting_system_matches?(progress, live_ship),
         {:ok, waypoints} <- outfitting_source_waypoints(agent, progress) do
      Enum.reduce_while(waypoints, {:error, :source_market_unavailable}, fn waypoint, _result ->
        case market_for_ship(agent, live_ship, waypoint) do
          {:ok, market} ->
            case Enum.find(market.trade_goods || [], fn good ->
                   good.symbol in progress["acceptable_modules"] and
                     outfitting_price_allowed?(good, progress) == :ok
                 end) do
              nil -> {:cont, {:error, :source_market_unavailable}}
              good -> {:halt, {:ok, %{waypoint: waypoint, good: good}}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp outfitting_source_waypoints(_agent, %{"source_waypoints" => [_ | _] = waypoints}),
    do: {:ok, waypoints}

  defp outfitting_source_waypoints(agent, %{"source_system" => system}) do
    with {:ok, waypoints} <- fetch_waypoint_pages(agent.agent_token, system) do
      {:ok,
       waypoints
       |> Enum.filter(&(market_waypoint?(&1) == :ok))
       |> Enum.map(& &1.symbol)}
    end
  end

  defp outfitting_source_waypoints(_agent, _progress), do: {:error, :source_market_unavailable}

  defp outfitting_price_allowed?(%{purchase_price: price}, progress) when is_integer(price) do
    if is_nil(progress["maximum_total_cost"]) or
         price <= outfitting_remaining_budget(progress),
       do: :ok,
       else: {:error, :maximum_total_cost_exceeded}
  end

  defp outfitting_price_allowed?(_good, _progress), do: {:error, :source_market_unavailable}

  defp outfitting_remaining_budget(%{"maximum_total_cost" => nil}), do: nil

  defp outfitting_remaining_budget(progress),
    do: max(progress["maximum_total_cost"] - progress["spent"], 0)

  defp waypoint_in_system?(waypoint, system) when is_binary(waypoint) and is_binary(system) do
    case system_from_headquarters(waypoint) do
      {:ok, ^system} -> true
      _ -> false
    end
  end

  defp waypoint_in_system?(_waypoint, nil), do: true
  defp waypoint_in_system?(_waypoint, _system), do: false

  defp block_outfitting_job(agent, ship_symbol, reason) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "outfitting"} = job <- unfinished_job(ship.id) do
      mark_outfitting_job_blocked(job, reason)
      {:error, {:outfitting_job_blocked, reason}}
    else
      _ -> {:error, :outfitting_job_not_configured}
    end
  end

  defp mark_outfitting_job_blocked(job, reason) do
    blocker = %{
      job_blocker(reason)
      | summary: "Ship Outfitting Job cannot progress: #{blocker_reason(reason)}."
    }

    {:error,
     Repo.update!(
       Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
     )}
  end

  defp construction_supply_progress(attrs, target_system) do
    system = attrs[:construction_system] || attrs["construction_system"]
    waypoint = attrs[:construction_waypoint] || attrs["construction_waypoint"]
    sources = attrs[:source_systems] || attrs["source_systems"] || []
    reserve = attrs[:reserve_credits] || attrs["reserve_credits"] || 0
    maximum_total_cost = attrs[:maximum_total_cost] || attrs["maximum_total_cost"]

    compatible? =
      attrs[:compatible_existing_cargo?] || attrs["compatible_existing_cargo?"] || false

    with true <- is_binary(system) and system == target_system,
         true <- is_binary(waypoint),
         :ok <- validate_procurement_sources(sources, target_system),
         true <- is_integer(reserve) and reserve >= 0,
         true <-
           is_nil(maximum_total_cost) or
             (is_integer(maximum_total_cost) and maximum_total_cost > 0) do
      {:ok,
       %{
         "construction_system" => system,
         "construction_waypoint" => waypoint,
         "target_system" => target_system,
         "source_systems" => sources,
         "reserve_credits" => reserve,
         "maximum_total_cost" => maximum_total_cost,
         "compatible_existing_cargo" => compatible?,
         "accepted" => %{},
         "acquired" => %{},
         "committed_cargo" => %{},
         "spent" => 0,
         "trips" => 0,
         "external_progress" => %{}
       }}
    else
      false -> {:error, :invalid_construction_supply_configuration}
      {:error, _reason} = error -> error
    end
  end

  @doc "Captures a paused recurring Market Trading Job for the Ship's current System."
  def configure_market_trading_job(%AgentRecord{agent_token: token} = agent, ship_symbol, attrs)
      when is_binary(token) and token != "" and is_map(attrs) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         nil <- unfinished_job(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship_symbol)),
         system when is_binary(system) <- live_ship.nav.system_symbol,
         {:ok, progress} <- market_trading_progress(attrs, system) do
      %Job{ship_id: ship.id}
      |> Job.changeset(%{
        type: "market_trading",
        extraction_waypoint: "MARKET-NONE",
        market_waypoint: "MARKET-NONE",
        cargo_threshold: 1
      })
      |> Ecto.Changeset.put_change(:status, "paused")
      |> Ecto.Changeset.put_change(:blocked_reason, "Awaiting Operator resume")
      |> Ecto.Changeset.put_change(:progress, progress)
      |> Repo.insert()
    else
      %Job{} -> {:error, :unfinished_job_already_assigned}
      nil -> {:error, :current_system_unavailable}
      error -> error
    end
  end

  def configure_market_trading_job(%AgentRecord{}, _ship_symbol, _attrs),
    do: {:error, :agent_token_missing}

  @doc "Starts or resumes a recurring Market Trading Job from known candidates."
  def start_market_trading_job(%AgentRecord{} = agent, ship_symbol) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "market_trading"} = job <- unfinished_job(ship.id),
         nil <- unfinished_manual_intent(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ),
         :ok <- market_system_matches?(job.progress, live_ship),
         {:ok, overview} <- Agent.agent_overview(agent) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job, status: "active", blocker: nil, blocked_reason: nil)
        )

      constraints =
        job.progress["constraints"]
        |> atomize_market_keys()
        |> Map.put(:credits, overview.credits)

      {candidate, rejected} = MarketTradingPolicy.select(job.progress["candidates"], constraints)

      if candidate do
        params = %{
          "trade_symbol" => candidate.trade_symbol,
          "units" => candidate.units,
          "max_price" => candidate.purchase_price,
          "reserve_credits" => constraints.reserve_credits,
          "market_trade" => candidate
        }

        with {:ok, intent} <-
               request_job_intent(agent, job, live_ship, %{
                 type: "buy",
                 target_waypoint: candidate.source_waypoint,
                 parameters: params
               }),
             {:ok, intent} <-
               Intents.reconcile_internal(
                 agent.id,
                 live_ship.symbol,
                 live_ship,
                 :job,
                 intent.id,
                 job.id
               ) do
          {:ok,
           Repo.update!(
             Ecto.Changeset.change(job,
               progress: Map.put(job.progress, "last_intent_id", intent.id)
             )
           )}
        end
      else
        blocker = job_blocker({:no_viable_market_trade, rejected})

        Repo.update!(
          Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
        )

        {:error, {:market_trading_job_blocked, blocker}}
      end
    else
      nil -> {:error, :market_trading_job_not_configured}
      %Job{} -> {:error, :market_trading_job_not_configured}
      {:error, reason} -> block_market_trading_job(agent, ship_symbol, reason)
    end
  end

  def resume_market_trading_job(agent, ship_symbol),
    do: start_market_trading_job(agent, ship_symbol)

  def pause_market_trading_job(%AgentRecord{} = agent, ship_symbol),
    do: pause_job_type(agent, ship_symbol, "market_trading", "Market Trading Job")

  def stop_market_trading_job(%AgentRecord{} = agent, ship_symbol),
    do: stop_job_type(agent, ship_symbol, "market_trading", "Market Trading Job")

  defp market_trading_progress(attrs, system) do
    candidates = attrs[:candidates] || attrs["candidates"] || []

    constraints = %{
      "reserve_credits" => attrs[:reserve_credits] || attrs["reserve_credits"] || 0,
      "credit_exposure" => attrs[:credit_exposure] || attrs["credit_exposure"],
      "minimum_profit" => attrs[:minimum_profit] || attrs["minimum_profit"] || 0,
      "minimum_return_percentage" =>
        attrs[:minimum_return_percentage] || attrs["minimum_return_percentage"] || 0,
      "compatible_existing_cargo" =>
        attrs[:compatible_existing_cargo] || attrs["compatible_existing_cargo"] || false
    }

    if is_list(candidates) and is_integer(constraints["reserve_credits"]) and
         is_integer(constraints["minimum_profit"]) and
         is_number(constraints["minimum_return_percentage"]) and
         (is_nil(constraints["credit_exposure"]) or is_integer(constraints["credit_exposure"])),
       do:
         {:ok,
          %{
            "target_system" => system,
            "constraints" => constraints,
            "candidates" => candidates,
            "completed_trades" => 0,
            "realized_gross_profit" => 0,
            "realized_net_profit" => 0,
            "estimated_fuel_cost" => 0
          }},
       else: {:error, :invalid_market_trading_configuration}
  end

  defp atomize_market_keys(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp market_system_matches?(%{"target_system" => system}, live_ship)
       when system == live_ship.nav.system_symbol,
       do: :ok

  defp market_system_matches?(%{"target_system" => system}, live_ship),
    do:
      {:error,
       {:fixed_system_changed,
        %{configured_system: system, current_system: live_ship.nav.system_symbol}}}

  defp market_system_matches?(_, _), do: {:error, :current_system_unavailable}

  defp block_market_trading_job(agent, ship_symbol, reason) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "market_trading"} = job <- unfinished_job(ship.id) do
      blocker = job_blocker(reason)

      Repo.update!(
        Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
      )

      {:error, {:market_trading_job_blocked, reason}}
    else
      _ -> {:error, :market_trading_job_not_configured}
    end
  end

  defp procurement_progress(attrs, target_system) do
    destination = attrs[:destination_waypoint] || attrs["destination_waypoint"]
    source_systems = attrs[:source_systems] || attrs["source_systems"] || []

    with {:ok, destination_system} <- system_from_headquarters(destination),
         :ok <- validate_procurement_destination(destination_system, target_system),
         :ok <- validate_procurement_sources(source_systems, target_system) do
      procurement_progress_in_system(attrs, target_system)
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_procurement_destination(destination_system, destination_system), do: :ok

  defp validate_procurement_destination(destination_system, target_system) do
    {:error,
     {:remote_destination_system_unsupported,
      %{current_system: target_system, destination_system: destination_system}}}
  end

  defp validate_procurement_sources(source_systems, target_system) do
    case Enum.find(source_systems, &(&1 != target_system)) do
      nil ->
        :ok

      source_system ->
        {:error,
         {:remote_source_system_unsupported,
          %{current_system: target_system, source_system: source_system}}}
    end
  end

  defp validate_procurement_attrs(attrs) do
    with trade_symbol when is_binary(trade_symbol) <-
           attrs[:trade_symbol] || attrs["trade_symbol"],
         quantity when is_integer(quantity) and quantity > 0 <-
           attrs[:quantity] || attrs["quantity"],
         destination when is_binary(destination) <-
           attrs[:destination_waypoint] || attrs["destination_waypoint"] do
      :ok
    else
      _ -> {:error, :invalid_procurement_configuration}
    end
  end

  defp procurement_progress_in_system(attrs, target_system) do
    contract_id = attrs[:contract_id] || attrs["contract_id"]
    recipient_type = attrs[:recipient_type] || attrs["recipient_type"] || "contract"
    construction_system = attrs[:construction_system] || attrs["construction_system"]
    trade_symbol = attrs[:trade_symbol] || attrs["trade_symbol"]
    quantity = attrs[:quantity] || attrs["quantity"]
    destination = attrs[:destination_waypoint] || attrs["destination_waypoint"]
    source_systems = attrs[:source_systems] || attrs["source_systems"] || []
    reserve_credits = attrs[:reserve_credits] || attrs["reserve_credits"] || 0
    price_ceiling = attrs[:price_ceiling] || attrs["price_ceiling"]
    minimum_sale_price = attrs[:minimum_sale_price] || attrs["minimum_sale_price"]
    minimum_sale_value = attrs[:minimum_sale_value] || attrs["minimum_sale_value"]

    compatible_cargo? =
      attrs[:compatible_existing_cargo?] || attrs["compatible_existing_cargo?"] || false

    if recipient_type in ["contract", "construction", "market"] and
         (recipient_type in ["market", "construction"] or is_binary(contract_id)) and
         is_binary(trade_symbol) and
         is_integer(quantity) and
         quantity > 0 and
         is_binary(destination) and is_list(source_systems) and
         Enum.all?(source_systems, &is_binary/1) and
         is_integer(reserve_credits) and reserve_credits >= 0 and
         (is_nil(price_ceiling) or (is_integer(price_ceiling) and price_ceiling > 0)) and
         (is_nil(minimum_sale_price) or
            (is_integer(minimum_sale_price) and minimum_sale_price > 0)) and
         (is_nil(minimum_sale_value) or
            (is_integer(minimum_sale_value) and minimum_sale_value > 0)) and
         valid_construction_recipient?(recipient_type, construction_system, target_system) do
      {:ok,
       %{
         "recipient_type" => recipient_type,
         "trade_symbol" => trade_symbol,
         "requested" => quantity,
         "destination_waypoint" => destination,
         "target_system" => target_system,
         "source_systems" => source_systems,
         "reserve_credits" => reserve_credits,
         "price_ceiling" => price_ceiling,
         "minimum_sale_price" => minimum_sale_price,
         "minimum_sale_value" => minimum_sale_value,
         "compatible_existing_cargo" => compatible_cargo?,
         "acquired" => 0,
         "aboard" => 0,
         "sold" => 0,
         "accepted" => 0,
         "shared_fulfilled" => 0,
         "external_progress" => 0,
         "spent" => 0
       }
       |> maybe_put_contract_id(contract_id)
       |> maybe_put_construction_system(recipient_type, construction_system)}
    else
      {:error, :invalid_procurement_configuration}
    end
  end

  defp maybe_put_contract_id(progress, contract_id) when is_binary(contract_id),
    do: Map.put(progress, "contract_id", contract_id)

  defp maybe_put_contract_id(progress, _contract_id), do: progress

  defp maybe_put_construction_system(progress, "construction", construction_system),
    do: Map.put(progress, "construction_system", construction_system)

  defp maybe_put_construction_system(progress, _recipient_type, _construction_system),
    do: progress

  defp valid_construction_recipient?("construction", construction_system, target_system),
    do: is_binary(construction_system) and construction_system == target_system

  defp valid_construction_recipient?(_recipient_type, _construction_system, _target_system),
    do: true

  @doc "Starts or resumes a Procurement Job from fresh Contract, Ship, and credit state."
  def start_procurement_job(%AgentRecord{} = agent, ship_symbol) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "procurement"} = job <- unfinished_job(ship.id),
         nil <- unfinished_manual_intent(ship.id) do
      job = apply_unapplied_procurement_intent!(job)

      case unfinished_job_intent(job.id) do
        %Intent{} = intent ->
          job =
            Repo.update!(
              Ecto.Changeset.change(job, status: "active", blocker: nil, blocked_reason: nil)
            )

          case reconcile_procurement_intent(agent, ship, job, intent) do
            :ok -> {:ok, Repo.get!(Job, job.id)}
            {:ok, %Job{} = result} -> {:ok, result}
            result -> result
          end

        nil ->
          case start_fresh_procurement_job(agent, ship_symbol, job) do
            :ok -> {:ok, Repo.get!(Job, job.id)}
            result -> result
          end
      end
    else
      nil ->
        {:error, :procurement_job_not_configured}

      %Job{} ->
        {:error, :procurement_job_not_configured}

      %Intent{in_flight_action: action} when is_map(action) ->
        {:error, :cargo_operation_reconciliation_required}

      %Intent{} ->
        {:error, :intents_active}

      :cargo_operation_reconciliation_required ->
        {:error, :cargo_operation_reconciliation_required}

      {:error, reason} ->
        block_procurement_job(agent, ship_symbol, reason)

      :ok ->
        {:ok,
         Repo.one!(
           from j in Job,
             join: s in Ship,
             on: s.id == j.ship_id,
             where:
               s.symbol == ^ship_symbol and j.type == "procurement" and
                 j.status not in ["completed", "failed", "stopped", "replaced"]
         )}
    end
  end

  defp start_fresh_procurement_job(agent, ship_symbol, job) do
    with {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ),
         :ok <- procurement_system_matches?(job.progress, live_ship),
         {:ok, recipient} <- procurement_recipient(agent, job),
         {:ok, job} <- initialize_procurement_progress(job, live_ship, recipient),
         {:ok, overview} <- Agent.agent_overview(agent) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "active",
            blocker: nil,
            blocked_reason: nil,
            last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
        )

      advance_procurement_job(agent, job, live_ship, recipient, overview.credits)
    else
      {:error, reason} -> block_procurement_job(agent, ship_symbol, reason)
    end
  end

  defp reconcile_procurement_intent(agent, ship, job, intent) do
    with {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship.symbol)
           ),
         :ok <- procurement_system_matches?(job.progress, live_ship),
         %Job{} = current_job <- Repo.get(Job, job.id),
         true <- Job.running?(current_job) or current_job.status == "paused",
         %Intent{} = current_intent <- unfinished_intent(intent.id),
         reconciliation <-
           Intents.reconcile_internal(
             agent.id,
             live_ship.symbol,
             live_ship,
             :job,
             current_intent.id,
             job.id
           ) do
      case reconciliation do
        :ok ->
          Repo.get!(Job, job.id)

        {:ok, %Job{} = completed_job} ->
          completed_job

        {:ok, %Intent{} = updated_intent} ->
          advance_procurement_after_intent(agent, current_job, updated_intent)

        {:error, reason} ->
          block_procurement_cargo_intent(intent, reason)
          mark_procurement_job_blocked(job, reason)
      end
    else
      :ok ->
        Repo.get!(Job, job.id)

      false ->
        Repo.get!(Job, job.id)

      nil ->
        Repo.get!(Job, job.id)

      {:error, reason} ->
        block_procurement_cargo_intent(intent, reason)
        mark_procurement_job_blocked(job, reason)
    end
  end

  def resume_procurement_job(agent, ship_symbol) do
    case start_procurement_job(agent, ship_symbol) do
      {:error, :cargo_operation_reconciliation_required} ->
        reconcile_procurement_job(agent, ship_symbol)

      result ->
        result
    end
  end

  @doc "Reconciles unresolved Cargo evidence for the owning Procurement Job."
  def reconcile_procurement_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "procurement"} = job <- unfinished_job(ship.id),
         %Intent{in_flight_action: action} = intent <- unfinished_job_intent(job.id),
         true <- is_map(action) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job, status: "active", blocker: nil, blocked_reason: nil)
        )

      reconcile_procurement_intent(agent, ship, job, intent)
    else
      _ -> {:error, :cargo_operation_reconciliation_required}
    end
  end

  def pause_procurement_job(%AgentRecord{} = agent, ship_symbol),
    do: pause_job_type(agent, ship_symbol, "procurement", "Procurement Job")

  def stop_procurement_job(%AgentRecord{} = agent, ship_symbol),
    do: stop_job_type(agent, ship_symbol, "procurement", "Procurement Job")

  defp pause_job_type(agent, ship_symbol, type, label) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: ^type} = job <- unfinished_job(ship.id) do
      case Repo.transaction(
             fn ->
               case stop_job_intent(agent, job) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end

               Repo.update!(
                 Ecto.Changeset.change(job,
                   status: "paused",
                   blocker: nil,
                   blocked_reason: "Paused by Operator"
                 )
               )
             end,
             mode: :immediate
           ) do
        {:ok, job} ->
          record_activity(agent, ship, "pause", "#{label} paused by Operator")
          {:ok, job}

        {:error, :cargo_operation_reconciliation_required} ->
          {:error, :cargo_operation_reconciliation_required}
      end
    else
      _ -> {:error, :procurement_job_not_configured}
    end
  end

  defp stop_job_type(agent, ship_symbol, type, label) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: ^type} = job <- unfinished_job(ship.id) do
      case Repo.transaction(
             fn ->
               case stop_job_intent(agent, job) do
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end

               terminalize_job!(job, "stopped")
             end,
             mode: :immediate
           ) do
        {:ok, _job} ->
          record_activity(agent, ship, "stop", "#{label} stopped; Ship returned to Manual")
          :ok

        {:error, :cargo_operation_reconciliation_required} ->
          {:error, :cargo_operation_reconciliation_required}
      end
    else
      _ -> {:error, :procurement_job_not_configured}
    end
  end

  defp procurement_contract(agent, job) do
    with {:ok, contracts} <- Contracts.list_contracts(agent),
         %{} = contract <- Enum.find(contracts, &(&1.id == job.progress["contract_id"])),
         true <- Contracts.active?(contract),
         %{} = term <-
           Enum.find(
             contract.terms.deliver || [],
             &(&1.trade_symbol == job.progress["trade_symbol"])
           ),
         true <- term.destination_symbol == job.progress["destination_waypoint"] do
      {:ok, contract}
    else
      nil -> {:error, :recipient_unavailable}
      false -> {:error, :recipient_conflict}
      _ -> {:error, :recipient_unavailable}
    end
  end

  defp procurement_construction(agent, job) do
    system = job.progress["construction_system"]
    waypoint = job.progress["destination_waypoint"]

    with true <- system == job.progress["target_system"],
         {:ok, construction} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_construction(agent.agent_token, system, waypoint)
           ),
         :ok <- construction_requirement_available?(construction, job.progress["trade_symbol"]) do
      record_construction_observation(agent, system, construction, "get_construction")
      {:ok, construction}
    else
      false -> {:error, :recipient_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp construction_requirement_available?(%{is_complete: true}, _trade_symbol), do: :ok

  defp construction_requirement_available?(construction, trade_symbol) do
    if Enum.any?(construction.materials || [], &(&1.trade_symbol == trade_symbol)),
      do: :ok,
      else: {:error, :recipient_conflict}
  end

  defp procurement_recipient(_agent, %{progress: %{"recipient_type" => "market"}}),
    do: {:ok, :market}

  defp procurement_recipient(agent, %{progress: %{"recipient_type" => "construction"}} = job),
    do: procurement_construction(agent, job)

  defp procurement_recipient(agent, job), do: procurement_contract(agent, job)

  defp initialize_procurement_progress(job, live_ship, recipient) do
    progress = job.progress || %{}
    held = item_units(live_ship, progress["trade_symbol"])

    cond do
      not progress["compatible_existing_cargo"] and not is_integer(progress["accepted_baseline"]) and
          held > 0 ->
        {:error, :incompatible_existing_cargo}

      is_integer(progress["accepted_baseline"]) ->
        {:ok, job}

      true ->
        baseline =
          case recipient do
            :market ->
              0

            recipient ->
              recipient_fulfilled_units(recipient, progress["trade_symbol"])
          end

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(job,
             progress: Map.put(progress, "accepted_baseline", baseline)
           )
         )}
    end
  end

  # The policy re-reads its recipient before deciding. Shared fulfillment reduces
  # outstanding work, while only correlated operation evidence counts as this Job's acceptance.
  defp advance_procurement_job(agent, job, live_ship, recipient, credits) do
    progress = procurement_counts(job.progress, live_ship, recipient)
    job = Repo.update!(Ecto.Changeset.change(job, progress: progress))

    cond do
      progress["accepted"] >= progress["requested"] or
          progress["shared_fulfilled"] >= progress["requested"] ->
        job = terminalize_job!(job, "completed")

        record_activity_by_config(
          job,
          "procurement_completed",
          "Procurement Job completed",
          progress
        )

        {:ok, job}

      progress["aboard"] > 0 ->
        start_procurement_intent(agent, job, live_ship, recipient, credits)

      true ->
        start_procurement_intent(agent, job, live_ship, recipient, credits)
    end
  end

  defp procurement_counts(progress, live_ship, recipient) do
    {accepted, shared_fulfilled, external_progress} =
      case recipient do
        :market ->
          sold = progress["sold"] || 0
          {sold, sold, 0}

        recipient ->
          fulfilled = recipient_fulfilled_units(recipient, progress["trade_symbol"])
          shared = max(fulfilled - (progress["accepted_baseline"] || fulfilled), 0)
          accepted = min(progress["accepted"] || 0, shared)
          {accepted, shared, max(shared - accepted, 0)}
      end

    requested = progress["requested"]
    remaining = max(requested - shared_fulfilled, 0)
    held = item_units(live_ship, progress["trade_symbol"])

    aboard =
      if progress["compatible_existing_cargo"],
        do: min(held, remaining),
        else: min(held, remaining)

    progress
    |> Map.put("requested", requested)
    |> Map.put("accepted", accepted)
    |> Map.put("shared_fulfilled", shared_fulfilled)
    |> Map.put("external_progress", external_progress)
    |> Map.put("aboard", max(aboard, 0))
    |> Map.put("acquired", progress["acquired"] || 0)
    |> Map.put("spent", progress["spent"] || 0)
  end

  # Procurement selects parameters; the shared Intent engine owns every Ship
  # prerequisite and mutation (navigation, dock, listing, request, recovery).
  defp start_procurement_intent(agent, job, live_ship, recipient, credits) do
    progress = job.progress

    with {:ok, attrs} <- procurement_intent_attrs(agent, live_ship, progress, recipient, credits),
         {:ok, intent} <- procurement_intent_request(agent, job, live_ship, attrs) do
      advance_procurement_after_intent(agent, job, intent)
    else
      :ok ->
        :ok

      {:ok, %Intent{} = intent} ->
        mark_procurement_job_blocked(job, intent.blocker || :procurement_operation_blocked)

      {:error, reason} ->
        mark_procurement_job_blocked(job, reason)
    end
  end

  defp procurement_intent_request(
         agent,
         job,
         live_ship,
         %{type: "deliver", target_waypoint: waypoint, parameters: parameters}
       ) do
    owner = %Intents.JobOwner{job: job}

    if get_in(parameters, ["recipient", "type"]) == "construction" do
      Intents.request(
        job_scope(agent),
        agent,
        owner,
        live_ship.symbol,
        %Intents.DeliverGoods{
          recipient: %Intents.ConstructionRecipient{
            system: get_in(parameters, ["recipient", "system"]),
            waypoint: waypoint
          },
          trade_good: parameters["trade_symbol"],
          quantity: parameters["units"]
        }
      )
    else
      Intents.request(
        job_scope(agent),
        agent,
        owner,
        live_ship.symbol,
        %Intents.DeliverGoods{
          recipient: %Intents.ContractRecipient{
            contract_id: parameters["contract_id"],
            waypoint: waypoint
          },
          trade_good: parameters["trade_symbol"],
          quantity: parameters["units"]
        }
      )
    end
  end

  defp procurement_intent_request(
         agent,
         job,
         live_ship,
         %{type: "sell", parameters: parameters} = attrs
       ) do
    constraints =
      parameters
      |> Map.take(["min_price", "min_total"])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    Intents.request(
      job_scope(agent),
      agent,
      %Intents.JobOwner{job: job},
      live_ship.symbol,
      %Intents.SellGoods{
        market: attrs.target_waypoint,
        trade_good: parameters["trade_symbol"],
        quantity: parameters["units"],
        constraints: constraints,
        parameters: %{}
      },
      live_ship
    )
  end

  defp procurement_intent_request(agent, job, live_ship, attrs) do
    with {:ok, intent} <- request_job_intent(agent, job, live_ship, attrs) do
      case Intents.reconcile_internal(
             agent.id,
             live_ship.symbol,
             live_ship,
             :job,
             intent.id,
             job.id
           ) do
        :ok -> {:ok, Repo.get!(Intent, intent.id)}
        result -> result
      end
    end
  end

  defp procurement_intent_attrs(agent, live_ship, progress, recipient, credits) do
    units = min(progress["aboard"], max(progress["requested"] - progress["shared_fulfilled"], 0))

    cond do
      units > 0 and recipient == :market ->
        {:ok,
         %{
           type: "sell",
           target_waypoint: progress["destination_waypoint"],
           parameters: %{
             "trade_symbol" => progress["trade_symbol"],
             "units" => units,
             "min_price" => progress["minimum_sale_price"],
             "min_total" => progress["minimum_sale_value"],
             "recipient" => %{"type" => "market", "waypoint" => progress["destination_waypoint"]}
           }
         }}

      units > 0 ->
        {:ok,
         %{
           type: "deliver",
           target_waypoint: progress["destination_waypoint"],
           parameters: %{
             "trade_symbol" => progress["trade_symbol"],
             "units" => units,
             "contract_id" => progress["contract_id"],
             "recipient" => %{
               "type" => progress["recipient_type"],
               "contract_id" => progress["contract_id"],
               "system" => progress["construction_system"],
               "waypoint" => progress["destination_waypoint"]
             }
           }
         }}

      true ->
        with {:ok, source} <- procurement_source(agent, live_ship, progress),
             :ok <- procurement_price_allowed?(source.good, progress),
             {:ok, units} <- procurement_purchase_units(live_ship, source.good, progress, credits) do
          {:ok,
           %{
             type: "buy",
             target_waypoint: source.waypoint,
             parameters: %{
               "trade_symbol" => progress["trade_symbol"],
               "units" => units,
               "max_price" => progress["price_ceiling"],
               "reserve_credits" => progress["reserve_credits"],
               "recipient" => %{
                 "type" => progress["recipient_type"],
                 "contract_id" => progress["contract_id"],
                 "system" => progress["construction_system"],
                 "waypoint" => progress["destination_waypoint"]
               }
             }
           }}
        end
    end
  end

  defp advance_procurement_after_intent(
         agent,
         %Job{type: type} = job,
         %Intent{status: "completed"} = intent
       )
       when type != "market_trading" do
    job = apply_procurement_intent_result(job, intent)

    if (intent.type == "deliver" and job.progress["accepted"] >= job.progress["requested"]) or
         (intent.type == "sell" and job.progress["sold"] >= job.progress["requested"]) do
      {:ok, terminalize_job!(job, "completed")}
    else
      with %Job{} = current_job <- Repo.get(Job, job.id),
           true <- Job.running?(current_job),
           {:ok, live_ship} <-
             Agent.handle_game_result(
               agent,
               SpaceTraders.API.get_ship(
                 agent.agent_token,
                 Repo.get!(Ship, current_job.ship_id).symbol
               )
             ),
           {:ok, recipient} <- procurement_recipient(agent, current_job),
           {:ok, overview} <- Agent.agent_overview(agent) do
        advance_procurement_job(agent, current_job, live_ship, recipient, overview.credits)
      else
        false -> {:ok, job}
        {:error, reason} -> mark_procurement_job_blocked(job, reason)
      end
    end
  end

  defp advance_procurement_after_intent(
         agent,
         %Job{type: "market_trading"} = job,
         %Intent{status: "completed", type: "buy"} = intent
       ) do
    candidate = intent.parameters["market_trade"]

    with {:ok, sell} <-
           SpaceTraders.Fleet.Intents.request(
             job_scope(agent),
             agent,
             %SpaceTraders.Fleet.Intents.JobOwner{job: job},
             Repo.get!(Ship, job.ship_id).symbol,
             %SpaceTraders.Fleet.Intents.SellGoods{
               market: candidate["destination_waypoint"],
               trade_good: candidate["trade_symbol"],
               quantity: candidate["units"],
               constraints: %{min_price: candidate["sell_price"]},
               parameters: %{market_trade: candidate}
             }
           ) do
      advance_procurement_after_intent(agent, job, sell)
    end
  end

  defp advance_procurement_after_intent(
         agent,
         %Job{type: "market_trading"} = job,
         %Intent{status: "completed", type: "sell"} = intent
       ) do
    candidate = intent.parameters["market_trade"]
    units = candidate["units"]
    profit = (candidate["sell_price"] - candidate["purchase_price"]) * units

    progress =
      job.progress
      |> Map.update!("completed_trades", &(&1 + 1))
      |> Map.update!("realized_gross_profit", &(&1 + profit))
      |> Map.update!(
        "realized_net_profit",
        &(&1 + profit - (candidate["estimated_fuel_cost"] || 0))
      )

    job = Repo.update!(Ecto.Changeset.change(job, status: "active", progress: progress))
    start_market_trading_job(agent, Repo.get!(Ship, job.ship_id).symbol)
  end

  defp advance_procurement_after_intent(
         _agent,
         %Job{type: "market_trading"} = job,
         %Intent{} = intent
       ) do
    blocker = intent.blocker || job_blocker(:market_trade_intent_blocked)

    {:error,
     Repo.update!(
       Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
     )}
  end

  defp advance_procurement_after_intent(_agent, job, %Intent{status: "waiting"} = intent) do
    case with_current_intent(intent, fn _current_intent ->
           case Repo.get(Job, job.id) do
             %Job{} = current when current.status == "active" ->
               {:ok, Repo.update!(Ecto.Changeset.change(current, status: "waiting"))}

             %Job{} = current ->
               {:ok, current}

             nil ->
               :ok
           end
         end) do
      :intent_no_longer_owned -> :ok
      result -> result
    end
  end

  defp advance_procurement_after_intent(_agent, job, %Intent{} = intent),
    do: mark_procurement_job_blocked(job, intent.blocker || :procurement_operation_blocked)

  defp apply_procurement_intent_result(job, %Intent{id: id} = intent) do
    if job.progress["last_applied_intent_id"] == id do
      job
    else
      progress =
        case intent do
          %Intent{type: "buy", last_action_result: result} ->
            units = get_in(result, ["transaction", "units"]) || 0
            total_price = get_in(result, ["transaction", "total_price"]) || 0

            job.progress
            |> Map.update("acquired", units, &(&1 + units))
            |> Map.update("spent", total_price, &(&1 + total_price))

          %Intent{type: "sell", last_action_result: result} ->
            units = get_in(result, ["transaction", "units"]) || result["units"] || 0

            job.progress
            |> Map.update("sold", units, &(&1 + units))
            |> Map.update("accepted", units, &(&1 + units))

          %Intent{type: "deliver", last_action_result: result} ->
            if is_integer(result["units"]),
              do: Map.update(job.progress, "accepted", result["units"], &(&1 + result["units"])),
              else: job.progress

          _ ->
            job.progress
        end

      Repo.update!(
        Ecto.Changeset.change(job, progress: Map.put(progress, "last_applied_intent_id", id))
      )
    end
  end

  @doc false
  def recipient_fulfilled_units(%{terms: terms}, trade_symbol) do
    case Enum.find(terms.deliver || [], &(&1.trade_symbol == trade_symbol)) do
      %{units_fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  def recipient_fulfilled_units(%{materials: materials}, trade_symbol) do
    case Enum.find(materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp apply_unapplied_procurement_intent!(job) do
    intent = last_completed_job_intent(job.id)

    if intent, do: apply_procurement_intent_result(job, intent), else: job
  end

  defp procurement_source(agent, live_ship, progress) do
    systems = progress["source_systems"]
    systems = if systems == [], do: [live_ship.nav.system_symbol], else: systems

    case Enum.find(systems, &(&1 != live_ship.nav.system_symbol)) do
      nil ->
        Enum.reduce_while(systems, {:error, :source_market_unavailable}, fn system, _ ->
          with {:ok, waypoints} <- fetch_waypoint_pages(agent.agent_token, system),
               {:ok, source} <-
                 procurement_market_source(agent, live_ship, waypoints, progress["trade_symbol"]) do
            {:halt, {:ok, source}}
          else
            {:error, :source_market_unavailable} ->
              {:cont, {:error, :source_market_unavailable}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      source_system ->
        # Market reads are scoped to the Ship's current System. Do not inspect a
        # remote waypoint through that local route until inter-System routing exists.
        {:error,
         {:remote_source_system_unsupported,
          %{current_system: live_ship.nav.system_symbol, source_system: source_system}}}
    end
  end

  defp procurement_system_matches?(%{"target_system" => system}, live_ship)
       when system == live_ship.nav.system_symbol,
       do: :ok

  defp procurement_system_matches?(%{"target_system" => system}, live_ship) do
    {:error,
     {:fixed_system_changed,
      %{configured_system: system, current_system: live_ship.nav.system_symbol}}}
  end

  defp procurement_system_matches?(_progress, _live_ship),
    do: {:error, :current_system_unavailable}

  defp procurement_market_source(agent, live_ship, waypoints, trade_symbol) do
    Enum.reduce_while(waypoints, {:error, :source_market_unavailable}, fn waypoint, _result ->
      if market_waypoint?(waypoint) == :ok do
        case market_for_ship(agent, live_ship, waypoint.symbol) do
          {:ok, market} ->
            case Enum.find(market.trade_goods || [], &(&1.symbol == trade_symbol)) do
              nil -> {:cont, {:error, :source_market_unavailable}}
              good -> {:halt, {:ok, %{waypoint: waypoint.symbol, good: good}}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      else
        {:cont, {:error, :source_market_unavailable}}
      end
    end)
  end

  defp procurement_price_allowed?(_good, %{"price_ceiling" => nil}), do: :ok

  defp procurement_price_allowed?(%{purchase_price: price}, %{"price_ceiling" => ceiling})
       when price <= ceiling,
       do: :ok

  defp procurement_price_allowed?(_, _), do: {:error, :price_ceiling_exceeded}

  defp block_procurement_cargo_intent(intent, reason) do
    case transition_intent(intent,
           status: "blocked",
           blocker: job_blocker(reason),
           in_flight_action:
             if(ambiguous_cargo_operation_error?(reason),
               do: intent.in_flight_action,
               else: nil
             ),
           last_action_result: %{
             "kind" => intent.type,
             "error" => cargo_error_message(reason)
           }
         ) do
      {:ok, intent} -> intent
      :intent_no_longer_owned -> :ok
    end
  end

  @doc false
  def transaction_evidence(transaction) do
    %{
      "type" => transaction.type,
      "trade_symbol" => transaction.trade_symbol,
      "ship_symbol" => transaction.ship_symbol,
      "waypoint_symbol" => transaction.waypoint_symbol,
      "units" => transaction.units,
      "price_per_unit" => transaction.price_per_unit,
      "total_price" => transaction.total_price
    }
  end

  @doc false
  def find_deliverable(%{terms: %{deliver: deliver}}, trade_symbol) do
    Enum.find(deliver || [], &(&1.trade_symbol == trade_symbol))
  end

  def find_deliverable(_contract, _trade_symbol), do: nil

  @doc false
  def contract_delivery_evidence(contract, trade_symbol) do
    case find_deliverable(contract, trade_symbol) do
      nil -> %{"trade_symbol" => trade_symbol, "accepted" => "unavailable"}
      delivery -> %{"trade_symbol" => trade_symbol, "units_fulfilled" => delivery.units_fulfilled}
    end
  end

  @doc false
  def construction_delivery_evidence(construction, trade_symbol) do
    case Enum.find(construction.materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: fulfilled} when is_integer(fulfilled) ->
        %{"trade_symbol" => trade_symbol, "units_fulfilled" => fulfilled}

      _ ->
        %{"trade_symbol" => trade_symbol, "accepted" => "unavailable"}
    end
  end

  defp procurement_purchase_units(live_ship, good, progress, credits) do
    affordable =
      affordable_cargo_units(
        max(credits - progress["reserve_credits"], 0),
        good.purchase_price
      )

    free = max(live_ship.cargo.capacity - live_ship.cargo.units, 0)
    needed = progress["requested"] - progress["accepted"]
    units = min(min(free, good.trade_volume), min(needed, affordable))
    if units > 0, do: {:ok, units}, else: {:error, :spending_or_cargo_constraint}
  end

  defp block_procurement_job(agent, ship_symbol, reason) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "procurement"} = job <- unfinished_job(ship.id) do
      mark_procurement_job_blocked(job, reason)
      {:error, {:procurement_job_blocked, reason}}
    else
      _ -> {:error, :procurement_job_not_configured}
    end
  end

  defp mark_procurement_job_blocked(job, %JobBlocker{} = blocker) do
    job =
      Repo.update!(
        Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
      )

    record_activity_by_config(job, "procurement_job_blocked", "Procurement Job blocked", %{
      "block" => blocker.evidence
    })

    {:error, blocker}
  end

  defp mark_procurement_job_blocked(job, reason) do
    blocker = %{
      job_blocker(reason)
      | summary: "Procurement Job cannot progress: #{blocker_reason(reason)}."
    }

    job =
      Repo.update!(
        Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
      )

    record_activity_by_config(job, "procurement_job_blocked", "Procurement Job blocked", %{
      "block" => inspect(reason)
    })

    {:error, reason}
  end

  @doc "Starts or resumes a Construction Supply Job from fresh project, Ship, and credit state."
  def start_construction_supply_job(%AgentRecord{} = agent, ship_symbol) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "construction_supply"} = job <- unfinished_job(ship.id),
         nil <- unfinished_manual_intent(ship.id),
         nil <- unresolved_cargo_intent(ship.id) do
      job = apply_unapplied_construction_supply_intent!(job)

      case unfinished_job_intent(job.id) do
        %Intent{} = intent -> reconcile_construction_supply_intent(agent, ship, job, intent)
        nil -> start_fresh_construction_supply_job(agent, ship_symbol, job)
      end
    else
      nil ->
        {:error, :construction_supply_job_not_configured}

      %Job{} ->
        {:error, :construction_supply_job_not_configured}

      %Intent{in_flight_action: action} when is_map(action) ->
        {:error, :cargo_operation_reconciliation_required}

      %Intent{} ->
        {:error, :intents_active}

      :cargo_operation_reconciliation_required ->
        {:error, :cargo_operation_reconciliation_required}

      {:error, reason} ->
        block_construction_supply_job(agent, ship_symbol, reason)
    end
  end

  def resume_construction_supply_job(agent, ship_symbol) do
    case start_construction_supply_job(agent, ship_symbol) do
      {:error, :cargo_operation_reconciliation_required} ->
        reconcile_construction_supply_job(agent, ship_symbol)

      result ->
        result
    end
  end

  @doc "Reconciles unresolved Cargo evidence for the owning Construction Supply Job."
  def reconcile_construction_supply_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "construction_supply"} = job <- unfinished_job(ship.id),
         %Intent{in_flight_action: action} = intent <- unfinished_job_intent(job.id),
         true <- is_map(action) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job, status: "active", blocker: nil, blocked_reason: nil)
        )

      reconcile_construction_supply_intent(agent, ship, job, intent)
    else
      _ -> {:error, :cargo_operation_reconciliation_required}
    end
  end

  def pause_construction_supply_job(%AgentRecord{} = agent, ship_symbol),
    do: pause_job_type(agent, ship_symbol, "construction_supply", "Construction Supply Job")

  def stop_construction_supply_job(%AgentRecord{} = agent, ship_symbol),
    do: stop_job_type(agent, ship_symbol, "construction_supply", "Construction Supply Job")

  defp start_fresh_construction_supply_job(agent, ship_symbol, job) do
    with {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ),
         :ok <- procurement_system_matches?(job.progress, live_ship),
         {:ok, construction} <- construction_supply_construction(agent, job),
         {:ok, job} <- initialize_construction_supply_progress(job, live_ship, construction),
         {:ok, overview} <- Agent.agent_overview(agent) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "active",
            blocker: nil,
            blocked_reason: nil,
            last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
        )

      advance_construction_supply_job(agent, job, live_ship, construction, overview.credits)
    else
      {:error, reason} -> block_construction_supply_job(agent, ship_symbol, reason)
    end
  end

  defp construction_supply_construction(agent, job) do
    Agent.handle_game_result(
      agent,
      SpaceTraders.API.get_construction(
        agent.agent_token,
        job.progress["construction_system"],
        job.progress["construction_waypoint"]
      )
    )
  end

  defp initialize_construction_supply_progress(job, live_ship, construction) do
    requirements = construction_supply_requirements(construction)

    cond do
      requirements == [] and not construction.is_complete ->
        {:error, :construction_requirements_unavailable}

      not job.progress["compatible_existing_cargo"] and
          Enum.any?(requirements, &(item_units(live_ship, &1["trade_symbol"]) > 0)) ->
        {:error, :incompatible_existing_cargo}

      true ->
        baseline = Map.new(requirements, &{&1["trade_symbol"], &1["fulfilled"]})

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(job,
             progress:
               job.progress
               |> Map.put_new("fulfilled_baseline", baseline)
               |> Map.put("requirements", requirements)
           )
         )}
    end
  end

  defp advance_construction_supply_job(agent, job, live_ship, construction, credits) do
    progress = construction_supply_counts(job.progress, live_ship, construction)
    job = Repo.update!(Ecto.Changeset.change(job, progress: progress))

    if construction.is_complete or construction_supply_remaining(progress) == 0 do
      {:ok, terminalize_job!(job, "completed")}
    else
      start_construction_supply_intent(agent, job, live_ship, construction, credits)
    end
  end

  defp construction_supply_counts(progress, live_ship, construction) do
    requirements = construction_supply_requirements(construction)
    baseline = progress["fulfilled_baseline"] || %{}
    accepted = progress["accepted"] || %{}

    external_progress =
      Map.new(requirements, fn requirement ->
        symbol = requirement["trade_symbol"]

        shared =
          max(requirement["fulfilled"] - Map.get(baseline, symbol, requirement["fulfilled"]), 0)

        {symbol, max(shared - Map.get(accepted, symbol, 0), 0)}
      end)

    committed =
      Map.new(requirements, fn requirement ->
        symbol = requirement["trade_symbol"]
        remaining = max(requirement["required"] - requirement["fulfilled"], 0)
        {symbol, min(item_units(live_ship, symbol), remaining)}
      end)

    remaining =
      Map.new(requirements, fn requirement ->
        {requirement["trade_symbol"], max(requirement["required"] - requirement["fulfilled"], 0)}
      end)

    progress
    |> Map.put("requirements", requirements)
    |> Map.put("remaining", remaining)
    |> Map.put("external_progress", external_progress)
    |> Map.put("committed_cargo", committed)
  end

  defp construction_supply_requirements(construction) do
    Enum.map(construction.materials || [], fn material ->
      %{
        "trade_symbol" => material.trade_symbol,
        "required" => material.required,
        "fulfilled" => material.fulfilled
      }
    end)
  end

  defp construction_supply_remaining(progress) do
    Enum.reduce(progress["requirements"] || [], 0, fn requirement, total ->
      total + max(requirement["required"] - requirement["fulfilled"], 0)
    end)
  end

  defp start_construction_supply_intent(agent, job, live_ship, construction, credits) do
    with {:ok, attrs} <-
           construction_supply_intent_attrs(agent, job.progress, live_ship, construction, credits),
         {:ok, intent} <- construction_supply_intent_request(agent, job, live_ship, attrs) do
      advance_construction_supply_after_intent(agent, job, intent)
    else
      :ok ->
        :ok

      {:ok, %Intent{} = intent} ->
        mark_construction_supply_job_blocked(
          job,
          intent.blocker || :construction_supply_operation_blocked
        )

      {:error, reason} ->
        mark_construction_supply_job_blocked(job, reason)
    end
  end

  defp construction_supply_intent_request(
         agent,
         job,
         live_ship,
         %{type: "deliver", target_waypoint: waypoint, parameters: parameters}
       ) do
    Intents.request(
      job_scope(agent),
      agent,
      %Intents.JobOwner{job: job},
      live_ship.symbol,
      %Intents.DeliverGoods{
        recipient: %Intents.ConstructionRecipient{
          system: get_in(parameters, ["recipient", "system"]),
          waypoint: waypoint
        },
        trade_good: parameters["trade_symbol"],
        quantity: parameters["units"]
      },
      live_ship
    )
  end

  defp construction_supply_intent_request(agent, job, live_ship, attrs) do
    with {:ok, intent} <- request_job_intent(agent, job, live_ship, attrs) do
      Intents.reconcile_internal(agent.id, live_ship.symbol, live_ship, :job, intent.id, job.id)
    end
  end

  defp construction_supply_intent_attrs(agent, progress, live_ship, construction, credits) do
    if live_ship.cargo.units < live_ship.cargo.capacity do
      case construction_supply_purchase_attrs(agent, progress, live_ship, construction, credits) do
        {:ok, _attrs} = purchase ->
          purchase

        {:error, reason} ->
          case construction_supply_delivery_attrs(progress, live_ship) do
            {:ok, _attrs} = delivery -> delivery
            {:error, _} -> {:error, reason}
          end
      end
    else
      construction_supply_delivery_attrs(progress, live_ship)
    end
  end

  defp construction_supply_delivery_attrs(progress, live_ship) do
    case Enum.find(progress["requirements"], fn requirement ->
           item_units(live_ship, requirement["trade_symbol"]) > 0 and
             requirement["fulfilled"] < requirement["required"]
         end) do
      %{"trade_symbol" => symbol, "required" => required, "fulfilled" => fulfilled} ->
        {:ok,
         %{
           type: "deliver",
           target_waypoint: progress["construction_waypoint"],
           parameters: %{
             "trade_symbol" => symbol,
             "units" => min(item_units(live_ship, symbol), required - fulfilled),
             "recipient" => %{
               "type" => "construction",
               "system" => progress["construction_system"],
               "waypoint" => progress["construction_waypoint"]
             }
           }
         }}

      nil ->
        {:error, :no_executable_construction_supply_batch}
    end
  end

  defp construction_supply_purchase_attrs(agent, progress, live_ship, _construction, credits) do
    with {:ok, source} <- construction_supply_source(agent, live_ship, progress),
         :ok <- construction_supply_cost_allowed?(progress, source.good, credits),
         {:ok, units} <-
           construction_supply_purchase_units(
             live_ship,
             source.good,
             source.remaining,
             progress,
             credits
           ) do
      {:ok,
       %{
         type: "buy",
         target_waypoint: source.waypoint,
         parameters: %{
           "trade_symbol" => source.symbol,
           "units" => units,
           "reserve_credits" => progress["reserve_credits"],
           "max_price" => source.good.purchase_price,
           "recipient" => %{
             "type" => "construction",
             "system" => progress["construction_system"],
             "waypoint" => progress["construction_waypoint"]
           }
         }
       }}
    end
  end

  defp construction_supply_source(agent, live_ship, progress) do
    with {:ok, waypoints} <- fetch_waypoint_pages(agent.agent_token, live_ship.nav.system_symbol) do
      progress["requirements"]
      |> Enum.filter(fn requirement ->
        requirement["fulfilled"] + item_units(live_ship, requirement["trade_symbol"]) <
          requirement["required"]
      end)
      |> Enum.reduce_while({:error, :source_market_unavailable}, fn requirement, _result ->
        case procurement_market_source(agent, live_ship, waypoints, requirement["trade_symbol"]) do
          {:ok, source} ->
            {:halt,
             {:ok,
              Map.merge(source, %{
                symbol: requirement["trade_symbol"],
                remaining:
                  requirement["required"] - requirement["fulfilled"] -
                    item_units(live_ship, requirement["trade_symbol"])
              })}}

          {:error, :source_market_unavailable} ->
            {:cont, {:error, :source_market_unavailable}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp construction_supply_cost_allowed?(progress, good, credits) do
    maximum = progress["maximum_total_cost"]
    remaining_budget = if maximum, do: maximum - progress["spent"], else: credits

    if remaining_budget >= good.purchase_price,
      do: :ok,
      else: {:error, :maximum_total_cost_exceeded}
  end

  defp construction_supply_purchase_units(live_ship, good, needed, progress, credits) do
    credit_budget = max(credits - progress["reserve_credits"], 0)

    total_budget =
      case progress["maximum_total_cost"] do
        nil -> credit_budget
        maximum -> min(credit_budget, max(maximum - progress["spent"], 0))
      end

    units =
      min(
        min(max(live_ship.cargo.capacity - live_ship.cargo.units, 0), good.trade_volume),
        min(needed, affordable_cargo_units(total_budget, good.purchase_price))
      )

    if units > 0, do: {:ok, units}, else: {:error, :spending_or_cargo_constraint}
  end

  defp reconcile_construction_supply_intent(agent, ship, job, intent) do
    with {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship.symbol)
           ),
         :ok <- procurement_system_matches?(job.progress, live_ship),
         %Job{} = current_job <- Repo.get(Job, job.id),
         true <- Job.running?(current_job) or current_job.status == "paused",
         %Intent{} = current_intent <- unfinished_intent(intent.id),
         {:ok, current_intent} <-
           Intents.reconcile_internal(
             agent.id,
             live_ship.symbol,
             live_ship,
             :job,
             current_intent.id,
             job.id
           ) do
      advance_construction_supply_after_intent(agent, current_job, current_intent)
    else
      false ->
        :ok

      nil ->
        :ok

      {:error, reason} ->
        block_procurement_cargo_intent(intent, reason)
        mark_construction_supply_job_blocked(job, reason)
    end
  end

  defp advance_construction_supply_after_intent(
         agent,
         job,
         %Intent{status: "completed"} = intent
       ) do
    job = apply_construction_supply_intent_result(job, intent)

    with %Job{} = current <- Repo.get(Job, job.id),
         true <- Job.running?(current),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, Repo.get!(Ship, current.ship_id).symbol)
           ),
         {:ok, construction} <- construction_supply_construction(agent, current),
         {:ok, overview} <- Agent.agent_overview(agent) do
      advance_construction_supply_job(agent, current, live_ship, construction, overview.credits)
    else
      false -> {:ok, job}
      {:error, reason} -> mark_construction_supply_job_blocked(job, reason)
    end
  end

  defp advance_construction_supply_after_intent(_agent, job, %Intent{status: "waiting"}),
    do: {:ok, Repo.update!(Ecto.Changeset.change(job, status: "waiting"))}

  defp advance_construction_supply_after_intent(_agent, job, %Intent{} = intent),
    do:
      mark_construction_supply_job_blocked(
        job,
        intent.blocker || :construction_supply_operation_blocked
      )

  defp apply_construction_supply_intent_result(job, %Intent{id: id} = intent) do
    if job.progress["last_applied_intent_id"] == id do
      job
    else
      progress =
        case intent do
          %Intent{type: "buy", last_action_result: result} ->
            symbol = intent.parameters["trade_symbol"]
            units = get_in(result, ["transaction", "units"]) || 0
            cost = get_in(result, ["transaction", "total_price"]) || 0

            job.progress
            |> update_in(["acquired", symbol], fn value -> (value || 0) + units end)
            |> Map.update("spent", cost, &(&1 + cost))

          %Intent{type: "deliver", last_action_result: result} ->
            symbol = intent.parameters["trade_symbol"]
            units = result["units"] || 0

            job.progress
            |> update_in(["accepted", symbol], fn value -> (value || 0) + units end)
            |> Map.update("trips", 1, &(&1 + 1))

          _ ->
            job.progress
        end

      Repo.update!(
        Ecto.Changeset.change(job, progress: Map.put(progress, "last_applied_intent_id", id))
      )
    end
  end

  defp apply_unapplied_construction_supply_intent!(job) do
    intent = last_completed_job_intent(job.id)

    if intent, do: apply_construction_supply_intent_result(job, intent), else: job
  end

  defp block_construction_supply_job(agent, ship_symbol, reason) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "construction_supply"} = job <- unfinished_job(ship.id) do
      mark_construction_supply_job_blocked(job, reason)
      {:error, {:construction_supply_job_blocked, reason}}
    else
      _ -> {:error, :construction_supply_job_not_configured}
    end
  end

  defp mark_construction_supply_job_blocked(job, reason) do
    blocker = %{
      job_blocker(reason)
      | summary: "Construction Supply Job cannot progress: #{blocker_reason(reason)}."
    }

    job =
      Repo.update!(
        Ecto.Changeset.change(job, status: "blocked", blocker: blocker, blocked_reason: nil)
      )

    record_activity_by_config(
      job,
      "construction_supply_job_blocked",
      "Construction Supply Job blocked",
      %{"block" => inspect(reason)}
    )

    {:error, reason}
  end

  @doc "Starts a System Exploration Job and acquires its current public baseline."
  def start_explorer_job(%AgentRecord{} = agent, ship_symbol) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "explorer"} = job <- unfinished_job(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "active",
            blocker: nil,
            blocked_reason: nil,
            last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
        )

      advance_explorer_job(agent, job, live_ship)
    else
      nil -> {:error, :explorer_job_not_configured}
      %Job{} -> {:error, :explorer_job_not_configured}
      {:error, reason} -> block_explorer_job(agent, ship_symbol, reason)
    end
  end

  @doc "Pauses a System Exploration Job without changing its fixed target."
  def pause_explorer_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "explorer"} = job <- unfinished_job(ship.id) do
      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            status: "paused",
            blocker: nil,
            blocked_reason: "Paused by Operator"
          )
        )

      record_activity(agent, ship, "pause", "System Exploration Job paused by Operator")
      {:ok, job}
    else
      _ -> {:error, :explorer_job_not_configured}
    end
  end

  @doc "Resumes a System Exploration Job from authoritative game state."
  def resume_explorer_job(%AgentRecord{} = agent, ship_symbol),
    do: start_explorer_job(agent, ship_symbol)

  @doc "Stops a System Exploration Job and preserves its terminal history."
  def stop_explorer_job(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{type: "explorer"} = job <- unfinished_job(ship.id) do
      terminalize_job!(job, "stopped")

      record_activity(
        agent,
        ship,
        "stop",
        "System Exploration Job stopped; Ship returned to Manual"
      )

      :ok
    else
      _ -> {:error, :explorer_job_not_configured}
    end
  end

  @doc "Reconciles an Explorer Job after an explicit Operator retry."
  def reconcile_explorer_job(%AgentRecord{} = agent, ship_symbol),
    do: start_explorer_job(agent, ship_symbol)

  @doc "Reconciles public baseline acquisition for a System Exploration Job."
  def advance_explorer_job(
        %AgentRecord{agent_token: token} = agent,
        %Job{type: "explorer"} = job,
        live_ship
      )
      when is_binary(token) and token != "" do
    system = get_in(job.progress || %{}, ["target_system"])

    with true <- is_binary(system),
         {:ok, job} <- scan_explorer_waypoints(agent, token, job, live_ship),
         {:ok, waypoints} <- fetch_waypoint_pages(token, system),
         :ok <- ensure_explorer_waypoints(waypoints),
         {:ok, job} <- acquire_explorer_baseline(agent, token, job, live_ship, system, waypoints),
         {:ok, final_waypoints} <- fetch_waypoint_pages(token, system),
         :ok <- ensure_explorer_waypoints(final_waypoints),
         {:ok, job} <-
           acquire_explorer_baseline(agent, token, job, live_ship, system, final_waypoints) do
      coverage = Intelligence.waypoint_coverage(agent, system, final_waypoints)
      missing = Map.new(coverage, fn {symbol, result} -> {symbol, result.missing} end)

      job =
        Repo.update!(
          Ecto.Changeset.change(job,
            progress:
              Map.merge(job.progress || %{}, %{
                "coverage" => missing,
                "methods" => get_in(job.progress || %{}, ["methods"]) || %{},
                "viability" => get_in(job.progress || %{}, ["viability"]) || %{}
              })
          )
        )

      if Enum.all?(coverage, fn {_symbol, result} -> result.complete? end) do
        job =
          Repo.update!(
            Ecto.Changeset.change(job,
              status: "completed",
              blocker: nil,
              blocked_reason: nil,
              last_action_result: %{"kind" => "baseline_acquired"},
              finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
            )
          )

        record_activity_by_config(
          job,
          "explorer_job_completed",
          "System Exploration Job completed",
          %{
            "system" => system,
            "coverage" => missing
          }
        )

        {:ok, job}
      else
        block_explorer_job(
          job,
          {:unresolved_coverage, missing, get_in(job.progress || %{}, ["viability"]) || %{}}
        )
      end
    else
      {:waiting, job} -> {:ok, job}
      false -> block_explorer_job(job, :target_system_missing)
      {:error, reason} -> block_explorer_job(job, reason)
    end
  end

  defp scan_explorer_waypoints(agent, token, job, live_ship) do
    cond do
      cooldown_active?(live_ship) ->
        {:waiting, job} = wait_for_explorer_cooldown(agent, job, live_ship, "cooldown")
        {:waiting, job}

      get_in(job.progress || %{}, ["methods", "scan"]) == "completed" ->
        {:ok, job}

      not sensor_capability?(live_ship) ->
        {:ok, record_explorer_method(job, "scan", "unavailable", "sensor_capability_missing")}

      true ->
        action = %{"kind" => "scan", "expected" => %{"cooldown_or_observation" => true}}
        job = Repo.update!(Ecto.Changeset.change(job, status: "active", in_flight_action: action))

        case Agent.handle_game_result(
               agent,
               SpaceTraders.API.scan_waypoints(token, live_ship.symbol)
             ) do
          {:ok, %{waypoints: waypoints} = result} ->
            Enum.each(
              waypoints,
              &Intelligence.observe_waypoint(agent, &1, source: "scan_waypoints")
            )

            job = record_explorer_method(job, "scan", "completed", nil)

            if cooldown_active?(%{cooldown: result.cooldown}) do
              wait_for_explorer_cooldown(
                agent,
                job,
                %{live_ship | cooldown: result.cooldown},
                "scan"
              )
            else
              {:ok, Repo.update!(Ecto.Changeset.change(job, in_flight_action: nil))}
            end

          {:error, reason} ->
            {:ok,
             job
             |> record_explorer_method("scan", "unavailable", inspect(reason))
             |> then(&Repo.update!(Ecto.Changeset.change(&1, in_flight_action: nil)))}
        end
    end
  end

  defp ensure_explorer_waypoints([]), do: {:error, :target_system_waypoints_unavailable}
  defp ensure_explorer_waypoints(_waypoints), do: :ok

  defp sensor_capability?(%{mounts: mounts}) do
    Enum.any?(mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_SENSOR_ARRAY"))
  end

  defp sensor_capability?(_), do: false

  defp acquire_explorer_baseline(agent, token, job, live_ship, system, waypoints) do
    Enum.reduce_while(waypoints, {:ok, job}, fn waypoint, {:ok, job} ->
      missing =
        get_in(Intelligence.waypoint_coverage(agent, system, [waypoint]), [
          waypoint.symbol,
          :missing
        ])

      if missing == [] do
        {:cont, {:ok, record_explorer_method(job, waypoint.symbol, "reused_public", nil)}}
      else
        case SpaceTraders.API.get_waypoint(token, system, waypoint.symbol) do
          {:ok, full_waypoint} ->
            with :ok <- observe_explorer_waypoint(agent, full_waypoint),
                 :ok <- acquire_explorer_market(agent, token, system, live_ship, full_waypoint) do
              job = record_explorer_method(job, waypoint.symbol, "public_read", nil)
              {:cont, maybe_chart_explorer_waypoint(agent, token, job, live_ship, full_waypoint)}
            else
              {:error, reason} ->
                {:cont,
                 {:ok,
                  record_explorer_method(
                    job,
                    waypoint.symbol,
                    "public_read_failed",
                    inspect(reason)
                  )}}
            end

          {:error, reason} ->
            {:cont,
             {:ok,
              record_explorer_method(job, waypoint.symbol, "public_read_failed", inspect(reason))}}
        end
      end
    end)
  end

  # Charting is optional baseline enrichment, but its request changes game state.
  # Persist the exact method first so restart recovery never blindly repeats it.
  defp maybe_chart_explorer_waypoint(agent, token, job, live_ship, waypoint) do
    if live_ship.nav.status in ["DOCKED", "IN_ORBIT"] and
         live_ship.nav.waypoint_symbol == waypoint.symbol and is_nil(waypoint.chart) do
      action = %{"kind" => "chart", "waypoint" => waypoint.symbol}
      job = Repo.update!(Ecto.Changeset.change(job, in_flight_action: action))

      case Agent.handle_game_result(agent, SpaceTraders.API.create_chart(token, live_ship.symbol)) do
        {:ok, %{waypoint: charted_waypoint}} ->
          :ok = observe_explorer_waypoint(agent, charted_waypoint)

          {:ok,
           job
           |> record_explorer_method(waypoint.symbol, "chart", nil)
           |> then(&Repo.update!(Ecto.Changeset.change(&1, in_flight_action: nil)))}

        {:error, reason} ->
          {:ok,
           job
           |> record_explorer_method(waypoint.symbol, "chart_unavailable", inspect(reason))
           |> then(&Repo.update!(Ecto.Changeset.change(&1, in_flight_action: nil)))}
      end
    else
      {:ok, job}
    end
  end

  defp wait_for_explorer_cooldown(agent, job, live_ship, method) do
    maybe_schedule_live_cooldown(agent, live_ship, job.id)

    {:waiting,
     Repo.update!(
       Ecto.Changeset.change(job,
         status: "waiting",
         in_flight_action: %{"kind" => "cooldown", "method" => method}
       )
     )}
  end

  defp record_explorer_method(job, key, method, viability) do
    progress = job.progress || %{}
    methods = Map.put(progress["methods"] || %{}, key, method)

    viability =
      if is_nil(viability),
        do: Map.delete(progress["viability"] || %{}, key),
        else: Map.put(progress["viability"] || %{}, key, viability)

    Repo.update!(
      Ecto.Changeset.change(job,
        progress: Map.merge(progress, %{"methods" => methods, "viability" => viability})
      )
    )
  end

  defp observe_explorer_waypoint(agent, waypoint) do
    case Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoint") do
      {:ok, _observation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp acquire_explorer_market(agent, token, system, live_ship, waypoint) do
    if market_waypoint?(waypoint) == :ok do
      with {:ok, market} <- SpaceTraders.API.get_market(token, system, waypoint.symbol),
           {:ok, _observation} <-
             Intelligence.observe_market(agent, system, market,
               source: "get_market",
               observing_ship_symbol: observing_ship_at(live_ship, waypoint.symbol)
             ) do
        :ok
      end
    else
      :ok
    end
  end

  defp observing_ship_at(%{symbol: ship_symbol, nav: %{waypoint_symbol: waypoint}}, waypoint),
    do: ship_symbol

  defp observing_ship_at(_live_ship, _waypoint), do: nil

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

  @doc false
  @spec continue_job_after_intent(SpaceTraders.Agent.Agent.t(), Job.t(), Intent.t(), map()) ::
          term()
  def continue_job_after_intent(
        %AgentRecord{} = agent,
        %Job{type: "outfitting"} = job,
        intent,
        _live_ship
      ),
      do: advance_outfitting_after_intent(agent, job, intent)

  def continue_job_after_intent(agent, %Job{type: "miner"} = job, intent, live_ship),
    do: advance_miner_after_intent(agent, job, intent, live_ship)

  def continue_job_after_intent(
        agent,
        %Job{type: "construction_supply"} = job,
        intent,
        _live_ship
      ),
      do: advance_construction_supply_after_intent(agent, job, intent)

  def continue_job_after_intent(agent, job, intent, _live_ship),
    do: advance_procurement_after_intent(agent, job, intent)

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
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
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
      %Intent{} -> {:error, :intents_active}
      {:error, reason} -> block_miner_job(agent, ship_symbol, reason)
    end
  end

  @doc false
  def owned_ship(agent, symbol) do
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
        blocked_reason: terminal_job_reason(status),
        in_flight_action: nil,
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )
    )
  end

  @doc false
  def unfinished_job(ship_id) do
    Repo.one(
      from job in Job,
        where: job.ship_id == ^ship_id and job.status not in ^@terminal_job_states
    )
  end

  defp preempt_miner_job(agent, ship, reason) do
    case unfinished_job(ship.id) do
      %Job{} = config ->
        preempt_job_without_unresolved_operation(agent, ship, config, reason)

      _ ->
        :ok
    end
  end

  defp preempt_job_without_unresolved_operation(agent, ship, config, reason) do
    Repo.transaction(
      fn ->
        current = Repo.get(Job, config.id)

        cond do
          is_nil(current) ->
            :ok

          is_map(current.in_flight_action) and not cargo_preemption?(reason) ->
            Repo.rollback(:job_action_reconciliation_required)

          match?(
            %Intent{in_flight_action: action} when is_map(action),
            unfinished_job_intent(current.id)
          ) ->
            Repo.rollback(:job_action_reconciliation_required)

          current.status in @running_job_states ->
            Repo.update!(
              Ecto.Changeset.change(current,
                status: "paused",
                blocker: nil,
                blocked_reason: preemption_message(reason)
              )
            )

            message = preemption_message(reason)
            record_activity(agent, ship, "manual_override", message, %{"recovery" => "resume"})
            :ok

          true ->
            :ok
        end
      end,
      mode: :immediate
    )
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp preemption_message({:manual_override, action}), do: "Paused by direct #{action}"
  defp preemption_message(:manual_override), do: "Paused by a direct Ship action"
  defp preemption_message(:configuration_changed), do: "Paused because configuration changed"
  defp preemption_message(reason), do: "Paused: #{inspect(reason)}"

  defp cargo_preemption?({:manual_override, action}) when is_binary(action),
    do: action in ["buy goods", "sell goods", "deliver goods"]

  defp cargo_preemption?(_reason), do: false

  @doc false
  def preempt_miner_job_for(agent, ship_symbol, reason) do
    with :ok <- Agent.execution_allowed?(agent) do
      case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
        %Ship{} = ship -> preempt_miner_job(agent, ship, reason)
        nil -> :ok
      end
    end
  end

  @doc false
  def record_activity(agent, ship, kind, message, metadata \\ %{}) do
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
  rescue
    exception ->
      Logger.warning("Could not record #{kind} activity: #{Exception.message(exception)}")
  end

  defp terminal_job_reason("completed"), do: "Completed"
  defp terminal_job_reason("failed"), do: "Failed"
  defp terminal_job_reason("stopped"), do: "Stopped by Operator"
  defp terminal_job_reason("replaced"), do: "Replaced by configuration change"

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
    with :ok <- Agent.execution_allowed?(agent) do
      Agent.handle_game_result(agent, advance_miner_job(agent, config, live_ship, :normal))
    end
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

  @doc false
  @spec continue_job_event(non_neg_integer(), String.t(), map(), atom(), non_neg_integer() | nil) ::
          :ok | {:ok, Job.t()}
  def continue_job_event(agent_id, ship_symbol, live_ship, trigger, expected_job_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %Job{} = config <- unfinished_job(ship.id),
         true <- job_matches_event?(config, expected_job_id),
         true <- config.status in @running_job_states,
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      case trigger do
        :arrival ->
          job_arrival_event(agent, ship_symbol, config, live_ship)

        :cooldown ->
          job_cooldown_event(agent, config, live_ship)

        :boot when is_map(config.in_flight_action) ->
          reconcile_in_flight(agent.id, ship, config, live_ship)

        :boot ->
          continue_job_policy(agent, config, live_ship)

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  defp job_matches_event?(_job, nil), do: true
  defp job_matches_event?(%Job{id: id}, id), do: true
  defp job_matches_event?(_job, _expected_job_id), do: false

  defp continue_job_policy(agent, config, live_ship) do
    case config.type do
      "explorer" -> advance_explorer_job(agent, config, live_ship)
      "procurement" -> start_procurement_job(agent, live_ship.symbol)
      "construction_supply" -> start_construction_supply_job(agent, live_ship.symbol)
      "outfitting" -> start_outfitting_job(agent, live_ship.symbol)
      _ -> advance_miner_job(agent, config, live_ship)
    end
  end

  # Marks Job-owned navigation progress after an authoritative arrival, then
  # continues the owning Job policy.
  defp job_arrival_event(agent, ship_symbol, config, live_ship) do
    with true <- arrived_at_configured_waypoint?(live_ship, config) do
      waypoint = get_in(config.in_flight_action, ["waypoint"])

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "active",
            in_flight_action: nil,
            progress:
              Map.merge(config.progress || %{}, %{
                "waypoint" => waypoint,
                "last_completed" => "navigate"
              })
          )
        )

      case config.type do
        "explorer" -> advance_explorer_job(agent, config, live_ship)
        "procurement" -> start_procurement_job(agent, ship_symbol)
        "construction_supply" -> start_construction_supply_job(agent, ship_symbol)
        _ -> advance_miner_job(agent, config, live_ship, :timeline)
      end
    else
      _ -> :ok
    end
  end

  # Marks Job-owned extraction or cooldown progress after authoritative
  # cooldown revalidation, then continues the owning Job policy.
  defp job_cooldown_event(agent, config, live_ship) do
    with true <- cooldown_ready?(live_ship) do
      case config.in_flight_action do
        %{"kind" => "cooldown"} when config.type == "explorer" ->
          config =
            Repo.update!(Ecto.Changeset.change(config, status: "active", in_flight_action: nil))

          advance_explorer_job(agent, config, live_ship)

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

  defp arrived_at_configured_waypoint?(%{nav: %{waypoint_symbol: waypoint, status: status}}, %Job{
         in_flight_action: %{"waypoint" => waypoint}
       })
       when status in ["DOCKED", "IN_ORBIT"],
       do: true

  defp arrived_at_configured_waypoint?(_, _), do: false

  defp extract_if_below_threshold(agent, config, live_ship, mode) do
    cond do
      live_ship.nav.status == "DOCKED" ->
        case Agent.handle_game_result(
               agent,
               SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol)
             ) do
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

    case Intents.request(
           job_scope(agent),
           agent,
           %Intents.JobOwner{job: config},
           live_ship.symbol,
           %Intents.DeliverGoods{
             recipient: %Intents.ContractRecipient{
               contract_id: contract_id,
               waypoint: waypoint
             },
             trade_good: trade_symbol,
             quantity: units
           },
           live_ship
         ) do
      {:ok, %Intent{status: "completed", last_action_result: result}} ->
        fresh_ship =
          case result["cargo"] do
            cargo when is_map(cargo) -> %{live_ship | cargo: ShipCargo.from_json(cargo)}
            _ -> live_ship
          end

        with true <- is_map(result) do
          accepted = result["units"] || units
          remaining = max(entry["units_remaining"] - accepted, 0)

          config =
            Repo.update!(
              Ecto.Changeset.change(config,
                status: "active",
                in_flight_action: nil,
                last_action_result: result,
                contract_deliverables:
                  refresh_miner_deliverable(
                    config.contract_deliverables,
                    contract_id,
                    trade_symbol,
                    result["recipient"]
                  )
              )
            )

          record_miner_job_activity(
            agent,
            live_ship,
            "miner_job_deliver",
            "Delivered #{accepted} #{trade_symbol} to contract #{contract_id} at #{waypoint}; " <>
              "#{remaining} remain",
            %{"deliver" => "#{trade_symbol} #{accepted}", "remaining" => "#{remaining} remain"}
          )

          {:ok, %{ship: fresh_ship, config: config}}
        end

      {:ok, %Intent{} = intent} ->
        {:ok,
         %{
           ship: live_ship,
           config:
             Repo.update!(
               Ecto.Changeset.change(config,
                 status: intent.status,
                 in_flight_action: intent.in_flight_action,
                 last_action_result: intent.last_action_result
               )
             )
         }}

      {:error, reason} ->
        mark_miner_job_blocked(config, {:deliver_failed, contract_id, trade_symbol, reason})
    end
  end

  defp refresh_miner_deliverable(entries, contract_id, trade_symbol, %{
         "units_fulfilled" => fulfilled
       })
       when is_integer(fulfilled) do
    Enum.map(entries, fn entry ->
      if entry["contract_id"] == contract_id and entry["trade_symbol"] == trade_symbol,
        do: Contracts.refresh_deliverable(entry, entry["units_required"], fulfilled),
        else: entry
    end)
  end

  defp refresh_miner_deliverable(entries, _contract_id, _trade_symbol, _recipient), do: entries

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
        case SpaceTraders.Fleet.Intents.request(
               job_scope(agent),
               agent,
               %SpaceTraders.Fleet.Intents.JobOwner{job: config},
               live_ship.symbol,
               %SpaceTraders.Fleet.Intents.SellGoods{
                 market: config.market_waypoint,
                 trade_good: item.symbol,
                 quantity: item.units,
                 parameters: %{market_listing_prevalidated: true}
               },
               live_ship
             ) do
          {:ok, %Intent{status: "completed"}} ->
            {:ok, %{live_ship | cargo: remove_cargo_item(live_ship.cargo, item.symbol)}}

          {:ok, %Intent{} = intent} ->
            {:error, intent.blocker || :market_sale_blocked}

          {:error, reason} ->
            {:error, reason}
        end
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

  defp jettison_cargo_for_miner_job(
         %AgentRecord{agent_token: token},
         ship_symbol,
         trade_symbol,
         units
       ) do
    SpaceTraders.API.jettison_cargo(token, ship_symbol, trade_symbol, units)
  end

  defp remove_cargo_item(cargo, symbol) do
    %{
      cargo
      | units: max(cargo.units - item_units(cargo, symbol), 0),
        inventory: Enum.reject(cargo.inventory || [], &(&1.symbol == symbol))
    }
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
    do_navigate_miner_job(agent, config, live_ship, waypoint)
  end

  defp do_navigate_miner_job(agent, config, live_ship, waypoint) do
    config = Repo.update!(Ecto.Changeset.change(config, status: "active"))

    case SpaceTraders.Fleet.Intents.request(
           job_scope(agent),
           agent,
           %SpaceTraders.Fleet.Intents.JobOwner{job: config},
           live_ship.symbol,
           %SpaceTraders.Fleet.Intents.Navigate{waypoint: waypoint},
           live_ship
         ) do
      {:ok, intent} -> advance_miner_after_intent(agent, config, intent, live_ship)
      :ok -> {:ok, config}
      {:error, reason} -> mark_miner_job_blocked(config, reason)
    end
  end

  defp advance_miner_after_intent(_agent, job, %Intent{status: "waiting"} = intent, _live_ship) do
    {:ok,
     Repo.update!(
       Ecto.Changeset.change(job,
         status: "waiting",
         in_flight_action: intent.in_flight_action,
         last_action_result: intent.last_action_result,
         progress: Map.put(job.progress || %{}, "waypoint", intent.target_waypoint)
       )
     )}
  end

  defp advance_miner_after_intent(agent, job, %Intent{status: "completed"}, live_ship) do
    advance_miner_job(agent, %{job | in_flight_action: nil}, live_ship, :timeline)
  end

  defp advance_miner_after_intent(_agent, job, %Intent{} = intent, _live_ship),
    do: mark_miner_job_blocked(job, intent.blocker || :navigation_blocked)

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

  defp block_explorer_job(agent, ship_symbol, reason) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} ->
        case unfinished_job(ship.id) do
          %Job{type: "explorer"} = job -> block_explorer_job(job, reason)
          _ -> {:error, :explorer_job_not_configured}
        end

      error ->
        error
    end
  end

  defp block_explorer_job(job, reason) do
    blocker = %{
      job_blocker(reason)
      | summary: "System Exploration Job cannot progress: #{blocker_reason(reason)}."
    }

    job =
      Repo.update!(
        Ecto.Changeset.change(job,
          status: "blocked",
          blocker: blocker,
          blocked_reason: nil,
          in_flight_action: nil
        )
      )

    record_activity_by_config(job, "explorer_job_blocked", "System Exploration Job blocked", %{
      "reason" => inspect(reason),
      "coverage" => get_in(job.progress || %{}, ["coverage"]) || %{}
    })

    {:error, {:explorer_job_blocked, reason}}
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
    with {:ok, result} <-
           Agent.handle_game_result(agent, SpaceTraders.API.extract_resources(token, ship_symbol)),
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
    with {:ok, result} <-
           Agent.handle_game_result(agent, SpaceTraders.API.siphon_resources(token, ship_symbol)),
         :ok <- schedule_cooldown(agent, ship_symbol, result, job_id) do
      {:ok, result}
    end
  end

  defp maybe_schedule_live_cooldown(agent, %{symbol: ship_symbol, cooldown: cooldown}, job_id) do
    due_at = Timeline.parse_expiration(cooldown.expiration, cooldown.remaining_seconds)
    schedule_cooldown_event(agent, ship_symbol, due_at, %{"job_id" => job_id})
  end

  defp maybe_put_job_id(payload, nil), do: payload
  defp maybe_put_job_id(payload, job_id), do: Map.put(payload, "job_id", job_id)

  # Arms a persisted cooldown on the Ship's timer; Job policies only ever arm
  # through Timeline persistence plus ShipServer.
  defp schedule_cooldown_event(agent, ship_symbol, due_at, payload \\ %{}) do
    {:ok, event} = Timeline.schedule_event(:ship, ship_symbol, :cooldown, due_at, payload)
    ShipServer.arm(agent, ship_symbol, event)
  end

  @doc false
  def cooldown_active?(%{cooldown: %{remaining_seconds: seconds}})
      when is_integer(seconds),
      do: seconds > 0

  def cooldown_active?(_), do: false

  defp cargo_units(%{cargo: %{units: units}}) when is_integer(units), do: units
  defp cargo_units(_), do: 0

  @doc false
  def item_units(%{cargo: %{inventory: inventory}}, symbol) do
    inventory_units(inventory, symbol)
  end

  def item_units(%{inventory: inventory}, symbol) do
    inventory_units(inventory, symbol)
  end

  defp inventory_units(inventory, symbol) do
    case Enum.find(inventory || [], fn item ->
           (Map.get(item, :symbol) || Map.get(item, "symbol")) == symbol
         end) do
      item when is_map(item) -> Map.get(item, :units) || Map.get(item, "units") || 0
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

  @doc false
  def record_construction_observation(%AgentRecord{id: id} = agent, system, construction, source)
      when is_integer(id) do
    Intelligence.observe_construction(agent, system, construction, source: source)
  rescue
    exception ->
      Logger.warning(
        "Could not persist construction intelligence: #{Exception.message(exception)}"
      )
  end

  def record_construction_observation(_agent, _system, _construction, _source), do: :ok

  defp record_jump_gate_observation(%AgentRecord{id: id} = agent, system, gate, source)
       when is_integer(id) do
    Intelligence.observe_jump_gate(agent, system, gate, source: source)
  rescue
    exception ->
      Logger.warning("Could not persist jump-gate intelligence: #{Exception.message(exception)}")
  end

  defp record_jump_gate_observation(_agent, _system, _gate, _source), do: :ok

  defp refresh_construction_after(
         {:ok, %{construction: construction}} = result,
         agent,
         system_symbol,
         _waypoint_symbol,
         ship_symbol
       ) do
    Intelligence.observe_construction(agent, system_symbol, construction,
      source: "supply_construction",
      observing_ship_symbol: ship_symbol
    )

    result
  rescue
    exception ->
      Logger.warning(
        "Could not persist supplied construction intelligence: #{Exception.message(exception)}"
      )

      result
  end

  defp refresh_construction_after(
         {:error, %SpaceTraders.API.GameplayError{}} = result,
         agent,
         system_symbol,
         waypoint_symbol,
         _ship_symbol
       ) do
    Intelligence.invalidate(agent, :construction, system_symbol, waypoint_symbol)
    result
  rescue
    exception ->
      Logger.warning(
        "Could not invalidate construction intelligence: #{Exception.message(exception)}"
      )

      result
  end

  defp refresh_construction_after(result, _agent, _system, _waypoint, _ship), do: result

  @doc false
  def system_from_headquarters(headquarters) when is_binary(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end

  def system_from_headquarters(_headquarters), do: {:error, :invalid_headquarters}

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
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.navigate_ship(agent_token, ship_symbol, waypoint_symbol)
           ) do
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
      Agent.handle_game_result(
        agent,
        SpaceTraders.API.set_ship_flight_mode(agent_token, ship_symbol, flight_mode)
      )
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

  @doc false
  def record_destination(agent, ship_symbol, waypoint_symbol) do
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
      Agent.handle_game_result(agent, SpaceTraders.API.dock_ship(agent_token, ship_symbol))
      |> then(&record_command_result(agent, ship_symbol, "dock", &1))
    end
  end

  def dock_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Puts a ship into orbit at its current waypoint."
  def orbit_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "orbit"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      Agent.handle_game_result(agent, SpaceTraders.API.orbit_ship(agent_token, ship_symbol))
      |> then(&record_command_result(agent, ship_symbol, "orbit", &1))
    end
  end

  def orbit_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Extracts resources and persists the returned cooldown on the timeline."
  def extract_resources(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "extraction"}),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.extract_resources(agent_token, ship_symbol)
           ),
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
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(agent_token, ship_symbol)),
         {:ok, waypoint} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_waypoint(
               agent_token,
               live_ship.nav.system_symbol,
               live_ship.nav.waypoint_symbol
             )
           ),
         :ok <- siphon_location?(waypoint),
         :ok <- siphon_capability?(live_ship),
         {:ok, result} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.siphon_resources(agent_token, ship_symbol)
           ),
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

  @doc "Refuels a ship at a marketplace that sells fuel."
  def refuel_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_miner_job_for(agent, ship_symbol, {:manual_override, "refueling"}),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      invalidate_market_after(
        Agent.handle_game_result(agent, SpaceTraders.API.refuel_ship(agent_token, ship_symbol)),
        agent
      )
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

  @doc false
  def market_for_ship(%AgentRecord{agent_token: token} = agent, live_ship, waypoint_symbol) do
    system_symbol = live_ship.nav.system_symbol

    case Agent.handle_game_result(
           agent,
           SpaceTraders.API.get_market(token, system_symbol, waypoint_symbol)
         ) do
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
      Agent.handle_game_result(
        agent,
        SpaceTraders.API.jettison_cargo(agent_token, ship_symbol, trade_symbol, units)
      )
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
    with :ok <- Agent.execution_allowed?(agent),
         :ok <- different_transfer_ships?(from_ship, to_ship),
         {:ok, source} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, from_ship)),
         {:ok, target} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, to_ship)),
         :ok <- transfer_preflight(source, target, trade_symbol, units),
         :ok <- preempt_miner_job_for(agent, from_ship, {:manual_override, "cargo transfer"}),
         :ok <- ShipServer.ensure_ready(from_ship) do
      Agent.handle_game_result(
        agent,
        SpaceTraders.API.transfer_cargo(token, from_ship, trade_symbol, units, to_ship)
      )
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

  @doc "Reconciles a blocked in-flight Miner Job before explicitly retrying it."
  def reconcile_miner_job(%AgentRecord{} = agent, ship_symbol) do
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{status: "blocked", blocker: %JobBlocker{}, in_flight_action: action} = config
         when is_map(action) <-
           unfinished_job(ship.id),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol, retry: false)
           ) do
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
          agent = Repo.get!(AgentRecord, agent_id)

          case recovered_config.type do
            "explorer" -> advance_explorer_job(agent, recovered_config, live_ship)
            "procurement" -> start_procurement_job(agent, live_ship.symbol)
            "construction_supply" -> start_construction_supply_job(agent, live_ship.symbol)
            _ -> advance_miner_job(agent, recovered_config, live_ship, :timeline)
          end
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

      arrived_at_waypoint?(live_ship, waypoint) ->
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

  # Cargo alone cannot distinguish a Market sale from another mutation after a
  # crash. Preserve the in-flight evidence as an actionable blocker instead of
  # claiming Market completion from an uncorrelated hold decrease.
  defp action_outcome(%{"kind" => "sell", "sold_baseline" => _baseline}, _live_ship),
    do: :ambiguous

  defp action_outcome(
         %{"kind" => kind, "trade_symbol" => symbol, "expected" => %{"units_at_most" => units}},
         live_ship
       )
       when kind in ["sell", "jettison", "deliver"] do
    if item_units(live_ship, symbol) <= units, do: :confirmed, else: :absent
  end

  defp action_outcome(
         %{
           "kind" => "buy",
           "trade_symbol" => symbol,
           "expected" => %{"cargo_units_at_least" => units}
         },
         live_ship
       ) do
    if item_units(live_ship, symbol) >= units, do: :confirmed, else: :absent
  end

  defp action_outcome(%{"kind" => "refuel", "expected" => %{"fuel_full" => true}}, live_ship) do
    if fuel_full?(live_ship), do: :confirmed, else: :absent
  end

  # The persisted cooldown action is written only after the mutating request
  # returned. It is therefore safe to continue after a restart, even if the
  # cooldown elapsed while the process was down.
  defp action_outcome(%{"kind" => "cooldown"}, _live_ship), do: :confirmed

  defp action_outcome(_action, _live_ship), do: :ambiguous

  defp arrived_at_waypoint?(%{nav: %{waypoint_symbol: waypoint, status: status}}, waypoint)
       when status in ["DOCKED", "IN_ORBIT"],
       do: true

  defp arrived_at_waypoint?(_live_ship, _waypoint), do: false

  defp confirm_recovery(config, live_ship) do
    action = config.in_flight_action

    progress =
      case action do
        %{"kind" => "navigate", "waypoint" => waypoint} ->
          Map.put(config.progress || %{}, "waypoint", waypoint)

        %{"kind" => "sell", "units" => units, "sold_baseline" => baseline} ->
          Map.put(config.progress || %{}, "sold", baseline + units)

        _ ->
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

    agent = Repo.get!(AgentRecord, agent_id)

    result =
      case config.type do
        "procurement" -> start_procurement_job(agent, live_ship.symbol)
        "construction_supply" -> start_construction_supply_job(agent, live_ship.symbol)
        _ -> advance_miner_job(agent, config, live_ship, :timeline)
      end

    case result do
      {:ok, recovered_config} ->
        {:ok,
         Repo.update!(
           Ecto.Changeset.change(recovered_config, recovery_attempts: 0, recovery_started_at: nil)
         )}

      error ->
        error
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

  @doc false
  def record_activity_by_id(agent_id, ship, kind, message, outcome) do
    record_activity(Repo.get!(AgentRecord, agent_id), ship, kind, message, %{"outcome" => outcome})
  end

  @doc false
  def job_blocker(reason) do
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

  defp blocker_summary({:jump_gate_incomplete, waypoint}),
    do: "Jump Gate #{waypoint} is not complete."

  defp blocker_summary({:jump_gate_not_connected, source, destination}),
    do: "Jump Gate #{source} is not connected to #{destination}."

  defp blocker_summary({:jump_route_candidates, reason, _candidates}),
    do: "Jump route blocked: #{blocker_reason(reason)}."

  defp blocker_summary(:ambiguous_jump_evidence),
    do: "The jump response is ambiguous; authoritative Ship state did not confirm arrival."

  defp blocker_summary(:target_system_waypoints_unavailable),
    do: "System Exploration Job cannot progress: target system waypoints are unavailable."

  defp blocker_summary(reason), do: "Miner Job cannot progress: #{blocker_reason(reason)}."

  defp blocker_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp blocker_reason({:jump_route_candidates, reason, _candidates}), do: blocker_reason(reason)
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

      {"fuel_unavailable", _reason} ->
        {"game_state", "fuel_observation_available", ["refresh_ship", "refuel"]}

      {code, _reason} when code in ["insufficient_credits", "antimatter_unavailable"] ->
        {"operator", "jump_resources_available", ["acquire_credits", "buy_antimatter", "resume"]}

      {code, _reason}
      when code in [
             "construction_unavailable",
             "construction_intelligence_unavailable",
             "destination_construction_incomplete"
           ] ->
        {"operator", "construction_intelligence_and_completion_available",
         ["inspect_construction", "supply_construction", "resume"]}

      {"jump_gate_intelligence_unavailable", _reason} ->
        {"operator", "jump_gate_intelligence_available", ["inspect_jump_gate", "resume"]}

      {code, _reason}
      when code in ["navigation_budget_unavailable", "reverse_connection_unavailable"] ->
        {"operator", "navigable_route_available",
         ["inspect_waypoint", "choose_connected_gate", "resume"]}

      {"orbit_required", _reason} ->
        {"operator", "ship_in_orbit", ["orbit", "resume"]}

      {"cooldown_active", _reason} ->
        {"game_state", "cooldown_elapsed", ["wait_for_cooldown", "resume"]}

      {"jump_gate_incomplete", _reason} ->
        {"operator", "construction_completed",
         ["inspect_construction", "supply_construction", "resume"]}

      {"jump_gate_not_connected", _reason} ->
        {"operator", "connected_gate_selected",
         ["inspect_jump_gate", "choose_connected_gate", "resume"]}

      {"ambiguous_jump_evidence", _reason} ->
        {"game_state", "authoritative_arrival_confirmed", ["inspect_activity", "reconcile"]}

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
      payload = %{"destination" => nav.route.destination.symbol} |> maybe_put_job_id(job_id)

      {:ok, event} =
        Timeline.schedule_event(:ship, ship_symbol, :arrival, due_at, payload)

      ShipServer.arm(agent, ship_symbol, event)
    end
  end

  defp maybe_schedule_arrival(_agent, _ship_symbol, _result, _job_id), do: :ok

  defp parse_arrival(%{arrival: arrival}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} -> {:ok, due_at}
      _ -> :error
    end
  end

  defp parse_arrival(_route), do: :error

  defp schedule_cooldown(agent, ship_symbol, %{
         cooldown: %{remaining_seconds: seconds, expiration: expiration}
       })
       when is_integer(seconds) and seconds > 0 do
    due_at = Timeline.parse_expiration(expiration, seconds)
    schedule_cooldown_event(agent, ship_symbol, due_at)
  end

  defp schedule_cooldown(_agent, _ship_symbol, _result), do: :ok

  defp schedule_cooldown(agent, ship_symbol, result, job_id) do
    case result do
      %{cooldown: %{remaining_seconds: seconds, expiration: expiration}}
      when is_integer(seconds) and seconds > 0 ->
        due_at = Timeline.parse_expiration(expiration, seconds)
        schedule_cooldown_event(agent, ship_symbol, due_at, %{"job_id" => job_id})

      _ ->
        :ok
    end
  end

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

  @doc false
  def rearm_on_boot do
    intent_ship_ids =
      Repo.all(
        from intent in Intent,
          where: intent.status in ^Intent.unfinished_states(),
          select: intent.ship_id
      )

    job_ship_ids =
      Repo.all(
        from job in Job,
          where: job.status in ^@running_job_states,
          select: job.ship_id
      )

    pending_ship_ids =
      Timeline.pending_owners(:ship)
      |> Enum.flat_map(fn %{owner_id: symbol} ->
        case Repo.get_by(Ship, symbol: symbol) do
          %Ship{id: id} -> [id]
          nil -> []
        end
      end)

    (intent_ship_ids ++ job_ship_ids ++ pending_ship_ids)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(fn ship_id ->
      case Repo.get(Ship, ship_id) do
        %Ship{symbol: symbol, agent_id: agent_id} ->
          case ship_credentials(symbol) do
            {:ok, ^agent_id, token} ->
              ShipServer.ensure_started(symbol, agent_id, token)

              unless pending_event_matches_current_intent?(symbol) do
                Intents.reconcile_internal(agent_id, symbol, nil, :boot, nil, nil)
              end

            _ ->
              :ok
          end

        nil ->
          :ok
      end
    end)

    :ok
  end

  defp pending_event_matches_current_intent?(ship_symbol) do
    case Repo.get_by(Ship, symbol: ship_symbol) do
      %Ship{id: ship_id} ->
        case Repo.one(
               from intent in Intent,
                 where:
                   intent.ship_id == ^ship_id and intent.status in ^Intent.unfinished_states()
             ) do
          %Intent{id: intent_id} ->
            Timeline.pending_events(:ship, ship_symbol)
            |> Enum.any?(&(&1.payload["intent_id"] == intent_id))

          nil ->
            Timeline.pending_events(:ship, ship_symbol) != []
        end

      nil ->
        false
    end
  end

  defp request_job_intent(agent, job, live_ship, %{
         type: "buy",
         target_waypoint: waypoint,
         parameters: p
       }) do
    Intents.request(
      job_scope(agent),
      agent,
      %Intents.JobOwner{job: job},
      live_ship.symbol,
      %Intents.BuyGoods{
        market: waypoint,
        trade_good: p["trade_symbol"],
        quantity: p["units"],
        constraints:
          p
          |> Map.take(["max_price", "reserve_credits"])
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end),
        parameters: Map.take(p, ["recipient"])
      },
      live_ship
    )
  end

  defp request_job_intent(agent, job, live_ship, %{
         type: "sell",
         target_waypoint: waypoint,
         parameters: p
       }) do
    Intents.request(
      job_scope(agent),
      agent,
      %Intents.JobOwner{job: job},
      live_ship.symbol,
      %Intents.SellGoods{
        market: waypoint,
        trade_good: p["trade_symbol"],
        quantity: p["units"],
        constraints:
          p
          |> Map.take(["min_price", "min_total"])
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      },
      live_ship
    )
  end

  defp request_job_intent(_agent, _job, _live_ship, _attrs),
    do: {:error, :unsupported_intent_goal}

  defp job_scope(%AgentRecord{operator_id: operator_id}),
    do: %Scope{operator: %{id: operator_id}}

  defp stop_job_intent(agent, job) do
    case unfinished_job_intent(job.id) do
      %Intent{id: intent_id} ->
        Intents.stop(job_scope(agent), %Intents.JobOwner{job: job}, intent_id)

      nil ->
        :ok
    end
  end

  defp unfinished_intent(id) do
    case Repo.get(Intent, id) do
      %Intent{} = intent -> if Intent.unfinished?(intent), do: intent
      _ -> nil
    end
  end

  defp unfinished_job_intent(job_id),
    do:
      Repo.one(
        from i in Intent,
          where: i.job_id == ^job_id and i.status in ["active", "waiting", "blocked"]
      )

  defp unfinished_manual_intent(ship_id),
    do:
      Repo.one(
        from i in Intent,
          where:
            i.ship_id == ^ship_id and i.caller == "manual" and
              i.status in ["active", "waiting", "blocked", "awaiting_confirmation"]
      )

  defp last_completed_job_intent(job_id, type \\ nil) do
    query =
      from i in Intent,
        where: i.job_id == ^job_id and i.caller == "job" and i.status == "completed",
        order_by: [desc: i.id],
        limit: 1

    Repo.one(if(type, do: where(query, [i], i.type == ^type), else: query))
  end

  defp with_current_intent(%Intent{id: id}, fun) do
    case Repo.get(Intent, id) do
      %Intent{} = current when current.status in ["active", "waiting", "blocked"] -> fun.(current)
      _ -> :intent_no_longer_owned
    end
  end

  defp transition_intent(%Intent{id: id}, attrs) do
    case Repo.get(Intent, id) do
      %Intent{} = current ->
        {:ok, Repo.update!(Ecto.Changeset.change(current, attrs))}

      nil ->
        :intent_no_longer_owned
    end
  end

  defp ambiguous_cargo_operation_error?(%SpaceTraders.API.Error{}), do: true
  defp ambiguous_cargo_operation_error?({:ambiguous_operation_evidence, _}), do: true
  defp ambiguous_cargo_operation_error?(_), do: false
  defp cargo_error_message(%{message: message}) when is_binary(message), do: message
  defp cargo_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cargo_error_message(reason), do: inspect(reason)
  defp module_count(modules, symbol), do: Enum.count(modules || [], &(&1.symbol == symbol))
  defp affordable_cargo_units(_credits, 0), do: :infinity
  defp affordable_cargo_units(credits, price), do: div(credits, price)

  defp unresolved_cargo_intent(ship_id),
    do:
      Repo.one(
        from i in Intent,
          where:
            i.ship_id == ^ship_id and i.type in ["buy", "sell", "deliver"] and
              i.status in ["active", "waiting", "blocked"] and not is_nil(i.in_flight_action)
      )

  @doc false
  def ship_credentials(ship_symbol) do
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
