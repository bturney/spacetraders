defmodule SpaceTraders.Repo.Migrations.RetainRegistrationRecoveryCredential do
  use Ecto.Migration

  # A successful registration's AgentToken is retained encrypted on its
  # MutationAttempt until local adoption links the attempt to its Generation
  # (ADR 0011: the attempt stays the one recovery record).
  def change do
    alter table(:mutation_attempts) do
      add :recovery_credential_ciphertext, :text
    end
  end
end
