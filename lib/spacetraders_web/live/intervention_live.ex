defmodule SpaceTradersWeb.InterventionLive do
  @moduledoc "Manual Intervention record."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.ManualIntervention

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load_state(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <header class="mb-8 max-w-3xl space-y-2">
        <p class="eyebrow">Exceptional Operator action</p>
        <h1 class="text-3xl font-bold">Manual Intervention</h1>
      </header>

      <section id="manual-interventions" class="mt-8">
        <h2 class="text-xl font-semibold">Intervention record</h2>
        <p :if={@interventions == []}>No interventions recorded.</p>
        <ul class="mt-3 space-y-2">
          <li :for={entry <- @interventions} class="rounded-lg border border-base-300 p-3">
            {entry.target_waypoint} · {entry.reason} · {if entry.intent,
              do: entry.intent.status,
              else: entry.final_status || "pending"}
            <button
              :if={entry.intent && SpaceTraders.Fleet.Intent.unfinished?(entry.intent)}
              type="button"
              phx-click="stop_intervention"
              phx-value-intent_id={entry.intent.id}
              class="btn btn-outline btn-sm ml-3"
            >Stop intervention</button>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("stop_intervention", %{"intent_id" => raw_id}, socket) do
    with {:ok, intent_id} <- parse_id(raw_id),
         :ok <- Intents.stop_intervention(socket.assigns.current_scope, intent_id) do
      {:noreply, socket |> load_state() |> put_flash(:info, "Intervention stopped.")}
    else
      {:error, cause} -> {:noreply, put_flash(socket, :error, "Cannot stop: #{inspect(cause)}")}
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_ship}
    end
  end

  defp parse_id(_), do: {:error, :invalid_ship}

  defp load_state(socket),
    do: assign(socket, interventions: ManualIntervention.list(socket.assigns.current_scope))
end
