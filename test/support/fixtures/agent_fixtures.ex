defmodule SpaceTraders.AgentFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `SpaceTraders.Agent` context.
  """

  import Ecto.Query

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Repo

  def unique_operator_email, do: "operator#{System.unique_integer()}@example.com"
  def valid_operator_password, do: "hello world!"

  def valid_operator_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_operator_email(),
      password: valid_operator_password()
    })
  end

  def unconfirmed_operator_fixture(attrs \\ %{}) do
    operator_fixture(attrs)
    |> Ecto.Changeset.change(confirmed_at: nil, hashed_password: nil)
    |> SpaceTraders.Repo.update!()
  end

  # Explicit pre-contraction data only: ownership/ambiguity tests still need
  # legacy rows. This is not a supported creation/authentication path.
  def legacy_operator_fixture(attrs \\ %{}) do
    %Operator{}
    |> Operator.registration_changeset(valid_operator_attributes(attrs))
    |> SpaceTraders.Repo.insert!()
  end

  def operator_fixture(attrs \\ %{}) do
    {:ok, operator} =
      attrs
      |> valid_operator_attributes()
      |> Agent.register_operator()

    operator
  end

  def operator_scope_fixture do
    operator = operator_fixture()
    operator_scope_fixture(operator)
  end

  def operator_scope_fixture(operator) do
    Scope.for_operator(operator)
  end

  def agent_fixture(operator, attrs \\ %{}) do
    agent =
      Repo.insert!(%AgentRecord{
        symbol: Map.get(attrs, :symbol, "TEST-#{System.unique_integer()}"),
        faction: Map.get(attrs, :faction, "COSMIC"),
        headquarters: Map.get(attrs, :headquarters, "X1-UX81-A1"),
        agent_token: Map.get(attrs, :agent_token, "test-agent-token"),
        stale_at: Map.get(attrs, :stale_at),
        operator_id: operator.id
      })

    if Map.get(attrs, :publish, true) do
      current =
        Repo.one(
          from i in "current_fleet_identity", where: i.id == 1, select: i.fleet_generation_id
        )

      predecessor = current && Repo.get(Generation, current)

      historical? =
        operator.id != SpaceTraders.OperatorAuthority.deployment_operator_id() or
          (predecessor && is_nil(predecessor.retired_at))

      revision = SpaceTraders.FleetStrategy.get().active_revision
      number = (Repo.one(from g in Generation, select: max(g.number)) || 0) + 1

      generation =
        Repo.insert!(%Generation{
          operator_id: operator.id,
          agent_id: agent.id,
          number: number,
          symbol: agent.symbol,
          faction: agent.faction,
          fenced_at: with_microseconds(agent.stale_at),
          retired_at: if(historical?, do: DateTime.utc_now()),
          fleet_strategy_revision_id: revision && revision.id,
          initial_fleet_strategy_revision_id: revision && revision.id,
          replacement_symbols: %{"symbols" => [agent.symbol]}
        })

      unless historical?,
        do:
          Repo.transaction(fn ->
            SpaceTraders.FleetGeneration.Identity.publish_generation!(operator.id, generation.id)
          end)
    end

    agent
  end

  @doc "Configures a fixture Agent's established Generation without creating a competing Fleet."
  def generation_fixture(%Ecto.Changeset{} = changeset),
    do: changeset |> Ecto.Changeset.apply_action!(:insert) |> generation_fixture()

  def generation_fixture(%Generation{} = desired) do
    generation =
      case desired.agent_id && Repo.get_by(Generation, agent_id: desired.agent_id) do
        %Generation{} = established ->
          attrs =
            Map.take(
              Map.from_struct(desired),
              Generation.__schema__(:fields) -- [:id, :updated_at]
            )
            |> Map.reject(fn {key, value} ->
              is_nil(value) and key in [:inserted_at, :initial_fleet_strategy_revision_id]
            end)

          established |> Ecto.Changeset.change(attrs) |> Repo.update!()

        _ ->
          Repo.insert!(desired)
      end

    current =
      Repo.one(
        from i in "current_fleet_identity", where: i.id == 1, select: i.fleet_generation_id
      )

    if is_nil(current) and is_nil(generation.retired_at) and generation.agent_id do
      Repo.transaction(fn ->
        SpaceTraders.FleetGeneration.Identity.publish_generation!(
          generation.operator_id,
          generation.id
        )
      end)
    end

    generation
  end

  def established_agent_fixture(%AgentRecord{} = record) do
    operator =
      if record.operator_id,
        do: Repo.get!(Operator, record.operator_id),
        else: Repo.one(Operator) || operator_fixture()

    agent_fixture(operator, Map.from_struct(record))
  end

  defp with_microseconds(nil), do: nil

  defp with_microseconds(%DateTime{} = time),
    do: %{time | microsecond: {elem(time.microsecond, 0), 6}}

  @doc "Removes only one real-commit test installation after its observers have stopped."
  def cleanup_operator_fixture(operator_id) when is_integer(operator_id) do
    Repo.transaction(fn ->
      Repo.query!(
        "UPDATE current_fleet_identity SET operator_id = NULL, fleet_generation_id = NULL WHERE operator_id = $1",
        [operator_id]
      )

      for table <- ~w(observation_demands authoritative_observations) do
        Repo.query!(
          "DELETE FROM #{table} WHERE agent_id IN (SELECT id FROM agents WHERE operator_id = $1)",
          [operator_id]
        )
      end

      for table <-
            ~w(mutation_attempts fleet_generations fleet_strategies agents operators) do
        column = if table == "operators", do: "id", else: "operator_id"
        Repo.query!("DELETE FROM #{table} WHERE #{column} = $1", [operator_id])
      end
    end)

    :ok
  end

  def set_password(operator) do
    {:ok, {operator, _expired_tokens}} =
      Agent.update_operator_password(operator, %{password: valid_operator_password()})

    operator
  end

  def extract_operator_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    SpaceTraders.Repo.update_all(
      from(t in Agent.OperatorToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_operator_magic_link_token(operator) do
    {encoded_token, operator_token} = Agent.OperatorToken.build_email_token(operator, "login")
    SpaceTraders.Repo.insert!(operator_token)
    {encoded_token, operator_token.token}
  end

  def offset_operator_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    SpaceTraders.Repo.update_all(
      from(ut in Agent.OperatorToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
