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

  defp parse_deadline(%Contract{terms: %{deadline: deadline}}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, date_time, _offset} -> {:ok, date_time}
      _ -> {:error, :invalid_contract_deadline}
    end
  end

  defp parse_deadline(_contract), do: {:error, :invalid_contract_deadline}
end
