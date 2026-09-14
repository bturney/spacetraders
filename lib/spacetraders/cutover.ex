defmodule SpaceTraders.Cutover do
  @moduledoc """
  Enforces the one-way transition from legacy SQLite work to PostgreSQL truth.
  """

  import Ecto.Query

  alias SpaceTraders.Fleet.{Intent, Job}
  alias SpaceTraders.Repo

  def assess(repo \\ Repo) do
    unsafe = %{
      intents: unprotected_count(repo, Intent),
      jobs: unprotected_count(repo, Job)
    }

    if unsafe == %{intents: 0, jobs: 0},
      do: :ok,
      else: {:error, {:unprotected_mutations, unsafe}}
  end

  defp unprotected_count(repo, schema) do
    schema
    |> where([record], not is_nil(record.in_flight_action))
    |> repo.all()
    |> Enum.count(&(not SpaceTraders.SafetyFence.explicit?(&1)))
  end
end
