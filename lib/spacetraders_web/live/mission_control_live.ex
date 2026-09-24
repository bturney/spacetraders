defmodule SpaceTradersWeb.MissionControlLive do
  @moduledoc "Authenticated, concise read projection for Fleet Strategy outcomes."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.MissionControl

  @impl true
  def mount(_params, _session, socket) do
    operator_id = socket.assigns.current_scope.operator.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_strategy:#{operator_id}")
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "mission_conditions:#{operator_id}")
    end

    {:ok, assign_projection(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="space-y-6">
        <header class="max-w-3xl space-y-2">
          <p class="eyebrow">Autonomous outcome summary</p>
          <.header>
            Mission Control
            <:subtitle>
              Strategy intent, Fleet health, and only the Operator actions that need attention.
            </:subtitle>
          </.header>
        </header>
        <.link navigate={~p"/intervention"} class="link link-primary text-sm">
          Reserve a Ship or intervene
        </.link>

        <section
          :if={!@projection.strategy.active_revision || @projection.fleets == []}
          id="mission-onboarding"
          class="rounded-2xl border border-primary/30 bg-primary/5 p-5 sm:p-7"
        >
          <h2 class="text-xl font-bold">Set the Fleet direction</h2>
          <p class="mt-1 text-sm opacity-70">{onboarding_message(@projection)}</p>
          <div class="mt-4 flex flex-wrap gap-3">
            <.link
              :if={!@projection.strategy.active_revision}
              navigate={~p"/strategy"}
              class="btn btn-primary"
            >Review Fleet Strategy</.link>
            <.link :if={@projection.fleets == []} navigate={~p"/agents/new"} class="btn btn-outline">Mint an Agent</.link>
          </div>
        </section>

        <section id="operating-health" class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <p class="eyebrow">Operating health</p>
          <h2 class="mt-2 text-2xl font-bold">{health_label(@projection)}</h2>
          <p class="mt-1 text-sm opacity-70">{health_detail(@projection)}</p>
        </section>

        <section id="needs-attention" class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <h2 class="text-xl font-bold">Needs attention</h2>
          <p :if={@projection.conditions == []} class="mt-2 text-sm opacity-70">
            No unresolved Attention or Intervention.
          </p>
          <ul class="mt-3 space-y-3">
            <li :for={condition <- @projection.conditions} class="border-t border-base-300 pt-3">
              <strong>{if condition.kind == :intervention, do: "Intervention", else: "Attention"}</strong>
              <p>{condition.summary}</p>
              <span :if={condition.acknowledged_at} class="text-sm opacity-70">Acknowledged · unresolved</span>
              <button
                :if={!condition.acknowledged_at}
                type="button"
                phx-click="acknowledge"
                phx-value-id={condition.id}
                class="btn btn-ghost btn-sm"
              >Acknowledge</button>
            </li>
          </ul>
        </section>

        <section id="strategy-context" class="grid gap-4 lg:grid-cols-3">
          <article class="rounded-2xl border border-base-300 bg-base-100 p-5">
            <p class="eyebrow">Fleet Strategy Revision</p>
            <p :if={@projection.strategy.active_revision} class="mt-2 text-2xl font-bold">
              Revision {@projection.strategy.active_revision.number}
            </p>
            <p :if={!@projection.strategy.active_revision} class="mt-2 font-semibold">
              No active revision
            </p>
            <.link navigate={~p"/strategy"} class="link link-primary mt-3 inline-block text-sm">Review Strategy</.link>
          </article>
          <article class="rounded-2xl border border-base-300 bg-base-100 p-5">
            <p class="eyebrow">Fleet Generation</p>
            <p :if={current_generation(@projection)} class="mt-2 text-2xl font-bold">
              Generation {current_generation(@projection).number}
            </p>
            <p :if={!current_generation(@projection)} class="mt-2 font-semibold">
              No current Fleet Generation
            </p>
            <p :if={current_generation(@projection)} class="mt-1 text-sm opacity-70">
              {current_generation(@projection).symbol}
            </p>
          </article>
          <article class="rounded-2xl border border-base-300 bg-base-100 p-5">
            <p class="eyebrow">Strategy-capable state</p>
            <p class="mt-2 font-semibold">
              {strategy_capable_label(current_generation(@projection))}
            </p>
            <p class="mt-1 text-sm opacity-70">
              {strategy_capable_detail(current_generation(@projection))}
            </p>
          </article>
        </section>

        <section
          :if={@projection.market_execution.expected}
          id="market-execution"
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="eyebrow">Market execution</p><h2 class="text-xl font-bold">
                Adaptive market trading
              </h2>
            </div><span class="badge">
              {market_execution_state(@projection.market_execution)}
            </span>
          </div>
          <div class="mt-4 grid gap-4 sm:grid-cols-3">
            <div>
              <p class="text-sm opacity-70">Expected credit change</p>
              <p class="mt-1 font-semibold">
                {expected_label(@projection.market_execution.expected)}
              </p>
            </div>
            <div>
              <p class="text-sm opacity-70">Realized net credit change</p>
              <p class="mt-1 font-semibold">
                {realized_label(@projection.market_execution.realized.realized_net_credit_change)}
              </p>
            </div>
            <div>
              <p class="text-sm opacity-70">Fleet contribution</p>
              <p class="mt-1 font-semibold">
                {contribution_label(@projection.market_execution.contribution)}
              </p>
            </div>
          </div>
          <div
            :if={@projection.market_execution.limitation}
            class="mt-4 rounded-xl bg-warning/10 p-4 text-sm"
          >
            {limitation_label(@projection.market_execution.limitation)}
          </div>
        </section>

        <section id="objective-evaluations" class="space-y-3">
          <div>
            <p class="eyebrow">Outcome Observability</p><h2 class="text-2xl font-bold">
              Objective evaluations
            </h2>
          </div>
          <p
            :if={@projection.objectives == []}
            class="rounded-2xl border border-dashed border-base-300 p-5 text-sm opacity-70"
          >
            No Strategic Objectives are active yet.
          </p>
          <article
            :for={objective <- @projection.objectives}
            class="rounded-2xl border border-base-300 bg-base-100 p-5"
          >
            <h3 class="font-bold">{objective.priority}. {objective.objective["objective"]}</h3>
            <p class="mt-1 text-sm opacity-70">{objective.objective["evaluation"]}</p>
            <p class="mt-4 text-sm">{evaluation_label(objective.evaluation)}</p>
          </article>
        </section>

        <section id="fleet-health" class="grid gap-4 lg:grid-cols-2">
          <article
            :for={fleet <- @projection.fleets}
            class="rounded-2xl border border-base-300 bg-base-100 p-5"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="eyebrow">Agent / Fleet contribution</p><h2 class="text-xl font-bold">
                  {fleet.agent.symbol}
                </h2>
              </div><span class="badge">{fleet_status(fleet)}</span>
            </div>
            <p class="mt-3 text-sm">{fleet_contribution(fleet)}</p>
          </article>
        </section>

        <section id="notable-activity" class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <div class="flex items-center justify-between gap-3">
            <h2 class="text-xl font-bold">Notable activity</h2>
            <.link navigate={~p"/activity"} class="link link-primary text-sm">All Activity</.link>
          </div>
          <p :if={@projection.notable_activity == []} class="mt-2 text-sm opacity-70">
            No consequential events recorded yet.
          </p>
          <ul class="mt-3 space-y-2 text-sm">
            <li :for={entry <- @projection.notable_activity}>
              <span class="font-semibold">{entry.type |> Atom.to_string() |> String.capitalize()}</span>
              · {entry.summary}
            </li>
          </ul>
          <.link navigate={~p"/generations"} class="link link-primary mt-4 inline-block text-sm">Compare Fleet Generations</.link>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("acknowledge", %{"id" => raw_id}, socket) do
    with {id, ""} <- Integer.parse(raw_id),
         :ok <- MissionControl.acknowledge_condition(socket.assigns.current_scope, id) do
      {:noreply, assign_projection(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:fleet_strategy_updated, operator_id}, socket)
      when operator_id == socket.assigns.current_scope.operator.id,
      do: {:noreply, assign_projection(socket)}

  def handle_info(:mission_conditions_updated, socket),
    do: {:noreply, assign_projection(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_projection(socket),
    do: assign(socket, :projection, MissionControl.overview(socket.assigns.current_scope))

  defp current_generation(projection),
    do: Enum.find(projection.generations, &is_nil(&1.retired_at))

  defp health_label(%{strategy: %{emergency_stopped_at: %DateTime{}}}), do: "STOPPED"
  defp health_label(%{strategy: %{active_revision: nil}}), do: "Awaiting Fleet Strategy"
  defp health_label(%{conditions: [_ | _]}), do: "Needs Operator attention"

  defp health_label(projection) do
    case current_generation(projection) do
      nil ->
        "Awaiting Fleet Generation"

      %{fenced_at: %DateTime{}} ->
        "Server Reset transition"

      %{strategy_capable_at: nil} ->
        "Establishing Fleet state"

      _ ->
        if Enum.any?(projection.fleets, &unknown_fleet?/1),
          do: "Fleet health unknown",
          else: "Operating normally"
    end
  end

  defp health_detail(%{strategy: %{emergency_stopped_at: %DateTime{}}}),
    do: "Emergency Stop suppresses every new gameplay mutation. Review Strategy to resume safely."

  defp health_detail(%{conditions: [_ | _]}),
    do: "Unresolved conditions remain pinned below, including acknowledged ones."

  defp health_detail(%{fleets: fleets}) do
    if Enum.any?(fleets, &unknown_fleet?/1),
      do: "Authoritative Agent or Ship state is unavailable; this is not a zero measurement.",
      else: "Review objective outcomes, Fleet contribution and recent decisions below."
  end

  defp unknown_fleet?(%{overview: {:error, _}}), do: true
  defp unknown_fleet?(%{ships: {:error, _}}), do: true
  defp unknown_fleet?(_), do: false

  defp strategy_capable_label(%{strategy_capable_at: %DateTime{}}), do: "Strategy-capable"
  defp strategy_capable_label(_), do: "Not Strategy-capable"

  defp strategy_capable_detail(%{strategy_capable_at: %DateTime{} = at}),
    do: "Available since #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}."

  defp strategy_capable_detail(nil),
    do: "Activate a Fleet Strategy and establish a Fleet Generation."

  defp strategy_capable_detail(_),
    do: "This Fleet Generation is still establishing authoritative state."

  defp onboarding_message(%{strategy: %{active_revision: nil}}),
    do:
      "Choose and explicitly activate a Fleet Strategy Revision before autonomous progress begins."

  defp onboarding_message(_), do: "Mint an Agent to establish the current Fleet Generation."
  defp fleet_status(%{stale?: true}), do: "Stale Agent"
  defp fleet_status(%{control: %{healthy?: true}}), do: "Healthy"
  defp fleet_status(_), do: "Limited"

  defp fleet_contribution(%{ships: {:ok, ships}}),
    do: "#{length(ships)} Ships contributing to this Fleet Generation."

  defp fleet_contribution(%{ships: {:error, _}}),
    do: "Fleet contribution is unknown while authoritative Ship state is unavailable."

  defp evaluation_label({:ok, %{kind: :attain, progress: progress, feasible?: true}}),
    do: "Measured progress: #{Float.round(progress * 100, 1)}%."

  defp evaluation_label({:ok, %{kind: :maintain, margin: margin, feasible?: true}}),
    do: "Measured margin: #{margin}."

  defp evaluation_label({:ok, %{kind: :continuous, rate: rate, feasible?: true}}),
    do: "Measured outcome rate: #{Float.round(rate, 2)} per horizon."

  defp evaluation_label({:ok, %{feasible?: false}}),
    do:
      "Limitation: current evidence shows this objective is not feasible. Attention is required."

  defp evaluation_label(_), do: "Unknown: no complete, authoritative evaluation is available yet."

  defp market_execution_state(%{realized: %{completed_round_trips: 0}}), do: "Active"
  defp market_execution_state(_execution), do: "Realized"

  defp expected_label(%{expected_value: value}),
    do: "Expected net credit change #{value}."

  defp contribution_label(%{commitment_count: count}),
    do: "#{count} Market commitment(s) contributing."

  defp realized_label(nil), do: "Unknown — no completed round trip evidence"
  defp realized_label(amount), do: "#{amount} credits"

  defp limitation_label(limitation), do: limitation
end
