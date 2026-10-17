defmodule SpaceTradersWeb.ActivityLive do
  @moduledoc "Consequential Fleet decisions in Operator chronology."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.MissionControl
  alias SpaceTraders.MissionControl.Channels

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Channels.subscribe_allocation()
    end

    {:ok, assign(socket, filter: "all") |> load_activity()}
  end

  @impl true
  def handle_info({:outbox, _id, _event, _payload}, socket), do: {:noreply, load_activity(socket)}

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

      <nav class="my-5 flex flex-wrap gap-2" aria-label="Activity filters">
        <button
          :for={filter <- ~w(all notable decision)}
          phx-click="filter"
          phx-value-filter={filter}
          aria-pressed={@filter == filter}
          class="btn btn-ghost btn-sm"
        >{String.capitalize(filter)}</button>
      </nav>

      <ol id="activity-history" class="space-y-3">
        <li
          :for={entry <- filtered(@activity, @filter)}
          id={entry.id}
          class="rounded-xl border border-base-300 p-4"
        >
          <span class="font-semibold">{entry.type |> Atom.to_string() |> String.capitalize()}</span>
          <time class="ml-2 text-sm opacity-70" datetime={DateTime.to_iso8601(entry.at)}>{Calendar.strftime(
            entry.at,
            "%Y-%m-%d %H:%M UTC"
          )}</time>
          <p class="mt-1">{entry.summary}</p>
          <details class="mt-2 text-sm">
            <summary class="cursor-pointer text-primary">Why and context</summary>
            <p class="mt-2 opacity-75">{entry.detail}</p>
            <.link
              :if={Map.get(entry, :decision_episode_id)}
              navigate={~p"/decision-episodes/#{Map.get(entry, :decision_episode_id)}"}
              class="link link-primary mt-1 block"
            >Decision Episode {Map.get(entry, :decision_episode_id)}</.link>
            <.link navigate={~p"/generations"} class="link link-primary mt-1 inline-block">Generation history</.link>
          </details>
        </li>
      </ol>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket)
      when filter in ~w(all notable decision),
      do: {:noreply, assign(socket, filter: filter)}

  defp load_activity(socket) do
    assign(socket, activity: MissionControl.activity(socket.assigns.current_scope))
  end

  defp filtered(entries, "all"), do: entries
  defp filtered(entries, "notable"), do: Enum.filter(entries, &MissionControl.notable_activity?/1)
  defp filtered(entries, filter), do: Enum.filter(entries, &(Atom.to_string(&1.type) == filter))
end
