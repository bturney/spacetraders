defmodule SpaceTraders.Repo.Migrations.CreateAgentsAndShips do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add :symbol, :string, null: false
      add :faction, :string, null: false
      add :headquarters, :string, null: false
      add :agent_token_ciphertext, :string
      add :operator_id, references(:operators, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agents, [:symbol])
    create index(:agents, [:operator_id])

    create table(:ships) do
      add :symbol, :string, null: false
      add :ship_type, :string, null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ships, [:symbol])
    create index(:ships, [:agent_id])
  end
end
