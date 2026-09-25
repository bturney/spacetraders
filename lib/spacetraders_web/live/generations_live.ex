defmodule SpaceTradersWeb.GenerationsLive do
  @moduledoc "Comparable, evidence-bound Fleet Generation recaps."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.MissionControl

  @impl true
  def mount(_params, _session, socket) do
    recaps = MissionControl.generation_recaps(socket.assigns.current_scope)
    {:ok, assign(socket, recaps: recaps, comparison: Enum.take(recaps, 2))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <header class="mb-6">
        <p class="eyebrow">Continuing Fleet Strategy</p>
        <h1 class="text-3xl font-bold">Fleet Generations</h1>
        <p class="mt-2 opacity-70">
          Each replacement begins again from the game's starting state. Only evidenced outcomes are compared.
        </p>
      </header>
      <p :if={@recaps == []}>No Fleet Generations yet.</p>
      <section
        :if={length(@comparison) == 2}
        id="generation-comparison"
        class="mb-6 overflow-x-auto rounded-2xl border border-base-300 p-5"
      >
        <h2 class="mb-3 text-xl font-bold">Latest two Generations, compared</h2>
        <table class="table table-sm w-full">
          <thead>
            <tr>
              <th>Outcome</th><th :for={recap <- @comparison}>
                Generation {recap.generation.number}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <th>Strategy</th><td :for={recap <- @comparison}>
                {Enum.map_join(recap.revisions, ", ", &"Revision #{&1}")}
              </td>
            </tr>
            <tr>
              <th>Starting credits</th><td :for={recap <- @comparison}>
                {starting_credit_label(recap.generation.starting_credits)}
              </td>
            </tr>
            <tr>
              <th>Realized credit change</th><td :for={recap <- @comparison}>
                {credit_label(recap.realized_credit_change)}
              </td>
            </tr>
            <tr>
              <th>Decision limitations</th><td :for={recap <- @comparison}>
                {limitations_label(recap.limitations)}
              </td>
            </tr>
            <tr>
              <th>Reset cause</th><td :for={recap <- @comparison}>{reset_cause(recap)}</td>
            </tr>
            <tr>
              <th>Strategy resumed</th><td :for={recap <- @comparison}>{resume_label(recap)}</td>
            </tr>
          </tbody>
        </table>
      </section>
      <div class="grid gap-4 lg:grid-cols-2">
        <article
          :for={recap <- @recaps}
          id={"generation-#{recap.generation.number}"}
          class="rounded-2xl border border-base-300 p-5"
        >
          <p class="eyebrow">
            {if recap.generation.retired_at, do: "Past chapter", else: "Current chapter"}
          </p>
          <h2 class="mt-2 text-xl font-bold">
            Generation {recap.generation.number} · {recap.generation.symbol}
          </h2>
          <p class="mt-2 text-sm">
            Started {format_time(recap.generation.inserted_at)} · Ended {format_time(
              recap.generation.retired_at
            )}
          </p>
          <p class="mt-1 text-sm">
            {Enum.map_join(recap.revisions, ", ", &"Strategy revision #{&1}")}
          </p>
          <div class="mt-4">
            <h3 class="font-semibold">Strategic Objectives · last active revision</h3>
            <ul class="mt-2 space-y-1 text-sm">
              <li :for={objective <- recap.objective_outcomes}>
                {objective.name}: {objective_label(objective.evaluation)}
              </li>
            </ul>
          </div>
          <dl class="mt-4 grid gap-3 sm:grid-cols-2">
            <div>
              <dt class="text-sm opacity-70">Starting credits</dt><dd>
                {starting_credit_label(recap.generation.starting_credits)}
              </dd>
            </div>
            <div>
              <dt class="text-sm opacity-70">Realized credit change</dt><dd>
                {credit_label(recap.realized_credit_change)}
              </dd>
            </div>
            <div>
              <dt class="text-sm opacity-70">Realized decisions</dt><dd>
                {recap.realized_decisions}
              </dd>
            </div>
            <div>
              <dt class="text-sm opacity-70">Decision limitations</dt><dd>
                {limitations_label(recap.limitations)}
              </dd>
            </div>
            <div>
              <dt class="text-sm opacity-70">Strategy-capable</dt><dd>
                {format_time(recap.generation.strategy_capable_at)}
              </dd>
            </div>
          </dl>
          <p :if={recap.generation.fenced_at} class="mt-4 text-sm">
            Server Reset detected · {if recap.resumed?,
              do: "replacement Strategy-capable",
              else: "replacement not yet Strategy-capable"}
          </p>
        </article>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(nil), do: "Unknown"
  defp format_time(time), do: Calendar.strftime(time, "%Y-%m-%d %H:%M UTC")

  defp credit_label(nil), do: "Unknown — no realized credit evidence"
  defp credit_label(amount), do: "#{amount} credits"

  defp starting_credit_label(nil), do: "Unknown — no starting snapshot"
  defp starting_credit_label(amount), do: "#{amount} credits"

  defp limitations_label([]), do: "No classified decision limitations"
  defp limitations_label(limits), do: Enum.join(limits, "; ")

  defp reset_cause(%{generation: %{fenced_at: %DateTime{}}}),
    do: "Definitive Server Reset mismatch"

  defp reset_cause(%{generation: %{retired_at: %DateTime{}}}),
    do: "Unknown — no reset evidence recorded"

  defp reset_cause(_), do: "Current Generation"

  defp resume_label(%{generation: %{retired_at: nil}}), do: "Current operation"
  defp resume_label(%{resumed?: true}), do: "Replacement Strategy-capable"
  defp resume_label(_), do: "Not yet confirmed"

  defp objective_label({:ok, %{kind: :continuous, rate: rate}}),
    do: "#{Float.round(rate, 2)} per horizon"

  defp objective_label({:ok, %{kind: :maintain, margin: margin}}), do: "#{margin} margin"

  defp objective_label({:ok, %{kind: :attain, progress: progress}}),
    do: "#{Float.round(progress * 100, 1)}% progress"

  defp objective_label(_), do: "Unknown — no complete evaluation evidence"
end
