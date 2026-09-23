defmodule SpaceTradersWeb.InterventionLive do
  @moduledoc "Exceptional Ship reservation and one-off Manual Intervention."

  use SpaceTradersWeb, :live_view
  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intents, Ship}
  alias SpaceTraders.{ManualIntervention, Repo, ShipReservation}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(form_drafts: %{}) |> load_state()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <header class="mb-8 max-w-3xl space-y-2">
        <p class="eyebrow">Exceptional Operator action</p>
        <h1 class="text-3xl font-bold">Manual Intervention</h1>
        <p>
          Reserve a Ship before requesting a one-off Navigate outcome. Reservations exclude Ships from Fleet allocation until released.
        </p>
      </header>

      <section id="ship-reservations" class="space-y-3">
        <h2 class="text-xl font-semibold">Ship reservations</h2>
        <p :if={@ships == []}>No Ships are available in this Fleet.</p>
        <article :for={ship <- @ships} class="rounded-lg border border-base-300 p-4">
          <h3 class="font-semibold">{ship.symbol}</h3>
          <%= if reservation = @reservations[ship.id] do %>
            <p class="text-sm">Reserved: {reservation.reason}</p>
            <form
              id={"intervene-#{ship.id}"}
              phx-submit="intervene"
              phx-change="draft"
              class="mt-3 flex flex-wrap gap-2"
            >
              <input type="hidden" name="ship_id" value={ship.id} />
              <input
                name="waypoint"
                aria-label="Destination Waypoint"
                placeholder="Destination Waypoint"
                value={get_in(@form_drafts, [ship.id, "waypoint"])}
                class="input input-bordered"
                required
              />
              <input
                name="reason"
                aria-label="Intervention reason"
                placeholder="Why intervene?"
                value={get_in(@form_drafts, [ship.id, "reason"])}
                class="input input-bordered"
                required
              />
              <button type="submit" class="btn btn-warning">Request intervention</button>
            </form>
            <button
              type="button"
              phx-click="release"
              phx-value-ship_id={ship.id}
              class="btn btn-outline btn-sm mt-3"
            >Release reservation</button>
          <% else %>
            <form
              id={"reserve-#{ship.id}"}
              phx-submit="reserve"
              phx-change="draft"
              class="mt-3 flex flex-wrap gap-2"
            >
              <input type="hidden" name="ship_id" value={ship.id} />
              <input
                name="reason"
                aria-label="Reservation reason"
                placeholder="Why reserve?"
                value={get_in(@form_drafts, [ship.id, "reason"])}
                class="input input-bordered"
                required
              />
              <button type="submit" class="btn btn-outline">Reserve Ship</button>
            </form>
          <% end %>
        </article>
      </section>

      <section id="manual-interventions" class="mt-8">
        <h2 class="text-xl font-semibold">Intervention record</h2>
        <p :if={@interventions == []}>No interventions recorded.</p>
        <ul class="mt-3 space-y-2">
          <li :for={entry <- @interventions} class="rounded-lg border border-base-300 p-3">
            {entry.ship_reservation.ship_symbol} → {entry.target_waypoint} · {entry.reason} · {if entry.intent,
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
  def handle_event("draft", %{"ship_id" => raw_id} = params, socket) do
    with {:ok, ship_id} <- parse_id(raw_id),
         true <- Map.has_key?(socket.assigns.ship_ids, ship_id) do
      draft = Map.take(params, ["reason", "waypoint"])

      {:noreply,
       update(
         socket,
         :form_drafts,
         &Map.update(&1, ship_id, draft, fn old -> Map.merge(old, draft) end)
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("reserve", %{"ship_id" => raw_id, "reason" => reason}, socket) do
    with {:ok, ship_id} <- parse_id(raw_id),
         {:ok, _} <- ShipReservation.reserve(socket.assigns.current_scope, ship_id, reason) do
      {:noreply, socket |> load_state() |> put_flash(:info, "Ship reserved.")}
    else
      {:error, cause} ->
        {:noreply, put_flash(socket, :error, "Reservation unavailable: #{cause}")}
    end
  end

  def handle_event("release", %{"ship_id" => raw_id}, socket) do
    with {:ok, ship_id} <- parse_id(raw_id),
         :ok <- ShipReservation.release(socket.assigns.current_scope, ship_id) do
      {:noreply, socket |> load_state() |> put_flash(:info, "Reservation released.")}
    else
      {:error, cause} -> {:noreply, put_flash(socket, :error, "Cannot release: #{cause}")}
    end
  end

  def handle_event("stop_intervention", %{"intent_id" => raw_id}, socket) do
    with {:ok, intent_id} <- parse_id(raw_id),
         :ok <- Intents.stop_intervention(socket.assigns.current_scope, intent_id) do
      {:noreply, socket |> load_state() |> put_flash(:info, "Intervention stopped.")}
    else
      {:error, cause} -> {:noreply, put_flash(socket, :error, "Cannot stop: #{inspect(cause)}")}
    end
  end

  def handle_event(
        "intervene",
        %{"ship_id" => raw_id, "reason" => reason, "waypoint" => waypoint},
        socket
      ) do
    with {:ok, ship_id} <- parse_id(raw_id),
         %{agent: agent, symbol: symbol} <- socket.assigns.ship_ids[ship_id],
         {:ok, _intent} <-
           Intents.intervene_navigate(
             socket.assigns.current_scope,
             agent,
             symbol,
             waypoint,
             reason
           ) do
      {:noreply, socket |> load_state() |> put_flash(:info, "Intervention recorded.")}
    else
      {:error, cause} ->
        {:noreply, put_flash(socket, :error, "Intervention unavailable: #{inspect(cause)}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Ship unavailable.")}
    end
  end

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, :invalid_ship}
    end
  end

  defp parse_id(_), do: {:error, :invalid_ship}

  defp load_state(socket) do
    operator_id = socket.assigns.current_scope.operator.id

    ships =
      Repo.all(
        from ship in Ship,
          join: agent in AgentRecord,
          on: agent.id == ship.agent_id,
          where: agent.operator_id == ^operator_id,
          preload: [agent: agent],
          order_by: ship.symbol
      )

    assign(socket,
      ships: ships,
      ship_ids: Map.new(ships, &{&1.id, &1}),
      reservations:
        Map.new(ShipReservation.list(socket.assigns.current_scope), &{&1.ship_id, &1}),
      interventions: ManualIntervention.list(socket.assigns.current_scope)
    )
  end
end
