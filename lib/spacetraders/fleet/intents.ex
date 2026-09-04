defmodule SpaceTraders.Fleet.Intents do
  @moduledoc """
  The public seam for durable, caller-owned Intent execution.

  Manual Control and Job Policies request operational outcomes here; ShipServer
  timers and boot recovery re-enter the same reconciliation. The module hides
  ownership transactions, mutation claims, game calls, Timeline scheduling,
  ShipServer arming, evidence reconciliation, and Job continuation.
  """

  import Ecto.Query

  require Logger

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model.{Contract, ShipNav}
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Repo
  alias SpaceTraders.{Agent, Contracts, Timeline}

  defmodule Navigate do
    @moduledoc "A closed Navigate goal for a Ship."
    defstruct [:waypoint, parameters: %{}]
  end

  defmodule BuyGoods do
    @moduledoc "A closed Buy Goods goal for a Ship."
    defstruct [:market, :trade_good, :quantity, constraints: %{}]
  end

  defmodule SellGoods do
    @moduledoc "A closed Sell Goods goal for a Ship."
    defstruct [:market, :trade_good, :quantity, constraints: %{}, parameters: %{}]
  end

  defmodule DeliverGoods do
    @moduledoc "A closed Deliver Goods goal for a typed recipient."
    defstruct [:recipient, :trade_good, :quantity]
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

  defmodule ManualControl do
    @moduledoc "Manual Control ownership for an Intent."
    defstruct []
  end

  defmodule JobOwner do
    @moduledoc "Job ownership for an Intent."
    defstruct [:job]
  end

  @unfinished_states Intent.unfinished_states()
  @terminal_states Intent.terminal_states()
  @job_types [
    "miner",
    "procurement",
    "market_trading"
  ]

  defp request_for_agent(agent, owner, ship_symbol, %BuyGoods{} = goal) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_goal_parameters(goal.constraints),
         {:ok, market} <- valid_goal_waypoint(goal.market),
         {:ok, trade_good} <- valid_trade_good(goal.trade_good),
         :ok <- valid_quantity(goal.quantity),
         :ok <- valid_buy_constraints(goal.constraints) do
      opts =
        goal.constraints
        |> Map.to_list()
        |> Keyword.new()

      opts =
        case owner do
          :manual -> opts
          %JobOwner{job: %Job{id: job_id}} -> Keyword.merge(opts, caller: "job", job_id: job_id)
        end

      buy_goods_intent(agent, ship_symbol, market, trade_good, goal.quantity, opts)
    end
  end

  defp request_for_agent(agent, owner, ship_symbol, %SellGoods{} = goal) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_goal_parameters(goal.constraints),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, market} <- valid_goal_waypoint(goal.market),
         {:ok, trade_good} <- valid_trade_good(goal.trade_good),
         :ok <- valid_quantity(goal.quantity),
         :ok <- valid_sell_constraints(goal.constraints) do
      opts =
        goal.constraints
        |> Map.to_list()
        |> Keyword.new()
        |> Keyword.merge(Map.to_list(goal.parameters))

      opts =
        case owner do
          :manual -> opts
          %JobOwner{job: %Job{id: job_id}} -> Keyword.merge(opts, caller: "job", job_id: job_id)
        end

      case owner do
        :manual ->
          sell_goods_intent(agent, ship_symbol, market, trade_good, goal.quantity, opts)

        %JobOwner{job: job} ->
          request_job_sell_goods_intent(
            agent,
            job,
            ship_symbol,
            market,
            trade_good,
            goal.quantity,
            goal.constraints,
            goal.parameters,
            nil
          )
      end
    end
  end

  defp request_for_agent(agent, owner, ship_symbol, %DeliverGoods{} = goal) do
    request_delivery(agent, owner, ship_symbol, goal, nil)
  end

  defp request_for_agent(agent, owner, ship_symbol, %Navigate{} = goal) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, waypoint} <- valid_goal_waypoint(goal.waypoint) do
      case owner do
        :manual ->
          request_manual_navigate(agent, ship_symbol, waypoint, goal.parameters)

        %JobOwner{job: %Job{type: type} = job} when type in @job_types ->
          request_job_navigate(agent, job, ship_symbol, waypoint, goal.parameters)

        %JobOwner{} ->
          {:error, :unsupported_job_navigate}
      end
    end
  end

  defp request_for_agent(agent, owner, ship_symbol, %InstallModule{} = goal) do
    request_module(
      agent,
      owner,
      ship_symbol,
      "install_module",
      goal.module_symbol,
      goal.parameters
    )
  end

  defp request_for_agent(agent, owner, ship_symbol, %RemoveModule{} = goal) do
    parameters =
      if is_map(goal.parameters),
        do: Map.put(goal.parameters, :authorized_removals, goal.authorized_removals),
        else: goal.parameters

    request_module(
      agent,
      owner,
      ship_symbol,
      "remove_module",
      goal.module_symbol,
      parameters
    )
  end

  defp request_for_agent(_agent, _owner, _ship_symbol, _goal),
    do: {:error, :unsupported_intent_goal}

  @doc "Requests a closed operational goal for its owning Job."
  def request(%AgentRecord{} = agent, %JobOwner{} = owner, ship_symbol, goal) do
    request_for_agent(agent, owner, ship_symbol, goal)
  end

  def request(_agent, _owner, _ship_symbol, _goal), do: {:error, :invalid_intent_owner}

  def request_sell_with_live_ship(
        agent,
        %JobOwner{job: %Job{} = job} = owner,
        ship_symbol,
        %SellGoods{} = goal,
        live_ship
      ) do
    with :ok <- token_present(agent),
         {:ok, _owner} <- normalize_owner(owner),
         :ok <- valid_goal_parameters(goal.constraints),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, market} <- valid_goal_waypoint(goal.market),
         {:ok, trade_good} <- valid_trade_good(goal.trade_good),
         :ok <- valid_quantity(goal.quantity),
         :ok <- valid_sell_constraints(goal.constraints) do
      request_job_sell_goods_intent(
        agent,
        job,
        ship_symbol,
        market,
        trade_good,
        goal.quantity,
        goal.constraints,
        goal.parameters,
        live_ship
      )
    end
  end

  def request(agent, %JobOwner{} = owner, ship_symbol, %Navigate{} = goal, live_ship) do
    with {:ok, owner} <- normalize_owner(owner),
         :ok <- token_present(agent),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, waypoint} <- valid_goal_waypoint(goal.waypoint) do
      case owner do
        %JobOwner{job: %Job{type: type} = job} when type in @job_types ->
          request_job_navigate(agent, job, ship_symbol, waypoint, goal.parameters, live_ship)

        _ ->
          {:error, :unsupported_job_navigate}
      end
    end
  end

  def request(agent, %JobOwner{} = owner, ship_symbol, %DeliverGoods{} = goal, live_ship) do
    request_delivery(agent, owner, ship_symbol, goal, live_ship)
  end

  @doc "Requests a closed operational goal through Operator-owned Manual Control."
  def request(
        %Scope{} = current_scope,
        %AgentRecord{} = agent,
        %ManualControl{},
        ship_symbol,
        goal
      ) do
    with {:ok, agent} <- scoped_agent_for_ship(current_scope, agent.id, ship_symbol) do
      request_for_agent(agent, :manual, ship_symbol, goal)
    end
  end

  defp request_delivery(agent, owner, ship_symbol, goal, live_ship) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         {:ok, recipient, waypoint} <- valid_delivery_recipient(goal.recipient),
         {:ok, trade_good} <- valid_trade_good(goal.trade_good),
         :ok <- valid_quantity(goal.quantity) do
      opts = if live_ship, do: [live_ship: live_ship], else: []

      opts =
        if owner == :manual,
          do: opts,
          else: Keyword.merge(opts, caller: "job", job_id: owner.job.id)

      deliver_goods_intent(
        agent,
        ship_symbol,
        recipient,
        waypoint,
        trade_good,
        goal.quantity,
        opts
      )
    end
  end

  defp request_module(agent, owner, ship_symbol, type, module_symbol, parameters)
       when is_map(parameters) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_module_symbol(module_symbol),
         {:ok, parameters} <- valid_module_request(type, module_symbol, parameters, owner) do
      case owner do
        :manual ->
          request_module_intent(agent, :manual, ship_symbol, type, module_symbol, parameters)

        %JobOwner{job: %Job{} = job} ->
          request_module_intent(agent, job, ship_symbol, type, module_symbol, parameters)
      end
    end
  end

  defp request_module(_agent, _owner, _ship_symbol, _type, _module_symbol, _parameters),
    do: {:error, :invalid_intent_parameters}

  defp valid_module_request(type, module_symbol, parameters, :manual),
    do: valid_module_parameters(type, module_symbol, parameters)

  defp valid_module_request("remove_module", module_symbol, parameters, %JobOwner{})
       when is_map(parameters),
       do: {:ok, Map.merge(parameters, %{"module_symbol" => module_symbol, "quantity" => 1})}

  defp valid_module_request(type, module_symbol, parameters, %JobOwner{}),
    do: valid_module_parameters(type, module_symbol, parameters)

  @doc "Persists an Operator-scoped reviewed Navigate Intent without dispatching a mutation."
  def review(
        scope,
        agent,
        owner,
        ship_symbol,
        waypoint,
        preview,
        opts \\ []
      )

  def review(
        %Scope{} = current_scope,
        %AgentRecord{} = agent,
        %ManualControl{},
        ship_symbol,
        waypoint,
        preview,
        opts
      )
      when is_map(preview) do
    with {:ok, agent} <- scoped_agent_for_ship(current_scope, agent.id, ship_symbol) do
      review_navigation_intent(agent, ship_symbol, waypoint, preview, opts)
    end
  end

  def review(_current_scope, _agent, _owner, _ship_symbol, _waypoint, _preview, _opts),
    do: {:error, :unsupported_intent_review}

  @doc "Persists an Operator-scoped blocked Navigate Intent after preview rejects the route."
  def block_review(
        %Scope{} = current_scope,
        %AgentRecord{} = agent,
        %ManualControl{},
        ship_symbol,
        waypoint,
        reason
      ) do
    with {:ok, agent} <- scoped_agent_for_ship(current_scope, agent.id, ship_symbol) do
      block_jump_preview(agent, ship_symbol, waypoint, reason)
    end
  end

  @doc "Confirms a persisted reviewed Navigate Intent by identity and revision."
  def confirm(%Scope{} = current_scope, %ManualControl{}, intent_id, review_revision) do
    confirm_navigation_intent(current_scope, intent_id, review_revision)
  end

  def confirm(_current_scope, _owner, _intent_id, _review_revision),
    do: {:error, :invalid_intent_owner}

  @doc "Stops one owned Intent without hiding unresolved mutation evidence."
  def stop(%Scope{operator: %{id: operator_id}}, %ManualControl{}, intent_id) do
    with {%Intent{} = intent, %AgentRecord{} = agent} <-
           owned_intent_for_operator(operator_id, intent_id),
         :ok <- owner_matches?(:manual, intent) do
      do_stop_intent(agent, intent_id, :manual)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  def stop(%AgentRecord{} = agent, %JobOwner{} = owner, intent_id) do
    with %Intent{} = intent <- owned_intent(agent, intent_id),
         :ok <- owner_matches?(owner, intent) do
      do_stop_intent(agent, intent_id, owner)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  @doc "Stops an owned Intent after binding the request to its Ship identity."
  def stop(%Scope{operator: %{id: operator_id}}, %ManualControl{}, ship_symbol, intent_id) do
    with {%Intent{} = intent, %AgentRecord{} = agent} <-
           owned_intent_for_operator(operator_id, intent_id),
         :ok <- owner_matches?(:manual, intent),
         :ok <- intent_ship_matches?(intent, ship_symbol) do
      do_stop_intent(agent, intent_id, :manual)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  def stop(%AgentRecord{} = agent, %JobOwner{} = owner, ship_symbol, intent_id) do
    with %Intent{} = intent <- owned_intent(agent, intent_id),
         :ok <- owner_matches?(owner, intent),
         :ok <- intent_ship_matches?(intent, ship_symbol) do
      do_stop_intent(agent, intent_id, owner)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  @doc """
  Re-enters the one shared Intent reconciliation for a typed trigger.

  `:arrival` and `:cooldown` carry the expected Intent identity and ShipServer's
  fresh authoritative Ship observation. `:boot` with no observation performs the
  fresh authoritative read itself before any progress. Stale events that name a
  replaced Intent are ignored idempotently and cannot advance replacement work.
  """
  def reconcile(agent_id, ship_symbol, nil, :boot, expected_intent_id, expected_job_id) do
    case Repo.get(AgentRecord, agent_id) do
      %AgentRecord{agent_token: agent_token} = agent
      when is_binary(agent_token) and agent_token != "" ->
        with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
             %Intent{status: status} = intent when status != "awaiting_confirmation" <-
               manual_boot_intent(ship.id, expected_intent_id),
             :ok <- Agent.execution_allowed?(agent) do
          case Agent.handle_game_result(
                 agent,
                 SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
               ) do
            {:ok, fresh_ship} ->
              reconcile(agent_id, ship_symbol, fresh_ship, :boot, intent.id, expected_job_id)

            {:error, :stale_agent} ->
              :ok

            {:error, reason} ->
              intent_recovery_retry_or_block(ship, intent, agent_id, reason)
          end
        else
          _ -> :ok
        end

      _ ->
        :ok
    end
  end

  def reconcile(agent_id, ship_symbol, live_ship, trigger, expected_intent_id, expected_job_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      case unfinished_intent_for_ship(ship.id) do
        %Intent{} = intent ->
          if intent_matches_event?(intent, expected_intent_id) do
            advance_intent_for_trigger(agent, intent.id, live_ship)
          else
            :ok
          end

        nil when trigger in [:arrival, :cooldown] ->
          Fleet.continue_job_event(agent_id, ship_symbol, live_ship, trigger, expected_job_id)

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  # The trigger-aware continuation: wake-up evidence re-enters the Intent
  # engine; job-owned lifecycle changes continue through the one internal Job
  # continuation seam. ShipServer never branches by Job type.
  defp advance_intent_for_trigger(agent, intent_id, live_ship) do
    case Repo.get(Intent, intent_id) do
      %Intent{status: status} = intent when status in ["active", "waiting", "blocked"] ->
        case intent.caller do
          "job" ->
            case Repo.get(Job, intent.job_id) do
              %Job{} = job ->
                if Job.running?(job) do
                  with {:ok, intent} <- advance_intents(agent, intent, live_ship) do
                    Fleet.continue_job_after_intent(agent, job, intent, live_ship)
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

  @doc "Re-enters reconciliation after boot's authoritative Ship read."
  def recover(agent, ship_symbol, live_ship, expected_intent_id, expected_job_id) do
    reconcile(agent.id, ship_symbol, live_ship, :boot, expected_intent_id, expected_job_id)
  end

  @doc """
  Re-arms Ship timers and re-enters reconciliation for persisted Intent and Job
  work on boot. Intents already scheduled on a pending Ship timer are left for
  that trigger; their recovery would duplicate the timer's fresh read.
  """
  def rearm_on_boot do
    timeline_symbols = Timeline.pending_owners(:ship) |> Enum.map(& &1.owner_id)
    running_job_states = Job.running_states()

    job_symbols =
      Job
      |> join(:inner, [c], s in Ship, on: c.ship_id == s.id)
      |> where([c, _s], c.status in ^running_job_states)
      |> select([_c, s], s.symbol)
      |> Repo.all()

    intent_symbols =
      Intent
      |> join(:inner, [i], s in Ship, on: i.ship_id == s.id)
      |> where([i, _s], i.status in ^@unfinished_states)
      |> select([_i, s], s.symbol)
      |> Repo.all()

    (timeline_symbols ++ job_symbols ++ intent_symbols)
    |> Enum.uniq()
    |> Enum.each(fn ship_symbol ->
      case Fleet.ship_credentials(ship_symbol) do
        {:ok, agent_id, agent_token} ->
          ShipServer.ensure_started(ship_symbol, agent_id, agent_token)

          unless intents_waiting_on_timeline?(ship_symbol) do
            reconcile(agent_id, ship_symbol, nil, :boot, nil, nil)
          end

          unless ship_symbol in timeline_symbols do
            Fleet.recover_job_on_boot(ship_symbol, agent_id, agent_token)
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
         %Intent{} = intent <- unfinished_intent_for_ship(ship.id) do
      Timeline.pending_events(:ship, ship_symbol)
      |> Enum.any?(&(&1.payload["intent_id"] == intent.id))
    else
      _ -> false
    end
  end

  @doc "Re-enters reconciliation for one unfinished Intent with a fresh authoritative Ship observation."
  def advance(agent, %Intent{} = intent, live_ship), do: advance_intents(agent, intent, live_ship)

  @doc false
  def last_completed_job_intent(job_id, type \\ nil) do
    query =
      from intent in Intent,
        where:
          intent.job_id == ^job_id and intent.caller == "job" and intent.status == "completed",
        order_by: [desc: intent.id],
        limit: 1

    if type do
      Repo.one(where(query, [intent], intent.type == ^type))
    else
      Repo.one(query)
    end
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

  defp normalize_owner(:manual), do: {:ok, :manual}
  defp normalize_owner(%ManualControl{}), do: {:ok, :manual}
  defp normalize_owner(%JobOwner{job: %Job{} = job}), do: {:ok, %JobOwner{job: job}}
  defp normalize_owner(%Job{} = job), do: {:ok, %JobOwner{job: job}}
  defp normalize_owner(_owner), do: {:error, :invalid_intent_owner}

  defp token_present(%AgentRecord{agent_token: token}) when is_binary(token) and token != "",
    do: :ok

  defp token_present(_agent), do: {:error, :agent_token_missing}

  defp valid_goal_waypoint(waypoint) when is_binary(waypoint) do
    case String.trim(waypoint) do
      "" -> {:error, :invalid_waypoint}
      waypoint -> {:ok, waypoint}
    end
  end

  defp valid_goal_waypoint(_waypoint), do: {:error, :invalid_waypoint}

  defp valid_goal_parameters(parameters) when is_map(parameters), do: :ok
  defp valid_goal_parameters(_parameters), do: {:error, :invalid_intent_parameters}

  defp valid_module_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, :invalid_module_intent}, else: :ok
  end

  defp valid_module_symbol(_symbol), do: {:error, :invalid_module_intent}

  defp valid_module_parameters("install_module", module_symbol, parameters) do
    {:ok, Map.merge(parameters, %{"module_symbol" => module_symbol, "quantity" => 1})}
  end

  defp valid_module_parameters("remove_module", module_symbol, parameters) do
    removals = parameters[:authorized_removals] || parameters["authorized_removals"] || %{}

    if is_map(removals) and
         Map.new(removals, fn {key, value} -> {to_string(key), value} end) ==
           %{module_symbol => 1},
       do: {:ok, Map.merge(parameters, %{"module_symbol" => module_symbol, "quantity" => 1})},
       else: {:error, :invalid_module_intent}
  end

  defp valid_trade_good(trade_good) when is_binary(trade_good) do
    case String.trim(trade_good) do
      "" -> {:error, :invalid_trade_good}
      trade_good -> {:ok, trade_good}
    end
  end

  defp valid_trade_good(_trade_good), do: {:error, :invalid_trade_good}

  defp valid_identifier(value, error) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp valid_identifier(_value, error), do: {:error, error}

  defp valid_delivery_recipient(%ContractRecipient{contract_id: contract_id, waypoint: waypoint}) do
    with {:ok, contract_id} <- valid_identifier(contract_id, :invalid_contract_id),
         {:ok, waypoint} <- valid_goal_waypoint(waypoint) do
      {:ok, %{type: "contract", contract_id: contract_id, waypoint: waypoint}, waypoint}
    end
  end

  defp valid_delivery_recipient(%ConstructionRecipient{system: system, waypoint: waypoint}) do
    with {:ok, system} <- valid_identifier(system, :invalid_system_symbol),
         {:ok, waypoint} <- valid_goal_waypoint(waypoint) do
      {:ok, %{type: "construction", system: system, waypoint: waypoint}, waypoint}
    end
  end

  defp valid_delivery_recipient(_recipient), do: {:error, :invalid_delivery_recipient}

  defp valid_quantity(quantity) when is_integer(quantity) and quantity > 0, do: :ok
  defp valid_quantity(_quantity), do: {:error, :invalid_quantity}

  defp valid_buy_constraints(constraints) do
    if Enum.all?(constraints, fn {key, value} ->
         key in [:max_price, :max_unit_price, :max_total_price, :reserve_credits] and
           is_integer(value) and value >= 0
       end),
       do: :ok,
       else: {:error, :invalid_buy_constraints}
  end

  defp valid_sell_constraints(constraints) do
    if Enum.all?(constraints, fn {key, value} ->
         key in [:min_price, :min_total] and is_integer(value) and value >= 0
       end),
       do: :ok,
       else: {:error, :invalid_sell_constraints}
  end

  defp owner_matches?(:manual, %Intent{caller: "manual"}), do: :ok

  defp owner_matches?(%JobOwner{job: %Job{id: job_id}}, %Intent{caller: "job", job_id: job_id}),
    do: :ok

  defp owner_matches?(_owner, _intent), do: {:error, :invalid_intent_owner}

  defp intent_ship_matches?(%Intent{ship_id: ship_id}, ship_symbol) do
    case Repo.get(Ship, ship_id) do
      %Ship{symbol: ^ship_symbol} -> :ok
      %Ship{} -> {:error, :intent_ship_mismatch}
      nil -> {:error, :intent_not_found}
    end
  end

  defp manual_boot_intent(_ship_id, intent_id) when is_integer(intent_id) do
    case Repo.get(Intent, intent_id) do
      %Intent{status: status} = intent when status in @unfinished_states -> intent
      _ -> nil
    end
  end

  defp manual_boot_intent(ship_id, _expected_intent_id), do: unfinished_manual_intent(ship_id)

  defp validate_intent_waypoint(""), do: {:error, :invalid_waypoint}
  defp validate_intent_waypoint(_waypoint), do: :ok

  def insert_job_intent(job, attrs) do
    %Intent{ship_id: job.ship_id, job_id: job.id}
    |> Intent.changeset(Map.put(attrs, :caller, "job"))
    |> Ecto.Changeset.put_change(:status, "active")
    |> Repo.insert()
  end

  # Job Navigate is inserted and advanced as a Job-owned Intent. Manual Navigate
  # uses the separate path above because it may preempt a Job.
  defp request_manual_navigate(
         %AgentRecord{agent_token: agent_token} = agent,
         ship_symbol,
         waypoint,
         parameters
       )
       when is_binary(agent_token) and agent_token != "" and is_map(parameters) do
    waypoint = String.trim(waypoint || "")

    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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

  # A Job Policy may pass its fresh authoritative Ship observation; without one,
  # the request performs its own authoritative read before advancing.
  defp request_job_navigate(agent, job, ship_symbol, waypoint, parameters, live_ship \\ nil) do
    with {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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
         {:ok, live_ship} <- fresh_job_ship(agent, ship_symbol, live_ship) do
      advance_intents(agent, intent, live_ship)
    else
      false -> {:error, :invalid_intent_owner}
      error -> error
    end
  end

  defp fresh_job_ship(_agent, _ship_symbol, %SpaceTraders.API.Model.Ship{} = live_ship),
    do: {:ok, live_ship}

  defp fresh_job_ship(agent, ship_symbol, _live_ship) do
    Agent.handle_game_result(
      agent,
      SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
    )
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

  def unfinished_intent_for_ship(ship_id) do
    Repo.one(
      from intent in Intent,
        where: intent.ship_id == ^ship_id and intent.status in ^@unfinished_states
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

  defp review_navigation_intent(agent, ship_symbol, waypoint, preview, opts)
       when is_map(preview) do
    method = if preview[:method] == "warp", do: "warp", else: "jump"
    review = stringify_nested_keys(preview)
    allowed_methods = Keyword.get(opts, :allowed_methods, ["jump", "warp"])

    with {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, intent} <-
           replace_intents(ship, %{
             type: "navigate",
             target_waypoint: waypoint,
             parameters: %{
               "review_method" => method,
               "reviewed_#{method}" => review,
               "allowed_methods" => allowed_methods
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

  defp confirm_navigation_intent(%Scope{operator: %{id: operator_id}}, intent_id, review_revision) do
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

  defp block_jump_preview(%AgentRecord{} = agent, ship_symbol, waypoint, reason) do
    with :ok <- validate_intent_waypoint(waypoint),
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, intent} <- replace_intents(ship, waypoint) do
      block_intents(intent, reason)
    else
      {:error, %Ecto.Changeset{}} -> {:error, :intents_conflict}
      error -> error
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
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         {:ok, live_ship} <-
           Agent.handle_game_result(agent, SpaceTraders.API.get_ship(token, ship.symbol)),
         true <- remote_waypoint?(live_ship.nav.waypoint_symbol, waypoint),
         {:ok, source_system} <- Fleet.system_from_headquarters(live_ship.nav.waypoint_symbol),
         {:ok, destination_system} <- Fleet.system_from_headquarters(waypoint),
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
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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

  @doc """
  Evaluates both jump and warp from fresh authoritative state and returns the
  ranked viable methods for an off-System Navigate Intent.

  The selection includes the preferred method, all viable alternatives, and
  rejection reasons for every non-viable option. When `allowed_methods` is
  provided, only those methods may appear in the result; restricting to a
  single method skips the other preview entirely.
  """
  def method_selection(agent, ship_symbol, waypoint, opts \\ [])

  def method_selection(%AgentRecord{agent_token: token} = agent, ship_symbol, waypoint, opts)
      when is_binary(token) and token != "" do
    allowed = Keyword.get(opts, :allowed_methods, ["jump", "warp"])

    jump =
      if "jump" in allowed,
        do: jump_preview(agent, ship_symbol, waypoint),
        else: {:error, :method_not_allowed}

    warp =
      if "warp" in allowed,
        do: warp_preview(agent, ship_symbol, waypoint),
        else: {:error, :method_not_allowed}

    # Both preview functions return {:error, :same_system_route} for same-system
    # targets, which propagates here as a same_system_route error.
    cond do
      match?({:error, :same_system_route}, jump) ->
        {:error, :same_system_route}

      match?({:error, :same_system_route}, warp) and not match?({:ok, _}, jump) ->
        {:error, :same_system_route}

      true ->
        viable =
          [{"jump", jump}, {"warp", warp}]
          |> Enum.filter(fn {_method, result} -> match?({:ok, _}, result) end)
          |> Enum.map(fn {method, {:ok, preview}} -> {method, preview} end)

        rejected =
          [{"jump", jump}, {"warp", warp}]
          |> Enum.filter(fn {_method, result} -> match?({:error, _}, result) end)
          |> Enum.map(fn {method, {:error, reason}} -> {method, reason} end)

        selected =
          cond do
            viable == [] -> nil
            # Jump is preferred before warp unless the operator restricts it
            List.keyfind(viable, "jump", 0) -> "jump"
            true -> "warp"
          end

        {:ok,
         %{
           selected: selected,
           viable: viable,
           rejected: rejected,
           allowed_methods: allowed
         }}
    end
  end

  def method_selection(%AgentRecord{}, _ship_symbol, _waypoint, _opts),
    do: {:error, :agent_token_missing}

  defp installed_warp_drive(%{modules: modules}) do
    case Enum.find(modules || [], &warp_drive_module?/1) do
      nil -> {:error, :warp_drive_missing}
      module -> {:ok, module}
    end
  end

  defp warp_drive_module?(%{symbol: symbol}) when is_binary(symbol),
    do: symbol in ~w(MODULE_WARP_DRIVE_I MODULE_WARP_DRIVE_II MODULE_WARP_DRIVE_III)

  defp warp_drive_module?(_), do: false

  defp buy_goods_intent(agent, ship_symbol, waypoint, trade_symbol, units, opts) do
    cargo_intent(agent, ship_symbol, "buy", waypoint, trade_symbol, units, opts)
  end

  defp sell_goods_intent(agent, ship_symbol, waypoint, trade_symbol, units, opts) do
    cargo_intent(agent, ship_symbol, "sell", waypoint, trade_symbol, units, opts)
  end

  defp request_job_sell_goods_intent(
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

    with {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
         true <- ship.id == ship_id,
         {:ok, live_ship} <- fresh_job_ship(agent, ship_symbol, live_ship),
         true <- live_ship.symbol == ship_symbol,
         {:ok, intent} <-
           Repo.transaction(
             fn ->
               current_job = Repo.get(Job, job.id)

               if current_job && current_job.ship_id == ship.id && Job.running?(current_job) do
                 case insert_job_intent(current_job, %{
                        type: "sell",
                        target_waypoint: waypoint,
                        parameters: intent_parameters
                      }) do
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
      false -> {:error, :invalid_cargo_intent_owner}
      error -> error
    end
  end

  defp deliver_goods_intent(
         agent,
         ship_symbol,
         recipient,
         waypoint,
         trade_symbol,
         units,
         opts
       )

  defp deliver_goods_intent(
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

  defp deliver_goods_intent(
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

  defp deliver_goods_intent(
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
             {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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

  defp deliver_construction_goods_intent(
         agent,
         ship_symbol,
         system_symbol,
         waypoint,
         trade_symbol,
         units,
         opts
       ) do
    with {:ok, live_ship} <-
           construction_live_ship(agent, ship_symbol, opts),
         {:ok, ^system_symbol} <- Fleet.system_from_headquarters(waypoint),
         true <- live_ship.nav.system_symbol == system_symbol do
      opts =
        Keyword.merge(opts,
          recipient: %{type: "construction", system: system_symbol, waypoint: waypoint}
        )

      case opts[:caller] do
        "job" ->
          with %Job{} = job <- Repo.get(Job, opts[:job_id]),
               {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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

  defp request_module_intent(agent, :manual, ship_symbol, type, module_symbol, parameters)
       when type in ["install_module", "remove_module"] and is_map(parameters) do
    authorized_removals =
      parameters[:authorized_removals] || parameters["authorized_removals"] || %{}

    module_intent(agent, ship_symbol, type, module_symbol, authorized_removals)
  end

  defp request_module_intent(
         %AgentRecord{} = agent,
         %Job{type: "outfitting", id: job_id, ship_id: ship_id},
         ship_symbol,
         type,
         module_symbol,
         parameters
       )
       when type in ["install_module", "remove_module"] and is_map(parameters) do
    with {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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

  defp request_module_intent(_, _, _, _, _, _), do: {:error, :invalid_module_intent}

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
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol) do
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
    case unfinished_manual_intent(ship.id) do
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
           Fleet.preempt_miner_job_for(
             agent,
             ship.symbol,
             {:manual_override, "module modification"}
           ),
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
         {:ok, ship} <- Fleet.owned_ship(agent, ship_symbol),
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
      Fleet.preempt_miner_job_for(agent, ship_symbol, {:manual_override, "#{type} goods"})
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

  defp do_stop_intent(%AgentRecord{} = agent, intent_id, owner) do
    case Repo.transaction(
           fn ->
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

        Fleet.record_activity(
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

      case unfinished_manual_intent(ship.id) do
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
      case Fleet.unfinished_job(ship.id) do
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

  @doc false
  def unfinished_manual_intent(ship_id) do
    Repo.one(
      from intent in Intent,
        where:
          intent.ship_id == ^ship_id and intent.caller == "manual" and
            intent.status in ^@unfinished_states
    )
  end

  @doc false
  def unfinished_job_intent(job_id) do
    Repo.one(
      from intent in Intent,
        where:
          intent.job_id == ^job_id and intent.caller == "job" and
            intent.status in ^@unfinished_states
    )
  end

  @doc false
  def terminalize_job_intent!(job) do
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
    (is_map(intent.in_flight_action) and
       intent.in_flight_action["kind"] in ["navigate", "orbit", "dock"]) or
      (is_map(intent.last_action_result) and intent.last_action_result["wait"] == "arrival")
  end

  defp prerequisite_action_reconciled?(
         %{"kind" => "orbit", "waypoint" => waypoint},
         live_ship
       ),
       do: live_ship.nav.status == "IN_ORBIT" and live_ship.nav.waypoint_symbol == waypoint

  defp prerequisite_action_reconciled?(%{"kind" => "dock", "waypoint" => waypoint}, live_ship),
    do: live_ship.nav.status == "DOCKED" and live_ship.nav.waypoint_symbol == waypoint

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

  defp preemption_message({:manual_override, action}), do: "Paused by direct #{action}"
  defp preemption_message(reason), do: "Paused: #{inspect(reason)}"

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

  defp do_advance_intents(
         agent,
         %Intent{type: "navigate", in_flight_action: action} = intent,
         live_ship
       )
       when is_map(action) do
    if action["kind"] in ["navigate", "orbit", "dock"] do
      if prerequisite_action_reconciled?(action, live_ship) do
        case transition_intent(intent, in_flight_action: nil) do
          {:ok, intent} -> advance_intents(agent, intent, live_ship)
          :intent_no_longer_owned -> :ok
        end
      else
        block_intents(intent, {:ambiguous_operation_evidence, action["kind"]})
      end
    else
      block_intents(intent, {:ambiguous_operation_evidence, action["kind"]})
    end
  end

  defp do_advance_intents(agent, %Intent{type: "navigate"} = intent, live_ship) do
    cond do
      arrived_at_target?(live_ship, intent.target_waypoint) ->
        complete_intents(agent, intent)

      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
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
      %{"kind" => kind} = action when kind in ["navigate", "orbit", "dock"] ->
        if prerequisite_action_reconciled?(action, live_ship) do
          case transition_intent(intent, in_flight_action: nil) do
            {:ok, intent} -> advance_intents(agent, intent, live_ship)
            :intent_no_longer_owned -> :ok
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

  defp advance_cargo_intent(agent, intent, live_ship) do
    cond do
      live_ship.nav.waypoint_symbol != intent.target_waypoint ->
        advance_cargo_navigation(agent, intent, live_ship)

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

  defp advance_cargo_navigation(agent, intent, live_ship) do
    cond do
      in_transit?(live_ship) ->
        wait_for_manual_arrival(agent, intent, live_ship)

      Fleet.cooldown_active?(live_ship) ->
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
        "listing_price" => cargo_price(intent.type, good),
        "cargo_before" => Fleet.item_units(live_ship.cargo, intent.parameters["trade_symbol"])
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
    case Fleet.supply_construction(
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
         cargo_delta = cargo_before - Fleet.item_units(cargo, trade_symbol),
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
  @doc false
  def with_current_intent(%Intent{id: id}, fun) do
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

  @doc false
  def transition_intent(intent, attrs) do
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
    cargo_before = Fleet.item_units(live_ship.cargo, module_symbol)

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

          {:error, %SpaceTraders.API.GameplayError{} = reason} ->
            block_module_intent(intent, reason)

          {:error, reason} ->
            await_module_reconciliation(intent, reason)
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

  defp reconcile_module_intent(intent, live_ship, action) do
    module_symbol = action["module_symbol"]
    installed_before = action["installed_before"]
    cargo_before = action["cargo_before"]
    installed_now = module_count(live_ship.modules, module_symbol)
    cargo_now = Fleet.item_units(live_ship.cargo, module_symbol)

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
          blocker: Fleet.job_blocker({:awaiting_reconciliation, reason}),
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
          blocker: Fleet.job_blocker(intents_block_reason(reason)),
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
          blocker: Fleet.job_blocker(reason),
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

  defp block_cargo_intent(intent, reason) do
    evidence = %{
      "target" => intent.target_waypoint,
      "trade_good" => intent.parameters["trade_symbol"],
      "constraint" => intent.parameters,
      "observed" => inspect(reason)
    }

    case transition_intent(intent,
           status: "blocked",
           blocker: %{Fleet.job_blocker(reason) | evidence: inspect(evidence)},
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
           Fleet.find_deliverable(contract, trade_symbol) do
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

      cargo_delta = cargo_before - Fleet.item_units(cargo, trade_symbol)

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
    accepted =
      Fleet.recipient_fulfilled_units(recipient, action["trade_symbol"]) - fulfilled_before

    if delivery_evidence?(action, cargo, accepted), do: {:accepted, accepted}, else: :ambiguous
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
    with {:ok, source_system} <- Fleet.system_from_headquarters(live_ship.nav.waypoint_symbol),
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
    allowed = get_in(intent.parameters, ["allowed_methods"]) || ["jump", "warp"]
    warp_reviewed? = get_in(intent.parameters, ["reviewed_warp", "method"]) == "warp"

    cond do
      warp_reviewed? and "warp" in allowed ->
        dispatch_manual_warp(agent, intent, live_ship)

      "jump" in allowed ->
        advance_manual_jump_route(agent, intent, live_ship)

      true ->
        block_intents(intent, :method_not_allowed)
    end
  end

  defp jump_origin_for_intent(
         agent,
         source_system,
         %Intent{parameters: parameters} = intent
       ) do
    case get_in(parameters, ["reviewed_jump", "source_waypoint"]) do
      source when is_binary(source) ->
        with {:ok, destination_system} <- Fleet.system_from_headquarters(intent.target_waypoint),
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
             case Fleet.waypoint_jump_gate(agent, waypoint) do
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
            case Fleet.waypoint_construction(agent, waypoint) do
              {:ok, %{is_complete: true}} -> "complete"
              {:ok, _} -> "incomplete"
              {:error, _} -> "unavailable"
            end

          case Fleet.waypoint_jump_gate(agent, waypoint) do
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
    with {:ok, source_system} <- Fleet.system_from_headquarters(live_ship.nav.waypoint_symbol),
         :ok <- reviewed_jump_flight_mode(intent, live_ship.nav.flight_mode),
         {:ok, destination_system} <- Fleet.system_from_headquarters(intent.target_waypoint),
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

  defp block_intents(intent, reason) do
    already_blocked? = match?(%Intent{status: "blocked"}, Repo.get(Intent, intent.id))

    case transition_intent(intent,
           status: "blocked",
           blocker: Fleet.job_blocker(intents_block_reason(reason)),
           in_flight_action:
             if(preserve_claim?(reason) and is_map(intent.in_flight_action),
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

  # A fuel-independent Ship is recognized from authoritative capacity; zero
  # current fuel only blocks Ships that actually burn fuel.
  defp fuel_empty?(%{fuel: %{capacity: capacity}}) when is_integer(capacity) and capacity <= 0,
    do: false

  defp fuel_empty?(%{fuel: %{current: current}}) when is_integer(current), do: current <= 0
  defp fuel_empty?(_), do: false

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
        "manual_intent_recovery",
        "Authoritative recovery read failed; retrying",
        "transport_error"
      )

      recover_manual_intent_on_boot(ship_symbol, agent_id)
    else
      case Repo.transaction(
             fn ->
               current = Repo.get!(Intent, intent.id)

               if Intent.unfinished?(current) do
                 Repo.update!(
                   Ecto.Changeset.change(current,
                     status: "blocked",
                     blocker: Fleet.job_blocker({:retry_exhausted, reason}),
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

  # A restarted job-owned navigate Intent re-enters the same reconciliation from
  # boot's fresh observation; recovery never replays a stored mutation.
  defp recover_manual_intent_on_boot(ship_symbol, agent_id) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %Intent{status: status} = intent when status != "awaiting_confirmation" <-
           unfinished_manual_intent(ship.id),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id),
         :ok <- Agent.execution_allowed?(agent) do
      case Agent.handle_game_result(
             agent,
             SpaceTraders.API.get_ship(agent.agent_token, ship_symbol)
           ) do
        {:ok, live_ship} ->
          reconcile(agent.id, ship_symbol, live_ship, :boot, intent.id, nil)

        {:error, reason} ->
          if reason == :stale_agent,
            do: :ok,
            else: intent_recovery_retry_or_block(ship, intent, agent_id, reason)
      end
    else
      _ -> :ok
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
end
