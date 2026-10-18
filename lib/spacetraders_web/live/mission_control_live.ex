defmodule SpaceTradersWeb.MissionControlLive do
  @moduledoc "Authenticated, concise read projection for Fleet Strategy outcomes."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{FleetGeneration, MissionControl}
  alias SpaceTraders.MissionControl.Channels
  alias SpaceTradersWeb.GrafanaLink

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Channels.subscribe_strategy()
      Channels.subscribe_allocation()
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
              Strategy intent and Fleet health.
            </:subtitle>
          </.header>
        </header>

        <section
          :if={
            @projection.current_fleet.state != :unresolved &&
              (!@projection.strategy.active_revision || @projection.current_fleet.state == :empty)
          }
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
            <.link
              :if={@projection.current_fleet.state == :empty && !registration_pending?(@projection)}
              navigate={~p"/agents/new"}
              class="btn btn-outline"
            >Mint an Agent</.link>
            <.link
              :if={@projection.current_fleet.state == :empty && !registration_pending?(@projection)}
              navigate={~p"/operators/settings#import-agent"}
              class="btn btn-ghost"
            >Import an existing Agent</.link>
          </div>
        </section>

        <section
          :if={@projection.current_fleet.state in [:empty, :transition, :unresolved]}
          id="current-fleet-state"
          class="rounded-2xl border border-warning/30 bg-warning/5 p-5"
        >
          <h2 class="text-xl font-bold">Current Fleet</h2>
          <p :if={@projection.current_fleet.state == :empty && !registration_pending?(@projection)}>
            No current Agent. Mint or import an Agent to establish the Fleet.
          </p>
          <div
            :if={@projection.current_fleet.state == :transition}
            id="server-reset-replacement"
            class="space-y-3"
          >
            <p>
              A Server Reset fenced {transition_symbol(@projection)}; its gameplay cannot resume.
              Replacement requests {transition_symbol(@projection)} first, then the remaining
              Agent Name Bank names in order, as a fresh Fleet Generation under the accepted Fleet Strategy.
            </p>
            <button
              :if={!registration_pending?(@projection)}
              id="retry-reset-replacement"
              phx-click="retry_replacement"
              phx-disable-with="Replacing..."
              class="btn btn-primary btn-sm"
            >
              Retry replacement
            </button>
          </div>
          <p :if={@projection.current_fleet.state == :unresolved}>
            {@projection.current_fleet.summary}
          </p>
          <.link navigate={~p"/operators/settings"} class="link link-primary">Review Settings</.link>
        </section>

        <section
          :if={registration_pending?(@projection)}
          id="mission-registration-recovery"
          class="rounded-2xl border border-warning/30 bg-warning/5 p-5"
        >
          <h2 class="text-xl font-bold">Registration recovery</h2>
          <p>{@projection.registration_recovery.summary}</p>
          <.link navigate={~p"/agents/new"} class="link link-primary">Reconcile registration</.link>
        </section>

        <section id="operating-health" class="rounded-2xl border border-base-300 bg-base-100 p-5">
          <p class="eyebrow">Operating health</p>
          <h2 class="mt-2 text-2xl font-bold">{health_label(@projection)}</h2>
          <p class="mt-1 text-sm opacity-70">{health_detail(@projection)}</p>
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
            <p
              :if={reset_predecessor(@projection)}
              id="generation-replacement"
              class="mt-1 text-sm opacity-70"
            >
              Replaced Generation {reset_predecessor(@projection).number} ({reset_predecessor(
                @projection
              ).symbol}) after a Server Reset.
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
            <p class="mt-2 font-semibold">
              Objective status: {objective_status(objective.evaluation)}
            </p>
            <p class="mt-1 text-sm opacity-70">{objective.objective["evaluation"]}</p>
            <p class="mt-4 text-sm">{evaluation_label(objective.evaluation)}</p>
            <a
              :if={objective_grafana_url(@projection)}
              href={objective_grafana_url(@projection)}
              target="_blank"
              rel="noreferrer"
              class="link link-primary mt-3 inline-block text-sm"
            >Inspect Strategy outcomes</a>
          </article>
        </section>

        <section
          :if={@projection.market_execution.expected}
          id="market-execution"
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="eyebrow">Fleet contribution</p><h2 class="text-xl font-bold">
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
            <div id="realized-trade-margin">
              <p class="text-sm opacity-70">Realized trade margin</p>
              <p class="mt-1 font-semibold">
                {realized_label(@projection.market_execution.realized.realized_trade_margin)}
              </p>
            </div>
            <div id="realized-net-earnings">
              <p class="text-sm opacity-70">Net earnings (after the trade's own fuel)</p>
              <p class="mt-1 font-semibold">
                {net_earnings_label(@projection.market_execution.realized)}
              </p>
            </div>
            <div>
              <p class="text-sm opacity-70">Current work</p>
              <p class="mt-1 font-semibold">
                {contribution_label(@projection.market_execution.contribution, :market)}
              </p>
            </div>
          </div>
          <div
            :if={@projection.market_execution.limitation}
            class="mt-4 rounded-xl bg-warning/10 p-4 text-sm"
          >
            LIMITING · {limitation_label(@projection.market_execution.limitation)}
          </div>
        </section>

        <section
          :for={disposition <- @projection.market_execution.dispositions}
          id={"allocation-disposition-#{disposition.agent_symbol}"}
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="eyebrow">Allocation disposition · {disposition.agent_symbol}</p>
              <h2 class="text-xl font-bold">{disposition_label(disposition)}</h2>
            </div>
            <span class={["badge", !disposition.healthy? && "badge-warning"]}>
              {if disposition.healthy?, do: "Healthy", else: "Degraded Operation"}
            </span>
          </div>
          <p :if={disposition.state != :neutral_wait} class="mt-2 text-sm">
            Active Revision {disposition.active_revision.number}
            <span :if={disposition.portfolio}>
              · Portfolio {disposition.portfolio.id} ·
              <.link
                :if={disposition.portfolio.decision_episode_id}
                navigate={~p"/decision-episodes/#{disposition.portfolio.decision_episode_id}"}
                class="link link-primary"
              >Decision Episode {disposition.portfolio.decision_episode_id}</.link>
            </span>
          </p>
          <div :if={disposition.stall} class="mt-3 rounded-xl bg-warning/10 p-4 text-sm">
            <p class="font-semibold">STALLED · {stall_reason_label(disposition.stall.reason)}</p>
            <p :if={disposition.stall.portfolio_revision_number}>
              Portfolio {disposition.stall.portfolio_id} belongs to superseded Revision {disposition.stall.portfolio_revision_number}.
            </p>
            <p :if={disposition.stall.intent_ids != []}>
              Blocked Intents: {Enum.join(disposition.stall.intent_ids, ", ")}
            </p>
            <p :if={disposition.stall.commitment_ids != []}>
              Commitments: {Enum.join(disposition.stall.commitment_ids, ", ")}
            </p>
            <p :if={disposition.stall.stall_episode_id}>
              Recorded as
              <.link
                navigate={~p"/decision-episodes/#{disposition.stall.stall_episode_id}"}
                class="link link-primary"
              >Decision Episode {disposition.stall.stall_episode_id}</.link>
              ({disposition.stall.observation_count} observations).
            </p>
            <p>Releases when: {disposition.stall.release}</p>
            <p class="opacity-70">No Operator action is needed; this clears by reconciliation.</p>
          </div>
          <div :if={disposition.spending_pause} class="mt-3 rounded-xl bg-info/10 p-4 text-sm">
            <p class="font-semibold">SHORTFALL · spending paused, not a Neutral Wait</p>
            <p>
              Balance {balance_label(disposition.spending_pause.balance)} · credit floor {disposition.spending_pause.floor}
            </p>
            <p>Releases when: {disposition.spending_pause.release}</p>
          </div>
          <div :if={disposition.capacity_deferral} class="mt-3 rounded-xl bg-info/10 p-4 text-sm">
            <p class="font-semibold">CAPACITY DEFERRAL · API pressure, not an objective verdict</p>
            <p :if={disposition.capacity_deferral.retry_at}>
              Reconsidered after {utc_label(disposition.capacity_deferral.retry_at)}.
            </p>
          </div>
          <%!-- ADR 0012: exactly five summary facts; identity is click-through only. --%>
          <div
            :if={disposition.state == :neutral_wait}
            id={"neutral-wait-#{disposition.agent_symbol}"}
            class="mt-3 rounded-xl bg-info/10 p-4 text-sm"
          >
            <p class="font-semibold">
              <.link
                navigate={~p"/decision-episodes/#{disposition.neutral_wait.decision_episode_id}"}
                class="link"
              >no worthwhile admissible contribution</.link>
            </p>
            <p>{limitation_kind_label(disposition.neutral_wait.limitation_kind)}</p>
            <p :if={disposition.neutral_wait.limitation_kind == :incomplete_coverage}>
              {coverage_label(disposition.neutral_wait.coverage)}
            </p>
            <p>Last evaluated {utc_label(disposition.neutral_wait.last_evaluated_at)}</p>
            <p>Next due {utc_label(disposition.neutral_wait.next_observation_at)}</p>
          </div>
          <p
            :if={
              disposition.overdue_demand_count > 0 and disposition.healthy? and
                disposition.state != :neutral_wait
            }
            class="mt-3 text-sm opacity-70"
          >
            {disposition.overdue_demand_count} Market Observation Demand(s) overdue; explained by the state above.
          </p>
          <p
            :if={disposition.unallocated_ships != []}
            id={"unallocated-ships-#{disposition.agent_symbol}"}
            class="mt-3 text-sm"
          >
            Unallocated Ships:
            <.link
              :for={symbol <- disposition.unallocated_ships}
              navigate={unallocated_ship_path(disposition, symbol)}
              class="link link-primary mr-2"
            >{symbol}</.link>
          </p>
        </section>

        <section
          :if={@projection.market_execution.family in [:resources, :other]}
          id="other-contributions"
          class="rounded-2xl border border-base-300 bg-base-100 p-5"
        >
          <h2 class="text-xl font-bold">Fleet contribution</h2>
          <p class="mt-2">
            {contribution_label(
              @projection.market_execution.contribution,
              @projection.market_execution.family
            )} pursuing a non-trading outcome.
          </p>
          <p class="mt-1 text-sm opacity-70">Expected credit change is unknown for this work.</p>
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
  def handle_event("retry_replacement", _params, socket) do
    socket =
      case FleetGeneration.replace_after_reset(socket.assigns.current_scope) do
        {:ok, %{agent: agent}} ->
          put_flash(socket, :info, "Replaced after the Server Reset: #{agent.symbol} is current.")

        {:error, reason} ->
          put_flash(socket, :error, replacement_error(reason))
      end

    {:noreply, assign_projection(socket)}
  end

  @impl true
  def handle_info(:fleet_strategy_updated, socket),
    do: {:noreply, assign_projection(socket)}

  def handle_info({:outbox, _id, _event, _payload}, socket),
    do: {:noreply, assign_projection(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp assign_projection(socket) do
    assign(socket, :projection, MissionControl.overview(socket.assigns.current_scope))
  end

  defp current_generation(projection),
    do: projection.current_fleet[:generation]

  defp transition_symbol(projection) do
    case current_generation(projection) do
      %{symbol: symbol} -> symbol
      _ -> "the predecessor Agent"
    end
  end

  # The fenced Generation the current one replaced. Only Server Reset evidence
  # fences a Generation before its replacement.
  defp reset_predecessor(%{current_fleet: %{state: :current}} = projection) do
    with %{number: number} <- current_generation(projection) do
      Enum.find(projection.generations, fn generation ->
        generation.number == number - 1 and not is_nil(generation.fenced_at) and
          not is_nil(generation.retired_at)
      end)
    end
  end

  defp reset_predecessor(_projection), do: nil

  defp replacement_error(:account_token_not_linked),
    do: "Link an AccountToken in Settings before replacement can mint."

  defp replacement_error(:replacement_symbols_exhausted),
    do: "Every replacement name was definitively taken. Edit the Agent Name Bank in Settings."

  defp replacement_error(:registration_unresolved),
    do: "The last registration outcome is unknown. Reconcile it before another registration."

  defp replacement_error(:no_server_reset),
    do: "No Server Reset replacement is pending."

  defp replacement_error(:runtime_authority_unavailable),
    do: "Replacement is temporarily unavailable. Please try again shortly."

  defp replacement_error(_reason),
    do: "Replacement did not complete. The predecessor stays fenced; its state is shown below."

  defp health_label(%{registration_recovery: %{status: :in_progress}}),
    do: "Registration in progress"

  defp health_label(%{registration_recovery: %{status: status}})
       when status in [:unresolved, :awaiting_adoption],
       do: "Registration recovery needed"

  defp health_label(%{current_fleet: %{state: :unresolved}}), do: "Current Fleet needs resolution"
  defp health_label(%{current_fleet: %{state: :transition}}), do: "Server Reset transition"
  defp health_label(%{strategy: %{active_revision: nil}}), do: "Awaiting Fleet Strategy"

  defp health_label(projection) do
    case current_generation(projection) do
      nil ->
        "Awaiting Fleet Generation"

      %{fenced_at: %DateTime{}} ->
        "Server Reset transition"

      %{strategy_capable_at: nil} ->
        "Establishing Fleet state"

      _ ->
        cond do
          Enum.any?(projection.fleets, &unknown_fleet?/1) ->
            "Fleet health unknown"

          stalled?(projection) ->
            "Fleet allocation stalled"

          Enum.any?(projection.objectives, &match?({:error, _}, &1.evaluation)) ->
            "Outcome status unknown"

          Enum.any?(
            projection.objectives,
            &(objective_status(&1.evaluation) in [
                "Falling behind",
                "Infeasible",
                "Below protected margin"
              ])
          ) ->
            "Objectives limited"

          Enum.any?(projection.fleets, &(not &1.control.healthy?)) ->
            "Fleet capacity limited"

          true ->
            "Operating normally"
        end
    end
  end

  defp health_detail(%{registration_recovery: %{status: status, summary: summary}})
       when status != :clear,
       do: summary

  defp health_detail(%{current_fleet: %{state: :transition}} = projection),
    do:
      "A Server Reset fenced #{transition_symbol(projection)}. Nothing it reported is counted as the current Fleet until a replacement Generation is established."

  defp health_detail(%{market_execution: %{dispositions: dispositions}} = projection)
       when is_list(dispositions) do
    if stalled?(projection),
      do: "Degraded Operation: see the allocation disposition below for the cause and release.",
      else: health_detail_fleets(projection)
  end

  defp health_detail(projection), do: health_detail_fleets(projection)

  defp stalled?(%{market_execution: %{dispositions: dispositions}}),
    do: Enum.any?(dispositions, &(not &1.healthy?))

  defp health_detail_fleets(%{fleets: fleets}) do
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

  defp registration_pending?(%{registration_recovery: %{status: status}}), do: status != :clear

  defp onboarding_message(%{registration_recovery: %{status: status}}) when status != :clear,
    do:
      "Registration must be reconciled before establishing another Agent. Fleet Strategy can still be reviewed."

  defp onboarding_message(%{strategy: %{active_revision: nil}}),
    do:
      "Choose and explicitly activate a Fleet Strategy Revision before autonomous progress begins."

  defp onboarding_message(_), do: "Mint an Agent to establish the current Fleet Generation."
  defp fleet_status(%{stale?: true}), do: "Stale Agent"
  defp fleet_status(%{control: %{healthy?: true}}), do: "Healthy"
  defp fleet_status(_), do: "Limited"

  defp fleet_contribution(%{ships: {:ok, ships}}),
    do:
      "#{length(ships)} Ships in this Fleet Generation; current commitments are summarized above."

  defp fleet_contribution(%{ships: {:error, _}}),
    do: "Fleet contribution is unknown while authoritative Ship state is unavailable."

  defp evaluation_label({:ok, %{kind: :attain, progress: progress, feasible?: true}}),
    do: "Measured progress: #{Float.round(progress * 100, 1)}%."

  defp evaluation_label({:ok, %{kind: :maintain, margin: margin, feasible?: true}}),
    do: "Measured margin: #{margin}."

  defp evaluation_label({:ok, %{kind: :continuous, rate: rate, feasible?: true}}),
    do: "Measured outcome rate: #{Float.round(rate, 2)} per horizon."

  defp evaluation_label({:ok, %{feasible?: false}}),
    do: "Limitation: current evidence shows this objective is not feasible."

  defp evaluation_label({:observed, %{change: change, rate: rate}}),
    do:
      "Observed net change: #{if change > 0, do: "+", else: ""}#{change} credits since Generation began (#{Float.round(rate, 2)} credits/hour over that interval). Feasibility is unknown."

  defp evaluation_label(_), do: "Unknown: no complete, authoritative evaluation is available yet."

  defp objective_status({:ok, %{feasible?: false}}), do: "Infeasible"
  defp objective_status({:ok, %{kind: :attain, attained?: true}}), do: "Attained"

  defp objective_status({:ok, %{kind: :attain, progress: progress}}) when progress > 0,
    do: "Progressing"

  defp objective_status({:ok, %{kind: :attain}}), do: "Not yet progressing"
  defp objective_status({:ok, %{kind: :maintain, protected?: true}}), do: "Holding"
  defp objective_status({:ok, %{kind: :maintain}}), do: "Below protected margin"
  defp objective_status({:ok, %{kind: :continuous, rate: rate}}) when rate > 0, do: "Growing"

  defp objective_status({:ok, %{kind: :continuous, rate: rate}}) when rate < 0,
    do: "Falling behind"

  defp objective_status({:ok, %{kind: :continuous}}), do: "Holding steady"
  defp objective_status({:observed, %{change: change}}) when change > 0, do: "Growing"
  defp objective_status({:observed, %{change: change}}) when change < 0, do: "Falling behind"
  defp objective_status({:observed, _}), do: "Holding steady"
  defp objective_status(_), do: "Unknown"

  defp market_execution_state(%{dispositions: dispositions} = execution) do
    cond do
      Enum.any?(dispositions, &(not &1.healthy?)) -> "Stalled"
      execution.realized.completed_round_trips == 0 -> "Active"
      true -> "Realized"
    end
  end

  defp disposition_label(%{state: :stalled}), do: "Structural stall"
  defp disposition_label(%{state: :spending_paused}), do: "Shortfall at the credit floor"
  defp disposition_label(%{state: :capacity_deferred}), do: "Capacity deferred"
  defp disposition_label(%{state: :neutral_wait}), do: "Neutral Wait"
  defp disposition_label(%{state: :busy_trade}), do: "Trading under the active Revision"

  defp disposition_label(%{state: :retained_coverage}),
    do: "Market coverage under the active Revision"

  defp disposition_label(%{state: :unallocated}), do: "No allocated work"

  defp stall_reason_label(:stale_revision_portfolio),
    do: "Portfolio belongs to a superseded Revision"

  defp stall_reason_label(:authority_blocked_intent),
    do: "Retained Intent is blocked on authority"

  defp stall_reason_label(:overdue_demands_without_coverage),
    do: "Overdue Market Demands with no coverage and no decisive reason"

  # During a Neutral Wait an Unallocated Ship links to the wait's cause.
  defp unallocated_ship_path(%{state: :neutral_wait, neutral_wait: wait}, _symbol),
    do: ~p"/decision-episodes/#{wait.decision_episode_id}"

  defp unallocated_ship_path(_disposition, symbol), do: ~p"/ships/#{symbol}"

  defp limitation_kind_label(kind), do: kind |> to_string() |> String.replace("_", " ")

  defp coverage_label(%{completed: completed, required: required}),
    do: "#{completed} of #{required} Marketplaces covered"

  defp coverage_label(_unknown), do: "Coverage unknown"

  defp utc_label(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M:%S UTC")
  defp utc_label(_unknown), do: "unknown"

  defp balance_label(nil), do: "unknown (no fresh authoritative balance)"
  defp balance_label(credits), do: "#{credits} credits"

  defp expected_label(%{expected_value: value}),
    do: "Expected net credit change #{value}."

  defp contribution_label(%{commitment_count: count}, :market),
    do: "#{count} trading commitment(s) contributing"

  defp contribution_label(%{commitment_count: count}, :resources),
    do: "#{count} resource acquisition commitment(s)"

  defp contribution_label(%{commitment_count: count}, _),
    do: "#{count} Fleet commitment(s)"

  defp realized_label(nil), do: "Unknown — no completed round trip evidence"
  defp realized_label(amount), do: "#{amount} credits"

  defp net_earnings_label(%{net_earnings: amount}) when is_integer(amount),
    do: "#{amount} credits"

  defp net_earnings_label(_realized), do: "Unknown — no completed round trip evidence"

  defp limitation_label(limitation), do: limitation

  defp objective_grafana_url(%{
         strategy: %{active_revision: revision},
         generations: generations
       }) do
    case Enum.find(
           generations,
           &(&1.fleet_strategy_revision_id == revision.id and is_nil(&1.fenced_at) and
               is_nil(&1.retired_at))
         ) do
      nil ->
        nil

      generation ->
        GrafanaLink.url(:strategy_outcomes,
          fleet_generation: generation.id,
          strategy_revision: revision.id,
          from: DateTime.add(generation.inserted_at, -300),
          to: :now
        )
    end
  end

  defp objective_grafana_url(_projection), do: nil
end
