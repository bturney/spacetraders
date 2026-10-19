defmodule SpaceTradersWeb.ShipLive do
  @moduledoc """
  Ship + Why (#772): one Ship's status in plain words, what it chose and why,
  an "Options it had" chart, and expected vs actual for its last 10 trades.

  Read from stored state only; mounting and updating make no game request. A
  stored change to this Ship re-reads it at once; Intent, allocation and
  Earnings prompts re-read at most once per second.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Clock, Fleet, FleetGeneration}
  alias SpaceTraders.MissionControl.{Channels, ShipWhy}

  @refresh_ms 1_000
  @chips %{
    trading: :trading,
    scouting: :scouting,
    waiting: :waiting,
    stuck: :stuck,
    busy_not_earning: :busy
  }

  @impl true
  def mount(%{"ship_symbol" => symbol}, _session, socket) do
    agent =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent}} -> agent
        _ -> nil
      end

    if agent && connected?(socket) do
      Fleet.subscribe_ship_state(agent.id)
      Fleet.subscribe_intent_changes()
      Channels.subscribe_earnings()
      Channels.subscribe_allocation()
    end

    socket
    |> assign(agent: agent, symbol: symbol, refresh: nil, timer: nil, why: nil)
    |> load()
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_info({:ship_state, %{symbol: symbol}}, %{assigns: %{symbol: symbol}} = socket),
    do: {:noreply, load(socket)}

  def handle_info({:ship_state, _other}, socket), do: {:noreply, socket}

  def handle_info(:refresh, socket), do: {:noreply, socket |> assign(refresh: nil) |> load()}

  def handle_info(:overdue, socket), do: {:noreply, socket |> assign(timer: nil) |> load()}

  def handle_info(_prompt, %{assigns: %{agent: nil}} = socket), do: {:noreply, socket}

  def handle_info(_prompt, %{assigns: %{refresh: ref}} = socket) when ref != nil,
    do: {:noreply, socket}

  def handle_info(_prompt, socket),
    do: {:noreply, assign(socket, refresh: Process.send_after(self(), :refresh, @refresh_ms))}

  defp load(%{assigns: %{agent: nil}} = socket), do: socket

  defp load(socket) do
    now = Clock.utc_now()

    why =
      case ShipWhy.for_ship(socket.assigns.agent, socket.assigns.symbol, now) do
        {:ok, why} -> why
        {:error, :not_found} -> nil
      end

    socket |> assign(why: why) |> schedule_overdue(why, now)
  end

  # One timer for the moment this Ship turns overdue, so silent staleness shows.
  defp schedule_overdue(socket, why, now) do
    if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)

    timer =
      case why && why.row do
        %{overdue?: false, overdue_at: %DateTime{} = at} ->
          Process.send_after(self(), :overdue, max(0, DateTime.diff(at, now, :millisecond)))

        _ ->
          nil
      end

    assign(socket, timer: timer)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:ships}>
      <.link navigate={~p"/ships"} class="text-xs text-dim">← Ships</.link>

      <p :if={!@why} id="ship-missing" class="mt-3 text-dim">
        No current Ship named {@symbol}.
      </p>

      <div :if={@why} id={"ship-#{@why.ship.symbol}"} class="mt-2 space-y-3">
        <.card tone={chip(@why.status.kind)}>
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <h1 class="text-xl font-medium">{@why.ship.symbol}</h1>
              <div class="text-xs text-dim">
                {@why.row.location}<span :if={@why.row.overdue?} class="text-warning"> · as of {clock(
                  @why.row.observed_at
                )}</span>
              </div>
            </div>
            <.status_chip status={chip(@why.status.kind)} />
          </div>
          <div class="mt-2">
            <.route_bar
              id="ship-route"
              from={@why.row.from}
              to={@why.row.to}
              at={@why.row.at}
              depart_at={@why.row.depart_at}
              arrive_at={@why.row.arrive_at}
              status={chip(@why.status.kind)}
              size={:md}
            />
          </div>
          <div class="num mt-1 flex justify-between gap-3 text-xs text-dim">
            <span>Fuel {fuel(@why.row.fuel)}</span>
            <span>{cargo(@why.row.cargo)}</span>
          </div>
        </.card>

        <.card id="ship-why">
          <.eyebrow>Why</.eyebrow>
          <p id="why-sentence" class="mt-1">{sentence(@why)}</p>
          <p :if={status_line(@why)} id="why-status" class="mt-1 text-xs text-dim">
            {status_line(@why)}
          </p>
          <div class="mt-2 flex items-end justify-between gap-3">
            <div>
              <div class="text-xs text-dim">Credits per Ship-hour</div>
              <div id="ship-gauge" class="num text-2xl">{rate(@why.credits_per_hour)}</div>
            </div>
            <.countdown
              :if={until(@why)}
              id="ship-countdown"
              until={until(@why)}
              caption={caption(@why)}
              size={18}
            />
          </div>
        </.card>

        <.card :if={@why.options != []} id="ship-options">
          <.eyebrow>
            Options it had<:right>credits per Ship-hour</:right>
          </.eyebrow>
          <div class="mt-2 space-y-1.5">
            <div :for={option <- @why.options} class="text-xs" data-chosen={to_string(option.chosen?)}>
              <div class="flex justify-between gap-2">
                <span class={option.chosen? && "font-medium"}>
                  {trade_name(option)}{option.chosen? && " · chosen"}
                </span>
                <span class="num">{rate(option.rate)}</span>
              </div>
              <div class="h-1.5 rounded-full bg-base-300">
                <div
                  class={["h-1.5 rounded-full", (option.chosen? && "bg-trading") || "bg-dim/50"]}
                  style={"width: #{bar(option.rate, @why.options)}%"}
                >
                </div>
              </div>
            </div>
          </div>
        </.card>

        <.card id="ship-history">
          <.eyebrow>
            Last {length(@why.history)} trades<:right>expected vs actual</:right>
          </.eyebrow>
          <p :if={@why.history == []} class="mt-1 text-xs text-dim">No completed trades yet.</p>
          <div :if={@why.history != []} class="mt-2 space-y-1.5">
            <div :for={trade <- @why.history} class="text-xs" id={"trade-#{trade.id}"}>
              <div class="flex justify-between gap-2">
                <span>{trade_name(trade)}</span>
                <span class="num text-dim">
                  {format_signed(trade.actual)}<span :if={trade.expected}> vs {format_signed(
                    trade.expected
                  )}</span>
                </span>
              </div>
              <div class="relative h-2">
                <div class="absolute inset-x-0 top-[3px] h-px bg-line"></div>
                <div
                  :if={trade.expected}
                  class="absolute top-0 size-2 -translate-x-1/2 rounded-full border border-dim bg-base-100"
                  style={"left: #{place(trade.expected, @why.history)}%"}
                  title="Expected"
                >
                </div>
                <div
                  class={[
                    "absolute top-0 size-2 -translate-x-1/2 rounded-full",
                    (met?(trade) && "bg-trading") || "bg-busy"
                  ]}
                  style={"left: #{place(trade.actual, @why.history)}%"}
                  title="Actual"
                >
                </div>
              </div>
            </div>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  ## The sentence

  # Extra facts beside the sentence: retry state, or what a busy Ship is doing.
  defp status_line(%{status: %{kind: :stuck} = status}), do: retry(status)
  defp status_line(%{choice: %{}, status: %{phrase: phrase}}), do: phrase
  defp status_line(_why), do: nil

  defp sentence(%{status: %{kind: :stuck, reason: reason}}), do: "#{reason}."

  defp sentence(%{choice: %{} = choice}) do
    "Chose #{trade_name(choice)} #{estimate(choice)}#{beat(choice.alternatives)}#{price_age(choice)}."
  end

  defp sentence(%{wait: %{} = wait}) do
    best =
      case wait.best do
        nil -> "no trade option is known yet"
        best -> "best was #{trade_name(best)}#{best_estimate(best)}"
      end

    "No trade worth it right now; #{best}; " <>
      "last checked #{clock(wait.last_checked_at)}, checking again at #{clock(wait.next_check_at)}."
  end

  defp sentence(%{status: %{phrase: phrase}}), do: "#{phrase}."

  defp estimate(%{net_credits: nil}), do: "(estimate after fuel unavailable)"

  defp estimate(choice) do
    parts = [
      "~#{format_signed(choice.net_credits)} after fuel",
      choice.seconds && "~#{max(1, round(choice.seconds / 60))} min",
      choice.rate && "~#{format_int(choice.rate)}/h"
    ]

    "(" <> (parts |> Enum.filter(& &1) |> Enum.join(" · ")) <> ")"
  end

  defp best_estimate(%{net_credits: nil}), do: ""
  defp best_estimate(best), do: " (~#{format_signed(best.net_credits)} after fuel)"

  defp beat([]), do: ""

  defp beat([first | rest]) do
    others =
      case length(rest) do
        0 -> ""
        1 -> " and 1 other"
        n -> " and #{n} others"
      end

    " over #{trade_name(first)}#{if first.rate, do: " (~#{format_int(first.rate)}/h)"}#{others}"
  end

  defp price_age(%{price_age_seconds: nil}), do: ""

  defp price_age(%{price_age_seconds: seconds}),
    do: "; price was #{max(1, round(seconds / 60))} min old"

  defp trade_name(%{good: good, source: source, destination: destination}) do
    name = good |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
    "#{name} #{short(source)}→#{short(destination)}"
  end

  defp short(nil), do: "—"
  defp short(symbol), do: symbol |> String.split("-") |> List.last()

  ## Charts

  defp bar(nil, _options), do: 0

  defp bar(rate, options) do
    top = options |> Enum.map(&(&1.rate || 0)) |> Enum.max(fn -> 0 end)
    if top <= 0, do: 0, else: round(max(rate, 0) / top * 100)
  end

  # Position of a value on the shared scale of all expected and actual values.
  defp place(value, history) do
    values = Enum.flat_map(history, &[&1.actual, &1.expected]) |> Enum.reject(&is_nil/1)
    {low, high} = Enum.min_max(values)
    if high == low, do: 50, else: 4 + round((value - low) / (high - low) * 92)
  end

  defp met?(%{expected: nil}), do: true
  defp met?(%{expected: expected, actual: actual}), do: actual >= 0.8 * expected

  ## Small helpers

  defp chip(status), do: Map.fetch!(@chips, status)

  defp until(%{row: %{in_transit?: true, arrive_at: at}}), do: at
  defp until(%{status: %{next_attempt_at: %DateTime{} = at}}), do: at
  defp until(%{status: %{next_check_at: %DateTime{} = at}}), do: at
  defp until(_why), do: nil

  defp caption(%{row: %{in_transit?: true}}), do: "to arrival"
  defp caption(%{status: %{next_attempt_at: %DateTime{}}}), do: "next attempt"
  defp caption(_why), do: "next check"

  defp retry(%{retries: retries, next_attempt_at: at}) when is_integer(retries),
    do: "Retry #{retries}#{if at, do: ", next attempt at #{clock(at)}"}"

  defp retry(_status), do: nil

  defp rate(nil), do: "— /h"
  defp rate(credits), do: "#{format_int(credits)}/h"

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp clock(_), do: "—"

  defp fuel({_current, 0}), do: "not needed"
  defp fuel({current, capacity}), do: "#{format_int(current)}/#{format_int(capacity)}"

  defp cargo([]), do: "No cargo"
  defp cargo(items), do: Enum.map_join(items, ", ", fn {good, units} -> "#{units} #{good}" end)
end
