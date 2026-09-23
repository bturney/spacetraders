defmodule SpaceTraders.LegacyRetirement do
  @moduledoc "Drains the old Ship authority before activating Fleet Strategy."

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.Repo

  def active_for_operator?(operator_id) when is_integer(operator_id) do
    Repo.exists?(
      from strategy in Strategy,
        where: strategy.operator_id == ^operator_id and not is_nil(strategy.active_revision_id)
    )
  end

  def active_for_operator?(_operator_id), do: false

  @doc "Called inside the revision activation transaction; rolls back on unresolved game actions."
  def retire_for_operator!(operator_id) do
    ship_ids =
      Repo.all(
        from ship in Ship,
          join: agent in AgentRecord,
          on: agent.id == ship.agent_id,
          where: agent.operator_id == ^operator_id,
          select: ship.id
      )

    if ship_ids != [] do
      pending_jobs =
        Repo.exists?(
          from job in Job,
            where:
              job.ship_id in ^ship_ids and job.status in ^Job.unfinished_states() and
                not is_nil(job.in_flight_action)
        )

      pending_intents =
        Repo.exists?(
          from intent in Intent,
            where:
              intent.ship_id in ^ship_ids and intent.caller in ["manual", "job"] and
                intent.status in ^Intent.unfinished_states() and
                not is_nil(intent.in_flight_action)
        )

      if pending_jobs or pending_intents,
        do: Repo.rollback(:legacy_action_reconciliation_required)

      now = DateTime.utc_now(:second)

      Repo.update_all(
        from(job in Job,
          where: job.ship_id in ^ship_ids and job.status in ^Job.unfinished_states()
        ),
        set: [
          status: "stopped",
          finished_at: now,
          blocked_reason: "Retired for Fleet Strategy",
          updated_at: now
        ]
      )

      Repo.update_all(
        from(intent in Intent,
          where:
            intent.ship_id in ^ship_ids and intent.caller in ["manual", "job"] and
              intent.status in ^Intent.unfinished_states()
        ),
        set: [status: "stopped", finished_at: now, updated_at: now]
      )
    end

    :ok
  end
end
