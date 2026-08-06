defmodule SpaceTraders.Repo.Migrations.CreateOperatorsAuthTables do
  use Ecto.Migration

  def change do
    create table(:operators) do
      add :email, :string, null: false, collate: :nocase
      add :hashed_password, :string
      add :confirmed_at, :utc_datetime
      add :account_token_ciphertext, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operators, [:email])

    create table(:operators_tokens) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :token, :binary, null: false, size: 32
      add :context, :string, null: false
      add :sent_to, :string
      add :authenticated_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:operators_tokens, [:operator_id])
    create unique_index(:operators_tokens, [:context, :token])
  end
end
