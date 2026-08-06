defmodule SpaceTraders.Fleet do
  @moduledoc """
  The Fleet context: the ships an Agent owns and their live state.

  The `ships` table is a local registry of owned ships (symbol + type); a ship's
  live state — location, fuel, cargo, cooldown, nav status — is pulled from the
  game through `SpaceTraders.API`. The server is the source of truth and the
  local rows are a cache (ADR 0005).

  All reads happen through this context so the dashboard stays a thin consumer
  with no game logic of its own.
  """

  import Ecto.Query, warn: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Repo

  @doc """
  Lists the ships locally registered to the agent, oldest first.

  This is the app's own registry of owned ships; it carries no live state.
  """
  def list_registered_ships(%AgentRecord{id: agent_id}) do
    Repo.all(from(s in Ship, where: s.agent_id == ^agent_id, order_by: s.id))
  end

  @doc """
  Pulls the agent's live fleet from the game API.

  Each ship carries its current nav (location + docked/orbiting/transit state),
  fuel, cargo and cooldown — the data the fleet cards render.

  Returns `{:ok, [%SpaceTraders.API.Model.Ship{}]}` or an API error. An agent
  without a stored AgentToken returns `{:error, :agent_token_missing}`.
  """
  def list_ships(%AgentRecord{agent_token: agent_token})
      when is_binary(agent_token) and agent_token != "" do
    SpaceTraders.API.get_ships(agent_token)
  end

  def list_ships(%AgentRecord{}), do: {:error, :agent_token_missing}
end
