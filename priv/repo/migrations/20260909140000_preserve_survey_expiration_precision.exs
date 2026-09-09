defmodule SpaceTraders.Repo.Migrations.PreserveSurveyExpirationPrecision do
  use Ecto.Migration

  def up do
    # Existing rows lost fractional seconds before their signatures were stored.
    # They cannot be used for Survey extraction after this migration.
    execute "UPDATE surveys SET exhausted_at = CURRENT_TIMESTAMP WHERE exhausted_at IS NULL"
  end

  def down, do: :ok
end
