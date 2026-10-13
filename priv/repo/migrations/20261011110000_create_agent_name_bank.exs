defmodule SpaceTraders.Repo.Migrations.CreateAgentNameBank do
  use Ecto.Migration

  # Defaults are seeded once, only into an empty table, so a later migration run
  # or deploy never overwrites Operator-approved names or ordering.
  def up do
    create table(:agent_name_bank_entries) do
      add :position, :integer, null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_name_bank_entries, [:name])
    create unique_index(:agent_name_bank_entries, [:position])

    create constraint(:agent_name_bank_entries, :name_registration_length,
             check: "char_length(name) BETWEEN 3 AND 14 AND name = upper(name)"
           )

    execute("""
    INSERT INTO agent_name_bank_entries (position, name, inserted_at, updated_at)
    SELECT ord, name, now(), now()
    FROM unnest(ARRAY['ORBITALIST','PARALLAX','APHELION','SIDEREAL','LIMINAL']) WITH ORDINALITY AS d(name, ord)
    WHERE NOT EXISTS (SELECT 1 FROM agent_name_bank_entries)
    """)
  end

  def down, do: drop(table(:agent_name_bank_entries))
end
