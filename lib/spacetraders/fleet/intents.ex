defmodule SpaceTraders.Fleet.Intents do
  @moduledoc "The public seam for durable, caller-owned Intent execution."

  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.Fleet
  alias SpaceTraders.Repo

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

  @doc "Requests a closed operational goal for Manual Control or a Job."
  def request(agent, owner, ship_symbol, %BuyGoods{} = goal) do
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

      Fleet.buy_goods_intent(agent, ship_symbol, market, trade_good, goal.quantity, opts)
    end
  end

  def request(agent, owner, ship_symbol, %SellGoods{} = goal) do
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
          Fleet.sell_goods_intent(agent, ship_symbol, market, trade_good, goal.quantity, opts)

        %JobOwner{job: job} ->
          Fleet.request_job_sell_goods_intent(
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

  def request(agent, owner, ship_symbol, %DeliverGoods{} = goal) do
    request_delivery(agent, owner, ship_symbol, goal, nil)
  end

  def request(agent, owner, ship_symbol, %Navigate{} = goal) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, waypoint} <- valid_goal_waypoint(goal.waypoint) do
      case owner do
        :manual ->
          Fleet.request_manual_navigate(agent, ship_symbol, waypoint, goal.parameters)

        %JobOwner{job: %Job{type: type} = job} when type in @job_types ->
          Fleet.request_job_navigate(agent, job, ship_symbol, waypoint, goal.parameters)

        %JobOwner{} ->
          {:error, :unsupported_job_navigate}
      end
    end
  end

  def request(agent, owner, ship_symbol, %InstallModule{} = goal) do
    request_module(
      agent,
      owner,
      ship_symbol,
      "install_module",
      goal.module_symbol,
      goal.parameters
    )
  end

  def request(agent, owner, ship_symbol, %RemoveModule{} = goal) do
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

  def request(_agent, _owner, _ship_symbol, _goal), do: {:error, :unsupported_intent_goal}

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
      Fleet.request_job_sell_goods_intent(
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

  defp request_module(agent, owner, ship_symbol, type, module_symbol, parameters)
       when is_map(parameters) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_module_symbol(module_symbol),
         {:ok, parameters} <- valid_module_request(type, module_symbol, parameters, owner) do
      case owner do
        :manual ->
          Fleet.request_module_intent(
            agent,
            :manual,
            ship_symbol,
            type,
            module_symbol,
            parameters
          )

        %JobOwner{job: %Job{} = job} ->
          Fleet.request_module_intent(
            agent,
            job,
            ship_symbol,
            type,
            module_symbol,
            parameters
          )
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

  def request(agent, %JobOwner{} = owner, ship_symbol, %Navigate{} = goal, live_ship) do
    with {:ok, owner} <- normalize_owner(owner),
         :ok <- token_present(agent),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, waypoint} <- valid_goal_waypoint(goal.waypoint) do
      case owner do
        %JobOwner{job: %Job{type: type} = job} when type in @job_types ->
          Fleet.request_job_navigate(
            agent,
            job,
            ship_symbol,
            waypoint,
            goal.parameters,
            live_ship
          )

        _ ->
          {:error, :unsupported_job_navigate}
      end
    end
  end

  def request(agent, %JobOwner{} = owner, ship_symbol, %DeliverGoods{} = goal, live_ship) do
    request_delivery(agent, owner, ship_symbol, goal, live_ship)
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

      Fleet.deliver_goods_intent(
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

  @doc "Persists a reviewed Navigate Intent without dispatching a mutation."
  def review(agent, owner, ship_symbol, waypoint, preview) when is_map(preview) do
    with {:ok, :manual} <- normalize_owner(owner) do
      Fleet.review_navigation_intent(agent, ship_symbol, waypoint, preview)
    end
  end

  def review(_agent, _owner, _ship_symbol, _waypoint, _preview),
    do: {:error, :unsupported_intent_review}

  @doc "Persists a blocked Navigate Intent after preview rejects the route."
  def block_review(agent, owner, ship_symbol, waypoint, reason) do
    with {:ok, :manual} <- normalize_owner(owner) do
      Fleet.block_jump_preview(agent, ship_symbol, waypoint, reason)
    end
  end

  @doc "Confirms a persisted reviewed Navigate Intent by identity and revision."
  def confirm(agent, owner, intent_id, review_revision) do
    with {:ok, :manual} <- normalize_owner(owner) do
      Fleet.confirm_navigation_intent(agent, intent_id, review_revision)
    end
  end

  @doc "Stops one owned Intent without hiding unresolved mutation evidence."
  def stop(agent, owner, intent_id) do
    with {:ok, owner} <- normalize_owner(owner),
         %Intent{} = intent <- owned_intent(agent, intent_id),
         :ok <- owner_matches?(owner, intent) do
      Fleet.stop_intent_legacy(agent, intent_id, owner)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  @doc "Stops an owned Intent after binding the request to its Ship identity."
  def stop(agent, owner, ship_symbol, intent_id) do
    with {:ok, owner} <- normalize_owner(owner),
         %Intent{} = intent <- owned_intent(agent, intent_id),
         :ok <- owner_matches?(owner, intent),
         :ok <- intent_ship_matches?(intent, ship_symbol) do
      Fleet.stop_intent_legacy(agent, intent_id, owner)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  @doc "Re-enters shared reconciliation after a durable Ship timer fires."
  def reconcile(agent_id, ship_symbol, live_ship, trigger, expected_intent_id, expected_job_id) do
    Fleet.reconcile_timeline_event(
      agent_id,
      ship_symbol,
      live_ship,
      trigger,
      expected_intent_id,
      expected_job_id
    )
  end

  @doc "Re-enters Navigate reconciliation after boot's authoritative Ship read."
  def recover(agent, ship_symbol, live_ship, expected_intent_id, expected_job_id) do
    reconcile(agent.id, ship_symbol, live_ship, :boot, expected_intent_id, expected_job_id)
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

  defp owned_intent(%AgentRecord{id: agent_id}, intent_id) do
    Repo.one(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: intent.id == ^intent_id and ship.agent_id == ^agent_id
    )
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
end
