defmodule SpaceTraders.API.AgentTokenReference do
  @moduledoc "A non-secret reference to an Agent's stored AgentToken."

  alias SpaceTraders.Agent.Agent

  @enforce_keys [:agent_id]
  defstruct [:agent_id]

  @type t() :: %__MODULE__{agent_id: pos_integer()}

  @spec new(%Agent{}) :: t()
  def new(%Agent{id: agent_id}) when is_integer(agent_id), do: %__MODULE__{agent_id: agent_id}
end
