defmodule SpaceTraders.Repo.Migrations.AddCallerOwnershipToManualIntents do
  use Ecto.Migration

  def up do
    alter table(:manual_intents) do
      add :caller, :string, null: false, default: "manual"
      add :job_id, references(:jobs, on_delete: :delete_all)
    end
  end

  def down do
    alter table(:manual_intents) do
      remove :job_id
      remove :caller
    end
  end
end
