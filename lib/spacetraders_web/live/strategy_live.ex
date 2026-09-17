defmodule SpaceTradersWeb.StrategyLive do
  @moduledoc "Authenticated review and activation workflow for Fleet Strategy revisions."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{FleetStrategy, MissionControl}

  @impl true
  def mount(_params, _session, socket) do
    operator_id = socket.assigns.current_scope.operator.id

    if connected?(socket) do
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_strategy:#{operator_id}")
    end

    {:ok, assign_projection(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="space-y-8">
        <header class="max-w-3xl space-y-2">
          <p class="eyebrow">Standing intent</p>
          <.header>
            Fleet Strategy
            <:subtitle>
              Review every outcome and boundary before granting Standing Authority. Presets and recommendations create drafts only.
            </:subtitle>
          </.header>
        </header>

        <section
          id="emergency-stop-control"
          class={[
            "rounded-2xl border p-5 sm:p-7",
            @projection.emergency_stopped_at && "border-error/40 bg-error/10",
            !@projection.emergency_stopped_at && "border-base-300 bg-base-100"
          ]}
        >
          <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <p class="eyebrow">Fleet-wide safety</p>
              <h2 class="text-xl font-bold">Emergency Stop</h2>
              <p
                :if={
                  @projection.emergency_stopped_at &&
                    !@projection.emergency_resume_prepared_at
                }
                class="mt-1 text-sm"
              >
                Gameplay mutations are suppressed. Reconciliation, safety observations, telemetry, and history continue.
              </p>
              <p :if={@projection.emergency_resume_prepared_at} class="mt-1 text-sm">
                Authoritative state is refreshed and stale work is retired. Mutations remain suppressed until fresh Fleet Allocation selects an admissible plan.
              </p>
              <p :if={!@projection.emergency_stopped_at} class="mt-1 text-sm opacity-70">
                Immediately suppress every new gameplay mutation, including replacement minting.
              </p>
            </div>
            <button
              :if={!@projection.emergency_stopped_at}
              id="engage-emergency-stop"
              phx-click="engage_emergency_stop"
              class="btn btn-error"
            >
              Engage Emergency Stop
            </button>
            <button
              :if={
                @projection.emergency_stopped_at &&
                  !@projection.emergency_resume_prepared_at
              }
              id="resume-from-emergency-stop"
              phx-click="resume_from_emergency_stop"
              class="btn btn-outline"
            >
              Resume from authoritative state
            </button>
          </div>
        </section>

        <section
          :if={@projection.active_revision}
          class="rounded-2xl border border-success/30 bg-success/5 p-5 sm:p-7"
        >
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div>
              <p class="eyebrow">Standing Authority</p>
              <h2 class="text-2xl font-bold">Active revision {@projection.active_revision.number}</h2>
            </div>
            <span class="badge badge-success">Immutable</span>
          </div>
          <.strategy_document document={@projection.active_revision.document} />
        </section>

        <section
          :if={!@projection.active_revision}
          class="rounded-2xl border border-dashed border-base-300 p-5 sm:p-7"
        >
          <p class="font-semibold">No active Fleet Strategy Revision</p>
          <p class="mt-1 text-sm opacity-70">
            Nothing below becomes standing intent until you explicitly activate a draft.
          </p>
        </section>

        <section
          :if={@projection.active_revision && @market_planning != []}
          id="market-candidate-contributions"
          class="space-y-4"
        >
          <div>
            <p class="eyebrow">Evidence-bound planning</p>
            <h2 class="text-2xl font-bold">Market Candidate Contributions</h2>
            <p class="mt-1 max-w-3xl text-sm opacity-70">
              Proposals describe possible contributions only. No Ship, credits, or Cargo are claimed until Fleet Allocation accepts a portfolio.
            </p>
          </div>

          <article
            :for={entry <- @market_planning}
            id={"market-planning-#{entry.agent.id}-#{entry.objective_index}"}
            class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
          >
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div>
                <p class="font-bold">{entry.objective["objective"]}</p>
                <p class="text-sm opacity-70">{entry.agent.symbol}</p>
              </div>
              <span class="badge badge-ghost">Candidate only</span>
            </div>

            <div
              :if={entry.planning.candidate_contributions != []}
              class="mt-4 grid gap-3 lg:grid-cols-2"
            >
              <div
                :for={candidate <- entry.planning.candidate_contributions}
                id={"candidate-contribution-#{candidate.id}"}
                class="rounded-xl border border-base-300 p-4"
              >
                <p class="font-semibold">
                  {candidate.trade_symbol}: {candidate.source_waypoint} to {candidate.destination_waypoint}
                </p>
                <p class="mt-1 text-sm">
                  Up to {candidate.expected_outcomes.maximum_credit_change} credits across {candidate.expected_outcomes.maximum_units} Cargo units
                </p>
                <dl class="mt-3 grid gap-3 text-xs sm:grid-cols-2">
                  <div>
                    <dt class="font-semibold">Uncertainty</dt>
                    <dd class="opacity-70">
                      Evidence age: {candidate.uncertainty.source_evidence_age_seconds}s / {candidate.uncertainty.destination_evidence_age_seconds}s. Fuel and travel time are not yet accounted for. Source supply {candidate.uncertainty.source_market_signal.supply ||
                        "unknown"}; destination supply {candidate.uncertainty.destination_market_signal.supply ||
                        "unknown"}.
                    </dd>
                  </div>
                  <div>
                    <dt class="font-semibold">Required role and capabilities</dt>
                    <dd class="opacity-70">
                      One Market trader; Cargo transport for {candidate.required_resources.cargo_capacity} units and Market access at both Waypoints.
                    </dd>
                  </div>
                  <div>
                    <dt class="font-semibold">Required resources</dt>
                    <dd class="opacity-70">
                      {candidate.required_resources.credits} credits of exposure, {candidate.required_resources.cargo_capacity} Cargo capacity, and {candidate.required_resources.ship_count} unassigned Ship.
                    </dd>
                  </div>
                  <div>
                    <dt class="font-semibold">Validity</dt>
                    <dd class="opacity-70">
                      Through {Calendar.strftime(
                        candidate.validity.expires_at,
                        "%Y-%m-%d %H:%M:%S UTC"
                      )}; source price {candidate.validity.conditions
                      |> Enum.at(0)
                      |> Map.fetch!(:value)}, destination price {candidate.validity.conditions
                      |> Enum.at(1)
                      |> Map.fetch!(:value)}, positive spread required.
                    </dd>
                  </div>
                  <div class="sm:col-span-2">
                    <dt class="font-semibold">Evidence dependencies</dt>
                    <dd class="opacity-70">
                      {Enum.map_join(candidate.dependencies, "; ", fn dependency ->
                        "#{dependency.subject} via #{dependency.source} at #{DateTime.to_iso8601(dependency.observed_at)}"
                      end)}
                    </dd>
                  </div>
                  <div class="sm:col-span-2">
                    <dt class="font-semibold">Alternatives</dt>
                    <dd class="opacity-70">
                      {if candidate.alternatives == [],
                        do: "No other positive-spread route in this snapshot.",
                        else:
                          Enum.map_join(candidate.alternatives, "; ", fn alternative ->
                            "#{alternative.trade_symbol}: #{alternative.source_waypoint} to #{alternative.destination_waypoint}"
                          end)}
                    </dd>
                  </div>
                </dl>
              </div>
            </div>

            <div
              :if={entry.planning.candidate_contributions == []}
              class="mt-4 rounded-xl border border-dashed border-base-300 p-4 text-sm"
            >
              <p class="font-semibold">No Market contribution is currently supported.</p>
            </div>

            <div
              :if={entry.planning.limitations != []}
              class="mt-4 rounded-xl border border-dashed border-base-300 p-4 text-sm"
            >
              <p class="font-semibold">Current limitations</p>
              <ul class="mt-2 list-inside list-disc opacity-70">
                <li :for={limitation <- entry.planning.limitations}>
                  {planning_limitation(limitation.reason)}
                </li>
              </ul>
            </div>

            <div :if={entry.planning.observation_demands != []} class="mt-4 text-sm">
              <p class="font-semibold">Observation Demands</p>
              <ul class="mt-2 list-inside list-disc opacity-70">
                <li :for={demand <- entry.planning.observation_demands}>
                  {demand.subject}: {Enum.join(demand.required_facts, ", ")} within {demand.freshness_seconds}s freshness
                </li>
              </ul>
            </div>
          </article>
        </section>

        <section class="space-y-4">
          <div>
            <p class="eyebrow">Starting points</p>
            <h2 class="text-2xl font-bold">Disclosed presets</h2>
          </div>
          <div class="grid gap-4 lg:grid-cols-2">
            <article
              :for={preset <- @projection.presets}
              id={"preset-#{preset.id}"}
              class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
            >
              <h3 class="text-xl font-bold">{preset.name}</h3>
              <p class="mt-1 text-sm opacity-70">{preset.summary}</p>
              <.disclosed_choices preset={preset} />
              <button
                id={"select-preset-#{preset.id}"}
                phx-click="select_preset"
                phx-value-id={preset.id}
                disabled={not is_nil(@projection.draft)}
                class="btn btn-outline mt-5 w-full"
              >
                Review as draft
              </button>
            </article>
          </div>
        </section>

        <section class="rounded-2xl border border-primary/25 bg-base-100 p-5 shadow-lg sm:p-7">
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="eyebrow">Operator-owned draft</p>
              <h2 class="text-2xl font-bold">Review and edit</h2>
              <p :if={@projection.draft} class="mt-1 text-sm font-semibold text-primary">
                Review this draft before activation
              </p>
              <p :if={!@projection.draft} class="mt-1 text-sm opacity-70">
                Edits autosave as a durable draft but do not change standing intent.
              </p>
            </div>
            <span :if={@projection.draft_source} class="badge badge-ghost">{@projection.draft_source}</span>
          </div>

          <.form for={@form} id="strategy-draft-form" phx-change="save_draft" class="mt-6 grid gap-5">
            <fieldset disabled={@draft_stale?} class="contents">
              <.input
                field={@form[:objectives]}
                type="textarea"
                label="Objectives in Strategic Priority order"
                rows="4"
                placeholder="Outcome | continuous | evaluation rule | recurring"
              />
              <.input
                field={@form[:hard_constraints]}
                type="textarea"
                label="Hard Constraints"
                rows="3"
                placeholder="Keep at least 50,000 credits available\nNo scrap"
              />
              <.input
                field={@form[:preferences]}
                type="textarea"
                label="Preferences"
                rows="3"
                placeholder="One plan-ranking preference per line"
              />
              <.input
                field={@form[:consequences]}
                type="textarea"
                label="Likely consequences"
                rows="3"
                placeholder="What authority and tradeoffs would activation permit?"
              />
            </fieldset>
          </.form>

          <div :if={@draft_stale?} class="alert alert-warning mt-6 items-start">
            <div>
              <strong>Draft changed elsewhere</strong>
              <p class="text-sm">
                Your local text is preserved. Review the latest durable draft before activation.
              </p>
            </div>
            <button id="review-latest-draft" phx-click="review_latest" class="btn btn-sm">
              Review latest draft
            </button>
          </div>

          <div :if={@projection.draft} class="mt-6 border-t border-base-300 pt-6">
            <div :if={@projection.active_revision} class="mb-6 rounded-xl bg-base-200 p-4">
              <h3 class="text-lg font-bold">Revision changes</h3>
              <div class="mt-3 grid gap-5 lg:grid-cols-2">
                <div>
                  <p class="eyebrow">Current active</p>
                  <.strategy_document document={@projection.active_revision.document} />
                </div>
                <div>
                  <p class="eyebrow">Proposed draft</p>
                  <.strategy_document document={@projection.draft} />
                </div>
              </div>
            </div>
            <.strategy_document document={@projection.draft} />
            <div class="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
              <button id="discard-strategy-draft" phx-click="discard_draft" class="btn btn-ghost">Discard draft</button>
              <button
                id="activate-strategy"
                phx-click="activate"
                disabled={@draft_stale?}
                class="btn btn-primary"
              >
                Activate this exact revision
              </button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("engage_emergency_stop", _params, socket) do
    case FleetStrategy.engage_emergency_stop(socket.assigns.current_scope) do
      {:ok, projection} ->
        {:noreply,
         socket
         |> put_flash(:error, "Emergency Stop engaged. New gameplay mutations are suppressed.")
         |> assign(:projection, with_presets(projection, socket))}
    end
  end

  def handle_event("resume_from_emergency_stop", _params, socket) do
    case FleetStrategy.resume(
           socket.assigns.current_scope,
           socket.assigns.projection.emergency_stop_version
         ) do
      {:ok, projection} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Authoritative state refreshed. Fresh planning must select an admissible plan before Emergency Stop clears."
         )
         |> assign(:projection, with_presets(projection, socket))}

      {:error, :stale_emergency_stop} ->
        {:noreply,
         socket
         |> put_flash(:error, "Emergency Stop changed elsewhere. Review its current state.")
         |> assign(:projection, MissionControl.strategy(socket.assigns.current_scope))}

      {:error, :authoritative_refresh_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Emergency Stop remains engaged because authoritative Fleet state could not be refreshed."
         )}

      {:error, :reconciliation_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Emergency Stop remains engaged while accepted game actions are reconciled."
         )}
    end
  end

  def handle_event("select_preset", %{"id" => preset_id}, socket) do
    case FleetStrategy.select_preset(socket.assigns.current_scope, preset_id) do
      {:ok, projection} ->
        {:noreply, assign_projection(socket, nil, with_presets(projection, socket))}

      {:error, :draft_exists} ->
        {:noreply, put_flash(socket, :error, "Discard or activate the current draft first.")}

      {:error, :preset_not_found} ->
        {:noreply, put_flash(socket, :error, "That preset is unavailable.")}
    end
  end

  def handle_event("save_draft", %{"strategy" => params}, socket) do
    if socket.assigns.draft_stale? do
      {:noreply, put_flash(socket, :error, "Review the latest durable draft before editing.")}
    else
      case FleetStrategy.save_draft(
             socket.assigns.current_scope,
             document_from_params(params),
             socket.assigns.projection.draft_version
           ) do
        {:ok, projection} ->
          {:noreply, assign_projection(socket, params, with_presets(projection, socket))}

        {:error, :stale_draft} ->
          {:noreply, mark_draft_stale(socket, "The draft changed before this edit was saved.")}
      end
    end
  end

  def handle_event("discard_draft", _params, socket) do
    case FleetStrategy.discard_draft(
           socket.assigns.current_scope,
           socket.assigns.projection.draft_version
         ) do
      {:ok, projection} ->
        {:noreply,
         socket
         |> put_flash(:info, "Draft discarded. Active intent is unchanged.")
         |> assign_projection(nil, with_presets(projection, socket))}

      {:error, :stale_draft} ->
        {:noreply, mark_draft_stale(socket, "The draft changed before it could be discarded.")}
    end
  end

  def handle_event("review_latest", _params, socket) do
    {:noreply, assign_projection(socket)}
  end

  def handle_event("activate", _params, socket) do
    if socket.assigns.draft_stale? do
      {:noreply, put_flash(socket, :error, "Review the latest durable draft before activation.")}
    else
      case FleetStrategy.activate(
             socket.assigns.current_scope,
             socket.assigns.projection.draft_version
           ) do
        {:ok, revision} ->
          projection = %{
            socket.assigns.projection
            | draft: nil,
              draft_source: nil,
              draft_version: socket.assigns.projection.draft_version + 1,
              active_revision: revision
          }

          {:noreply,
           socket
           |> put_flash(:info, "Fleet Strategy Revision #{revision.number} activated.")
           |> assign_projection(nil, projection)}

        {:error, :invalid_document} ->
          {:noreply,
           put_flash(socket, :error, "Add at least one Strategic Objective before activation.")}

        {:error, {:unenforceable_hard_constraint, constraint, explanation}} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Hard Constraint '#{constraint}' cannot be enforced. #{explanation}"
           )}

        {:error, :draft_not_found} ->
          {:noreply, put_flash(socket, :error, "There is no draft to activate.")}

        {:error, :stale_draft} ->
          {:noreply,
           mark_draft_stale(
             socket,
             "The draft changed. Review the latest version before activation."
           )}
      end
    end
  end

  @impl true
  def handle_info({:fleet_strategy_updated, operator_id}, socket) do
    if socket.assigns.current_scope.operator.id == operator_id do
      projection = MissionControl.strategy(socket.assigns.current_scope)

      cond do
        projection.draft_version != socket.assigns.projection.draft_version ->
          {:noreply,
           socket
           |> assign(:projection, projection)
           |> assign_market_planning()
           |> assign(:draft_stale?, true)}

        projection.emergency_stop_version !=
            socket.assigns.projection.emergency_stop_version ->
          {:noreply,
           socket
           |> assign(:projection, projection)
           |> assign_market_planning()}

        true ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  attr :preset, :map, required: true

  defp disclosed_choices(assigns) do
    ~H"""
    <div class="mt-5 grid gap-4 text-sm">
      <div>
        <h4 class="font-bold">Objectives and ordering</h4>
        <ol class="mt-2 list-inside list-decimal space-y-2">
          <li :for={objective <- @preset.objectives}>
            <strong>{objective["objective"]}</strong>
            <span class="block pl-5 opacity-70">
              {kind_label(objective["kind"])} / {objective["evaluation"]} / {scope_label(
                objective["scope"]
              )}
            </span>
          </li>
        </ol>
      </div>
      <.choice_list title="Hard Constraints" choices={@preset.hard_constraints} />
      <.choice_list title="Preferences" choices={@preset.preferences} />
      <div>
        <h4 class="font-bold">Likely consequences</h4>
        <p class="mt-1 opacity-70">{@preset.consequences}</p>
      </div>
    </div>
    """
  end

  attr :document, :map, required: true

  defp strategy_document(assigns) do
    ~H"""
    <div class="mt-5 grid gap-4 text-sm sm:grid-cols-3">
      <div>
        <h3 class="font-bold">Strategic Objectives</h3>
        <ol class="mt-2 list-inside list-decimal space-y-2">
          <li :for={objective <- @document["objectives"] || []}>
            <strong>{objective_name(objective)}</strong>
            <span :if={is_map(objective)} class="block pl-5 opacity-70">
              {kind_label(objective["kind"])} / {objective["evaluation"]} / {scope_label(
                objective["scope"]
              )}
            </span>
          </li>
        </ol>
      </div>
      <.choice_list title="Hard Constraints" choices={@document["hard_constraints"] || []} />
      <.choice_list title="Preferences" choices={@document["preferences"] || []} />
      <p :if={@document["consequences"]} class="sm:col-span-3">
        <strong>Likely consequences:</strong> {@document["consequences"]}
      </p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :choices, :list, required: true

  defp choice_list(assigns) do
    ~H"""
    <div>
      <h4 class="font-bold">{@title}</h4>
      <ul class="mt-2 list-inside list-disc space-y-1">
        <li :for={choice <- @choices}>{choice}</li>
      </ul>
    </div>
    """
  end

  defp assign_projection(socket, form_drafts \\ nil, projection \\ nil) do
    projection = projection || MissionControl.strategy(socket.assigns.current_scope)
    form_drafts = form_drafts || form_values(projection.draft)

    socket
    |> assign(:projection, projection)
    |> assign_market_planning()
    |> assign(:draft_stale?, false)
    |> assign(:form_drafts, form_drafts)
    |> assign(:form, to_form(form_drafts, as: "strategy"))
  end

  defp with_presets(projection, socket) do
    Map.put(projection, :presets, socket.assigns.projection.presets)
  end

  defp assign_market_planning(socket) do
    assign(socket, :market_planning, MissionControl.market_planning(socket.assigns.current_scope))
  end

  defp mark_draft_stale(socket, message) do
    socket
    |> put_flash(:error, message)
    |> assign(:projection, MissionControl.strategy(socket.assigns.current_scope))
    |> assign_market_planning()
    |> assign(:draft_stale?, true)
  end

  defp form_values(nil) do
    %{"objectives" => "", "hard_constraints" => "", "preferences" => "", "consequences" => ""}
  end

  defp form_values(document) do
    %{
      "objectives" =>
        document |> Map.get("objectives", []) |> Enum.map_join("\n", &objective_line/1),
      "hard_constraints" => document |> Map.get("hard_constraints", []) |> Enum.join("\n"),
      "preferences" => document |> Map.get("preferences", []) |> Enum.join("\n"),
      "consequences" => Map.get(document, "consequences", "")
    }
  end

  defp document_from_params(params) do
    %{
      "objectives" =>
        params
        |> Map.get("objectives", "")
        |> lines()
        |> Enum.map(&objective_from_line/1),
      "hard_constraints" => params |> Map.get("hard_constraints", "") |> lines(),
      "preferences" => params |> Map.get("preferences", "") |> lines(),
      "consequences" => params |> Map.get("consequences", "") |> String.trim()
    }
  end

  defp lines(value),
    do: value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp objective_name(%{"objective" => objective}), do: objective
  defp objective_name(objective) when is_binary(objective), do: objective

  defp scope_label("fleet_generation"), do: "Fleet Generation"
  defp scope_label("strategy_lifetime"), do: "Strategy lifetime"
  defp scope_label("recurring"), do: "Recurring"
  defp scope_label(_scope), do: "Scope not yet specified"

  defp kind_label("attain"), do: "Attain"
  defp kind_label("maintain"), do: "Maintain"
  defp kind_label("continuous"), do: "Continuous"
  defp kind_label(_kind), do: "Kind not yet specified"

  defp planning_limitation(:unsupported_market_objective),
    do: "Market activity does not directly advance this Strategic Objective."

  defp planning_limitation(:stale_market_evidence),
    do: "Market evidence is stale; an Observation Demand is required."

  defp planning_limitation(:insufficient_market_evidence),
    do: "Market evidence is insufficient; an Observation Demand is required."

  defp planning_limitation(:inconsistent_market_evidence),
    do: "Market evidence does not belong to the current planning snapshot."

  defp planning_limitation(:no_viable_market_routes),
    do: "Fresh evidence shows no positive-spread Market route."

  defp planning_limitation(_reason), do: "Market planning is currently limited."

  defp objective_line(objective) do
    Enum.join(
      [
        objective["objective"] || "",
        objective["kind"] || "",
        objective["evaluation"] || "",
        objective["scope"] || ""
      ],
      " | "
    )
  end

  defp objective_from_line(line) do
    case line |> String.split("|", parts: 4) |> Enum.map(&String.trim/1) do
      [objective, kind, evaluation, scope] ->
        %{"objective" => objective, "kind" => kind, "evaluation" => evaluation, "scope" => scope}

      [objective, kind, evaluation] ->
        %{"objective" => objective, "kind" => kind, "evaluation" => evaluation}

      [objective, kind] ->
        %{"objective" => objective, "kind" => kind}

      [objective] ->
        %{"objective" => objective}
    end
  end
end
