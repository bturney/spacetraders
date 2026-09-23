defmodule SpaceTraders.Repo.Migrations.CreateManualInterventions do
  use Ecto.Migration

  def change do
    create table(:manual_interventions) do
      add :ship_reservation_id, references(:ship_reservations, on_delete: :restrict), null: false
      add :intent_id, references(:intents, on_delete: :nilify_all)
      add :reason, :text, null: false
      add :target_waypoint, :string, null: false
      add :final_status, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:manual_interventions, [:intent_id])
    create index(:manual_interventions, [:ship_reservation_id])

    create constraint(:manual_interventions, :manual_intervention_reason_required,
             check: "length(trim(reason)) > 0"
           )

    execute(
      """
      CREATE FUNCTION preserve_manual_intervention_history() RETURNS trigger AS $$
      BEGIN
        UPDATE manual_interventions SET final_status =
          CASE WHEN OLD.status IN ('completed', 'infeasible', 'stopped', 'superseded')
               THEN OLD.status ELSE 'reset_censored' END
        WHERE intent_id = OLD.id;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION preserve_manual_intervention_history()"
    )

    execute(
      "CREATE TRIGGER preserve_manual_intervention_history BEFORE DELETE ON intents FOR EACH ROW EXECUTE FUNCTION preserve_manual_intervention_history()",
      "DROP TRIGGER preserve_manual_intervention_history ON intents"
    )
  end
end
