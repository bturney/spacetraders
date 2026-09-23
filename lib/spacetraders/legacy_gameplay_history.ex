defmodule SpaceTraders.LegacyGameplayHistory do
  @moduledoc "Operator-scoped snapshots of Jobs and Intents from retired Fleet Generations."

  use Ecto.Schema
  import Ecto.Query

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.Repo

  schema "legacy_gameplay_history" do
    belongs_to :operator, SpaceTraders.Agent.Operator
    field :original_id, :integer
    field :kind, :string
    field :agent_symbol, :string
    field :ship_symbol, :string
    field :type, :string
    field :caller, :string
    field :status, :string
    field :target_waypoint, :string
    field :details, :map, default: %{}
    field :original_inserted_at, :utc_datetime
    field :finished_at, :utc_datetime
    timestamps(type: :utc_datetime_usec)
  end

  def list(%Scope{operator: %{id: operator_id}}, kind) when kind in ["job", "intent"] do
    Repo.all(
      from entry in __MODULE__,
        where: entry.operator_id == ^operator_id and entry.kind == ^kind,
        order_by: [desc: entry.original_inserted_at, desc: entry.original_id]
    )
  end

  @doc "Snapshot before deleting a Stale Agent, in the same database transaction."
  def archive_agent!(%SpaceTraders.Agent.Agent{
        id: agent_id,
        operator_id: operator_id,
        symbol: symbol
      }) do
    now = DateTime.utc_now()

    ships = Repo.all(from ship in Ship, where: ship.agent_id == ^agent_id)

    Enum.each(ships, fn ship ->
      jobs = Repo.all(from job in Job, where: job.ship_id == ^ship.id)
      intents = Repo.all(from intent in Intent, where: intent.ship_id == ^ship.id)

      Enum.each(jobs, fn job ->
        insert_snapshot!(%{
          operator_id: operator_id,
          original_id: job.id,
          kind: "job",
          agent_symbol: symbol,
          ship_symbol: ship.symbol,
          type: job.type,
          status: archival_state(job.status, Job.unfinished_states()),
          original_inserted_at: job.inserted_at,
          finished_at: job.finished_at,
          inserted_at: now,
          updated_at: now,
          details: %{
            "extraction_waypoint" => job.extraction_waypoint,
            "market_waypoint" => job.market_waypoint,
            "progress" => job.progress,
            "last_action_result" => job.last_action_result,
            "state_before_reset" => job.status
          }
        })
      end)

      Enum.each(intents, fn intent ->
        insert_snapshot!(%{
          operator_id: operator_id,
          original_id: intent.id,
          kind: "intent",
          agent_symbol: symbol,
          ship_symbol: ship.symbol,
          type: intent.type,
          caller: intent.caller,
          status: archival_state(intent.status, Intent.unfinished_states()),
          target_waypoint: intent.target_waypoint,
          original_inserted_at: intent.inserted_at,
          finished_at: intent.finished_at,
          inserted_at: now,
          updated_at: now,
          details: %{
            "parameters" => intent.parameters,
            "last_action_result" => intent.last_action_result,
            "state_before_reset" => intent.status
          }
        })
      end)
    end)

    :ok
  end

  defp insert_snapshot!(attrs) do
    Repo.insert_all(__MODULE__, [attrs],
      on_conflict: :nothing,
      conflict_target: [:kind, :original_id]
    )

    :ok
  end

  defp archival_state(status, unfinished_states) do
    if status in unfinished_states, do: "reset_censored", else: status
  end
end
