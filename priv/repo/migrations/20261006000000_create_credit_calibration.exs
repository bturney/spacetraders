defmodule SpaceTraders.Repo.Migrations.CreateCreditCalibration do
  use Ecto.Migration

  @moduledoc """
  Durable credit calibration, realized-versus-quoted evidence, and credit
  shortfalls (ADR 0013, #584).

  Deployment one-way door. After this migration runs, admission reads the
  active calibration version and open shortfalls from these tables. A binary
  built before #584 ignores them: it would resume spending at the fixed 25%
  margin while a recorded breach still pauses spending, so do not roll the
  binary back past this migration.

  Compatibility: the seeded initial version keeps the label
  `market-purchase-v1-25pct` and margin 25 already written into prepared
  attempts' `prepared_evidence["spending"]`, so purchases prepared by the
  previous binary still validate after deploy. No existing row is rewritten.

  Forward recovery: fix forward with a new migration or release. To lift a
  wrongly recorded pause, set `released_at` on the open `credit_shortfalls`
  row; to undo a wrong widening, insert a newer `credit_calibration_versions`
  row (never update or delete history, and never below the 10% check). The
  `down/0` exists only for development databases.
  """

  def up do
    create table(:credit_calibration_versions) do
      add :version, :string, null: false
      add :margin_percent, :integer, null: false
      add :basis, :string, null: false
      add :previous_version_id, references(:credit_calibration_versions, on_delete: :restrict)
      add :mutation_attempt_id, references(:mutation_attempts, type: :uuid, on_delete: :nilify_all)
      add :evidence, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:credit_calibration_versions, [:version])

    create constraint(:credit_calibration_versions, :credit_calibration_hard_lower_bound,
             check: "margin_percent >= 10"
           )

    execute("""
    INSERT INTO credit_calibration_versions (version, margin_percent, basis, evidence, inserted_at)
    VALUES ('market-purchase-v1-25pct', 25, 'initial',
            '{"label": "initial conservative model"}', now())
    """)

    create table(:credit_shortfalls) do
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :mutation_attempt_id, references(:mutation_attempts, type: :uuid, on_delete: :nilify_all)

      add :calibration_version_id,
          references(:credit_calibration_versions, on_delete: :restrict)

      add :widened_calibration_version_id,
          references(:credit_calibration_versions, on_delete: :restrict)

      add :strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :nilify_all)

      add :credits, :bigint, null: false
      add :credit_floor, :bigint, null: false
      add :worst_case_exposure, :bigint
      add :realized_charge, :bigint
      add :evidence, :map, null: false, default: %{}
      add :detected_at, :utc_datetime_usec, null: false
      add :released_at, :utc_datetime_usec
      add :release_evidence, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:credit_shortfalls, [:agent_id, :released_at])

    create constraint(:credit_shortfalls, :credit_shortfall_kind,
             check:
               "kind IN ('pricing_model_miss', 'unattributable_shortfall', 'revision_floor', 'non_pricing_shortfall')"
           )

    create constraint(:credit_shortfalls, :credit_shortfall_miss_attribution,
             check:
               "kind <> 'pricing_model_miss' OR realized_charge > worst_case_exposure"
           )

    create table(:credit_realizations) do
      add :agent_id, references(:agents, on_delete: :nilify_all)

      add :mutation_attempt_id,
          references(:mutation_attempts, type: :uuid, on_delete: :nilify_all)

      add :calibration_version_id,
          references(:credit_calibration_versions, on_delete: :restrict),
          null: false

      add :operation_id, :string, null: false
      add :unit_price, :bigint, null: false
      add :units, :integer, null: false
      add :worst_case_exposure, :bigint, null: false
      add :realized_charge, :bigint, null: false
      add :credits_after, :bigint, null: false
      add :within_bound, :boolean, null: false
      add :credit_shortfall_id, references(:credit_shortfalls, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:credit_realizations, [:mutation_attempt_id])
  end

  def down do
    drop table(:credit_realizations)
    drop table(:credit_shortfalls)
    drop table(:credit_calibration_versions)
  end
end
