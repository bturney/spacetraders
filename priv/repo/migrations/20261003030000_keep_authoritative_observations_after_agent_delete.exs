defmodule SpaceTraders.Repo.Migrations.KeepAuthoritativeObservationsAfterAgentDelete do
  use Ecto.Migration

  @doc """
  Authoritative observations outlive the Agent that read them.

  Stale-Agent replacement deletes the Agent row; with the previous cascade the
  observation rows were erased and every fulfilled demand silently lost its
  fulfilled_observation_id. Nilifying the agent reference keeps the durable
  fulfillment provenance (demand -> observation) intact.
  """
  def up do
    execute("ALTER TABLE authoritative_observations ALTER COLUMN agent_id DROP NOT NULL")

    execute(
      "ALTER TABLE authoritative_observations " <>
        "DROP CONSTRAINT authoritative_observations_agent_id_fkey"
    )

    execute(
      "ALTER TABLE authoritative_observations " <>
        "ADD CONSTRAINT authoritative_observations_agent_id_fkey " <>
        "FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE SET NULL"
    )
  end

  def down do
    execute("DELETE FROM authoritative_observations WHERE agent_id IS NULL")

    execute(
      "ALTER TABLE authoritative_observations " <>
        "DROP CONSTRAINT authoritative_observations_agent_id_fkey"
    )

    execute(
      "ALTER TABLE authoritative_observations " <>
        "ADD CONSTRAINT authoritative_observations_agent_id_fkey " <>
        "FOREIGN KEY (agent_id) REFERENCES agents(id) ON DELETE CASCADE"
    )

    execute("ALTER TABLE authoritative_observations ALTER COLUMN agent_id SET NOT NULL")
  end
end
