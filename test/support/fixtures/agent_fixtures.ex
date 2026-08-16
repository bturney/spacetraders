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

  def unique_operator_email, do: "operator#{System.unique_integer()}@example.com"
  def valid_operator_password, do: "hello world!"

  def valid_operator_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_operator_email(),
      password: valid_operator_password()
    })
  end

  def unconfirmed_operator_fixture(attrs \\ %{}) do
    SpaceTraders.Repo.insert!(%Operator{email: Map.get(attrs, :email) || unique_operator_email()})
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
    SpaceTraders.Repo.insert!(%AgentRecord{
      symbol: Map.get(attrs, :symbol, "TEST-#{System.unique_integer()}"),
      faction: Map.get(attrs, :faction, "COSMIC"),
      headquarters: Map.get(attrs, :headquarters, "X1-UX81-A1"),
      agent_token: Map.get(attrs, :agent_token, "test-agent-token"),
      stale_at: Map.get(attrs, :stale_at),
      operator_id: operator.id
    })
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
