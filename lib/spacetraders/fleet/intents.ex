defmodule SpaceTraders.Fleet.Intents do
  @moduledoc "Agent-scoped reads for durable Intent history."

  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.Repo

  @unfinished_states Intent.unfinished_states()
  @terminal_states Intent.terminal_states()

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

  def list_current(%AgentRecord{} = agent), do: current(agent)
  def list_history(%AgentRecord{} = agent), do: history(agent)
end
