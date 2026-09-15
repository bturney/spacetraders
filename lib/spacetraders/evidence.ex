defmodule SpaceTraders.Evidence do
  @moduledoc """
  Owns authoritative observations used to admit recovery transitions.

  Emergency Stop resume uses this seam so Fleet Strategy coordinates durable
  authority without invoking or interpreting gameplay reads itself.
  """

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.FleetGeneration

  @doc "Refreshes authoritative Agent and Ship state before post-stop planning."
  def refresh_for_emergency_stop_resume(%Scope{operator: operator}) do
    operator
    |> Agent.list_agents()
    |> Enum.reduce_while(:ok, fn agent, :ok ->
      case FleetGeneration.agent_overview(agent) do
        {:ok, _overview} ->
          case Fleet.list_ships(agent) do
            {:ok, _ships} -> {:cont, :ok}
            _error -> {:halt, {:error, :authoritative_refresh_required}}
          end

        {:error, :stale_agent} ->
          {:cont, :ok}

        _error ->
          {:halt, {:error, :authoritative_refresh_required}}
      end
    end)
  end
end
