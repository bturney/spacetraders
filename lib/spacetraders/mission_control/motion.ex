defmodule SpaceTraders.MissionControl.Motion do
  @moduledoc """
  Glance's "Ships in motion" read (#771): every current Ship as a
  `MissionControl.ShipRow` with its status, from stored facts only (no game
  request, a fixed number of queries).

  A small Fleet (up to #{6} Ships) is shown as route cards; a larger one as a
  grid of progress cells with per-status counts, plus a row for each Ship that
  is not earning right now (Stuck or Busy, not earning). Waiting on purpose is
  deliberate and is not listed there.
  """

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet
  alias SpaceTraders.MissionControl.{ShipRow, ShipStatus}

  @cards_up_to 6
  @not_earning [:stuck, :busy_not_earning]

  @doc "Largest Fleet shown as route cards."
  def cards_up_to, do: @cards_up_to

  @doc "`%{mode: :cards | :grid, rows, counts, not_earning}` for the Agent's current Ships."
  def read(%AgentRecord{} = agent, %DateTime{} = now) do
    ships = Fleet.current_ships(agent.id)
    build(ships, ShipStatus.for_ships(agent, ships, now), now)
  end

  @doc "The same, from already-read Ships and their statuses (keyed by Ship id)."
  def build(ships, statuses, %DateTime{} = now) do
    rows = Enum.map(ships, &ShipRow.build(&1, statuses[&1.id], now))
    summary(rows)
  end

  @doc "Mode, counts and Not earning rows of the given rows."
  def summary(rows) do
    %{
      mode: if(length(rows) <= @cards_up_to, do: :cards, else: :grid),
      rows: rows,
      counts: ShipStatus.counts(Enum.map(rows, & &1.status)),
      not_earning: Enum.filter(rows, &(&1.status.kind in @not_earning))
    }
  end
end
