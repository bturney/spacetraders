defmodule SpaceTraders.Repo.Migrations.CreateManualIntents do
  use Ecto.Migration

  @terminal_states "('completed', 'stopped')"

  def up do
    create table(:manual_intents) do
      add :ship_id, references(:ships, on_delete: :delete_all), null: false
      add :type, :string, null: false, default: "navigate"
      add :target_waypoint, :string, null: false
      add :status, :string, null: false, default: "active"
      add :blocker, :map
      add :in_flight_action, :map
      add :last_action_result, :map
      add :recovery_attempts, :integer, null: false, default: 0
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:manual_intents, [:ship_id],
             where: "status NOT IN #{@terminal_states}",
             name: :manual_intents_one_active_per_ship_index
           )
  end

  def down do
    drop table(:manual_intents)
  end
end
