defmodule SpaceTraders.Repo.Migrations.AddJobLineage do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :predecessor_job_id, references(:jobs, on_delete: :nilify_all)
    end

    create index(:jobs, [:predecessor_job_id])
  end
end
