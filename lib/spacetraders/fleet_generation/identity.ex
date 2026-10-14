defmodule SpaceTraders.FleetGeneration.Identity do
  @moduledoc false
  import Ecto.Query
  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Repo

  @doc "Checks authentication authority without loading game credentials or selecting historical Agents."
  def operator?(operator_id) do
    Repo.exists?(
      from i in "current_fleet_identity", where: i.id == 1 and i.operator_id == ^operator_id
    )
  end

  @doc "Establishes and publishes sole-Operator setup under PostgreSQL serialization."
  def setup_operator(changeset) do
    Repo.transact(fn ->
      # Same first lock as adoption. Independent app processes and old writers
      # cannot both observe an empty installation and establish an Operator.
      Repo.query!("LOCK TABLE operators IN SHARE ROW EXCLUSIVE MODE")

      cond do
        not changeset.valid? ->
          {:error, %{changeset | action: :insert}}

        Repo.exists?(Operator) ->
          {:error, :setup_unavailable}

        true ->
          # Ecto query diagnostics use the original custom-type parameter (the
          # plaintext AccountToken), even though its database dump is encrypted.
          with {:ok, operator} <- Repo.insert(changeset, log: false) do
            %{num_rows: published} =
              Repo.query!(
                "UPDATE current_fleet_identity SET operator_id = $1 WHERE id = 1 AND operator_id IS NULL AND fleet_generation_id IS NULL",
                [operator.id]
              )

            if published == 1,
              do: {:ok, operator},
              else: {:error, :setup_unavailable}
          end
      end
    end)
  end

  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}, restart: :temporary}
  end

  # Synchronous supervisor preflight, before any autonomous child starts. A Task
  # would race runtime boot. This child needs no long-lived process or cache.
  def start_link(_opts) do
    case preflight() do
      {:ok, _identity} -> :ignore
      {:error, error} -> {:error, error.summary}
    end
  end

  @doc "Validates the migrated deployment before any autonomous child starts."
  def preflight do
    Repo.transaction(fn ->
      read!()
    end)
  rescue
    error in Postgrex.Error -> preflight_error(error)
  end

  def current do
    {:ok, read!()}
  rescue
    error in Postgrex.Error -> preflight_error(error)
  end

  @doc """
  Takes the durable establishment authority inside the caller's transaction.

  The sole Operator's row is the lock: every mint and import for this
  deployment queues on it in PostgreSQL, across processes and app instances,
  before dispatching any game request. `FOR NO KEY UPDATE` leaves session
  logins (foreign-key share locks) and adoption's table locks unblocked.
  Returns the identity as committed by any earlier establishment.
  """
  def lock_establishment(operator_id) do
    %{rows: locked} =
      Repo.query!(
        """
        SELECT o.id FROM operators o
        JOIN current_fleet_identity i ON i.id = 1 AND i.operator_id = o.id
        WHERE o.id = $1 FOR NO KEY UPDATE OF o
        """,
        [operator_id]
      )

    if locked == [] do
      {:error,
       %{
         reason: :not_deployment_operator,
         summary: "Sign in as the deployment Operator to access the current Fleet."
       }}
    else
      {:ok, read!()}
    end
  rescue
    error in Postgrex.Error -> preflight_error(error)
  end

  @doc """
  Decides whether an Agent's credential may be used for new gameplay.

  Once a Generation is published, only its own healthy Agent has authority:
  retired or fenced Generations, Stale Agents and any other retained Agent
   row are history, however their credential reference was obtained. Without
   a published Generation there is no gameplay authority.

  One statement with no locks, so every request can afford it and readers
  never wait on lifecycle transactions.
  """
  def gameplay_authority(agent_id) when is_integer(agent_id) do
    authority =
      Repo.one(
        from agent in Agent,
          left_join: own in Generation,
          on: own.agent_id == agent.id,
          left_join: identity in "current_fleet_identity",
          on: identity.id == 1,
          left_join: current in Generation,
          on: current.id == identity.fleet_generation_id,
          where: agent.id == ^agent_id,
          select: %{
            stale?: not is_nil(agent.stale_at),
            own_ended?: not is_nil(own.fenced_at) or not is_nil(own.retired_at),
            published?: not is_nil(current.id),
            current?:
              current.agent_id == agent.id and is_nil(current.fenced_at) and
                is_nil(current.retired_at)
          }
      )

    case authority do
      nil -> {:error, :agent_token_missing}
      %{stale?: true} -> {:error, :stale_agent}
      %{own_ended?: true} -> {:error, :generation_not_current}
      %{published?: true, current?: true} -> :ok
      %{published?: true} -> {:error, :generation_not_current}
      %{published?: false} -> {:error, :generation_not_current}
    end
  end

  @doc "Publishes a successful lifecycle transition inside its existing transaction."
  def publish_generation!(operator_id, generation_id) do
    %{num_rows: published} =
      Repo.query!(
        """
        UPDATE current_fleet_identity SET operator_id = $1, fleet_generation_id = $2
        WHERE id = 1 AND (operator_id IS NULL OR operator_id = $1)
          AND (fleet_generation_id IS NULL OR fleet_generation_id = $2 OR EXISTS
            (SELECT 1 FROM fleet_generations g WHERE g.id = fleet_generation_id
             AND (g.fenced_at IS NOT NULL OR g.retired_at IS NOT NULL OR g.agent_id IS NULL)))
        """,
        [operator_id, generation_id]
      )

    if published == 1, do: :ok, else: Repo.rollback(:current_fleet_conflict)
  end

  defp read! do
    # One SQL statement: readers cannot combine predecessor credentials with the
    # next Generation while a replacement transaction commits.
    {operator, generation, agent} =
      Repo.one!(
        from i in "current_fleet_identity",
          left_join: operator in Operator,
          on: operator.id == i.operator_id,
          left_join: generation in Generation,
          on: generation.id == i.fleet_generation_id,
          left_join: agent in Agent,
          on: agent.id == generation.agent_id,
          where: i.id == 1 and fragment("preflight_current_fleet()"),
          select: {operator, generation, agent}
      )

    state =
      cond do
        is_nil(operator) ->
          :setup

        is_nil(generation) ->
          :empty

        generation.retired_at || generation.fenced_at || is_nil(agent) || agent.stale_at ->
          :transition

        true ->
          :current
      end

    %{
      state: state,
      operator: operator && %{operator | account_token: nil, password: nil, hashed_password: nil},
      agent: agent && %{agent | agent_token: nil},
      generation: generation
    }
  end

  defp preflight_error(%Postgrex.Error{postgres: %{code: :raise_exception} = details}) do
    {:error,
     %{reason: :ambiguous_current_fleet, summary: details.message <> ". " <> details.hint}}
  end

  defp preflight_error(%Postgrex.Error{postgres: %{code: code}})
       when code in [:undefined_function, :undefined_column, :undefined_table] do
    {:error,
     %{
       reason: :incomplete_fleet_migration,
       summary: "Complete the Fleet tenancy migration before starting autonomous gameplay."
     }}
  end

  defp preflight_error(error), do: raise(error)
end
