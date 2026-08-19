defmodule SpaceTraders.Contracts do
  @moduledoc "Contract lifecycle operations for an Agent."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model.Contract
  alias SpaceTraders.Contracts.DeadlineServer
  alias SpaceTraders.Timeline

  @doc "Re-arms every pending contract deadline after an application restart."
  def rearm_deadlines_on_boot do
    Timeline.pending_owners(:contract)
    |> Enum.each(fn %{owner_id: contract_id} -> DeadlineServer.ensure_started(contract_id) end)

    :ok
  end

  @doc "Returns the Agent's contracts from the game API."
  def list_contracts(%AgentRecord{agent_token: token}) when is_binary(token) and token != "" do
    SpaceTraders.API.get_contracts(token)
  end

  def list_contracts(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc "Returns whether a Contract's authoritative deadline has passed."
  def expired?(%Contract{accepted: false, deadline_to_accept: deadline}),
    do: deadline_passed?(deadline)

  def expired?(%Contract{accepted: true, terms: %{deadline: deadline}}),
    do: deadline_passed?(deadline)

  def expired?(_contract), do: false

  @doc "Returns whether a Contract is fulfilled or no longer actionable."
  def historical?(%Contract{fulfilled: true}), do: true
  def historical?(%Contract{} = contract), do: expired?(contract)

  @doc "Returns the lifecycle status used to classify a Contract."
  def status(%Contract{fulfilled: true}), do: :fulfilled

  def status(%Contract{} = contract) do
    if expired?(contract),
      do: :expired,
      else: if(contract.accepted, do: :accepted, else: :pending)
  end

  @doc "Returns whether an accepted Contract is still actionable."
  def active?(%Contract{accepted: true} = contract), do: not historical?(contract)
  def active?(%Contract{}), do: false

  @doc "Returns whether all delivery terms for a Contract are complete."
  def ready?(%Contract{terms: %{deliver: deliver}}) when is_list(deliver) do
    Enum.all?(deliver, &(&1.units_fulfilled >= &1.units_required))
  end

  def ready?(%Contract{}), do: false

  @doc "Returns whether a list of Contracts allows negotiating another Contract."
  def negotiable?(contracts) when is_list(contracts), do: Enum.all?(contracts, &historical?/1)
  def negotiable?(_contracts), do: false

  @doc "Returns whether a pending Contract can be accepted."
  def acceptable?(%Contract{accepted: false} = contract), do: not historical?(contract)
  def acceptable?(%Contract{}), do: false

  @doc "Returns whether an accepted Contract can receive delivery or fulfillment actions."
  def fulfillable?(%Contract{accepted: true} = contract), do: not historical?(contract)
  def fulfillable?(%Contract{}), do: false

  @doc "Returns the authoritative deadline and its display kind for a Contract."
  def deadline(%Contract{accepted: true, terms: %{deadline: deadline}}),
    do: {:completion, deadline}

  def deadline(%Contract{accepted: false, deadline_to_accept: deadline}),
    do: {:acceptance, deadline}

  def deadline(%Contract{}), do: nil

  @doc "Accepts a contract and persists its fulfillment deadline for restart recovery."
  def accept_contract(%AgentRecord{agent_token: token}, contract_id)
      when is_binary(token) and token != "" do
    with {:ok, %{contract: %Contract{} = contract} = result} <-
           SpaceTraders.API.accept_contract(token, contract_id),
         {:ok, deadline} <- parse_deadline(contract) do
      {:ok, _event} = Timeline.schedule_event(:contract, contract.id, :deadline, deadline)
      {:ok, _pid} = DeadlineServer.ensure_started(contract.id)
      {:ok, result}
    end
  end

  def accept_contract(%AgentRecord{}, _contract_id), do: {:error, :agent_token_missing}

  @doc "Fetches the Agent's accepted, actionable contracts' remaining deliverables."
  def active_deliverables(%AgentRecord{agent_token: token})
      when is_binary(token) and token != "" do
    with {:ok, contracts} <- SpaceTraders.API.get_contracts(token) do
      {:ok, remaining_deliverables(contracts)}
    end
  end

  def active_deliverables(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc "Flattens active Contracts into their remaining delivery terms."
  def remaining_deliverables(contracts) when is_list(contracts) do
    contracts
    |> Enum.filter(&active?/1)
    |> Enum.flat_map(&deliver_terms/1)
  end

  @doc "The deliverable entries still owed at a given Waypoint, in contract order."
  def pending_deliverables(entries, waypoint) do
    entries
    |> Enum.filter(&(Map.get(&1, "destination_symbol") == waypoint))
    |> Enum.filter(&(Map.get(&1, "units_remaining", 0) > 0))
  end

  defp deliver_terms(%Contract{id: id, terms: %{deliver: deliver}}) do
    (deliver || [])
    |> Enum.map(fn good ->
      base = %{
        "contract_id" => id,
        "destination_symbol" => good.destination_symbol,
        "trade_symbol" => good.trade_symbol
      }

      refresh_deliverable(base, good.units_required, good.units_fulfilled)
    end)
  end

  @doc "Rebuilds a deliverable entry's requirement fields from authoritative counts."
  def refresh_deliverable(entry, units_required, units_fulfilled) do
    Map.merge(entry, %{
      "units_required" => units_required,
      "units_fulfilled" => units_fulfilled,
      "units_remaining" => max(units_required - units_fulfilled, 0)
    })
  end

  @doc "Delivers goods from a Ship against an accepted contract."
  def deliver_goods(
        %AgentRecord{agent_token: token},
        contract_id,
        ship_symbol,
        trade_symbol,
        units
      )
      when is_binary(token) and token != "" and is_integer(units) and units > 0 do
    SpaceTraders.API.deliver_contract(token, contract_id, ship_symbol, trade_symbol, units)
  end

  def deliver_goods(
        %AgentRecord{agent_token: token},
        _contract_id,
        _ship_symbol,
        _trade_symbol,
        _units
      )
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def deliver_goods(%AgentRecord{}, _contract_id, _ship_symbol, _trade_symbol, _units),
    do: {:error, :invalid_units}

  @doc "Fulfills a contract after all delivery terms are complete."
  def fulfill_contract(%AgentRecord{agent_token: token}, contract_id)
      when is_binary(token) and token != "" do
    case SpaceTraders.API.fulfill_contract(token, contract_id) do
      {:ok, result} ->
        Timeline.cancel_events(:contract, contract_id, :deadline)
        {:ok, result}

      error ->
        error
    end
  end

  def fulfill_contract(%AgentRecord{}, _contract_id), do: {:error, :agent_token_missing}

  @doc "Negotiates a new contract with the faction at a Ship's current waypoint."
  def negotiate_contract(%AgentRecord{agent_token: token}, ship_symbol)
      when is_binary(token) and token != "" do
    SpaceTraders.API.negotiate_contract(token, ship_symbol)
  end

  def negotiate_contract(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  defp parse_deadline(%Contract{terms: %{deadline: deadline}}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, date_time, _offset} -> {:ok, date_time}
      _ -> {:error, :invalid_contract_deadline}
    end
  end

  defp parse_deadline(_contract), do: {:error, :invalid_contract_deadline}

  defp deadline_passed?(deadline) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, date_time, _offset} -> DateTime.compare(date_time, DateTime.utc_now()) == :lt
      _ -> false
    end
  end

  defp deadline_passed?(_deadline), do: false
end
