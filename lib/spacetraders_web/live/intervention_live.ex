defmodule SpaceTradersWeb.InterventionLive do
  @moduledoc "Exceptional Ship reservation and one-off Manual Intervention."

  use SpaceTradersWeb, :live_view
  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intents, Ship, TravelEstimate}
  alias SpaceTraders.{ManualIntervention, Repo, ShipReservation}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(form_drafts: %{}, estimates: %{}) |> load_state()}
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
                phx-debounce="500"
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
              <select name="method" aria-label="Estimate method" class="select select-bordered">
                <option
                  :for={method <- TravelEstimate.methods()}
                  value={method}
                  selected={draft_value(@form_drafts, ship.id, "method", "navigate") == method}
                >
                  {method}
                </option>
              </select>
              <select
                name="flight_mode"
                aria-label="Estimate Flight Mode"
                class="select select-bordered"
              >
                <option
                  :for={mode <- TravelEstimate.flight_modes()}
                  value={mode}
                  selected={draft_value(@form_drafts, ship.id, "flight_mode", "CRUISE") == mode}
                >
                  {mode}
                </option>
              </select>
              <button type="submit" class="btn btn-warning">Request intervention</button>
            </form>
            <.travel_estimate
              :if={@estimates[ship.id]}
              ship_id={ship.id}
              estimate={@estimates[ship.id]}
            />
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

  attr :ship_id, :integer, required: true
  attr :estimate, :any, required: true

  defp travel_estimate(%{estimate: {:ok, est}} = assigns) do
    assigns = assign(assigns, :est, est)

    ~H"""
    <section
      id={"travel-estimate-#{@ship_id}"}
      aria-label="Travel estimate"
      class="mt-3 space-y-1 rounded-lg border border-base-300 p-3 text-sm"
    >
      <h4 class="font-semibold">Travel estimate (not dispatched)</h4>
      <dl class="grid grid-cols-2 gap-x-4">
        <dt>Method</dt>
        <dd data-field="method">{@est.method}</dd>
        <dt>Flight Mode</dt>
        <dd data-field="flight_mode">{@est.flight_mode}</dd>
        <dt>Distance</dt>
        <dd data-field="distance">{format_distance(@est.distance)}</dd>
        <dt>Current fuel</dt>
        <dd data-field="current_fuel">{@est.current_fuel || "unknown"}</dd>
        <dt>Estimated fuel</dt>
        <dd data-field="fuel_cost">{@est.fuel_cost || "unknown"}</dd>
        <dt>Fuel after leg</dt>
        <dd data-field="remaining_fuel">{@est.remaining_fuel || "unknown"}</dd>
        <dt>Fits tank</dt>
        <dd data-field="fits_tank">{fits_label(@est.fits_tank?)}</dd>
        <dt>Duration</dt>
        <dd data-field="duration">{format_duration(@est.seconds)}</dd>
      </dl>
      <p :if={@est.status == :insufficient_fuel} role="alert" class="font-semibold text-error">
        Blocked: estimated fuel exceeds the current tank.
      </p>
      <ul class="list-disc pl-5">
        <li :for={warning <- @est.warnings}>{warning}</li>
      </ul>
      <p class="opacity-70">Estimate only; the game response at dispatch is final.</p>
    </section>
    """
  end

  defp travel_estimate(%{estimate: {:error, cause}} = assigns) do
    assigns = assign(assigns, :cause, cause)

    ~H"""
    <section
      id={"travel-estimate-#{@ship_id}"}
      aria-label="Travel estimate"
      class="mt-3 rounded-lg border border-base-300 p-3 text-sm"
    >
      Estimate unavailable ({inspect(@cause)}). The game decides at dispatch.
    </section>
    """
  end

  defp draft_value(drafts, ship_id, key, default),
    do: get_in(drafts, [ship_id, key]) || default

  defp format_distance(nil), do: "unknown"
  defp format_distance(distance), do: :erlang.float_to_binary(distance * 1.0, decimals: 1)

  defp format_duration(nil), do: "unknown"
  defp format_duration(seconds), do: "#{seconds} s"

  defp fits_label(true), do: "yes"
  defp fits_label(false), do: "no"
  defp fits_label(nil), do: "unknown"

  @impl true
  def handle_event("draft", %{"ship_id" => raw_id} = params, socket) do
    with {:ok, ship_id} <- parse_id(raw_id),
         true <- Map.has_key?(socket.assigns.ship_ids, ship_id) do
      draft = Map.take(params, ["reason", "waypoint", "method", "flight_mode"])

      socket =
        update(
          socket,
          :form_drafts,
          &Map.update(&1, ship_id, draft, fn old -> Map.merge(old, draft) end)
        )

      {:noreply, refresh_estimate(socket, ship_id)}
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

  # Recomputed from live Ship and retained Waypoint state on every draft change;
  # the estimate never feeds the dispatch path.
  defp refresh_estimate(socket, ship_id) do
    draft = socket.assigns.form_drafts[ship_id] || %{}
    waypoint = String.trim(draft["waypoint"] || "")
    method = draft["method"] || "navigate"
    mode = draft["flight_mode"] || "CRUISE"
    ship = socket.assigns.ship_ids[ship_id]

    estimates =
      if waypoint != "" and method in TravelEstimate.methods() and
           mode in TravelEstimate.flight_modes() do
        Map.put(
          socket.assigns.estimates,
          ship_id,
          Fleet.travel_estimate(ship.agent, ship.symbol, waypoint, method, mode)
        )
      else
        Map.delete(socket.assigns.estimates, ship_id)
      end

    assign(socket, :estimates, estimates)
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
