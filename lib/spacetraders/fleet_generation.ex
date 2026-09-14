defmodule SpaceTraders.FleetGeneration do
  @moduledoc """
  Owns the lifecycle of an Agent and its Fleet across Server Resets.

  AccountTokens cross this module only while dispatching registration. Callers
  identify the authenticated Operator through a tokenless scope; this module
  resolves the corresponding credential reference immediately before minting.
  """

  import Ecto.Changeset, only: [get_field: 2]
  import Ecto.Query, warn: false

  alias SpaceTraders.API.Model.Agent, as: GameAgent
  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Fleet.{Ship, ShipServer}
  alias SpaceTraders.{Repo, Timeline}

  defmodule CredentialReference do
    @moduledoc "A non-secret reference to an Operator's stored AccountToken."

    @enforce_keys [:operator_id]
    defstruct [:operator_id]
  end

  @doc "Mints a new Fleet Generation for the authenticated Operator."
  def mint(%Scope{operator: %Operator{id: operator_id}}, attrs) do
    changeset = Agent.changeset(%Agent{}, attrs)
    credential_ref = %CredentialReference{operator_id: operator_id}

    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- validate_mint_attrs(changeset),
         {:ok, operator, account_token} <- resolve_account_token(credential_ref),
         :ok <-
           ensure_symbol_is_not_stale_for_another_operator(
             operator,
             get_field(changeset, :symbol)
           ) do
      case SpaceTraders.API.register(
             account_token,
             get_field(changeset, :symbol),
             get_field(changeset, :faction),
             operator.email
           ) do
        {:ok, %{token: agent_token, agent: %GameAgent{} = game_agent}} ->
          replace_stale_agent_and_create(
            operator,
            game_agent,
            agent_token,
            get_field(changeset, :faction)
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Retires every Stale Agent owned by the authenticated Operator."
  def retire_stale_agents(%Scope{operator: %Operator{} = operator}) do
    with {:ok, {retired_symbols, ship_symbols}} <-
           Repo.transaction(fn ->
             operator
             |> detected_stale_agent_ids()
             |> Enum.map(&retire_stale_agent/1)
             |> Enum.unzip()
             |> then(fn {symbols, ships} -> {List.flatten(symbols), List.flatten(ships)} end)
           end) do
      Enum.each(ship_symbols, &ShipServer.stop/1)
      {:ok, retired_symbols}
    end
  end

  @doc "Pulls an Agent's live game record and records definitive Server Reset evidence."
  def agent_overview(%Agent{agent_token: agent_token} = agent)
      when is_binary(agent_token) and agent_token != "" do
    case SpaceTraders.API.get_agent(agent_token) do
      {:error, %SpaceTraders.API.GameplayError{} = error} = result ->
        if server_reset_mismatch?(error) do
          mark_stale(agent)
          {:error, :stale_agent}
        else
          result
        end

      result ->
        result
    end
  end

  def agent_overview(%Agent{}), do: {:error, :agent_token_missing}

  @doc "Returns whether the game has verified this Agent as stale after a Server Reset."
  def stale?(%Agent{stale_at: stale_at}), do: not is_nil(stale_at)

  @doc "Fences execution against an Agent retired or invalidated by a Server Reset."
  def execution_allowed?(%Agent{} = agent) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?() do
      agent_execution_allowed?(agent)
    end
  end

  @doc "Converts a reset mismatch from any game call into the durable stale state."
  def handle_game_result(%Agent{} = agent, {:error, error}) do
    if server_reset_mismatch?(error) do
      mark_stale(agent)
      {:error, :stale_agent}
    else
      {:error, error}
    end
  end

  def handle_game_result(_agent, result), do: result

  defp resolve_account_token(%CredentialReference{operator_id: operator_id}) do
    case Repo.get(Operator, operator_id) do
      %Operator{account_token: account_token} = operator
      when is_binary(account_token) and account_token != "" ->
        {:ok, operator, account_token}

      _ ->
        {:error, :account_token_not_linked}
    end
  end

  defp validate_mint_attrs(%{valid?: true}), do: :ok
  defp validate_mint_attrs(%{valid?: false} = changeset), do: {:error, changeset}

  defp ensure_symbol_is_not_stale_for_another_operator(%Operator{id: operator_id}, symbol) do
    case Repo.get_by(Agent, symbol: symbol) do
      %Agent{operator_id: ^operator_id} ->
        :ok

      %Agent{stale_at: stale_at} when not is_nil(stale_at) ->
        {:error, :stale_symbol_owned_elsewhere}

      _ ->
        :ok
    end
  end

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

  defp replace_stale_agent_and_create(operator, game_agent, agent_token, faction) do
    with {:ok, {agent, retired_symbols, ship_symbols}} <-
           Repo.transaction(fn ->
             {retired_symbols, ship_symbols} =
               operator
               |> stale_agent_ids(game_agent.symbol)
               |> Enum.map(&retire_stale_agent/1)
               |> Enum.unzip()
               |> then(fn {symbols, ships} -> {List.flatten(symbols), List.flatten(ships)} end)

             case create_agent(operator, game_agent, agent_token, faction) do
               {:ok, agent} -> {agent, retired_symbols, ship_symbols}
               {:error, changeset} -> Repo.rollback(changeset)
             end
           end) do
      Enum.each(ship_symbols, &ShipServer.stop/1)
      {:ok, %{agent: %{agent | agent_token: nil}, retired_symbols: retired_symbols}}
    end
  end

  defp stale_agent_ids(%Operator{id: operator_id}, symbol) do
    same_symbol_id =
      Repo.one(
        from(agent in Agent,
          where: agent.operator_id == ^operator_id and agent.symbol == ^symbol,
          select: agent.id
        )
      )

    [same_symbol_id | detected_stale_agent_ids(operator_id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp detected_stale_agent_ids(%Operator{id: operator_id}),
    do: detected_stale_agent_ids(operator_id)

  defp detected_stale_agent_ids(operator_id) do
    Repo.all(
      from(agent in Agent,
        where: agent.operator_id == ^operator_id and not is_nil(agent.stale_at),
        select: agent.id
      )
    )
  end

  defp retire_stale_agent(stale_agent_id) do
    stale_agent = Repo.get!(Agent, stale_agent_id)

    ship_symbols =
      Repo.all(from(ship in Ship, where: ship.agent_id == ^stale_agent.id, select: ship.symbol))

    Enum.each(ship_symbols, &Timeline.cancel_events(:ship, &1))
    Repo.delete!(stale_agent)
    {[stale_agent.symbol], ship_symbols}
  end

  defp mark_stale(%Agent{} = agent) do
    agent
    |> Ecto.Changeset.change(stale_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  defp agent_execution_allowed?(%Agent{id: nil}), do: :ok

  defp agent_execution_allowed?(%Agent{id: id}) do
    case Repo.get(Agent, id) do
      %Agent{stale_at: nil} -> :ok
      _ -> {:error, :stale_agent}
    end
  end

  defp server_reset_mismatch?(%SpaceTraders.API.GameplayError{message: message}) do
    Regex.match?(
      ~r/^Failed to parse token\. Token reset_date does not match the server\. Server resets happen .+ After a reset, you should re-register your agent\. Expected: \d{4}-\d{2}-\d{2}, Actual: \d{4}-\d{2}-\d{2}$/,
      message
    )
  end

  defp server_reset_mismatch?(_error), do: false
end
