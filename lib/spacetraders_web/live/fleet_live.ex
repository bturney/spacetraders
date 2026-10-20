defmodule SpaceTradersWeb.FleetLive do
  @moduledoc """
  Plumbing shared by the Operator Fleet pages (Glance, Ships, Ship + Why):
  the current Agent, the change subscriptions, and the 1 s coalescing of
  change prompts into one re-read.
  """

  import Phoenix.Component, only: [assign: 3]

  alias SpaceTraders.{Fleet, FleetGeneration}
  alias SpaceTraders.MissionControl.Channels

  @refresh_ms 1_000

  @doc "The current Fleet's Agent of the scope, or nil."
  def current_agent(scope) do
    case FleetGeneration.current_fleet(scope) do
      {:ok, %{state: :current, agent: agent}} -> agent
      _ -> nil
    end
  end

  @doc """
  Subscribes the caller to what moves a Fleet page: stored Ship changes
  (`{:ship_state, ship}`), committed Intent changes, Earnings records and
  allocation notifications. Nothing without an Agent.
  """
  def subscribe(nil), do: :ok

  def subscribe(agent) do
    Fleet.subscribe_ship_state(agent.id)
    Fleet.subscribe_intent_changes()
    Channels.subscribe_earnings()
    Channels.subscribe_allocation()
  end

  @doc """
  Marks the page dirty: `message` arrives once, a second after the first
  prompt; later prompts before then are folded in. Clear `:refresh` (assign
  it nil) when handling `message`.
  """
  def mark_dirty(%{assigns: %{refresh: ref}} = socket, _message) when ref != nil, do: socket

  def mark_dirty(socket, message),
    do: assign(socket, :refresh, Process.send_after(self(), message, @refresh_ms))
end
