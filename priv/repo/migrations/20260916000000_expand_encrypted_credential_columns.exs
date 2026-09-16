defmodule SpaceTraders.Repo.Migrations.ExpandEncryptedCredentialColumns do
  use Ecto.Migration

  def change do
    alter table(:operators) do
      modify :account_token_ciphertext, :text
    end

    alter table(:agents) do
      modify :agent_token_ciphertext, :text
    end
  end
end
