defmodule SpaceTraders.Agent do
  @moduledoc """
  The Agent context: operator accounts, game secrets, and agent minting.

  Owns the human Operators (email/password login, per-operator AccountToken
  linking) and the in-game Agents they mint. AccountTokens and AgentTokens are
  stored encrypted at rest via `SpaceTraders.Secret` (ADR 0006) — the app reads
  them only from the database, never from `.env`. Minting talks to the game
  through `SpaceTraders.API.register/3`.
  """

  import Ecto.Changeset, only: [get_field: 2]
  import Ecto.Query, warn: false
  alias SpaceTraders.Repo

  alias SpaceTraders.API.Model.Agent, as: GameAgent
  alias SpaceTraders.Agent.{Agent, Operator, OperatorToken, OperatorNotifier, Scope}

  ## Database getters

  @doc """
  Returns true when at least one operator exists (used to gate first-run setup).
  """
  def has_operators? do
    Repo.aggregate(Operator, :count, :id) > 0
  end

  @doc """
  Gets a operator by email.

  ## Examples

      iex> get_operator_by_email("foo@example.com")
      %Operator{}

      iex> get_operator_by_email("unknown@example.com")
      nil

  """
  def get_operator_by_email(email) when is_binary(email) do
    Repo.get_by(Operator, email: email)
  end

  @doc """
  Gets a operator by email and password.

  ## Examples

      iex> get_operator_by_email_and_password("foo@example.com", "correct_password")
      %Operator{}

      iex> get_operator_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_operator_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    operator = Repo.get_by(Operator, email: email)
    if Operator.valid_password?(operator, password), do: operator
  end

  @doc """
  Gets a single operator.

  Raises `Ecto.NoResultsError` if the Operator does not exist.

  ## Examples

      iex> get_operator!(123)
      %Operator{}

      iex> get_operator!(456)
      ** (Ecto.NoResultsError)

  """
  def get_operator!(id), do: Repo.get!(Operator, id)

  ## Operator registration

  @doc """
  Registers a operator with email + password.

  The account is confirmed immediately — registration is the first-run setup
  surface for a LAN dashboard and has no email-confirmation step.

  ## Examples

      iex> register_operator(%{email: "a@example.com", password: "a long password"})
      {:ok, %Operator{confirmed_at: %DateTime{}}}

      iex> register_operator(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_operator(attrs) do
    %Operator{}
    |> Operator.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns a registration changeset for the setup / registration forms.
  """
  def change_registration(attrs \\ %{}, opts \\ []) do
    Operator.registration_changeset(%Operator{}, attrs, opts)
  end

  ## Game secrets

  @doc """
  Links the operator's my.spacetraders.io AccountToken once, stored encrypted.

  The token is only ever used to mint agents in-app; it never authorizes game
  actions and never leaves the database in plaintext (ADR 0006).
  """
  def link_account_token(%Operator{} = operator, account_token) when is_binary(account_token) do
    operator
    |> Operator.account_token_changeset(%{account_token: account_token})
    |> Repo.update()
  end

  @doc """
  Returns a changeset for the account-token form on the settings page.

  Built on a fresh operator so the currently-linked token is never pre-filled
  into the form.
  """
  def change_account_token(attrs \\ %{}) do
    Operator.account_token_changeset(%Operator{}, attrs)
  end

  ## Agents

  @doc """
  Returns a changeset for the agent-mint form (symbol + faction).
  """
  def change_mint(attrs \\ %{}) do
    Agent.changeset(%Agent{}, attrs)
  end

  @doc """
  Lists the agents owned by the given operator, newest last.
  """
  def list_agents(%Operator{id: operator_id}) do
    Repo.all(from(agent in Agent, where: agent.operator_id == ^operator_id, order_by: agent.id))
  end

  @doc """
  Gets a single agent by id, scoped to the given operator.

  Returns `nil` when the agent does not belong to the operator.
  """
  def get_agent(%Operator{id: operator_id}, agent_id) do
    Repo.get_by(Agent, id: agent_id, operator_id: operator_id)
  end

  @doc """
  Pulls an agent's live game record — credits, headquarters and faction — from
  the API.

  The server is the source of truth for an agent's current state; the local
  `Agent` row is the app's cached metadata and is used only as a fallback when
  the live read fails. Returns `{:ok, %SpaceTraders.API.Model.Agent{}}` or an
  API error. An agent without a stored AgentToken returns
  `{:error, :agent_token_missing}`.
  """
  def agent_overview(%Agent{agent_token: agent_token})
      when is_binary(agent_token) and agent_token != "" do
    SpaceTraders.API.get_agent(agent_token)
  end

  def agent_overview(%Agent{}), do: {:error, :agent_token_missing}

  @doc """
  Mints a new agent in the game on behalf of the operator.

  Calls `POST /register` with the operator's linked AccountToken and the chosen
  symbol + faction, then stores the resulting agent and its AgentToken
  (encrypted, per-agent) in the database.

  Returns `{:ok, %Agent{}}`, or one of:

    * `{:error, %Ecto.Changeset{}}` — invalid symbol/faction
    * `{:error, :account_token_not_linked}` — the operator has no AccountToken
    * `{:error, %SpaceTraders.API.Error{} | %SpaceTraders.API.GameplayError{}}` — API failure
  """
  def mint_agent(%Operator{} = operator, attrs) do
    changeset = Agent.changeset(%Agent{}, attrs)

    with :ok <- validate_mint_attrs(changeset),
         {:ok, account_token} <- require_account_token(operator) do
      case SpaceTraders.API.register(
             account_token,
             get_field(changeset, :symbol),
             get_field(changeset, :faction)
           ) do
        {:ok, %{token: agent_token, agent: %GameAgent{} = game_agent}} ->
          create_agent(operator, game_agent, agent_token, get_field(changeset, :faction))

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Imports an existing game agent after explicitly validating its AgentToken.

  The AccountToken cannot recover AgentTokens, so this flow never calls the
  registration endpoint. It reads the agent through the authenticated game API
  and stores the supplied token encrypted with the resulting metadata.
  """
  def import_agent(%Scope{operator: %Operator{} = operator}, agent_token, true)
      when is_binary(agent_token) and agent_token != "" do
    with {:ok, %GameAgent{} = game_agent} <- SpaceTraders.API.get_agent(agent_token),
         :ok <- ensure_agent_is_new(game_agent.symbol) do
      create_imported_agent(operator, game_agent, agent_token)
    end
  end

  def import_agent(_scope, _agent_token, false), do: {:error, :confirmation_required}
  def import_agent(_scope, _agent_token, _confirmed), do: {:error, :agent_token_required}

  defp ensure_agent_is_new(symbol) do
    if Repo.get_by(Agent, symbol: symbol), do: {:error, :agent_already_imported}, else: :ok
  end

  defp create_imported_agent(operator, game_agent, agent_token) do
    case create_agent(operator, game_agent, agent_token, game_agent.starting_faction) do
      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :symbol),
          do: {:error, :agent_already_imported},
          else: {:error, changeset}

      result ->
        result
    end
  end

  defp validate_mint_attrs(%{valid?: true}), do: :ok
  defp validate_mint_attrs(%{valid?: false} = changeset), do: {:error, changeset}

  defp require_account_token(%Operator{account_token: account_token})
       when is_binary(account_token) and account_token != "" do
    {:ok, account_token}
  end

  defp require_account_token(_operator), do: {:error, :account_token_not_linked}

  defp create_agent(operator, %GameAgent{} = game_agent, agent_token, requested_faction) do
    %Agent{}
    |> Agent.changeset(%{
      symbol: game_agent.symbol,
      faction: game_agent.starting_faction || requested_faction
    })
    |> Ecto.Changeset.put_change(:headquarters, game_agent.headquarters)
    |> Ecto.Changeset.put_change(:agent_token, agent_token)
    |> Ecto.Changeset.put_change(:operator_id, operator.id)
    |> Repo.insert()
  end

  @doc """
  Checks whether the operator is in sudo mode.

  The operator is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(operator, minutes \\ -20)

  def sudo_mode?(%Operator{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_operator, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the operator email.

  See `SpaceTraders.Agent.Operator.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_operator_email(operator)
      %Ecto.Changeset{data: %Operator{}}

  """
  def change_operator_email(operator, attrs \\ %{}, opts \\ []) do
    Operator.email_changeset(operator, attrs, opts)
  end

  @doc """
  Updates the operator email using the given token.

  If the token matches, the operator email is updated and the token is deleted.
  """
  def update_operator_email(operator, token) do
    context = "change:#{operator.email}"

    Repo.transact(fn ->
      with {:ok, query} <- OperatorToken.verify_change_email_token_query(token, context),
           %OperatorToken{sent_to: email} <- Repo.one(query),
           {:ok, operator} <- Repo.update(Operator.email_changeset(operator, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(
               from(OperatorToken, where: [operator_id: ^operator.id, context: ^context])
             ) do
        {:ok, operator}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the operator password.

  See `SpaceTraders.Agent.Operator.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_operator_password(operator)
      %Ecto.Changeset{data: %Operator{}}

  """
  def change_operator_password(operator, attrs \\ %{}, opts \\ []) do
    Operator.password_changeset(operator, attrs, opts)
  end

  @doc """
  Updates the operator password.

  Returns a tuple with the updated operator, as well as a list of expired tokens.

  ## Examples

      iex> update_operator_password(operator, %{password: ...})
      {:ok, {%Operator{}, [...]}}

      iex> update_operator_password(operator, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_operator_password(operator, attrs) do
    operator
    |> Operator.password_changeset(attrs)
    |> update_operator_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_operator_session_token(operator) do
    {token, operator_token} = OperatorToken.build_session_token(operator)
    Repo.insert!(operator_token)
    token
  end

  @doc """
  Gets the operator with the given signed token.

  If the token is valid `{operator, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_operator_by_session_token(token) do
    {:ok, query} = OperatorToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the operator with the given magic link token.
  """
  def get_operator_by_magic_link_token(token) do
    with {:ok, query} <- OperatorToken.verify_magic_link_token_query(token),
         {operator, _token} <- Repo.one(query) do
      operator
    else
      _ -> nil
    end
  end

  @doc """
  Logs the operator in by magic link.

  There are three cases to consider:

  1. The operator has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The operator has not confirmed their email and no password is set.
     In this case, the operator gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The operator has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_operator_by_magic_link(token) do
    {:ok, query} = OperatorToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%Operator{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%Operator{confirmed_at: nil} = operator, _token} ->
        operator
        |> Operator.confirm_changeset()
        |> update_operator_and_delete_all_tokens()

      {operator, token} ->
        Repo.delete!(token)
        {:ok, {operator, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given operator.

  ## Examples

      iex> deliver_operator_update_email_instructions(operator, current_email, &url(~p"/operators/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_operator_update_email_instructions(
        %Operator{} = operator,
        current_email,
        update_email_url_fun
      )
      when is_function(update_email_url_fun, 1) do
    {encoded_token, operator_token} =
      OperatorToken.build_email_token(operator, "change:#{current_email}")

    Repo.insert!(operator_token)

    OperatorNotifier.deliver_update_email_instructions(
      operator,
      update_email_url_fun.(encoded_token)
    )
  end

  @doc """
  Delivers the magic link login instructions to the given operator.
  """
  def deliver_login_instructions(%Operator{} = operator, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, operator_token} = OperatorToken.build_email_token(operator, "login")
    Repo.insert!(operator_token)
    OperatorNotifier.deliver_login_instructions(operator, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_operator_session_token(token) do
    Repo.delete_all(from(OperatorToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_operator_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, operator} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(OperatorToken, operator_id: operator.id)

        Repo.delete_all(
          from(t in OperatorToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id))
        )

        {:ok, {operator, tokens_to_expire}}
      end
    end)
  end
end
