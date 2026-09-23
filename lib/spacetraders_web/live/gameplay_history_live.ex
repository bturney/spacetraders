defmodule SpaceTradersWeb.GameplayHistoryLive do
  @moduledoc "Read-only history of legacy Jobs and Intents for the signed-in Operator."

  use SpaceTradersWeb, :live_view
  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.LegacyGameplayHistory
  alias SpaceTraders.Repo

  @impl true
  def mount(_params, _session, socket) do
    operator_id = socket.assigns.current_scope.operator.id

    current_jobs =
      Repo.all(
        from job in Job,
          join: ship in Ship,
          on: ship.id == job.ship_id,
          join: agent in AgentRecord,
          on: agent.id == ship.agent_id,
          where: agent.operator_id == ^operator_id,
          order_by: [desc: job.inserted_at, desc: job.id],
          select: %{
            id: job.id,
            type: job.type,
            state: job.status,
            ship: ship.symbol,
            finished_at: job.finished_at,
            inserted_at: job.inserted_at,
            archived?: false
          }
      )

    current_intents =
      Repo.all(
        from intent in Intent,
          join: ship in Ship,
          on: ship.id == intent.ship_id,
          join: agent in AgentRecord,
          on: agent.id == ship.agent_id,
          where: agent.operator_id == ^operator_id,
          order_by: [desc: intent.inserted_at, desc: intent.id],
          select: %{
            id: intent.id,
            caller: intent.caller,
            type: intent.type,
            state: intent.status,
            ship: ship.symbol,
            finished_at: intent.finished_at,
            inserted_at: intent.inserted_at,
            target_waypoint: intent.target_waypoint,
            archived?: false
          }
      )

    archived_jobs =
      Enum.map(LegacyGameplayHistory.list(socket.assigns.current_scope, "job"), fn entry ->
        %{
          id: entry.original_id,
          type: entry.type,
          state: entry.status,
          ship: entry.ship_symbol,
          finished_at: entry.finished_at,
          inserted_at: entry.original_inserted_at,
          archived?: true
        }
      end)

    archived_intents =
      Enum.map(LegacyGameplayHistory.list(socket.assigns.current_scope, "intent"), fn entry ->
        %{
          id: entry.original_id,
          type: entry.type,
          state: entry.status,
          caller: entry.caller,
          ship: entry.ship_symbol,
          finished_at: entry.finished_at,
          inserted_at: entry.original_inserted_at,
          target_waypoint: entry.target_waypoint,
          archived?: true
        }
      end)

    jobs = Enum.sort_by(current_jobs ++ archived_jobs, &{&1.inserted_at, &1.id}, :desc)
    intents = Enum.sort_by(current_intents ++ archived_intents, &{&1.inserted_at, &1.id}, :desc)

    {:ok, assign(socket, jobs: jobs, intents: intents)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <header class="mb-8">
        <p class="eyebrow">Read-only Fleet Generation record</p>
        <h1 class="text-3xl font-bold">Gameplay history</h1>
      </header>
      <section id="job-history" class="mb-8">
        <h2 class="text-xl font-semibold">Jobs</h2>
        <p :if={@jobs == []}>No Jobs recorded.</p>
        <ul class="mt-3 space-y-2">
          <li :for={job <- @jobs} class="rounded-lg border border-base-300 p-3">
            <strong>{job.type} Job #{job.id}</strong> · {job.ship} · {job.state}
            <span :if={job.archived?}> · Retired Fleet Generation</span>
            <span :if={job.finished_at}> · Finished {job.finished_at}</span>
          </li>
        </ul>
      </section>
      <section id="intent-history">
        <h2 class="text-xl font-semibold">Intents</h2>
        <p :if={@intents == []}>No Intents recorded.</p>
        <ul class="mt-3 space-y-2">
          <li :for={intent <- @intents} class="rounded-lg border border-base-300 p-3">
            <strong>{intent.type} Intent #{intent.id}</strong>
            · {intent.ship} · {intent.state} · {intent_owner(intent.caller)}
            <span :if={intent.target_waypoint}> · {intent.target_waypoint}</span>
            <span :if={intent.archived?}> · Retired Fleet Generation</span>
            <span :if={intent.finished_at}> · Finished {intent.finished_at}</span>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  defp intent_owner("job"), do: "Legacy Job"
  defp intent_owner("manual"), do: "Legacy Manual Control"
  defp intent_owner("commitment"), do: "Fleet Commitment"
  defp intent_owner("intervention"), do: "Manual Intervention"
  defp intent_owner(other), do: other
end
