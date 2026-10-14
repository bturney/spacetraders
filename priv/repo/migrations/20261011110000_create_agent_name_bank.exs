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
    WITH approved AS (
      SELECT generation.replacement_symbols->'symbols' AS names
      FROM current_fleet_identity AS identity
      JOIN fleet_generations AS generation ON generation.id = identity.fleet_generation_id
      WHERE jsonb_typeof(generation.replacement_symbols->'symbols') = 'array'
        AND jsonb_array_length(generation.replacement_symbols->'symbols') > 0
    ), candidates AS (
      SELECT name, min(ord) AS ord
      FROM jsonb_array_elements_text(COALESCE(
        (SELECT names FROM approved),
        '["ORBITALIST","PARALLAX","APHELION","SIDEREAL","LIMINAL"]'::jsonb
      )) WITH ORDINALITY AS d(name, ord)
      GROUP BY name
    )
    INSERT INTO agent_name_bank_entries (position, name, inserted_at, updated_at)
    SELECT row_number() OVER (ORDER BY ord), name, now(), now()
    FROM candidates
    WHERE NOT EXISTS (SELECT 1 FROM agent_name_bank_entries)
    """)
  end

  def down, do: drop(table(:agent_name_bank_entries))
end
