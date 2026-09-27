defmodule SpaceTradersWeb.OperationsLive do
  @moduledoc """
  Authenticated Objective-grouped Endeavors view of the active Fleet work.

  One Endeavor is one root Fleet Commitment of the current portfolio, presented
  under the Strategic Objective it serves. The view reads the shared Endeavor
  projection so Operations and Mission Control cannot disagree.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.MissionControl

  @impl true
  def mount(_params, _session, socket) do
    operator_id = socket.assigns.current_scope.operator.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_strategy:#{operator_id}")
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_allocation:#{operator_id}")
    end

    {:ok, assign_projection(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="space-y-6">
        <header class="max-w-3xl space-y-2">
          <p class="eyebrow">Objective-grouped Endeavors</p>
          <.header>
            Operations
            <:subtitle>
              The active Fleet work grouped by the Strategic Objective each Endeavor serves.
            </:subtitle>
          </.header>
        </header>

        <section
          :if={!active_revision(@projection) or @projection.groups == []}
          id="operations-onboarding"
          class="rounded-2xl border border-primary/30 bg-primary/5 p-5"
        >
          <h2 class="text-xl font-bold">No active Endeavors yet</h2>
          <p :if={!active_revision(@projection)} class="mt-1 text-sm opacity-70">
            Choose and explicitly activate a Fleet Strategy Revision before autonomous progress begins.
          </p>
          <p :if={active_revision(@projection)} class="mt-1 text-sm opacity-70">
            {empty_contribution(@projection.contribution)}
          </p>
          <div class="mt-4 flex flex-wrap gap-3">
            <.link
              :if={!active_revision(@projection)}
              navigate={~p"/strategy"}
              class="btn btn-primary"
            >Review Fleet Strategy</.link>
            <.link navigate={~p"/mission-control"} class="btn btn-outline">Mission Control</.link>
          </div>
        </section>

        <section
          :for={group <- @projection.groups}
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <h2 class="text-xl font-bold">{group.priority}. {group.objective["objective"]}</h2>
          <p class="mt-1 text-sm opacity-70">{group.objective["evaluation"]}</p>

          <div class="mt-4 space-y-3">
            <article
              :for={endeavor <- group.endeavors}
              id={"endeavor-#{endeavor.commitment_id}"}
              class="rounded-xl border border-base-300 p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <h3 class="font-semibold">{endeavor.outcome}</h3>
                <span class="badge">Active</span>
              </div>
              <p class="mt-2 text-sm">{endeavor.reason}</p>
              <p class="mt-1 text-sm opacity-70">
                Expected value {endeavor.forecast}. Decision Episode {endeavor.decision_episode_id}.
              </p>

              <div class="mt-3 grid gap-3 sm:grid-cols-3">
                <div>
                  <p class="text-sm opacity-70">Contributing Ships</p>
                  <p class="mt-1 text-sm">
                    {ship_label(endeavor.claims)}
                  </p>
                </div>
                <div>
                  <p class="text-sm opacity-70">Reservations</p>
                  <p class="mt-1 text-sm">{reservation_label(endeavor.reservations)}</p>
                </div>
                <div>
                  <p class="text-sm opacity-70">Pledges</p>
                  <p class="mt-1 text-sm">{pledge_label(endeavor.pledges)}</p>
                </div>
              </div>

              <div :if={endeavor.dependencies != []} class="mt-3 space-y-1">
                <p class="text-sm opacity-70">Material dependencies</p>
                <p :for={dependency <- endeavor.dependencies} class="text-sm">
                  {dependency}
                </p>
              </div>
            </article>

            <p :if={group.endeavors == []} class="text-sm opacity-70">
              No active Endeavor serves this objective yet.
            </p>
          </div>
        </section>

        <section
          :if={@projection.released != []}
          id="released-endeavors"
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <h2 class="text-xl font-bold">Released Endeavor evidence</h2>
          <p class="mt-1 text-sm opacity-70">
            Superseded or unwound Commitments left the active view; their Decision Episode
            evidence remains reachable by identity.
          </p>
          <ul class="mt-3 space-y-3">
            <li :for={evidence <- @projection.released} class="border-t border-base-300 pt-3">
              <p class="font-semibold">{evidence.outcome}</p>
              <p class="text-sm">{evidence.reason}</p>
              <p class="text-sm opacity-70">Decision Episode {evidence.decision_episode_id}</p>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_info({:fleet_strategy_updated, operator_id}, socket)
      when operator_id == socket.assigns.current_scope.operator.id,
      do: {:noreply, assign_projection(socket)}

  def handle_info({:outbox, _id, _event, _payload}, socket),
    do: {:noreply, assign_projection(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_projection(socket) do
    assign(socket, :projection, MissionControl.endeavors(socket.assigns.current_scope))
  end

  defp active_revision(%{strategy: %{active_revision: %_{}}}), do: true
  defp active_revision(_projection), do: false

  defp empty_contribution(%{commitment_count: 0}),
    do: "Fleet Allocation has not published an active Endeavor for this Generation."

  defp empty_contribution(_contribution), do: nil

  defp ship_label([]), do: "None"
  defp ship_label(claims), do: Enum.join(claims, ", ")

  defp reservation_label(reservations) when map_size(reservations) == 0, do: "None"

  defp reservation_label(reservations) do
    reservations
    |> Enum.map(fn {resource, amount} -> "#{resource}: #{amount}" end)
    |> Enum.join(", ")
  end

  defp pledge_label([]), do: "None"

  defp pledge_label([%{"amount" => amount} | _] = pledges) do
    "Promises #{Enum.sum_by(pledges, & &1["amount"])} (latest #{amount})"
  end

  defp pledge_label(_pledges), do: "Outcome promise recorded"
end
