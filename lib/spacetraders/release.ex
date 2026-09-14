defmodule SpaceTraders.Release do
  @moduledoc false

  @app :spacetraders

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      migrate_repo(repo)
    end
  end

  def migrate_postgres do
    Application.load(@app)

    if Application.get_env(@app, SpaceTraders.PostgresRepo) do
      original_adapter = Application.fetch_env!(@app, :repo_adapter)
      Application.put_env(@app, :repo_adapter, Ecto.Adapters.Postgres)

      try do
        migrate_repo(SpaceTraders.PostgresRepo)
      after
        Application.put_env(@app, :repo_adapter, original_adapter)
      end
    end
  end

  defp migrate_repo(repo) do
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
  end
end
