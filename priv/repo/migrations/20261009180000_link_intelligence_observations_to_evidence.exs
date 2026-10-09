defmodule SpaceTraders.Repo.Migrations.LinkIntelligenceObservationsToEvidence do
  use Ecto.Migration

  @moduledoc """
  Exact lineage from a retained Intelligence observation to the governed
  Evidence observation it projects (#670).

  Expansion only: one nullable column plus index; no existing row is
  rewritten. Legacy rows keep NULL and are interpreted as untraceable: they
  remain visible but cannot authorize an actionable Market candidate until a
  governed read retains replacement evidence. No linkage is inferred from
  equal payloads.

  Compatibility: a binary built before #670 ignores the column, so rolling the
  binary back is safe; rows written in the meantime simply stay linked.
  Rollback: `down/0` drops the column and loses only the linkage (rows revert
  to untraceable on the next forward deploy). Fix forward otherwise.
  """

  def up do
    alter table(:intelligence_observations) do
      add :evidence_observation_id,
          references(:authoritative_observations, type: :uuid, on_delete: :nilify_all)
    end

    create index(:intelligence_observations, [:evidence_observation_id])
  end

  def down do
    drop index(:intelligence_observations, [:evidence_observation_id])

    alter table(:intelligence_observations) do
      remove :evidence_observation_id
    end
  end
end
