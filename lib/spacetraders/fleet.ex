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
  alias SpaceTraders.API.Model.{Contract, Market, ShipCargo, ShipNav, ShipNavRoute}

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
  @unfinished_intent_states Intent.unfinished_states()
  @terminal_intent_states Intent.terminal_states()

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
    agent
    |> SpaceTraders.Fleet.Intents.current()
    |> Enum.filter(&(&1.caller == "manual"))
    |> Map.new(&{&1.ship_id, &1})
  end

  defp intents_history_for_ships(agent) do
    agent
    |> SpaceTraders.Fleet.Intents.history()
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
         nil <- unfinished_intents(ship.id),
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
           insert_job_intent(job, %{
             type: "buy",
             target_waypoint: source.waypoint,
             parameters: %{
               "trade_symbol" => source.good.symbol,
               "units" => 1,
               "max_price" => outfitting_remaining_budget(job.progress),
               "reserve_credits" => job.progress["reserve_credits"],
               "source_waypoint" => source.waypoint
             }
           }),
         {:ok, intent} <- advance_intents(agent, intent, live_ship) do
      advance_outfitting_after_intent(agent, job, intent)
    else
      {:error, reason} -> mark_outfitting_job_blocked(job, reason)
      :ok -> :ok
    end
  end

  defp reconcile_outfitting_intent(agent, job, intent, live_ship) do
    case advance_intents(agent, intent, live_ship) do
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
    intent =
      Repo.one(
        from intent in Intent,
          where:
            intent.job_id == ^job.id and intent.caller == "job" and intent.type == "buy" and
              intent.status == "completed",
          order_by: [desc: intent.id],
          limit: 1
      )

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
         nil <- unfinished_intents(ship.id),
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
               insert_job_intent(job, %{
                 type: "buy",
                 target_waypoint: candidate.source_waypoint,
                 parameters: params
               }),
             {:ok, intent} <- advance_intents(agent, intent, live_ship) do
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
         nil <- unfinished_intents(ship.id),
         nil <- unresolved_cargo_intent(ship.id) do
      job = apply_unapplied_procurement_intent!(job)

      case unfinished_job_intent(job.id) do
        %Intent{} = intent ->
          job =
            Repo.update!(
              Ecto.Changeset.change(job, status: "active", blocker: nil, blocked_reason: nil)
            )

          reconcile_procurement_intent(agent, ship, job, intent)

        nil ->
          start_fresh_procurement_job(agent, ship_symbol, job)
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
         %Intent{} = current_intent <- Repo.get(Intent, intent.id),
         true <- Intent.unfinished?(current_intent),
         {:ok, current_intent} <- advance_intents(agent, current_intent, live_ship) do
      advance_procurement_after_intent(agent, current_job, current_intent)
    else
      :ok ->
        :ok

      false ->
        :ok

      nil ->
        :ok

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
               terminalize_job_intent!(job)

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
               terminalize_job_intent!(job)
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
        },
        live_ship
      )
    else
      Intents.request(
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

    Intents.request_sell_with_live_ship(
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
    with {:ok, intent} <- insert_job_intent(job, attrs) do
      advance_intents(agent, intent, live_ship)
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

  defp insert_job_intent(job, attrs) do
    %Intent{ship_id: job.ship_id, job_id: job.id}
    |> Intent.changeset(Map.put(attrs, :caller, "job"))
    |> Ecto.Changeset.put_change(:status, "active")
    |> Repo.insert()
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

  defp recipient_fulfilled_units(%{terms: terms}, trade_symbol) do
    case Enum.find(terms.deliver || [], &(&1.trade_symbol == trade_symbol)) do
      %{units_fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp recipient_fulfilled_units(%{materials: materials}, trade_symbol) do
    case Enum.find(materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp apply_unapplied_procurement_intent!(job) do
    intent =
      Repo.one(
        from intent in Intent,
          where:
            intent.job_id == ^job.id and intent.caller == "job" and intent.status == "completed",
          order_by: [desc: intent.id],
          limit: 1
      )

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
             if(ambiguous_cargo_operation_error?(reason), do: intent.in_flight_action, else: nil),
           last_action_result: %{"kind" => intent.type, "error" => cargo_error_message(reason)}
         ) do
      {:ok, intent} -> intent
      :intent_no_longer_owned -> :ok
    end
  end

  defp transaction_evidence(transaction) do
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

  defp contract_delivery_evidence(contract, trade_symbol) do
    case find_deliverable(contract, trade_symbol) do
      nil -> %{"trade_symbol" => trade_symbol, "accepted" => "unavailable"}
      delivery -> %{"trade_symbol" => trade_symbol, "units_fulfilled" => delivery.units_fulfilled}
    end
  end

  defp construction_delivery_evidence(construction, trade_symbol) do
    case Enum.find(construction.materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: fulfilled} when is_integer(fulfilled) ->
        %{"trade_symbol" => trade_symbol, "units_fulfilled" => fulfilled}

      _ ->
        %{"trade_symbol" => trade_symbol, "accepted" => "unavailable"}
    end
  end

  defp procurement_purchase_units(live_ship, good, progress, credits) do
    affordable =
      affordable_cargo_units(max(credits - progress["reserve_credits"], 0), good.purchase_price)

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
         nil <- unfinished_intents(ship.id),
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
    with {:ok, intent} <- insert_job_intent(job, attrs) do
      advance_intents(agent, intent, live_ship)
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
         %Intent{} = current_intent <- Repo.get(Intent, intent.id),
         true <- Intent.unfinished?(current_intent),
         {:ok, current_intent} <- advance_intents(agent, current_intent, live_ship) do
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
    intent =
      Repo.one(
        from intent in Intent,
          where:
            intent.job_id == ^job.id and intent.caller == "job" and intent.status == "completed",
          order_by: [desc: intent.id],
          limit: 1
      )

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

  Returns `{:ok, %Intent{}}` with its current status (`active`,
  `waiting`, `blocked`, or `completed`), or an error.
  """
  # Kept as a thin compatibility facade; execution remains in Intents.
  def navigate_intent(%AgentRecord{} = agent, ship_symbol, waypoint) do
    SpaceTraders.Fleet.Intents.request(
      agent,
      :manual,
      ship_symbol,
      %SpaceTraders.Fleet.Intents.Navigate{waypoint: waypoint}
    )
  end

  # Job Navigate is inserted and advanced as a Job-owned Intent. Manual Navigate
  # uses the separate path above because it may preempt a Job.
  def request_manual_navigate(
        %AgentRecord{agent_token: agent_token} = agent,
        ship_symbol,
        waypoint,
        parameters
      )
      when is_binary(agent_token) and agent_token != "" and is_map(parameters) do
    waypoint = String.trim(waypoint || "")

    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         {:ok, intent} <-
           replace_intents(ship, %{
             type: "navigate",
             target_waypoint: waypoint,
             parameters: parameters
           }) do
      reconcile_intents(agent, intent)
    else
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
    end
  end

  def request_job_navigate(agent, job, ship_symbol, waypoint, parameters) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         :ok <- job_navigation_allowed?(job, waypoint),
         existing_intent <- unfinished_intent_for_ship(ship.id),
         {:ok, intent} <-
           Repo.transaction(
             fn ->
               current_job = Repo.get(Job, job.id)

               if current_job && current_job.ship_id == ship.id && Job.running?(current_job) do
                 case insert_or_reuse_job_navigation_intent(
                        current_job,
                        waypoint,
                        parameters,
                        existing_intent
                      ) do
                   {:ok, intent} -> intent
                   {:error, reason} -> Repo.rollback(reason)
                 end
               else
                 Repo.rollback(:invalid_intent_owner)
               end
             end,
             mode: :immediate
           ),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship.symbol)
           ) do
      advance_intents(agent, intent, live_ship)
    else
      false -> {:error, :invalid_intent_owner}
      error -> error
    end
  end

  def request_job_navigate(agent, job, ship_symbol, waypoint, parameters, live_ship) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         :ok <- job_navigation_allowed?(job, waypoint),
         existing_intent <- unfinished_intent_for_ship(ship.id),
         {:ok, intent} <-
           Repo.transaction(
             fn ->
               current_job = Repo.get(Job, job.id)

               if current_job && current_job.ship_id == ship.id && Job.running?(current_job) do
                 case insert_or_reuse_job_navigation_intent(
                        current_job,
                        waypoint,
                        parameters,
                        existing_intent
                      ) do
                   {:ok, intent} -> intent
                   {:error, reason} -> Repo.rollback(reason)
                 end
               else
                 Repo.rollback(:invalid_intent_owner)
               end
             end,
             mode: :immediate
           ) do
      advance_intents(agent, intent, live_ship)
    else
      false -> {:error, :invalid_intent_owner}
      error -> error
    end
  end

  defp insert_or_reuse_job_navigation_intent(job, waypoint, parameters, existing_intent) do
    case existing_intent do
      %Intent{caller: "job", job_id: job_id, type: "navigate"} = intent when job_id == job.id ->
        if intent.target_waypoint == waypoint and intent.parameters == parameters,
          do: {:ok, intent},
          else: {:error, :intents_active}

      %Intent{} ->
        {:error, :intents_active}

      nil ->
        insert_job_intent(job, %{
          type: "navigate",
          target_waypoint: waypoint,
          parameters: parameters
        })
    end
  end

  defp unfinished_intent_for_ship(ship_id) do
    Repo.one(
      from intent in Intent,
        where: intent.ship_id == ^ship_id and intent.status in ^@unfinished_intent_states
    )
  end

  defp job_navigation_allowed?(
         %Job{type: "miner", extraction_waypoint: extraction, market_waypoint: market},
         waypoint
       )
       when waypoint == extraction or waypoint == market,
       do: :ok

  defp job_navigation_allowed?(%Job{type: type}, _waypoint)
       when type in ["procurement", "market_trading"],
       do: :ok

  defp job_navigation_allowed?(_job, waypoint),
    do: {:error, {:job_navigation_not_authorized, waypoint}}

  @doc "Dispatches a reviewed jump route only when its fresh authority still matches the preview."
  def confirm_jump_intent(agent, ship_symbol, waypoint, preview) when is_map(preview) do
    with {:ok, fresh_preview} <- jump_preview(agent, ship_symbol, waypoint),
         true <- reviewed_jump_matches?(preview, fresh_preview) || {:error, :jump_preview_stale} do
      SpaceTraders.Fleet.Intents.request(
        agent,
        %SpaceTraders.Fleet.Intents.ManualControl{},
        ship_symbol,
        %SpaceTraders.Fleet.Intents.Navigate{
          waypoint: waypoint,
          parameters: %{
            "reviewed_jump" => %{
              "ship_symbol" => fresh_preview.ship_symbol,
              "current_waypoint" => fresh_preview.current_waypoint,
              "source_waypoint" => fresh_preview.source_waypoint,
              "destination_waypoint" => fresh_preview.destination_waypoint,
              "flight_mode" => fresh_preview.flight_mode,
              "credits" => fresh_preview.credits,
              "antimatter_cost" => fresh_preview.antimatter_cost,
              "cooldown_seconds" => fresh_preview.cooldown_seconds || 0,
              "candidates" => fresh_preview.candidates
            }
          }
        }
      )
    else
      {:error, _reason} = error -> error
      false -> {:error, :jump_preview_stale}
    end
  end

  @doc "Persists a remote Navigate review without dispatching a mutation."
  def review_navigation_intent(agent, ship_symbol, waypoint, preview) when is_map(preview) do
    method = if preview[:method] == "warp", do: "warp", else: "jump"
    review = stringify_nested_keys(preview)

    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         {:ok, intent} <-
           replace_intents(ship, %{
             type: "navigate",
             target_waypoint: waypoint,
             parameters: %{
               "review_method" => method,
               "reviewed_#{method}" => review
             },
             status: "awaiting_confirmation",
             review_revision: 1
           }) do
      {:ok, intent}
    else
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
    end
  end

  @doc "Confirms a persisted remote Navigate review after re-reading game truth."
  def confirm_navigation_intent(%AgentRecord{} = agent, intent_id, review_revision) do
    with {:ok, revision} <- parse_review_revision(review_revision),
         %Intent{} = intent <- owned_intent(agent, intent_id),
         true <-
           intent.status == "awaiting_confirmation" || {:error, :intent_not_awaiting_confirmation},
         true <- intent.review_revision == revision || {:error, :review_revision_stale},
         fresh <- fresh_navigation_review(agent, intent),
         {:ok, intent} <- refresh_or_authorize_review(intent, fresh) do
      case intent.status do
        "awaiting_confirmation" -> {:ok, intent}
        "active" -> reconcile_intents(agent, intent)
      end
    else
      nil -> {:error, :intent_not_found}
      {:error, _reason} = error -> error
      false -> {:error, :review_revision_stale}
    end
  end

  def confirm_navigation_intent(%{operator: %{id: operator_id}}, intent_id, review_revision) do
    with {:ok, revision} <- parse_review_revision(review_revision),
         {%Intent{} = intent, %AgentRecord{} = agent} <-
           owned_intent_for_operator(operator_id, intent_id),
         true <-
           intent.status == "awaiting_confirmation" || {:error, :intent_not_awaiting_confirmation},
         true <- intent.review_revision == revision || {:error, :review_revision_stale},
         fresh <- fresh_navigation_review(agent, intent),
         {:ok, intent} <- refresh_or_authorize_review(intent, fresh) do
      case intent.status do
        "awaiting_confirmation" -> {:ok, intent}
        "active" -> reconcile_intents(agent, intent)
      end
    else
      nil -> {:error, :intent_not_found}
      {:error, _reason} = error -> error
      false -> {:error, :review_revision_stale}
    end
  end

  defp parse_review_revision(value) when is_integer(value), do: {:ok, value}

  defp parse_review_revision(value) when is_binary(value) do
    case Integer.parse(value) do
      {revision, ""} -> {:ok, revision}
      _ -> {:error, :review_revision_stale}
    end
  end

  defp parse_review_revision(_value), do: {:error, :review_revision_stale}

  defp owned_intent(%AgentRecord{id: agent_id}, intent_id) do
    Repo.one(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: intent.id == ^intent_id and ship.agent_id == ^agent_id
    )
  end

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

  defp fresh_navigation_review(
         agent,
         %Intent{target_waypoint: waypoint, ship_id: ship_id} = intent
       ) do
    ship = Repo.get!(Ship, ship_id)
    method = intent.parameters["review_method"]

    case method do
      "warp" -> warp_preview(agent, ship.symbol, waypoint)
      "jump" -> jump_preview(agent, ship.symbol, waypoint)
      _ -> {:error, :review_revision_stale}
    end
  end

  defp refresh_or_authorize_review(intent, {:error, reason}) do
    method = intent.parameters["review_method"]
    key = "reviewed_#{method}"

    parameters =
      Map.put(intent.parameters, key, %{
        "method" => method,
        "destination_waypoint" => intent.target_waypoint,
        "status" => "blocked",
        "validation_error" => inspect(reason)
      })

    case Repo.update_all(
           from(i in Intent,
             where:
               i.id == ^intent.id and i.status == "awaiting_confirmation" and
                 i.review_revision == ^intent.review_revision
           ),
           set: [parameters: parameters, review_revision: intent.review_revision + 1]
         ) do
      {1, _} -> {:ok, Repo.get!(Intent, intent.id)}
      {0, _} -> {:error, :review_revision_stale}
    end
  end

  defp refresh_or_authorize_review(intent, {:ok, fresh}) do
    method = intent.parameters["review_method"]
    key = "reviewed_#{method}"
    persisted = intent.parameters[key] || %{}
    fresh = stringify_nested_keys(fresh)

    if canonical_preview_value(review_for_comparison(method, persisted)) ==
         canonical_preview_value(review_for_comparison(method, fresh)) do
      case Repo.update_all(
             from(i in Intent,
               where:
                 i.id == ^intent.id and i.status == "awaiting_confirmation" and
                   i.review_revision == ^intent.review_revision
             ),
             set: [status: "active"]
           ) do
        {1, _} -> {:ok, Repo.get!(Intent, intent.id)}
        {0, _} -> {:error, :review_revision_stale}
      end
    else
      case Repo.update_all(
             from(i in Intent,
               where:
                 i.id == ^intent.id and i.status == "awaiting_confirmation" and
                   i.review_revision == ^intent.review_revision
             ),
             set: [
               parameters: Map.put(intent.parameters, key, fresh),
               review_revision: intent.review_revision + 1
             ]
           ) do
        {1, _} -> {:ok, Repo.get!(Intent, intent.id)}
        {0, _} -> {:error, :review_revision_stale}
      end
    end
  end

  defp review_for_comparison("warp", review), do: Map.delete(review, "candidates")
  defp review_for_comparison(_method, review), do: review

  defp stringify_nested_keys(value) when is_map(value),
    do: Map.new(value, fn {key, value} -> {to_string(key), stringify_nested_keys(value)} end)

  defp stringify_nested_keys(value) when is_list(value),
    do: Enum.map(value, &stringify_nested_keys/1)

  defp stringify_nested_keys(value), do: value

  @doc "Dispatches a reviewed warp route only when fresh Ship readiness still matches the preview."
  def confirm_warp_intent(agent, ship_symbol, waypoint, preview) when is_map(preview) do
    with {:ok, fresh_preview} <- warp_preview(agent, ship_symbol, waypoint),
         true <- reviewed_warp_matches?(preview, fresh_preview) || {:error, :warp_preview_stale} do
      SpaceTraders.Fleet.Intents.request(
        agent,
        %SpaceTraders.Fleet.Intents.ManualControl{},
        ship_symbol,
        %SpaceTraders.Fleet.Intents.Navigate{
          waypoint: waypoint,
          parameters: %{
            "reviewed_warp" =>
              Map.new(fresh_preview, fn {key, value} -> {to_string(key), value} end)
          }
        }
      )
    else
      {:error, _reason} = error -> error
      false -> {:error, :warp_preview_stale}
    end
  end

  @doc "Records a rejected jump preview as durable Manual Control work without mutation."
  def block_jump_preview(%AgentRecord{} = agent, ship_symbol, waypoint, reason) do
    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         {:ok, intent} <- replace_intents(ship, waypoint) do
      block_intents(intent, reason)
    else
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
    end
  end

  defp reviewed_jump_matches?(reviewed, fresh) do
    canonical_preview_value(reviewed_value(reviewed, :ship_symbol)) == fresh.ship_symbol and
      reviewed_value(reviewed, :current_waypoint) == fresh.current_waypoint and
      reviewed_value(reviewed, :source_waypoint) == fresh.source_waypoint and
      reviewed_value(reviewed, :destination_waypoint) == fresh.destination_waypoint and
      canonical_preview_value(reviewed_value(reviewed, :flight_mode)) == fresh.flight_mode and
      integer_reviewed_value(reviewed, :credits) == fresh.credits and
      integer_reviewed_value(reviewed, :antimatter_cost) == fresh.antimatter_cost and
      integer_reviewed_value(reviewed, :cooldown_seconds) == (fresh.cooldown_seconds || 0)
  end

  defp reviewed_warp_matches?(reviewed, fresh) do
    Enum.all?(fresh, fn {key, value} ->
      canonical_preview_value(reviewed_value(reviewed, key)) == canonical_preview_value(value)
    end)
  end

  defp reviewed_value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp integer_reviewed_value(map, key) do
    case reviewed_value(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp canonical_preview_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, value} ->
      {canonical_preview_key(key), canonical_preview_value(value)}
    end)
    |> Map.new()
  end

  defp canonical_preview_value(value) when is_list(value),
    do: Enum.map(value, &canonical_preview_value/1)

  defp canonical_preview_value(value), do: value

  defp canonical_preview_key(key) when is_binary(key), do: key
  defp canonical_preview_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_preview_key(_key), do: "__malformed_key__"

  @doc "Reads the authoritative prerequisites for a direct jump-gate route without mutation."
  def jump_preview(%AgentRecord{agent_token: token} = agent, ship_symbol, waypoint)
      when is_binary(token) and token != "" do
    waypoint = String.trim(waypoint || "")

    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship.symbol)),
         true <- remote_waypoint?(live_ship.nav.waypoint_symbol, waypoint),
         {:ok, source_system} <- system_from_headquarters(live_ship.nav.waypoint_symbol),
         {:ok, destination_system} <- system_from_headquarters(waypoint),
         {:ok, candidates} <- jump_origin_candidates(agent, source_system, waypoint),
         {:ok, origin_gate} <- jump_origin_for(agent, source_system, waypoint),
         :ok <-
           validate_jump_route(
             agent,
             source_system,
             origin_gate,
             destination_system,
             waypoint
           ),
         {:ok, preflight} <-
           jump_cost_preflight(agent, source_system, origin_gate) do
      {:ok,
       Map.merge(preflight, %{
         ship_symbol: ship.symbol,
         current_waypoint: live_ship.nav.waypoint_symbol,
         source_waypoint: origin_gate,
         destination_waypoint: waypoint,
         flight_mode: live_ship.nav.flight_mode,
         cooldown_seconds: live_ship.cooldown.remaining_seconds,
         candidates: candidates
       })}
    else
      false -> {:error, :same_system_route}
      {:error, _reason} = error -> error
      error -> {:error, error}
    end
  end

  def jump_preview(%AgentRecord{}, _ship_symbol, _waypoint), do: {:error, :agent_token_missing}

  @doc "Reads authoritative Ship readiness for a direct inter-System warp without mutation."
  def warp_preview(%AgentRecord{agent_token: token} = agent, ship_symbol, waypoint)
      when is_binary(token) and token != "" do
    waypoint = String.trim(waypoint || "")

    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship.symbol)),
         true <-
           remote_waypoint?(live_ship.nav.waypoint_symbol, waypoint) ||
             {:error, :same_system_route},
         {:ok, module} <- installed_warp_drive(live_ship),
         true <- live_ship.nav.flight_mode != "BURN" || {:error, :warp_burn_fuel_budget_unknown},
         true <- not fuel_empty?(live_ship) || {:error, :insufficient_fuel} do
      {:ok,
       %{
         method: "warp",
         ship_symbol: ship.symbol,
         current_waypoint: live_ship.nav.waypoint_symbol,
         destination_waypoint: waypoint,
         flight_mode: live_ship.nav.flight_mode,
         fuel_current: live_ship.fuel.current,
         fuel_capacity: live_ship.fuel.capacity,
         warp_drive: module.symbol,
         warp_range: module.range
       }}
    else
      {:error, _reason} = error -> error
      error -> {:error, error}
    end
  end

  def warp_preview(%AgentRecord{}, _ship_symbol, _waypoint), do: {:error, :agent_token_missing}

  defp installed_warp_drive(%{modules: modules}) do
    case Enum.find(modules || [], &warp_drive_module?/1) do
      nil -> {:error, :warp_drive_missing}
      module -> {:ok, module}
    end
  end

  defp warp_drive_module?(%{symbol: symbol}) when is_binary(symbol),
    do: symbol in ~w(MODULE_WARP_DRIVE_I MODULE_WARP_DRIVE_II MODULE_WARP_DRIVE_III)

  defp warp_drive_module?(_), do: false

  @doc "Starts a durable Buy Goods Intent at a specified Market."
  def buy_goods_intent(agent, ship_symbol, waypoint, trade_symbol, units, opts \\ []) do
    cargo_intent(agent, ship_symbol, "buy", waypoint, trade_symbol, units, opts)
  end

  @doc "Starts a durable Sell Goods Intent at a specified Market."
  def sell_goods_intent(agent, ship_symbol, waypoint, trade_symbol, units, opts \\ []) do
    cargo_intent(agent, ship_symbol, "sell", waypoint, trade_symbol, units, opts)
  end

  def request_job_sell_goods_intent(
        agent,
        %Job{id: job_id, ship_id: ship_id} = job,
        ship_symbol,
        waypoint,
        trade_symbol,
        units,
        constraints,
        parameters,
        live_ship
      ) do
    intent_parameters =
      constraints
      |> Map.merge(parameters)
      |> Map.put(:caller, "job")
      |> Map.put(:job_id, job_id)
      |> Map.put(:trade_symbol, trade_symbol)
      |> Map.put(:units, units)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         true <- ship.id == ship_id,
         true <- live_ship.symbol == ship_symbol,
         true <- job.status in ["active", "waiting"],
         {:ok, intent} <-
           insert_job_intent(job, %{
             type: "sell",
             target_waypoint: waypoint,
             parameters: intent_parameters
           }) do
      advance_intents(agent, intent, live_ship)
    else
      false -> {:error, :invalid_cargo_intent_owner}
      error -> error
    end
  end

  @doc "Starts a durable Deliver Goods Intent for a typed recipient."
  def deliver_goods_intent(
        agent,
        ship_symbol,
        recipient,
        waypoint,
        trade_symbol,
        units,
        opts \\ []
      )

  def deliver_goods_intent(
        agent,
        ship_symbol,
        %{type: "construction", system: system} = recipient,
        waypoint,
        trade_symbol,
        units,
        opts
      ) do
    deliver_construction_goods_intent(
      agent,
      ship_symbol,
      system,
      waypoint,
      trade_symbol,
      units,
      Keyword.put(opts, :recipient, recipient)
    )
  end

  def deliver_goods_intent(
        agent,
        ship_symbol,
        %{type: "contract", contract_id: contract_id},
        waypoint,
        trade_symbol,
        units,
        opts
      ) do
    deliver_goods_intent(agent, ship_symbol, waypoint, contract_id, trade_symbol, units, opts)
  end

  def deliver_goods_intent(
        agent,
        ship_symbol,
        waypoint,
        contract_id,
        trade_symbol,
        units,
        opts
      ) do
    opts =
      Keyword.merge(opts,
        contract_id: contract_id,
        recipient: %{type: "contract", contract_id: contract_id, waypoint: waypoint}
      )

    case opts[:caller] do
      "job" ->
        with %Job{} = job <- Repo.get(Job, opts[:job_id]),
             {:ok, ship} <- owned_ship(agent, ship_symbol),
             true <- job.ship_id == ship.id and Job.running?(job),
             {:ok, live_ship} <- live_ship_for_job_intent(agent, ship_symbol, opts),
             {:ok, intent} <-
               insert_job_intent(job, %{
                 type: "deliver",
                 target_waypoint: waypoint,
                 parameters:
                   opts
                   |> Keyword.delete(:live_ship)
                   |> Map.new()
                   |> Map.put(:trade_symbol, trade_symbol)
                   |> Map.put(:units, units)
                   |> Map.new(fn {key, value} -> {to_string(key), value} end)
                   |> then(&normalize_delivery_recipient("deliver", &1, waypoint))
               }) do
          advance_intents(agent, intent, live_ship)
        else
          false -> {:error, :invalid_cargo_intent_owner}
          error -> error
        end

      _ ->
        cargo_intent(agent, ship_symbol, "deliver", waypoint, trade_symbol, units, opts)
    end
  end

  @doc "Starts a durable Deliver Goods Intent for a Construction recipient."
  def deliver_construction_goods_intent(
        agent,
        ship_symbol,
        system_symbol,
        waypoint,
        trade_symbol,
        units,
        opts \\ []
      ) do
    with {:ok, live_ship} <-
           construction_live_ship(agent, ship_symbol, opts),
         {:ok, ^system_symbol} <- system_from_headquarters(waypoint),
         true <- live_ship.nav.system_symbol == system_symbol do
      opts =
        Keyword.merge(opts,
          recipient: %{type: "construction", system: system_symbol, waypoint: waypoint}
        )

      case opts[:caller] do
        "job" ->
          with %Job{} = job <- Repo.get(Job, opts[:job_id]),
               {:ok, ship} <- owned_ship(agent, ship_symbol),
               true <- job.ship_id == ship.id and Job.running?(job),
               {:ok, intent} <-
                 insert_job_intent(job, %{
                   type: "deliver",
                   target_waypoint: waypoint,
                   parameters:
                     opts
                     |> Keyword.delete(:live_ship)
                     |> Map.new()
                     |> Map.put(:trade_symbol, trade_symbol)
                     |> Map.put(:units, units)
                     |> Map.new(fn {key, value} -> {to_string(key), value} end)
                 }) do
            advance_intents(agent, intent, live_ship)
          else
            false -> {:error, :invalid_cargo_intent_owner}
            error -> error
          end

        _ ->
          cargo_intent(agent, ship_symbol, "deliver", waypoint, trade_symbol, units, opts)
      end
    else
      false -> {:error, :remote_destination_system_unsupported}
      {:ok, _system} -> {:error, :remote_destination_system_unsupported}
      error -> error
    end
  end

  defp construction_live_ship(agent, ship_symbol, opts) do
    case opts[:live_ship] do
      %SpaceTraders.API.Model.Ship{symbol: ^ship_symbol} = ship ->
        {:ok, ship}

      %SpaceTraders.API.Model.Ship{} ->
        {:error, :invalid_cargo_intent_owner}

      _ ->
        Agent.handle_game_result(agent, SpaceTraders.API.get_ship(agent.agent_token, ship_symbol))
    end
  end

  @doc "Starts a module Intent for Manual Control or a Ship Outfitting Job."
  def request_module_intent(agent, :manual, ship_symbol, type, module_symbol, parameters)
      when type in ["install_module", "remove_module"] and is_map(parameters) do
    authorized_removals =
      parameters[:authorized_removals] || parameters["authorized_removals"] || %{}

    module_intent(agent, ship_symbol, type, module_symbol, authorized_removals)
  end

  def request_module_intent(
        %AgentRecord{} = agent,
        %Job{type: "outfitting", id: job_id, ship_id: ship_id},
        ship_symbol,
        type,
        module_symbol,
        parameters
      )
      when type in ["install_module", "remove_module"] and is_map(parameters) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         true <- ship.id == ship_id,
         %Job{} = current_job <- Repo.get(Job, job_id),
         true <- current_job.ship_id == ship_id and Job.running?(current_job),
         {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ),
         {:ok, intent} <-
           insert_module_job_intent(current_job, ship_id, type, module_symbol, parameters) do
      advance_intents(agent, intent, live_ship)
    else
      false -> {:error, :invalid_module_intent}
      error -> error
    end
  end

  def request_module_intent(_, _, _, _, _, _), do: {:error, :invalid_module_intent}

  defp insert_module_job_intent(job, ship_id, type, module_symbol, parameters) do
    Repo.transaction(fn ->
      current_job = Repo.get(Job, job.id)

      unless match?(%Job{type: "outfitting", ship_id: ^ship_id}, current_job) and
               Job.running?(current_job) do
        Repo.rollback(:invalid_module_intent)
      end

      authorized = get_in(current_job.progress, ["authorized_removals"]) || %{}
      removed = get_in(current_job.progress, ["removed_modules", module_symbol]) || 0
      allowance = Map.get(authorized, module_symbol, 0) - removed

      if type == "remove_module" and allowance < 1 do
        Repo.rollback(:invalid_module_intent)
      end

      case insert_job_intent(current_job, %{
             type: type,
             target_waypoint: module_symbol,
             parameters:
               parameters
               |> Map.put("authorized_removals", %{module_symbol => 1})
               |> Map.merge(%{"caller" => "job", "job_id" => current_job.id})
           }) do
        {:ok, intent} -> intent
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp module_intent(
         %AgentRecord{agent_token: token} = agent,
         ship_symbol,
         type,
         module_symbol,
         authorized_removals
       )
       when is_binary(token) and token != "" do
    parameters = %{
      "caller" => "manual",
      "module_symbol" => module_symbol,
      "quantity" => 1,
      "authorized_removals" => stringify_keys(authorized_removals)
    }

    with true <- type in ["install_module", "remove_module"],
         true <- is_binary(module_symbol) and module_symbol != "",
         true <- valid_module_removal?(type, module_symbol, parameters["authorized_removals"]),
         {:ok, ship} <- owned_ship(agent, ship_symbol) do
      case reconcile_pending_module_intent(agent, ship, type, module_symbol) do
        {:resolved, intent} -> {:ok, intent}
        :ok -> start_module_intent(agent, ship, type, module_symbol, parameters)
        error -> error
      end
    else
      false -> {:error, :invalid_module_intent}
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
    end
  end

  defp module_intent(%AgentRecord{}, _ship_symbol, _type, _module_symbol, _authorized_removals),
    do: {:error, :agent_token_missing}

  defp valid_module_removal?("install_module", _module_symbol, _authorized_removals), do: true

  defp valid_module_removal?("remove_module", module_symbol, authorized_removals) do
    authorized_removals == %{module_symbol => 1}
  end

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp stringify_keys(_), do: %{}

  # An unknown mutation outcome must be reconciled before a later Manual Control
  # request can replace its durable evidence and accidentally repeat the command.
  defp reconcile_pending_module_intent(agent, ship, requested_type, requested_module_symbol) do
    case unfinished_intents(ship.id) do
      %Intent{type: type, in_flight_action: action} = intent
      when type in ["install_module", "remove_module"] and is_map(action) ->
        case reconcile_intents(agent, intent) do
          {:ok, %Intent{in_flight_action: action}} when is_map(action) ->
            {:error, :intents_reconciliation_required}

          {:ok, intent} ->
            if intent.type == requested_type and
                 intent.parameters["module_symbol"] == requested_module_symbol,
               do: {:resolved, intent},
               else: :ok
        end

      _ ->
        :ok
    end
  end

  defp start_module_intent(agent, ship, type, module_symbol, parameters) do
    with :ok <-
           preempt_miner_job_for(agent, ship.symbol, {:manual_override, "module modification"}),
         {:ok, intent} <-
           replace_intents(ship, %{
             type: type,
             target_waypoint: module_symbol,
             parameters: parameters
           }) do
      reconcile_intents(agent, intent)
    else
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
    end
  end

  defp cargo_intent(
         %AgentRecord{agent_token: token} = agent,
         ship_symbol,
         type,
         waypoint,
         trade_symbol,
         units,
         opts
       )
       when is_binary(token) and token != "" do
    caller = opts[:caller] || "manual"

    parameters =
      opts
      |> Map.new()
      |> Map.put(:caller, caller)
      |> Map.put(:trade_symbol, trade_symbol)
      |> Map.put(:units, units)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)

    parameters = normalize_delivery_recipient(type, parameters, waypoint)

    with true <- type in ["buy", "sell", "deliver"],
         :ok <- validate_intent_waypoint(waypoint),
         true <-
           is_binary(trade_symbol) and trade_symbol != "" and is_integer(units) and units > 0,
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         true <- valid_cargo_constraints?(type, parameters),
         :ok <- validate_cargo_caller(ship, caller, parameters),
         :ok <- preempt_for_cargo_intent(agent, ship_symbol, type, caller),
         {:ok, intent} <-
           replace_intents(ship, %{
             type: type,
             target_waypoint: waypoint,
             parameters: parameters
           }) do
      reconcile_intents(agent, intent)
    else
      false -> {:error, :invalid_cargo_intent}
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
    end
  end

  defp cargo_intent(%AgentRecord{}, _ship_symbol, _type, _waypoint, _trade_symbol, _units, _opts),
    do: {:error, :agent_token_missing}

  defp normalize_delivery_recipient("deliver", %{"recipient" => recipient} = parameters, waypoint)
       when is_map(recipient) do
    Map.put(parameters, "recipient", %{
      "type" => recipient[:type] || recipient["type"],
      "contract_id" => recipient[:contract_id] || recipient["contract_id"],
      "system" => recipient[:system] || recipient["system"],
      "waypoint" => recipient[:waypoint] || recipient["waypoint"] || waypoint
    })
  end

  defp normalize_delivery_recipient("deliver", parameters, waypoint),
    do:
      Map.put(parameters, "recipient", %{
        "type" => "contract",
        "contract_id" => parameters["contract_id"],
        "waypoint" => waypoint
      })

  defp normalize_delivery_recipient(_type, parameters, _waypoint), do: parameters

  defp preempt_for_cargo_intent(agent, ship_symbol, type, caller) do
    if caller == "job" do
      :ok
    else
      preempt_miner_job_for(agent, ship_symbol, {:manual_override, "#{type} goods"})
    end
  end

  defp valid_cargo_constraints?("buy", parameters) do
    Enum.all?(["max_price", "max_unit_price", "max_total_price", "reserve_credits"], fn key ->
      is_nil(parameters[key]) or (is_integer(parameters[key]) and parameters[key] >= 0)
    end)
  end

  defp valid_cargo_constraints?(_type, _parameters), do: true

  defp validate_cargo_caller(_ship, "manual", _parameters), do: :ok

  defp validate_cargo_caller(ship, "job", %{"job_id" => job_id}) when is_integer(job_id) do
    case Repo.get(Job, job_id) do
      %Job{ship_id: ship_id, type: type} = job ->
        if ship_id == ship.id and
             type in [
               "miner",
               "procurement",
               "construction_supply",
               "outfitting",
               "market_trading"
             ] and Job.running?(job),
           do: :ok,
           else: {:error, :invalid_cargo_intent_owner}

      _ ->
        {:error, :invalid_cargo_intent_owner}
    end
  end

  defp validate_cargo_caller(_ship, _caller, _parameters),
    do: {:error, :invalid_cargo_intent_owner}

  @doc "Returns a Ship's unfinished Manual Control Intent, or nil."
  def ship_intents(%AgentRecord{} = agent, ship_symbol) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} -> unfinished_intents(ship.id)
      _ -> nil
    end
  end

  @doc "Stops a Ship's unfinished Manual Control Intent; the assigned Job remains paused."
  def stop_intents(%AgentRecord{} = agent, ship_symbol) do
    case ship_intents(agent, ship_symbol) do
      %Intent{id: intent_id} -> SpaceTraders.Fleet.Intents.stop(agent, :manual, intent_id)
      nil -> {:error, :intents_not_active}
    end
  end

  def stop_intent_legacy(%AgentRecord{} = agent, intent_id, owner \\ :manual) do
    case Repo.transaction(
           fn ->
             intent =
               Repo.one(
                 from intent in Intent,
                   join: ship in Ship,
                   on: ship.id == intent.ship_id,
                   where:
                     intent.id == ^intent_id and ship.agent_id == ^agent.id and
                       intent.status in ^@unfinished_intent_states
               )

             case intent do
               %Intent{} = intent ->
                 cond do
                   owner == :manual and intent.caller != "manual" ->
                     Repo.rollback(:invalid_intent_owner)

                   is_struct(owner, Job) and
                       (intent.caller != "job" or intent.job_id != owner.id) ->
                     Repo.rollback(:invalid_intent_owner)

                   unresolved_cargo_action?(intent) ->
                     Repo.rollback(:cargo_operation_reconciliation_required)

                   unresolved_module_evidence?(intent) ->
                     Repo.rollback(:intents_reconciliation_required)

                   unresolved_jump_action?(intent) or unresolved_warp_action?(intent) ->
                     Repo.rollback(:intents_reconciliation_required)

                   unresolved_navigation_action?(intent) ->
                     Repo.rollback(:intents_reconciliation_required)

                   true ->
                     terminalize_intents!(intent, "stopped")
                 end

               nil ->
                 Repo.rollback(:intents_not_active)
             end
           end,
           mode: :immediate
         ) do
      {:ok, %Intent{} = intent} ->
        ship = Repo.get!(Ship, intent.ship_id)

        record_activity(
          agent,
          ship,
          "manual_intent_stopped",
          "Navigate to #{intent.target_waypoint} stopped"
        )

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Reconciles the Ship's Manual Control Intent after an authoritative arrival."
  def revalidate_intents_arrival(agent_id, ship_symbol, live_ship, expected_intent_id) do
    revalidate_intents(agent_id, ship_symbol, live_ship, expected_intent_id)
  end

  @doc "Reconciles the Ship's Manual Control Intent after an authoritative cooldown."
  def revalidate_intents_cooldown(agent_id, ship_symbol, live_ship, expected_intent_id) do
    revalidate_intents(agent_id, ship_symbol, live_ship, expected_intent_id)
  end

  @doc "Reconciles whichever Navigate owner scheduled a durable Ship timer."
  def reconcile_timeline_event(
        agent_id,
        ship_symbol,
        live_ship,
        trigger,
        expected_intent_id,
        expected_job_id
      ) do
    cond do
      is_integer(expected_intent_id) ->
        revalidate_intents(agent_id, ship_symbol, live_ship, expected_intent_id)

      is_integer(expected_job_id) and unfinished_intent_for_ship_symbol?(agent_id, ship_symbol) ->
        :ok

      trigger == :arrival ->
        revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship, expected_job_id)

      trigger == :cooldown ->
        revalidate_miner_job_cooldown(agent_id, ship_symbol, live_ship, expected_job_id)

      true ->
        :ok
    end
  end

  defp unfinished_intent_for_ship_symbol?(agent_id, ship_symbol) do
    with %Ship{id: ship_id} <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %Intent{} <- unfinished_intent_for_ship(ship_id) do
      true
    else
      _ -> false
    end
  end

  # The Navigate Intent reconcile loop. Every step derives the next API action
  # from authoritative Ship state — location, navigation state, posture, fuel,
  # arrival, and cooldown — so recovery can resume from game truth instead of
  # replaying a fixed script.
  defp advance_intents(agent, intent, live_ship) do
    do_advance_intents(agent, intent, live_ship)
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
         %Intent{type: "navigate", in_flight_action: %{"kind" => "jump"}} = intent,
         live_ship
       ) do
    if arrived_at_target?(live_ship, intent.target_waypoint) do
      complete_intents(agent, intent)
    else
      block_intents(intent, :ambiguous_jump_evidence)
    end
  end

  defp do_advance_intents(
         agent,
         %Intent{type: "navigate", in_flight_action: %{"kind" => "warp"}} = intent,
         live_ship
       ) do
    cond do
      arrived_at_target?(live_ship, intent.target_waypoint) ->
        complete_intents(agent, intent)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      true ->
        block_intents(intent, :ambiguous_warp_evidence)
    end
  end

  defp do_advance_intents(agent, %Intent{type: "navigate"} = intent, live_ship) do
    cond do
      arrived_at_target?(live_ship, intent.target_waypoint) ->
        complete_intents(agent, intent)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      arrived_at_intermediate_waypoint?(intent, live_ship) ->
        case transition_intent(intent, in_flight_action: nil) do
          {:ok, intent} -> advance_intents(agent, intent, live_ship)
          :intent_no_longer_owned -> :ok
        end

      docked?(live_ship) ->
        orbit_for_intents(agent, intent, live_ship)

      remote_waypoint?(live_ship.nav.waypoint_symbol, intent.target_waypoint) ->
        advance_manual_remote_route(agent, intent, live_ship)

      fuel_empty?(live_ship) ->
        block_intents(intent, {:insufficient_fuel, intent.target_waypoint})

      true ->
        dispatch_manual_navigate(agent, intent, live_ship)
    end
  end

  defp do_advance_intents(agent, %Intent{type: type} = intent, live_ship)
       when type in ["install_module", "remove_module"] do
    case intent.in_flight_action do
      %{"kind" => ^type} = action -> reconcile_module_intent(intent, live_ship, action)
      _ -> dispatch_module_intent(agent, intent, live_ship)
    end
  end

  defp do_advance_intents(agent, %Intent{type: type} = intent, live_ship)
       when type in ["buy", "sell", "deliver"] do
    case intent.in_flight_action do
      %{"kind" => kind} when kind in ["navigate", "orbit", "dock"] ->
        # Prerequisites are proved by the authoritative Ship state and may safely resume.
        case transition_intent(intent, in_flight_action: nil) do
          {:ok, intent} -> advance_intents(agent, intent, live_ship)
          :intent_no_longer_owned -> :ok
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

  defp advance_cargo_intent(agent, intent, live_ship) do
    cond do
      live_ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_cargo_navigation(agent, intent, live_ship)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      not docked?(live_ship) ->
        dock_for_cargo_intent(agent, intent, live_ship)

      true ->
        dispatch_cargo_intent(agent, intent, live_ship)
    end
  end

  defp advance_cargo_navigation(agent, intent, live_ship) do
    cond do
      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      cooldown_active?(live_ship) ->
        wait_for_manual_cooldown(agent, intent, live_ship)

      docked?(live_ship) ->
        orbit_for_intents(agent, intent, live_ship)

      fuel_empty?(live_ship) ->
        block_cargo_intent(intent, {:insufficient_fuel, intent.target_waypoint})

      true ->
        dispatch_manual_navigate(agent, intent, live_ship)
    end
  end

  defp dock_for_cargo_intent(agent, intent, live_ship) do
    with {:ok, intent} <-
           claim_intent_action(intent, %{
             "kind" => "dock",
             "waypoint" => live_ship.nav.waypoint_symbol
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.dock_ship(agent.agent_token, live_ship.symbol)
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
      {:error, _reason} -> :ok
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

  defp dispatch_or_complete_construction(agent, intent, live_ship, recipient) do
    with {:ok, units, _credits} <- executable_cargo_units(intent, live_ship, recipient, agent) do
      action =
        %{
          "kind" => "deliver",
          "trade_symbol" => intent.parameters["trade_symbol"],
          "units" => units,
          "recipient" => intent.parameters["recipient"]
        }
        |> delivery_action_evidence(recipient, live_ship.cargo, intent.parameters["trade_symbol"])

      with {:ok, intent} <- claim_intent_action(intent, action) do
        execute_cargo_intent(agent, intent, live_ship, units, recipient)
      else
        {:error, _reason} -> :ok
      end
    else
      {:error, reason} -> block_cargo_intent(intent, reason)
    end
  end

  defp dispatch_market_cargo_intent(agent, intent, live_ship) do
    with {:ok, good} <- market_good_for_intent(agent, live_ship, intent),
         {:ok, units, _credits} <- executable_cargo_units(intent, live_ship, good, agent) do
      action = %{
        "kind" => intent.type,
        "trade_symbol" => intent.parameters["trade_symbol"],
        "units" => units,
        "listing_price" => cargo_price(intent.type, good)
      }

      with {:ok, intent} <- claim_intent_action(intent, action) do
        execute_cargo_intent(agent, intent, live_ship, units, good)
      else
        {:error, _reason} -> :ok
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
    with {:ok, market} <- market_for_ship(agent, live_ship, intent.target_waypoint),
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
    held = item_units(live_ship, parameters["trade_symbol"])

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
    held = item_units(live_ship, parameters["trade_symbol"])
    remaining = fulfillment_remaining(contract, parameters["trade_symbol"])
    units = min(parameters["units"], min(held, remaining))

    if units > 0,
      do: {:ok, units, nil},
      else: {:error, if(remaining <= 0, do: :recipient_rejected_delivery, else: :cargo_missing)}
  end

  defp affordable_cargo_units(_credits, 0), do: :infinity
  defp affordable_cargo_units(credits, price), do: div(credits, price)

  defp execute_cargo_intent(agent, %Intent{type: "buy"} = intent, live_ship, units, good) do
    case execute_cargo_operation(
           agent,
           "buy",
           live_ship,
           intent.parameters["trade_symbol"],
           units
         ) do
      {:ok, result} ->
        complete_market_cargo_intent(agent, intent, units, good.purchase_price, result)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp execute_cargo_intent(agent, %Intent{type: "sell"} = intent, live_ship, units, good) do
    case execute_cargo_operation(
           agent,
           "sell",
           live_ship,
           intent.parameters["trade_symbol"],
           units
         ) do
      {:ok, result} ->
        complete_market_cargo_intent(agent, intent, units, good.sell_price, result)

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp execute_cargo_intent(
         agent,
         %Intent{type: "deliver"} = intent,
         live_ship,
         units,
         {:contract, _contract}
       ) do
    with {:ok, contract} <- procurement_contract_for_intent(agent, intent),
         {:ok, result} <-
           execute_cargo_operation(
             agent,
             "deliver",
             live_ship,
             intent.parameters["trade_symbol"],
             units,
             contract_id_from_action(intent)
           ) do
      case result.contract do
        recipient when is_map(recipient) ->
          accepted = delivered_units(contract, recipient, intent.parameters["trade_symbol"])

          with :ok <-
                 verify_delivery_result(intent, recipient, intent.parameters["trade_symbol"]),
               true <- accepted > 0 do
            complete_cargo_intent(agent, intent, accepted, nil, result)
          else
            false -> block_cargo_intent(intent, :recipient_rejected_delivery)
            {:error, reason} -> block_cargo_intent(intent, reason)
          end

        _ ->
          block_cargo_intent(intent, :missing_delivery_recipient)
      end
    else
      {:error, %SpaceTraders.API.Error{} = reason} -> block_cargo_intent(intent, reason)
      {:error, reason} -> block_cargo_intent(intent, reason)
    end
  end

  defp execute_cargo_intent(
         agent,
         %Intent{type: "deliver"} = intent,
         live_ship,
         units,
         {:construction, construction}
       ) do
    recipient = intent.parameters["recipient"]

    if construction.is_complete do
      complete_cargo_intent(
        agent,
        intent,
        0,
        nil,
        %{construction: construction, external_completion: true}
      )
    else
      execute_construction_delivery(agent, intent, live_ship, units, recipient, construction)
    end
  end

  defp execute_construction_delivery(agent, intent, live_ship, units, recipient, construction) do
    case supply_construction(
           agent,
           recipient["system"],
           recipient["waypoint"],
           live_ship.symbol,
           intent.parameters["trade_symbol"],
           units
         ) do
      {:ok, %{construction: updated} = result} ->
        accepted = construction_response_accepted_units(intent, result, construction, updated)

        if is_integer(accepted) and accepted > 0 do
          complete_cargo_intent(agent, intent, accepted, nil, result)
        else
          block_cargo_intent(intent, {:ambiguous_operation_evidence, "deliver"})
        end

      {:error, reason} ->
        block_cargo_intent(intent, reason)
    end
  end

  defp construction_response_accepted_units(intent, result, before, updated) do
    trade_symbol = intent.parameters["trade_symbol"]
    claimed = get_in(intent.in_flight_action, ["units"])
    cargo_before = get_in(intent.in_flight_action, ["cargo_before"])

    with true <- is_integer(claimed) and claimed > 0,
         true <- is_integer(cargo_before),
         cargo when not is_nil(cargo) <- result.cargo,
         cargo_delta = cargo_before - item_units(cargo, trade_symbol),
         fulfilled_delta = delivered_construction_units(before, updated, trade_symbol),
         true <- cargo_delta > 0 and cargo_delta <= claimed and fulfilled_delta >= cargo_delta do
      cargo_delta
    else
      _ -> nil
    end
  end

  defp cargo_price("buy", good), do: good.purchase_price
  defp cargo_price("sell", good), do: good.sell_price
  defp cargo_price(_, _good), do: nil

  # Serialize the final ownership check with writing the request fingerprint.
  # A paused/replaced Job can therefore never dispatch an action from a stale
  # callback after another process changed its intent.
  defp claim_intent_action(intent, action) do
    Repo.transaction(
      fn ->
        current = Repo.get(Intent, intent.id)

        if (current && Intent.unfinished?(current)) and is_nil(current.in_flight_action) and
             intent_owned_by_running_job_or_manual?(current) do
          Repo.update!(Ecto.Changeset.change(current, status: "active", in_flight_action: action))
        else
          Repo.rollback(:intent_dispatch_no_longer_allowed)
        end
      end,
      mode: :immediate
    )
  end

  # Job callbacks may outlive a pause or preemption. Every durable transition
  # therefore reloads both records under the write lock; manual intents retain
  # their normal unfinished-state behavior.
  defp with_current_intent(%Intent{id: id}, fun) do
    case Repo.transaction(
           fn ->
             case Repo.get(Intent, id) do
               %Intent{} = current ->
                 if Intent.unfinished?(current) and
                      intent_owned_by_running_job_or_manual?(current) do
                   fun.(current)
                 else
                   Repo.rollback(:intent_no_longer_owned)
                 end

               _ ->
                 Repo.rollback(:intent_no_longer_owned)
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, :intent_no_longer_owned} -> :intent_no_longer_owned
    end
  end

  defp transition_intent(intent, attrs) do
    with_current_intent(intent, fn current ->
      {:ok, Repo.update!(Ecto.Changeset.change(current, attrs))}
    end)
  end

  defp intent_owned_by_running_job_or_manual?(%Intent{caller: "job", job_id: job_id}) do
    case Repo.get(Job, job_id) do
      %Job{} = job -> Job.running?(job)
      nil -> false
    end
  end

  defp intent_owned_by_running_job_or_manual?(%Intent{}), do: true

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
        if units == intent.parameters["units"],
          do: complete_cargo_intent(agent, intent, units, price, result),
          else: block_cargo_intent(intent, :buy_quantity_unfulfilled)

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
        if intent.type == "sell" and not sale_cargo_evidence?(result.cargo) do
          block_cargo_intent(intent, :unexpected_sale_cargo)
        else
          complete_cargo_intent(agent, intent, units, price, result)
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
    complete_cargo_intent_without_transaction(intent, units, price, result)
  end

  defp complete_market_cargo_intent(_agent, intent, _units, _price, _result),
    do: block_cargo_intent(intent, :missing_market_transaction)

  defp complete_cargo_intent_without_transaction(intent, units, price, _result) do
    result = %{"kind" => "sell", "units" => units, "price" => price}

    transition_intent(intent,
      status: "completed",
      in_flight_action: nil,
      last_action_result: result,
      blocker: nil,
      finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
  end

  defp sale_cargo_evidence?(cargo), do: is_map(cargo)

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

  # Cargo mutations are shared by Manual Control and Procurement. Callers persist
  # their own in-flight evidence before dispatching, then derive completion from
  # the authoritative response appropriate to their policy.
  defp execute_cargo_operation(agent, type, live_ship, trade_symbol, units, contract_id \\ nil)

  defp execute_cargo_operation(agent, "buy", live_ship, trade_symbol, units, _contract_id) do
    Agent.handle_game_result(
      agent,
      SpaceTraders.API.purchase_cargo(agent.agent_token, live_ship.symbol, trade_symbol, units)
    )
  end

  defp execute_cargo_operation(agent, "sell", live_ship, trade_symbol, units, _contract_id) do
    Agent.handle_game_result(
      agent,
      SpaceTraders.API.sell_cargo(agent.agent_token, live_ship.symbol, trade_symbol, units)
    )
  end

  defp execute_cargo_operation(agent, "deliver", live_ship, trade_symbol, units, contract_id) do
    Agent.handle_game_result(
      agent,
      Contracts.deliver_goods(agent, contract_id, live_ship.symbol, trade_symbol, units)
    )
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
    case module_mutation_allowed?(intent, live_ship) do
      :ok -> dispatch_module_request(agent, intent, live_ship)
      {:error, reason} -> block_module_intent(intent, reason)
    end
  end

  defp dispatch_module_request(agent, intent, live_ship) do
    module_symbol = intent.parameters["module_symbol"]
    installed_before = module_count(live_ship.modules, module_symbol)
    cargo_before = item_units(live_ship.cargo, module_symbol)

    action = %{
      "kind" => intent.type,
      "module_symbol" => module_symbol,
      "quantity" => 1,
      "installed_before" => installed_before,
      "cargo_before" => cargo_before
    }

    case claim_intent_action(intent, action) do
      {:ok, intent} ->
        result =
          case intent.type do
            "install_module" ->
              SpaceTraders.API.install_ship_module(
                agent.agent_token,
                live_ship.symbol,
                module_symbol
              )

            "remove_module" ->
              SpaceTraders.API.remove_ship_module(
                agent.agent_token,
                live_ship.symbol,
                module_symbol
              )
          end

        case Agent.handle_game_result(agent, result) do
          {:ok, result} ->
            if module_modification_evidence?(intent, result.modules, result.cargo) do
              complete_module_intent(intent, result)
            else
              block_module_intent_preserving_evidence(intent, :module_modification_unconfirmed)
            end

          {:error, %SpaceTraders.API.Error{} = reason} ->
            await_module_reconciliation(intent, reason)

          {:error, reason} ->
            block_module_intent(intent, reason)
        end

      {:error, :intent_dispatch_no_longer_allowed} ->
        :ok
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
        cargo_units = item_units(live_ship.cargo, module_symbol)
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

  defp reconcile_module_intent(intent, live_ship, action) do
    module_symbol = action["module_symbol"]
    installed_before = action["installed_before"]
    cargo_before = action["cargo_before"]
    installed_now = module_count(live_ship.modules, module_symbol)
    cargo_now = item_units(live_ship.cargo, module_symbol)

    completed? =
      case intent.type do
        "install_module" ->
          installed_now == installed_before + 1 and cargo_now == cargo_before - 1

        "remove_module" ->
          installed_now == installed_before - 1 and cargo_now == cargo_before + 1
      end

    if completed?,
      do: complete_module_intent(intent, %{modules: live_ship.modules, cargo: live_ship.cargo}),
      else: block_module_intent_preserving_evidence(intent, :ambiguous_module_modification)
  end

  defp complete_module_intent(intent, result) do
    module_symbol = intent.parameters["module_symbol"]

    intent =
      Repo.update!(
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
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: job_blocker({:awaiting_reconciliation, reason}),
          last_action_result: %{"kind" => intent.type, "error" => inspect(reason)}
        )
      )

    {:ok, intent}
  end

  defp block_module_intent(intent, reason) do
    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: job_blocker(intents_block_reason(reason)),
          in_flight_action: nil,
          last_action_result: %{"kind" => intent.type, "error" => inspect(reason)}
        )
      )

    {:ok, intent}
  end

  defp block_module_intent_preserving_evidence(intent, reason) do
    intent =
      Repo.update!(
        Ecto.Changeset.change(intent,
          status: "blocked",
          blocker: job_blocker(reason),
          last_action_result: %{"kind" => intent.type, "error" => inspect(reason)}
        )
      )

    {:ok, intent}
  end

  defp module_count(modules, symbol), do: Enum.count(modules || [], &(&1.symbol == symbol))
  defp module_intent_verb("install_module"), do: "Install"
  defp module_intent_verb("remove_module"), do: "Remove"

  defp module_modification_evidence?(intent, modules, cargo) do
    action = intent.in_flight_action
    module_symbol = action["module_symbol"]
    installed_before = action["installed_before"]
    cargo_before = action["cargo_before"]
    installed_now = module_count(modules, module_symbol)
    cargo_now = item_units(cargo, module_symbol)

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
    do: Map.put(result, "transaction", transaction_evidence(transaction))

  defp maybe_put_transaction(result, _response), do: result

  defp maybe_put_delivery(result, %{contract: contract}, "deliver") do
    Map.put(result, "recipient", contract_delivery_evidence(contract, result["trade_symbol"]))
  end

  defp maybe_put_delivery(result, %{construction: construction}, "deliver") do
    Map.put(
      result,
      "recipient",
      construction_delivery_evidence(construction, result["trade_symbol"])
    )
  end

  defp maybe_put_delivery(result, _response, _type), do: result

  defp block_cargo_intent(intent, reason) do
    evidence = %{
      "target" => intent.target_waypoint,
      "trade_good" => intent.parameters["trade_symbol"],
      "constraint" => intent.parameters,
      "observed" => inspect(reason)
    }

    case transition_intent(intent,
           status: "blocked",
           blocker: %{job_blocker(reason) | evidence: inspect(evidence)},
           in_flight_action:
             if(ambiguous_cargo_operation_error?(reason), do: intent.in_flight_action, else: nil),
           last_action_result: %{"kind" => intent.type, "error" => cargo_error_message(reason)}
         ) do
      {:ok, intent} -> {:ok, intent}
      :intent_no_longer_owned -> :ok
    end
  end

  defp cargo_error_message(%{message: message}) when is_binary(message), do: message
  defp cargo_error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cargo_error_message(reason), do: inspect(reason)

  defp ambiguous_cargo_operation_error?(%SpaceTraders.API.Error{}), do: true
  defp ambiguous_cargo_operation_error?({:ambiguous_operation_evidence, _type}), do: true

  defp ambiguous_cargo_operation_error?(reason)
       when reason in [
              :missing_market_transaction,
              :unexpected_market_transaction,
              :missing_delivery_recipient,
              :unexpected_delivery_recipient
            ],
       do: true

  defp ambiguous_cargo_operation_error?(_reason), do: false

  defp procurement_contract_for_intent(agent, intent) do
    delivery_contract_for_intent(agent, intent)
  end

  defp delivery_contract_for_intent(agent, intent) do
    with {:ok, %{"contract_id" => contract_id, "waypoint" => waypoint}} <-
           delivery_recipient(intent),
         true <- waypoint == intent.target_waypoint do
      case Contracts.list_contracts(agent) do
        {:ok, contracts} ->
          case Enum.find(contracts, &(&1.id == contract_id)) do
            %Contract{} = contract ->
              if Contracts.fulfillable?(contract),
                do: {:ok, contract},
                else: {:error, :recipient_unavailable}

            nil ->
              {:error, :recipient_unavailable}
          end

        {:error, _reason} ->
          {:ok,
           Contract.from_json(%{
             "id" => contract_id,
             "accepted" => true,
             "fulfilled" => false,
             "terms" => %{
               "deadline" => "9999-01-01T00:00:00Z",
               "deliver" => [
                 %{
                   "tradeSymbol" => intent.parameters["trade_symbol"],
                   "destinationSymbol" => waypoint,
                   "unitsRequired" => intent.parameters["units"],
                   "unitsFulfilled" => 0
                 }
               ]
             }
           })}
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
               SpaceTraders.API.get_construction(agent.agent_token, system, waypoint)
             ) do
          {:ok, construction} ->
            record_construction_observation(agent, system, construction, "get_construction")
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

  defp contract_id_from_action(intent) do
    with {:ok, %{"contract_id" => contract_id}} <- delivery_recipient(intent), do: contract_id
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
           find_deliverable(contract, trade_symbol) do
      :ok
    else
      _ -> {:error, :unexpected_delivery_recipient}
    end
  end

  defp delivered_units(before, recipient, trade_symbol) do
    max(fulfilled_units(recipient, trade_symbol) - fulfilled_units(before, trade_symbol), 0)
  end

  defp delivered_construction_units(before, recipient, trade_symbol) do
    max(
      construction_fulfilled_units(recipient, trade_symbol) -
        construction_fulfilled_units(before, trade_symbol),
      0
    )
  end

  defp delivery_action_evidence(action, {:construction, construction}, cargo, trade_symbol) do
    action
    |> Map.put("fulfilled_before", construction_fulfilled_units(construction, trade_symbol))
    |> Map.put("cargo_before", item_units(cargo, trade_symbol))
  end

  defp delivery_action_evidence(action, {:contract, contract}, cargo, trade_symbol) do
    action
    |> Map.put("fulfilled_before", fulfilled_units(contract, trade_symbol))
    |> Map.put("cargo_before", item_units(cargo, trade_symbol))
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
         {:ok, recipient} <- delivery_recipient_for_intent(agent, intent),
         result <-
           reconcile_delivery_evidence(recipient, action, live_ship.cargo, fulfilled_before) do
      case result do
        {:accepted, units} ->
          complete_cargo_intent(agent, intent, units, nil, %{})

        :external_completion ->
          complete_cargo_intent(agent, intent, 0, nil, %{
            construction: elem(recipient, 1),
            external_completion: true
          })

        :ambiguous ->
          block_cargo_intent(intent, {:ambiguous_operation_evidence, "deliver"})
      end
    else
      _ -> block_cargo_intent(intent, {:ambiguous_operation_evidence, "deliver"})
    end
  end

  defp reconcile_delivery_evidence({:construction, construction}, action, cargo, fulfilled_before) do
    with trade_symbol when is_binary(trade_symbol) <- action["trade_symbol"],
         cargo_before when is_integer(cargo_before) <- action["cargo_before"],
         units when is_integer(units) and units > 0 <- action["units"] do
      fulfilled_delta =
        construction_fulfilled_units(construction, trade_symbol) - fulfilled_before

      cargo_delta = cargo_before - item_units(cargo, trade_symbol)

      cond do
        construction.is_complete and cargo_delta == 0 ->
          :external_completion

        cargo_delta > 0 and cargo_delta <= units and fulfilled_delta >= cargo_delta ->
          {:accepted, cargo_delta}

        true ->
          :ambiguous
      end
    else
      _ -> :ambiguous
    end
  end

  defp reconcile_delivery_evidence({_type, recipient}, action, cargo, fulfilled_before) do
    accepted = recipient_fulfilled_units(recipient, action["trade_symbol"]) - fulfilled_before
    if delivery_evidence?(action, cargo, accepted), do: {:accepted, accepted}, else: :ambiguous
  end

  defp delivery_evidence?(action, cargo, accepted) do
    with units when is_integer(units) <- action["units"],
         cargo_before when is_integer(cargo_before) <- action["cargo_before"],
         trade_symbol when is_binary(trade_symbol) <- action["trade_symbol"] do
      accepted > 0 and accepted <= units and
        item_units(cargo, trade_symbol) == cargo_before - accepted
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

  defp reconcile_intents(agent, intent) do
    ship = Repo.get!(Ship, intent.ship_id)

    case Agent.handle_game_result(
           agent,
           SpaceTraders.API.get_ship(agent.agent_token, ship.symbol)
         ) do
      {:ok, live_ship} -> advance_intents(agent, intent, live_ship)
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp revalidate_intents(agent_id, ship_symbol, live_ship, expected_intent_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %Intent{} = scheduled_intent <- unfinished_intent(ship.id),
         true <- intent_matches_event?(scheduled_intent, expected_intent_id),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      advance_current_intent_for_event(agent, scheduled_intent.id, live_ship)
    else
      _ -> :ok
    end
  end

  defp advance_current_intent_for_event(agent, intent_id, live_ship) do
    case Repo.get(Intent, intent_id) do
      %Intent{status: status} = intent when status in ["active", "waiting", "blocked"] ->
        case intent.caller do
          "job" ->
            case Repo.get(Job, intent.job_id) do
              %Job{} = job ->
                if Job.running?(job) do
                  with {:ok, intent} <- advance_intents(agent, intent, live_ship) do
                    advance_job_intent_after_event(agent, job, intent, live_ship)
                  end
                else
                  :ok
                end

              nil ->
                :ok
            end

          _ ->
            advance_intents(agent, intent, live_ship)
        end

      _ ->
        :ok
    end
  end

  defp advance_job_intent_after_event(agent, %Job{type: "outfitting"} = job, intent, _live_ship),
    do: advance_outfitting_after_intent(agent, job, intent)

  defp advance_job_intent_after_event(agent, %Job{type: "miner"} = job, intent, live_ship),
    do: advance_miner_after_intent(agent, job, intent, live_ship)

  defp advance_job_intent_after_event(
         agent,
         %Job{type: "construction_supply"} = job,
         intent,
         _live_ship
       ),
       do: advance_construction_supply_after_intent(agent, job, intent)

  defp advance_job_intent_after_event(agent, job, intent, _live_ship),
    do: advance_procurement_after_intent(agent, job, intent)

  defp intent_matches_event?(_intent, nil), do: false
  defp intent_matches_event?(%Intent{id: id}, id), do: true
  defp intent_matches_event?(_intent, _expected_intent_id), do: false

  defp validate_intent_waypoint(""), do: {:error, :invalid_waypoint}
  defp validate_intent_waypoint(_waypoint), do: :ok

  # Replacing a pending manual outcome is explicit; it cannot cancel an action
  # the game already accepted, which reconciliation below accounts for.
  defp replace_intents(ship, waypoint) when is_binary(waypoint),
    do: replace_intents(ship, %{type: "navigate", target_waypoint: waypoint})

  defp replace_intents(ship, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      if unresolved_cargo_intent(ship.id) do
        Repo.rollback(:cargo_operation_reconciliation_required)
      end

      case unfinished_intents(ship.id) do
        %Intent{type: type, in_flight_action: action}
        when type in ["install_module", "remove_module"] and is_map(action) ->
          Repo.rollback(:intents_reconciliation_required)

        %Intent{} = predecessor ->
          if unresolved_navigation_action?(predecessor) or
               unresolved_jump_action?(predecessor) or unresolved_warp_action?(predecessor) do
            Repo.rollback(:intents_reconciliation_required)
          else
            terminalize_intents!(predecessor, "stopped")
          end

        nil ->
          :ok
      end

      # Manual Control owns the Ship. It explicitly supersedes an unfinished
      # Job operation before pausing the policy, then creates the sole active
      # operation in the same transaction.
      case unfinished_job(ship.id) do
        %Job{} = job ->
          if is_map(job.in_flight_action) and attrs[:type] not in ["buy", "sell", "deliver"] do
            Repo.rollback(:job_action_reconciliation_required)
          end

          case unfinished_job_intent(job.id) do
            %Intent{} = predecessor ->
              if unresolved_intent_evidence?(predecessor) do
                Repo.rollback(:intents_reconciliation_required)
              else
                terminalize_intents!(predecessor, "stopped")
              end

            nil ->
              :ok
          end

          unless job.status == "paused" do
            action =
              if attrs[:type] == "navigate", do: "navigation", else: "#{attrs[:type]} goods"

            Repo.update!(
              Ecto.Changeset.change(job,
                status: "paused",
                blocker: nil,
                blocked_reason: preemption_message({:manual_override, action})
              )
            )
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

  defp unfinished_intents(ship_id) do
    Repo.one(
      from intent in Intent,
        where:
          intent.ship_id == ^ship_id and intent.caller == "manual" and
            intent.status in ^@unfinished_intent_states
    )
  end

  defp unfinished_job_intent(job_id) do
    Repo.one(
      from intent in Intent,
        where:
          intent.job_id == ^job_id and intent.caller == "job" and
            intent.status in ^@unfinished_intent_states
    )
  end

  defp terminalize_job_intent!(job) do
    case unfinished_job_intent(job.id) do
      %Intent{} = intent ->
        # A claimed prerequisite can still be accepted by the game after this
        # process yields. Preemption must wait for its authoritative outcome,
        # just as it does for cargo mutations.
        cond do
          unresolved_cargo_action?(intent) ->
            Repo.rollback(:cargo_operation_reconciliation_required)

          unresolved_intent_evidence?(intent) ->
            Repo.rollback(:intents_reconciliation_required)

          true ->
            terminalize_intents!(intent, "stopped")
        end

      nil ->
        :ok
    end
  end

  defp unresolved_cargo_action?(intent) do
    is_map(intent.in_flight_action) and
      intent.in_flight_action["kind"] in ["buy", "sell", "deliver"]
  end

  defp unresolved_jump_action?(intent) do
    is_map(intent.in_flight_action) and intent.in_flight_action["kind"] == "jump"
  end

  defp unresolved_navigation_action?(intent) do
    (is_map(intent.in_flight_action) and intent.in_flight_action["kind"] == "navigate") or
      (is_map(intent.last_action_result) and intent.last_action_result["wait"] == "arrival")
  end

  defp unresolved_warp_action?(intent) do
    is_map(intent.in_flight_action) and intent.in_flight_action["kind"] == "warp"
  end

  defp unfinished_intent(ship_id) do
    Repo.one(
      from intent in Intent,
        where: intent.ship_id == ^ship_id and intent.status in ^@unfinished_intent_states
    )
  end

  defp unresolved_cargo_intent(ship_id) do
    Intent
    |> where([intent], intent.ship_id == ^ship_id)
    |> Repo.all()
    |> Enum.find(fn intent ->
      unresolved_cargo_action?(intent)
    end)
  end

  defp terminalize_intents!(intent, status) when status in @terminal_intent_states do
    preserve_evidence? = unresolved_intent_evidence?(intent)

    Repo.update!(
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

  defp complete_intents(agent, intent) do
    result =
      if jump_evidence?(intent) or warp_evidence?(intent) do
        (intent.last_action_result || %{"kind" => "jump", "waypoint" => intent.target_waypoint})
        |> Map.put("kind", if(warp_evidence?(intent), do: "warp", else: "jump"))
        |> Map.put("completion", "authoritative_ship_state")
      else
        %{"kind" => "navigate", "waypoint" => intent.target_waypoint}
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

        if intent.caller == "manual" do
          record_activity(
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

            record_activity(
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
    due_at = parse_expiration(live_ship.cooldown.expiration, live_ship.cooldown.remaining_seconds)

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

            record_activity(
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

  defp orbit_for_intents(agent, intent, live_ship) do
    with {:ok, intent} <-
           claim_intent_action(intent, %{
             "kind" => "orbit",
             "waypoint" => live_ship.nav.waypoint_symbol,
             "expected" => %{"status" => "IN_ORBIT"}
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol)
           ) do
        {:ok, result} ->
          case transition_intent(intent,
                 in_flight_action: nil,
                 last_action_result: %{"kind" => "orbit", "status" => result.nav.status}
               ) do
            {:ok, intent} ->
              live_ship = %{live_ship | nav: result.nav}

              if intent.caller == "job" and
                   not remote_waypoint?(live_ship.nav.waypoint_symbol, intent.target_waypoint) do
                dispatch_manual_navigate(agent, intent, live_ship)
              else
                advance_intents(agent, intent, live_ship)
              end

            :intent_no_longer_owned ->
              :ok
          end

        {:error, reason} ->
          block_intents(intent, reason)
      end
    else
      {:error, _reason} -> :ok
    end
  end

  defp advance_manual_jump_route(agent, intent, live_ship) do
    with {:ok, source_system} <- system_from_headquarters(live_ship.nav.waypoint_symbol),
         {:ok, origin_gate} <- jump_origin_for_intent(agent, source_system, intent) do
      if live_ship.nav.waypoint_symbol == origin_gate do
        dispatch_manual_jump(agent, intent, live_ship)
      else
        dispatch_manual_navigate(agent, intent, live_ship, origin_gate)
      end
    else
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp advance_manual_remote_route(agent, intent, live_ship) do
    if get_in(intent.parameters, ["reviewed_warp", "method"]) == "warp" do
      dispatch_manual_warp(agent, intent, live_ship)
    else
      advance_manual_jump_route(agent, intent, live_ship)
    end
  end

  defp jump_origin_for_intent(
         agent,
         source_system,
         %Intent{parameters: parameters} = intent
       ) do
    case get_in(parameters, ["reviewed_jump", "source_waypoint"]) do
      source when is_binary(source) ->
        with {:ok, destination_system} <- system_from_headquarters(intent.target_waypoint),
             :ok <-
               validate_jump_route(
                 agent,
                 source_system,
                 source,
                 destination_system,
                 intent.target_waypoint
               ),
             {:ok, _} <- jump_cost_preflight(agent, source_system, source) do
          {:ok, source}
        end

      _ ->
        jump_origin_for(agent, source_system, intent.target_waypoint)
    end
  end

  defp jump_origin_for(agent, system, destination) do
    with {:ok, waypoints} <-
           SpaceTraders.API.get_waypoints(agent.agent_token, system, type: "JUMP_GATE"),
         {:ok, gate} <-
           Enum.find_value(waypoints, fn waypoint ->
             case waypoint_jump_gate(agent, waypoint) do
               {:ok, %{connections: connections}} ->
                 if destination in connections, do: {:ok, waypoint}

               _ ->
                 nil
             end
           end) || {:error, :jump_gate_connection_unavailable} do
      {:ok, gate.symbol}
    end
  end

  # Keep every discovered gate visible to Manual Control. A connection read can
  # fail independently, so rejection remains evidence rather than omission.
  defp jump_origin_candidates(agent, system, destination) do
    with {:ok, waypoints} <-
           SpaceTraders.API.get_waypoints(agent.agent_token, system, type: "JUMP_GATE") do
      candidates =
        Enum.map(waypoints, fn waypoint ->
          construction =
            case waypoint_construction(agent, waypoint) do
              {:ok, %{is_complete: true}} -> "complete"
              {:ok, _} -> "incomplete"
              {:error, _} -> "unavailable"
            end

          case waypoint_jump_gate(agent, waypoint) do
            {:ok, %{connections: connections}} ->
              connected? = destination in connections

              reasons =
                []
                |> then(
                  if(construction == "complete",
                    do: & &1,
                    else: &["construction_#{construction}" | &1]
                  )
                )
                |> then(if(connected?, do: & &1, else: &["not_connected" | &1]))

              %{
                waypoint: waypoint.symbol,
                x: waypoint.x,
                y: waypoint.y,
                construction: construction,
                connection: if(connected?, do: "connected", else: "not_connected"),
                intelligence: "available",
                resource: "unreviewed",
                viable: reasons == [],
                reasons: Enum.reverse(reasons)
              }

            {:error, reason} ->
              reasons =
                [
                  if(construction == "complete", do: nil, else: "construction_#{construction}"),
                  jump_gate_rejection_reason(reason)
                ]
                |> Enum.reject(&is_nil/1)

              %{
                waypoint: waypoint.symbol,
                construction: construction,
                connection: "unknown",
                intelligence: "unavailable",
                resource: "unreviewed",
                viable: false,
                reasons: reasons
              }
          end
        end)

      {:ok, candidates}
    end
  end

  defp jump_gate_rejection_reason(%SpaceTraders.API.GameplayError{type: type})
       when is_atom(type),
       do: "jump_gate_#{type}"

  defp jump_gate_rejection_reason(%SpaceTraders.API.Error{}),
    do: "jump_gate_intelligence_unavailable"

  defp jump_gate_rejection_reason(_reason), do: "jump_gate_intelligence_unavailable"

  defp dispatch_manual_navigate(agent, intent, live_ship, destination \\ nil) do
    destination = destination || intent.target_waypoint

    with {:ok, intent} <-
           claim_intent_action(intent, %{
             "kind" => "navigate",
             "waypoint" => destination,
             "expected" => %{"status" => "IN_TRANSIT", "destination" => destination}
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.navigate_ship(
               agent.agent_token,
               live_ship.symbol,
               destination
             )
           ) do
        {:ok, result} ->
          case schedule_intent_arrival(agent, intent, live_ship.symbol, result) do
            :ok ->
              persist_destination_history(
                agent,
                live_ship.symbol,
                result.nav.route.destination.symbol
              )

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
                    record_activity(
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

        {:error, reason} ->
          block_intents(intent, reason)
      end
    else
      {:error, _reason} -> :ok
    end
  end

  defp dispatch_manual_warp(agent, intent, live_ship) do
    with :ok <- reviewed_warp_flight_mode(intent, live_ship.nav.flight_mode),
         {:ok, _module} <- installed_warp_drive(live_ship),
         true <- live_ship.nav.flight_mode != "BURN" || {:error, :warp_burn_fuel_budget_unknown},
         true <- not fuel_empty?(live_ship) || {:error, :insufficient_fuel},
         {:ok, intent} <-
           claim_intent_action(intent, %{
             "kind" => "warp",
             "waypoint" => intent.target_waypoint,
             "expected" => %{"status" => "IN_TRANSIT", "destination" => intent.target_waypoint}
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.warp_ship(
               agent.agent_token,
               live_ship.symbol,
               intent.target_waypoint
             )
           ) do
        {:ok, result} ->
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
            persist_destination_history(
              agent,
              live_ship.symbol,
              result.nav.route.destination.symbol
            )

            {:ok, intent}
          else
            :intent_no_longer_owned -> :ok
            {:error, _reason} = error -> error
          end

        {:error, reason} ->
          block_intents(intent, reason)
      end
    else
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp reviewed_warp_flight_mode(%Intent{parameters: parameters}, current_mode) do
    case get_in(parameters, ["reviewed_warp", "flight_mode"]) do
      ^current_mode -> :ok
      _ -> {:error, :warp_preview_stale}
    end
  end

  # A jump response proves execution, not completion. The subsequent Ship read
  # is what proves the requested off-System arrival after a restart or timeout.
  defp dispatch_manual_jump(agent, intent, live_ship) do
    with {:ok, source_system} <- system_from_headquarters(live_ship.nav.waypoint_symbol),
         :ok <- reviewed_jump_flight_mode(intent, live_ship.nav.flight_mode),
         {:ok, destination_system} <- system_from_headquarters(intent.target_waypoint),
         :ok <-
           validate_jump_route(
             agent,
             source_system,
             live_ship.nav.waypoint_symbol,
             destination_system,
             intent.target_waypoint
           ),
         {:ok, _preflight} <-
           jump_cost_preflight(agent, source_system, live_ship.nav.waypoint_symbol),
         {:ok, intent} <-
           claim_intent_action(intent, %{
             "kind" => "jump",
             "waypoint" => intent.target_waypoint,
             "expected" => %{
               "status" => "IN_ORBIT",
               "waypoint" => intent.target_waypoint,
               "system" => destination_system
             }
           }) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.jump_ship(
               agent.agent_token,
               live_ship.symbol,
               intent.target_waypoint
             )
           ) do
        {:ok, result} ->
          schedule_cooldown(agent, live_ship.symbol, result)

          case transition_intent(intent,
                 status: "active",
                 last_action_result: jump_execution_evidence(intent.target_waypoint, result)
               ) do
            {:ok, intent} -> reconcile_intents(agent, intent)
            :intent_no_longer_owned -> :ok
          end

        {:error, %SpaceTraders.API.GameplayError{} = reason} ->
          clear_jump_claim_and_block(intent, reason)

        {:error, reason} ->
          block_intents(intent, reason)
      end
    else
      {:error, reason} -> block_intents(intent, reason)
    end
  end

  defp reviewed_jump_flight_mode(%Intent{parameters: parameters}, current_mode) do
    case get_in(parameters, ["reviewed_jump", "flight_mode"]) do
      nil -> :ok
      ^current_mode -> :ok
      _ -> {:error, :jump_preview_stale}
    end
  end

  defp validate_jump_route(agent, source_system, source, destination_system, destination) do
    source_waypoint = %{system_symbol: source_system, symbol: source}
    destination_waypoint = %{system_symbol: destination_system, symbol: destination}

    with {:ok, source_construction} <- waypoint_construction(agent, source_waypoint),
         true <- source_construction.is_complete || {:error, {:jump_gate_incomplete, source}},
         {:ok, source_gate} <- waypoint_jump_gate(agent, source_waypoint),
         true <-
           destination in source_gate.connections ||
             {:error, {:jump_gate_not_connected, source, destination}},
         {:ok, destination_construction} <- waypoint_construction(agent, destination_waypoint),
         true <-
           destination_construction.is_complete || {:error, {:jump_gate_incomplete, destination}},
         {:ok, destination_gate} <- waypoint_jump_gate(agent, destination_waypoint),
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
             SpaceTraders.API.get_market(agent.agent_token, source_system, source_waypoint)
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
    case parse_arrival(nav.route) do
      {:ok, due_at} ->
        payload = arrival_payload(nav) |> Map.put("intent_id", intent.id)

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

  defp block_intents(intent, reason) do
    already_blocked? = match?(%Intent{status: "blocked"}, Repo.get(Intent, intent.id))

    case transition_intent(intent,
           status: "blocked",
           blocker: job_blocker(intents_block_reason(reason)),
           in_flight_action:
             if(unresolved_jump_action?(intent) or unresolved_warp_action?(intent),
               do: intent.in_flight_action,
               else: nil
             )
         ) do
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

  defp clear_jump_claim_and_block(intent, reason) do
    case transition_intent(intent, in_flight_action: nil) do
      {:ok, intent} -> block_intents(intent, reason)
      :intent_no_longer_owned -> :ok
    end
  end

  # Typed game rejections become stable blocker reasons; transport failures
  # keep their struct evidence.
  defp intents_block_reason(%SpaceTraders.API.GameplayError{type: type})
       when is_atom(type) and type != :other,
       do: type

  defp intents_block_reason(reason), do: reason

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

  defp remote_waypoint?(source, destination) do
    with {:ok, source_system} <- system_from_headquarters(source),
         {:ok, destination_system} <- system_from_headquarters(destination) do
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

  @doc "Reconciles a persisted Manual Control Intent after a process restart."
  def recover_intents_on_boot(ship_symbol, agent_id, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %Intent{status: status} = intent when status != "awaiting_confirmation" <-
           unfinished_intents(ship.id),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      case Agent.handle_game_result(agent, SpaceTraders.API.get_ship(agent_token, ship_symbol)) do
        {:ok, live_ship} ->
          SpaceTraders.Fleet.Intents.recover(agent, ship_symbol, live_ship, intent.id, nil)

        {:error, reason} ->
          if reason == :stale_agent,
            do: :ok,
            else: intent_recovery_retry_or_block(ship, intent, agent_id, agent_token, reason)
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

      recover_intents_on_boot(ship_symbol, agent_id, agent_token)
    else
      case Repo.transaction(
             fn ->
               current = Repo.get!(Intent, intent.id)

               if Intent.unfinished?(current) do
                 Repo.update!(
                   Ecto.Changeset.change(current,
                     status: "blocked",
                     blocker: job_blocker({:retry_exhausted, reason}),
                     in_flight_action:
                       if(
                         unresolved_cargo_action?(current) or unresolved_jump_action?(current) or
                           unresolved_warp_action?(current),
                         do: current.in_flight_action,
                         else: nil
                       )
                   )
                 )
               else
                 Repo.rollback(:intent_no_longer_unfinished)
               end
             end,
             mode: :immediate
           ) do
        {:ok, blocked_intent} ->
          record_activity_by_intent(
            blocked_intent,
            "manual_intent_recovery",
            "Manual navigate recovery blocked after retry exhaustion",
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
    with :ok <- Agent.execution_allowed?(agent),
         {:ok, ship} <- owned_ship(agent, ship_symbol),
         %Job{} = job <- unfinished_job(ship.id),
         nil <- unfinished_intents(ship.id),
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
        blocked_reason: terminal_job_reason(status),
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

  defp preempt_miner_job_for(agent, ship_symbol, reason) do
    with :ok <- Agent.execution_allowed?(agent) do
      case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
        %Ship{} = ship -> preempt_miner_job(agent, ship, reason)
        nil -> :ok
      end
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
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
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

  @doc "Marks Miner Job navigation complete after authoritative Arrival revalidation."
  def revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship) do
    revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship, nil)
  end

  def revalidate_miner_job_arrival(agent_id, ship_symbol, live_ship, expected_job_id) do
    case Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol) do
      %Ship{} = ship ->
        case unfinished_intent_for_ship(ship.id) do
          %Intent{id: intent_id} ->
            revalidate_intents(agent_id, ship_symbol, live_ship, intent_id)
            {:ok, Repo.get!(Job, unfinished_job(ship.id).id)}

          nil ->
            revalidate_miner_job_arrival_without_intent(
              agent_id,
              ship_symbol,
              live_ship,
              expected_job_id
            )
        end

      _ ->
        :ok
    end
  end

  defp revalidate_miner_job_arrival_without_intent(
         agent_id,
         ship_symbol,
         live_ship,
         expected_job_id
       ) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %Job{} = config <- unfinished_job(ship.id),
         true <- job_matches_event?(config, expected_job_id),
         true <- config.status in @running_job_states,
         true <- arrived_at_configured_waypoint?(live_ship, config),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
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
      {:ok, %Intent{status: "completed", last_action_result: result} = intent} ->
        Repo.delete!(intent)
        Repo.delete_all(from i in Intent, where: i.ship_id == ^config.ship_id)

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

  defp live_ship_for_job_intent(agent, ship_symbol, opts) do
    case opts[:live_ship] do
      %{symbol: ^ship_symbol} = live_ship ->
        {:ok, live_ship}

      _ ->
        Agent.handle_game_result(
          agent,
          SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
        )
    end
  end

  defp find_deliverable(%{terms: %{deliver: deliver}}, trade_symbol) do
    Enum.find(deliver || [], &(&1.trade_symbol == trade_symbol))
  end

  defp find_deliverable(_contract, _trade_symbol), do: nil

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
    Repo.delete_all(from i in Intent, where: i.ship_id == ^config.ship_id)

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
        case SpaceTraders.Fleet.Intents.request_sell_with_live_ship(
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
    inventory_units(inventory, symbol)
  end

  defp item_units(%{inventory: inventory}, symbol) do
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

  defp record_construction_observation(%AgentRecord{id: id} = agent, system, construction, source)
       when is_integer(id) do
    Intelligence.observe_construction(agent, system, construction, source: source)
  rescue
    exception ->
      Logger.warning(
        "Could not persist construction intelligence: #{Exception.message(exception)}"
      )
  end

  defp record_construction_observation(_agent, _system, _construction, _source), do: :ok

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

  defp system_from_headquarters(headquarters) when is_binary(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end

  defp system_from_headquarters(_headquarters), do: {:error, :invalid_headquarters}

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

  defp market_for_ship(%AgentRecord{agent_token: token} = agent, live_ship, waypoint_symbol) do
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
      Intent
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

          unless intents_waiting_on_timeline?(ship_symbol) do
            recover_intents_on_boot(ship_symbol, agent_id, agent_token)
          end

          unless ship_symbol in timeline_symbols do
            recover_job_on_boot(ship_symbol, agent_id, agent_token)
          end

        :error ->
          Logger.warning(
            "ship #{ship_symbol}: no stored credentials, not re-arming timeline events"
          )
      end
    end)

    :ok
  end

  defp intents_waiting_on_timeline?(ship_symbol) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol),
         %Intent{} = intent <- unfinished_intents(ship.id) do
      Timeline.pending_events(:ship, ship_symbol)
      |> Enum.any?(&(&1.payload["intent_id"] == intent.id))
    else
      _ -> false
    end
  end

  @doc "Reconciles a persisted Miner Job's in-flight action after a process restart."
  def recover_job_on_boot(ship_symbol, agent_id, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %Job{} = config <- unfinished_job(ship.id),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      if config.type in ["procurement", "construction_supply", "outfitting"] and
           match?(%Intent{}, unfinished_job_intent(config.id)) do
        if config.type == "outfitting",
          do: recover_outfitting_intent(agent, config),
          else: recover_procurement_intent(agent, ship, config)
      else
        if config.status in @running_job_states do
          # Recovery owns its own persisted attempt budget. Avoid nested client
          # retries so one authoritative read counts as one recovery attempt.
          case Agent.handle_game_result(
                 agent,
                 SpaceTraders.API.get_ship(agent_token, ship_symbol, retry: false)
               ) do
            {:ok, live_ship} when config.status == "active" and is_nil(config.in_flight_action) ->
              case config.type do
                "explorer" -> advance_explorer_job(agent, config, live_ship)
                "procurement" -> start_procurement_job(agent, ship_symbol)
                "construction_supply" -> start_construction_supply_job(agent, ship_symbol)
                "outfitting" -> start_outfitting_job(agent, ship_symbol)
                _ -> advance_miner_job(agent, config, live_ship)
              end

            {:ok, live_ship}
            when config.status in ["active", "waiting"] and is_map(config.in_flight_action) ->
              case unfinished_job_intent(config.id) do
                %Intent{type: "navigate", id: intent_id} ->
                  SpaceTraders.Fleet.Intents.recover(
                    agent,
                    ship_symbol,
                    live_ship,
                    intent_id,
                    config.id
                  )

                _ ->
                  reconcile_in_flight(agent_id, ship, config, live_ship)
              end

            {:ok, _live_ship} ->
              :ok

            {:error, reason} ->
              recovery_retry_or_block(agent_id, ship_symbol, reason, agent_token)
          end
        else
          :ok
        end
      end
    else
      _ -> :ok
    end
  end

  defp recover_outfitting_intent(agent, job) do
    intent = unfinished_job_intent(job.id)
    ship = Repo.get!(Ship, job.ship_id)

    with {:ok, live_ship} <-
           Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship.symbol)
           ),
         %Job{} = current_job <- Repo.get(Job, job.id),
         true <- Job.running?(current_job),
         :ok <- outfitting_system_matches?(current_job.progress, live_ship),
         %Intent{} = current_intent <- Repo.get(Intent, intent.id),
         true <- Intent.unfinished?(current_intent),
         {:ok, current_intent} <- advance_intents(agent, current_intent, live_ship) do
      advance_outfitting_after_intent(agent, current_job, current_intent)
    else
      false -> :ok
      nil -> :ok
      {:error, reason} -> mark_outfitting_job_blocked(job, reason)
    end
  end

  # A restarted cargo request has no idempotency key or transaction lookup. Its
  # request fingerprint stays durable, but the Job must stop until an Operator
  # can reconcile authoritative operation-specific evidence.
  defp recover_procurement_intent(_agent, _ship, job) do
    intent = unfinished_job_intent(job.id)
    agent = Repo.get!(AgentRecord, Repo.get!(Ship, job.ship_id).agent_id)
    ship = Repo.get!(Ship, job.ship_id)

    case Agent.handle_game_result(
           agent,
           SpaceTraders.API.get_ship(agent.agent_token, ship.symbol)
         ) do
      {:ok, live_ship} ->
        # Uses the same operation reconciliation as Manual Control. Cargo
        # requests with unresolved response evidence become durable blockers.
        with %Job{} = current_job <- Repo.get(Job, job.id),
             true <- Job.running?(current_job),
             :ok <- procurement_system_matches?(current_job.progress, live_ship),
             %Intent{} = current_intent <- Repo.get(Intent, intent.id),
             true <- Intent.unfinished?(current_intent),
             {:ok, current_intent} <- advance_intents(agent, current_intent, live_ship) do
          if current_job.type == "construction_supply",
            do: advance_construction_supply_after_intent(agent, current_job, current_intent),
            else: advance_procurement_after_intent(agent, current_job, current_intent)
        else
          false -> :ok
          nil -> :ok
        end

      {:error, reason} ->
        block_procurement_recovery_if_current(intent, job, reason)
    end
  end

  defp block_procurement_recovery_if_current(intent, job, reason) do
    case Repo.transaction(
           fn ->
             current_intent = Repo.get!(Intent, intent.id)
             current_job = Repo.get!(Job, job.id)

             if Intent.unfinished?(current_intent) and Job.running?(current_job) and
                  current_intent.in_flight_action == intent.in_flight_action do
               block_procurement_cargo_intent(current_intent, reason)
               mark_procurement_job_blocked(current_job, reason)
             else
               Repo.rollback(:operation_no_longer_current)
             end
           end,
           mode: :immediate
         ) do
      {:ok, result} -> result
      {:error, :operation_no_longer_current} -> :ok
    end
  end

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
