defmodule SpaceTraders.Repo.Migrations.PreserveDemandProvenanceOnAgentDelete do
  use Ecto.Migration

  @doc """
  Observation Demand provenance outlives the Agent that owned it.

  Stale-Agent replacement deletes the Agent row; nilifying the demand's agent
  reference keeps the durable, Operator-visible demand history (its Strategy
  revision, subject, owner, and timing) instead of erasing it.
  """
  def up do
    execute("ALTER TABLE observation_demands ALTER COLUMN agent_id DROP NOT NULL")

    execute(
      "ALTER TABLE observation_demands " <>
        "DROP CONSTRAINT observation_demands_agent_id_fkey"
    )

    execute(
      "ALTER TABLE observation_demands " <>
        "ADD CONSTRAINT observation_demands_agent_id_fkey " <>
        "FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL"
    )
  end

  def down do
    execute(
      "UPDATE observation_demands SET agent_id = NULL WHERE agent_id IS NOT NULL AND " <>
        "NOT EXISTS (SELECT 1 FROM agents WHERE agents.id = observation_demands.agent_id)"
    )

    execute("DELETE FROM observation_demands WHERE agent_id IS NULL")

    execute("ALTER TABLE observation_demands ALTER COLUMN agent_id SET NOT NULL")

    execute(
      "ALTER TABLE observation_demands " <>
        "DROP CONSTRAINT observation_demands_agent_id_fkey"
    )

    execute(
      "ALTER TABLE observation_demands " <>
        "ADD CONSTRAINT observation_demands_agent_id_fkey " <>
        "FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE"
    )
  end
end
