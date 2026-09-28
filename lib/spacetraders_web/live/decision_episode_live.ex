defmodule SpaceTradersWeb.DecisionEpisodeLive do
  @moduledoc "Authenticated evidence surface for one Strategy Decision Episode."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.MissionControl
  alias SpaceTradersWeb.{DecisionEvidence, GrafanaLink}

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    with {id, ""} <- Integer.parse(raw_id),
         %{} = episode <- MissionControl.decision_episode(socket.assigns.current_scope, id) do
      {:ok, assign(socket, episode: episode)}
    else
      _ -> {:ok, push_navigate(socket, to: ~p"/generations")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="space-y-6">
        <nav aria-label="Breadcrumb" class="text-sm">
          <.link navigate={~p"/generations"} class="link link-primary">Fleet Generations</.link>
          <span class="px-1 opacity-60">/</span>
          <span>Decision Episode {@episode.id}</span>
        </nav>

        <header class="max-w-3xl">
          <p class="eyebrow">Durable causal evidence</p>
          <h1 class="text-3xl font-bold">Decision Episode {@episode.id}</h1>
          <p class="mt-2 opacity-70">
            Generation {@episode.fleet_generation_number} · Revision {@episode.fleet_strategy_revision_number} · {@episode.calibration_version}
          </p>
        </header>

        <section class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.context label="Fleet Generation" value={"Generation #{@episode.fleet_generation_number}"} />
          <.context
            label="Strategy Revision"
            value={"Revision #{@episode.fleet_strategy_revision_number}"}
          />
          <.context label="Calibration version" value={@episode.calibration_version} />
          <.context
            label="Classification"
            value={DecisionEvidence.classification_label(@episode.classification)}
          />
        </section>

        <section class="grid gap-4 lg:grid-cols-2">
          <article id="episode-expectations" class="rounded-2xl border border-base-300 p-5">
            <h2 class="text-xl font-bold">Expected outcomes</h2>
            <.values values={@episode.expectations} empty="Unknown — no expectation was recorded." />
          </article>
          <article id="episode-actual-outcomes" class="rounded-2xl border border-base-300 p-5">
            <h2 class="text-xl font-bold">Actual outcomes</h2>
            <.values
              values={@episode.actual_outcomes}
              empty="Unknown — no actual outcome is recorded yet."
            />
          </article>
        </section>

        <section id="episode-evidence-references" class="rounded-2xl border border-base-300 p-5">
          <h2 class="text-xl font-bold">Evidence references</h2>
          <p class="mt-1 text-sm opacity-70">
            Every evidence reference retained when this episode was selected.
          </p>
          <p :if={@episode.evidence_references == []} class="mt-3 text-sm opacity-70">
            No evidence references were retained.
          </p>
          <ol class="mt-3 space-y-3">
            <li
              :for={{observation, index} <- Enum.with_index(@episode.evidence_references, 1)}
              id={"evidence-reference-#{index}"}
              class="rounded-xl border border-base-300 p-4"
            >
              <p class="font-semibold">Evidence reference {index}</p>
              <.values values={observation} empty="Unknown observation" />
            </li>
          </ol>
        </section>

        <section class="rounded-2xl border border-base-300 p-5">
          <h2 class="text-xl font-bold">Deeper evidence</h2>
          <p class="mt-1 text-sm opacity-70">
            The link carries only durable identities and the episode time range. Grafana authentication remains in Grafana.
          </p>
          <div class="mt-4 flex flex-wrap gap-3">
            <a
              href={grafana_url(:strategy_outcomes, @episode)}
              target="_blank"
              rel="noreferrer"
              class="btn btn-primary btn-sm"
            >Strategy outcome evidence</a>
            <a
              :if={calibration_family(@episode) != :strategy_outcomes}
              href={grafana_url(calibration_family(@episode), @episode)}
              target="_blank"
              rel="noreferrer"
              class="btn btn-outline btn-sm"
            >{calibration_link_label(calibration_family(@episode))}</a>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp context(assigns) do
    ~H"""
    <article class="rounded-xl border border-base-300 p-4">
      <p class="text-sm opacity-70">{@label}</p>
      <p class="mt-1 font-semibold">{@value}</p>
    </article>
    """
  end

  attr :values, :map, required: true
  attr :empty, :string, required: true

  defp values(assigns) do
    assigns = assign(assigns, :entries, Enum.sort_by(assigns.values, &elem(&1, 0)))

    ~H"""
    <p :if={@entries == []} class="mt-3 text-sm opacity-70">{@empty}</p>
    <dl :if={@entries != []} class="mt-3 space-y-2 text-sm">
      <div :for={{key, value} <- @entries} class="grid gap-1 sm:grid-cols-[12rem_1fr]">
        <dt class="opacity-70">{DecisionEvidence.field_label(key)}</dt>
        <dd class="break-words font-medium">{DecisionEvidence.value_label(value)}</dd>
      </div>
    </dl>
    """
  end

  defp grafana_url(family, episode) do
    GrafanaLink.url(family,
      fleet_generation: episode.fleet_generation_id,
      strategy_revision: episode.fleet_strategy_revision_id,
      decision_episode: episode.id,
      from: DateTime.add(episode.inserted_at, -300),
      to: episode_end(episode)
    )
  end

  defp episode_end(%{classification: :still_evaluating}), do: :now
  defp episode_end(%{updated_at: updated_at}), do: DateTime.add(updated_at, 300)

  defp calibration_family(episode),
    do: GrafanaLink.family_for_calibration(episode.calibration_version)

  defp calibration_link_label(:economics_capital), do: "Economic and capital evidence"
  defp calibration_link_label(:fleet_logistics), do: "Fleet and logistics evidence"
  defp calibration_link_label(:intelligence_api_capacity), do: "Intelligence and API evidence"
  defp calibration_link_label(:reliability_recovery), do: "Reliability and recovery evidence"
end
