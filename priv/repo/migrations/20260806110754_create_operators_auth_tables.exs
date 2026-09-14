defmodule SpaceTraders.Repo.Migrations.CreateOperatorsAuthTables do
  use Ecto.Migration

  def change do
    if postgres?() do
      # The extension can be shared with other PostgreSQL schemas, so rollback
      # leaves it in place rather than removing a dependency it may not own.
      execute("CREATE EXTENSION IF NOT EXISTS citext", "SELECT 1")
    end

    create table(:operators) do
      if postgres?() do
        add :email, :citext, null: false
      else
        add :email, :string, null: false, collate: :nocase
      end

      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :account_token_ciphertext, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operators, [:email])

    create table(:operators_tokens) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      # PostgreSQL bytea rejects SQLite's size modifier. SQLite does not
      # enforce it either, so both adapters store the same opaque token bytes.
      add :token, :binary, null: false
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:operators_tokens, [:operator_id])
    create unique_index(:operators_tokens, [:context, :token])
  end

  defp postgres?,
    do: Application.fetch_env!(:spacetraders, :repo_adapter) == Ecto.Adapters.Postgres
end
