defmodule SpaceTradersWeb.StatsLive do
  @moduledoc "Stats tab: best trade, most valuable Good and trades completed, from Earnings records."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.MissionControl.Channels
  alias SpaceTraders.Outcomes.Earnings

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Channels.subscribe_earnings()
    {:ok, assign_stats(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:stats}>
      <div class="space-y-3" id="stats">
        <.card id="stat-best-trade">
          <.eyebrow>Best trade</.eyebrow>
          <div :if={@stats.best_trade} class="mt-1">
            <.money value={@stats.best_trade.net_earnings} class="!text-2xl font-bold" />
            <p class="text-sm text-dim">
              {good_name(@stats.best_trade.good)} · {@stats.best_trade.source_waypoint} → {@stats.best_trade.destination_waypoint} · {@stats.best_trade.ship_symbol}
            </p>
          </div>
          <p :if={!@stats.best_trade} class="mt-1 text-sm text-dim">No trades completed yet.</p>
        </.card>

        <.card id="stat-best-good">
          <.eyebrow>Most valuable Good</.eyebrow>
          <div :if={@stats.best_good} class="mt-1">
            <p class="text-2xl font-bold">{good_name(@stats.best_good.good)}</p>
            <p class="text-sm text-dim">
              <.money value={@stats.best_good.net_earnings} /> across {@stats.best_good.trades} trades
            </p>
          </div>
          <p :if={!@stats.best_good} class="mt-1 text-sm text-dim">No trades completed yet.</p>
        </.card>

        <.card id="stat-trades">
          <.eyebrow>Trades completed</.eyebrow>
          <p class="num mt-1 text-2xl font-bold">{format_int(@stats.trades_completed)}</p>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info(:earnings_recorded, socket), do: {:noreply, assign_stats(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_stats(socket) do
    stats =
      case FleetAllocation.current_generation() do
        %{id: id} -> Earnings.stats(id)
        nil -> %{best_trade: nil, best_good: nil, trades_completed: 0}
      end

    assign(socket, :stats, stats)
  end

  defp good_name(good), do: good |> to_string() |> String.replace("_", " ") |> String.capitalize()
end
