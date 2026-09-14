defmodule SpaceTraders.Repo.Migrations.AddCallerOwnershipToManualIntents do
  use Ecto.Migration

  def up do
    alter table(:manual_intents) do
      add :caller, :string, null: false, default: "manual"
      add :job_id, references(:jobs, on_delete: :delete_all)
    end

    if postgres?() do
      execute("""
      UPDATE manual_intents
      SET caller = 'job',
          job_id = (parameters->>'job_id')::bigint
      WHERE parameters->>'caller' = 'job'
      """)
    else
      execute("""
      UPDATE manual_intents
      SET caller = 'job',
          job_id = json_extract(parameters, '$.job_id')
      WHERE json_extract(parameters, '$.caller') = 'job'
      """)
    end
  end

  def down do
    alter table(:manual_intents) do
      remove :job_id
      remove :caller
    end
  end

  defp postgres?,
    do: Application.fetch_env!(:spacetraders, :repo_adapter) == Ecto.Adapters.Postgres
end
