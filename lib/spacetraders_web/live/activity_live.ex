defmodule SpaceTradersWeb.ActivityLive do
  @moduledoc "Consequential Fleet decisions and conditions in Operator chronology."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{MissionControl, OperatorConditions}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        SpaceTraders.PubSub,
        "mission_conditions:#{socket.assigns.current_scope.operator.id}"
      )
    end

    {:ok, assign(socket, filter: "all") |> load_activity()}
  end

  @impl true
  def handle_info(:mission_conditions_updated, socket), do: {:noreply, load_activity(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <header class="mb-6">
        <p class="eyebrow">Fleet history</p>
        <h1 class="text-3xl font-bold">Activity</h1>
        <p class="mt-2 opacity-70">
          Consequential decisions and milestones, without routine API traffic.
        </p>
      </header>

      <section id="activity-attention" class="rounded-2xl border border-base-300 p-5">
        <h2 class="font-bold">Needs attention</h2>
        <p :if={@conditions == []} class="mt-2 text-sm opacity-70">
          No unresolved Attention or Intervention.
        </p>
        <ul class="mt-3 space-y-2">
          <li :for={condition <- @conditions}>
            <span class="font-semibold">{condition.kind}</span>
            · {condition.summary}
            <span :if={condition.acknowledged_at} class="text-sm opacity-70">Acknowledged · unresolved</span>
            <button
              :if={!condition.acknowledged_at}
              phx-click="acknowledge"
              phx-value-id={condition.id}
              class="btn btn-ghost btn-sm"
            >Acknowledge</button>
          </li>
        </ul>
      </section>

      <nav class="my-5 flex flex-wrap gap-2" aria-label="Activity filters">
        <button
          :for={filter <- ~w(all notable decision attention intervention)}
          phx-click="filter"
          phx-value-filter={filter}
          aria-pressed={@filter == filter}
          class="btn btn-ghost btn-sm"
        >{String.capitalize(filter)}</button>
      </nav>

      <ol id="activity-history" class="space-y-3">
        <li :for={entry <- filtered(@activity, @filter)} class="rounded-xl border border-base-300 p-4">
          <span class="font-semibold">{entry.type |> Atom.to_string() |> String.capitalize()}</span>
          <time class="ml-2 text-sm opacity-70" datetime={DateTime.to_iso8601(entry.at)}>{Calendar.strftime(
            entry.at,
            "%Y-%m-%d %H:%M UTC"
          )}</time>
          <p class="mt-1">{entry.summary}</p>
          <details class="mt-2 text-sm">
            <summary class="cursor-pointer text-primary">Why and context</summary>
            <p class="mt-2 opacity-75">{entry.detail}</p>
            <.link navigate={~p"/generations"} class="link link-primary mt-1 inline-block">Generation history</.link>
          </details>
        </li>
      </ol>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket)
      when filter in ~w(all notable decision attention intervention),
      do: {:noreply, assign(socket, filter: filter)}

  def handle_event("acknowledge", %{"id" => raw_id}, socket) do
    with {id, ""} <- Integer.parse(raw_id),
         :ok <- OperatorConditions.acknowledge(socket.assigns.current_scope, id) do
      {:noreply, load_activity(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  defp load_activity(socket) do
    scope = socket.assigns.current_scope

    assign(socket,
      activity: MissionControl.activity(scope),
      conditions: OperatorConditions.unresolved(scope)
    )
  end

  defp filtered(entries, "all"), do: entries
  defp filtered(entries, "notable"), do: Enum.filter(entries, &MissionControl.notable_activity?/1)
  defp filtered(entries, filter), do: Enum.filter(entries, &(Atom.to_string(&1.type) == filter))
end
