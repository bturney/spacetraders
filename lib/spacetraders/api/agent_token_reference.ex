defmodule SpaceTraders.API.AgentTokenReference do
  @moduledoc "A non-secret reference to an Agent's stored AgentToken."

  alias SpaceTraders.Agent.Agent

  defstruct [:agent_id, :temporary_id]

  @type t() :: %__MODULE__{
          agent_id: pos_integer() | nil,
          temporary_id: reference() | nil
        }

  @spec new(%Agent{}) :: t()
  def new(%Agent{id: agent_id}) when is_integer(agent_id), do: %__MODULE__{agent_id: agent_id}

  @doc "Creates an opaque, process-local reference for an AgentToken being imported."
  @spec temporary(String.t()) :: t()
  def temporary(token) when is_binary(token) and token != "" do
    temporary_id = make_ref()
    Process.put({__MODULE__, temporary_id}, token)
    %__MODULE__{temporary_id: temporary_id}
  end

  @doc false
  def release(%__MODULE__{temporary_id: temporary_id}) when is_reference(temporary_id) do
    Process.delete({__MODULE__, temporary_id})
    :ok
  end

  def release(%__MODULE__{}), do: :ok
end
