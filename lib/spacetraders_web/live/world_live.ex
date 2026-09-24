defmodule SpaceTradersWeb.WorldLive do
  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Agent, Fleet, World}

  @freshness_seconds 300

  @impl true
  def mount(_params, _session, socket) do
    groups =
      socket.assigns.current_scope.operator
      |> Agent.list_agents()
      |> Enum.flat_map(fn agent ->
        case Fleet.system_from_headquarters(agent.headquarters) do
          {:ok, system} ->
            [
              %{
                agent: agent,
                system: system,
                waypoints: World.waypoints(agent, system, DateTime.utc_now(), @freshness_seconds)
              }
            ]

          _ ->
            []
        end
      end)

    selected =
      groups
      |> Enum.find_value(fn group ->
        case group.waypoints do
          [first | _] -> {group.agent.id, first.symbol}
          [] -> nil
        end
      end)

    {:ok, assign(socket, groups: groups, selected: selected)}
  end

  @impl true
  def handle_event("select", %{"agent" => agent_id, "symbol" => symbol}, socket) do
    selection =
      Enum.find_value(socket.assigns.groups, fn group ->
        if to_string(group.agent.id) == agent_id and
             Enum.any?(group.waypoints, &(&1.symbol == symbol)),
           do: {group.agent.id, symbol}
      end)

    {:noreply, if(selection, do: assign(socket, selected: selection), else: socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="space-y-8">
        <header class="max-w-3xl space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">World</h1>
          <p class="text-sm opacity-70">
            Known places and the intelligence the Fleet has acquired. A place remains known even when its current conditions are unknown or stale.
          </p>
        </header>

        <section :if={@groups == []} class="rounded-xl border border-base-300 p-6">
          No Agent has a known headquarters System yet.
        </section>

        <section :for={group <- @groups} class="space-y-4" aria-label={"#{group.system} Atlas"}>
          <header class="flex flex-wrap items-baseline gap-x-3 gap-y-1 border-b border-base-300 pb-3">
            <h2 class="text-xl font-semibold">{group.system}</h2>
            <p class="text-sm opacity-70">
              {group.agent.symbol} · {length(group.waypoints)} known waypoints
            </p>
          </header>

          <p :if={group.waypoints == []} class="text-sm opacity-70">
            No Waypoints have been observed in this System.
          </p>

          <div
            :if={group.waypoints != []}
            class="grid gap-6 lg:grid-cols-[minmax(12rem,1fr)_minmax(0,2fr)]"
          >
            <nav aria-label={"#{group.system} known Waypoints"} class="flex flex-col gap-1">
              <button
                :for={waypoint <- group.waypoints}
                id={"world-waypoint-#{waypoint.symbol}"}
                phx-click="select"
                phx-value-agent={group.agent.id}
                phx-value-symbol={waypoint.symbol}
                aria-pressed={@selected == {group.agent.id, waypoint.symbol}}
                class={[
                  "rounded-lg px-3 py-2 text-left focus-visible:outline-2 focus-visible:outline-primary",
                  @selected == {group.agent.id, waypoint.symbol} && "bg-base-200 font-semibold"
                ]}
              >
                <span class="block">{waypoint.symbol}</span>
                <span class="text-xs opacity-70">Known waypoint</span>
              </button>
            </nav>

            <article
              :for={waypoint <- group.waypoints}
              :if={@selected == {group.agent.id, waypoint.symbol}}
              class="space-y-6"
              aria-label={"#{waypoint.symbol} intelligence"}
            >
              <header>
                <h3 class="text-2xl font-semibold">{waypoint.symbol}</h3>
                <p class="text-sm opacity-70">Known waypoint · {group.system}</p>
              </header>

              <div class="grid gap-6 sm:grid-cols-2">
                <section aria-label="Waypoint intelligence" class="space-y-2">
                  <h4 class="border-b border-base-300 pb-2 font-semibold">Waypoint</h4>
                  <.fact label="Type" fact={waypoint.facts["type"]} />
                  <.fact label="Traits" fact={waypoint.facts["traits"]} />
                  <.fact label="Modifiers" fact={waypoint.facts["modifiers"]} />
                  <.fact label="Chart" fact={waypoint.facts["chart"]} />
                </section>
                <section aria-label="Market intelligence" class="space-y-2">
                  <h4 class="border-b border-base-300 pb-2 font-semibold">Market</h4>
                  <.fact label="Exports" fact={waypoint.market.facts["exports"]} />
                  <.fact label="Live Listing" fact={waypoint.market.facts["trade_goods"]} />
                </section>
                <section aria-label="Shipyard intelligence" class="space-y-2">
                  <h4 class="border-b border-base-300 pb-2 font-semibold">Shipyard</h4>
                  <.fact label="Ship types" fact={waypoint.shipyard.facts["ship_types"]} />
                  <.fact label="Available Ships" fact={waypoint.shipyard.facts["ships"]} />
                </section>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :fact, :any, default: nil

  defp fact(assigns) do
    ~H"""
    <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 text-sm">
      <span class="opacity-70">{@label}</span>
      <span :if={is_nil(@fact) or @fact.state == "unknown"} class="font-medium">Unknown</span>
      <span :if={@fact && @fact.state == "known_unavailable"} class="font-medium">Unavailable</span>
      <span :if={@fact && @fact.state == "known"} class="font-medium">{format_value(@fact.value)}</span>
      <span
        :if={@fact}
        class={[@fact.freshness == :stale && "text-warning", "text-xs"]}
      >
        {if(@fact.freshness == :fresh,
          do: "Fresh",
          else: if(@fact.freshness == :stale, do: "Stale", else: "Not established")
        )} · observed {Calendar.strftime(
          @fact.observed_at,
          "%Y-%m-%d %H:%M UTC"
        )} via {@fact.source}
        <span :if={@fact.observing_ship_symbol}> aboard {@fact.observing_ship_symbol}</span>
      </span>
    </div>
    """
  end

  defp format_value(items) when is_list(items) do
    case items do
      [] ->
        "0 observed"

      _ ->
        names = Enum.map(items, &(Map.get(&1, "symbol") || Map.get(&1, "type")))

        if Enum.all?(names, &is_binary/1),
          do: Enum.join(names, ", "),
          else: "#{length(items)} observed"
    end
  end

  defp format_value(%{"submitted_by" => by}) when is_binary(by), do: "Charted by #{by}"
  defp format_value(%{}), do: "Observed"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: to_string(value)
end
