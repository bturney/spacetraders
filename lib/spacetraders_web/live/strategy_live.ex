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
                placeholder="One non-negotiable boundary per line"
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

          <div :if={@projection.draft} class="mt-6 border-t border-base-300 pt-6">
            <div :if={@draft_stale?} class="alert alert-warning mb-6 items-start">
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
                phx-value-version={@projection.draft_version}
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
  def handle_event("select_preset", %{"id" => preset_id}, socket) do
    case FleetStrategy.select_preset(socket.assigns.current_scope, preset_id) do
      {:ok, _projection} ->
        {:noreply, assign_projection(socket)}

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
      {:ok, _projection} =
        FleetStrategy.save_draft(socket.assigns.current_scope, document_from_params(params))

      {:noreply, assign_projection(socket, params)}
    end
  end

  def handle_event("discard_draft", _params, socket) do
    {:ok, _projection} = FleetStrategy.discard_draft(socket.assigns.current_scope)

    {:noreply,
     socket
     |> put_flash(:info, "Draft discarded. Active intent is unchanged.")
     |> assign_projection()}
  end

  def handle_event("review_latest", _params, socket) do
    {:noreply, assign_projection(socket)}
  end

  def handle_event("activate", %{"version" => version}, socket) do
    {expected_version, ""} = Integer.parse(version)

    case FleetStrategy.activate(socket.assigns.current_scope, expected_version) do
      {:ok, revision} ->
        {:noreply,
         socket
         |> put_flash(:info, "Fleet Strategy Revision #{revision.number} activated.")
         |> assign_projection()}

      {:error, :invalid_document} ->
        {:noreply,
         put_flash(socket, :error, "Add at least one Strategic Objective before activation.")}

      {:error, :draft_not_found} ->
        {:noreply, put_flash(socket, :error, "There is no draft to activate.")}

      {:error, :stale_draft} ->
        {:noreply,
         socket
         |> put_flash(:error, "The draft changed. Review the latest version before activation.")
         |> assign_projection()}
    end
  end

  @impl true
  def handle_info({:fleet_strategy_updated, operator_id}, socket) do
    if socket.assigns.current_scope.operator.id == operator_id do
      projection = MissionControl.strategy(socket.assigns.current_scope)

      if projection.draft_version == socket.assigns.projection.draft_version do
        {:noreply, socket}
      else
        {:noreply,
         socket
         |> assign(:projection, projection)
         |> assign(:draft_stale?, true)}
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

  defp assign_projection(socket, form_drafts \\ nil) do
    projection = MissionControl.strategy(socket.assigns.current_scope)
    form_drafts = form_drafts || form_values(projection.draft)

    socket
    |> assign(:projection, projection)
    |> assign(:draft_stale?, false)
    |> assign(:form_drafts, form_drafts)
    |> assign(:form, to_form(form_drafts, as: "strategy"))
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
