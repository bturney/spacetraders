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

  @doc "Establishes and publishes setup under PostgreSQL serialization, including legacy inserts."
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
    case adopt() do
      {:ok, _identity} -> :ignore
      {:error, error} -> {:error, error.summary}
    end
  end

  @doc "Serializes legacy adoption with legacy writes, including empty initialization."
  def adopt do
    Repo.transaction(fn ->
      Repo.query!(
        "LOCK TABLE operators, agents, fleet_generations, fleet_strategies, fleet_strategy_revisions IN SHARE ROW EXCLUSIVE MODE"
      )

      [[operator_id, agent_id, generation_id]] =
        Repo.query!("SELECT * FROM fleet_identity_candidate()").rows

      generation_id = generation_id || establish_generation(operator_id, agent_id)

      Repo.query!(
        """
        INSERT INTO current_fleet_identity (id, operator_id, fleet_generation_id)
        VALUES (1, $1, $2)
        ON CONFLICT (id) DO UPDATE SET operator_id = EXCLUDED.operator_id,
          fleet_generation_id = EXCLUDED.fleet_generation_id
        """,
        [operator_id, generation_id]
      )

      read!()
    end)
  rescue
    error in Postgrex.Error -> preflight_error(error)
  end

  def current do
    identity = read!()

    # Compatible setup/import writers still use the old context in this expand
    # phase. Adopt lazily only before an identity is established; never select a
    # replacement by symbol or timestamp once a Generation is published.
    if identity.state in [:setup, :empty], do: adopt(), else: {:ok, identity}
  rescue
    error in Postgrex.Error -> preflight_error(error)
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
          join: candidate in fragment("fleet_identity_candidate()"),
          on: true,
          left_join: operator in Operator,
          on: operator.id == i.operator_id,
          left_join: generation in Generation,
          on: generation.id == i.fleet_generation_id,
          left_join: agent in Agent,
          on: agent.id == generation.agent_id,
          where: i.id == 1,
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

  defp establish_generation(_operator_id, nil), do: nil

  defp establish_generation(operator_id, agent_id) do
    # This is the same adoption as the actual migration, not a game bootstrap.
    [[generation_id]] =
      Repo.query!(
        """
        INSERT INTO fleet_generations
          (operator_id, agent_id, number, symbol, faction, fleet_strategy_revision_id,
           replacement_symbols, objective_progress, fenced_at, inserted_at, updated_at)
        SELECT a.operator_id, a.id,
               COALESCE((SELECT max(g.number) FROM fleet_generations g WHERE g.operator_id = a.operator_id), 0) + 1,
               a.symbol, a.faction, s.active_revision_id,
               jsonb_build_object('symbols', jsonb_build_array(a.symbol)), '{}'::jsonb,
               a.stale_at, a.inserted_at, CURRENT_TIMESTAMP
        FROM agents a LEFT JOIN fleet_strategies s ON s.operator_id = a.operator_id
        WHERE a.operator_id = $1 AND a.id = $2 RETURNING id
        """,
        [operator_id, agent_id]
      ).rows

    generation_id
  end

  defp preflight_error(%Postgrex.Error{postgres: %{code: :raise_exception} = details}) do
    {:error,
     %{reason: :ambiguous_current_fleet, summary: details.message <> ". " <> details.hint}}
  end

  defp preflight_error(error), do: raise(error)
end
