defmodule SpaceTraders.Shipyard do
  @moduledoc "Ship purchases for an Agent."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  @doc "Purchases a ship at a shipyard waypoint."
  def purchase(%AgentRecord{agent_token: token}, _ship_type, _waypoint)
      when not is_binary(token) or token == "" do
    {:error, :agent_token_missing}
  end

  def purchase(%AgentRecord{agent_token: token}, ship_type, waypoint) do
    with {:ok, %{transaction: transaction, ship: ship}} <-
           SpaceTraders.API.purchase_ship(token, ship_type, waypoint) do
      {:ok, %{transaction: transaction, ship: ship}}
    end
  end
end
