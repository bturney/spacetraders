defmodule SpaceTraders.Fleet.Intents do
  @moduledoc "The public seam for durable, caller-owned Intent execution."

  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.Fleet
  alias SpaceTraders.Repo

  defmodule Navigate do
    @moduledoc "A closed Navigate goal for a Ship."
    defstruct [:waypoint, parameters: %{}]
  end

  defmodule ManualControl do
    @moduledoc "Manual Control ownership for an Intent."
    defstruct []
  end

  defmodule JobOwner do
    @moduledoc "Job ownership for an Intent."
    defstruct [:job]
  end

  @unfinished_states Intent.unfinished_states()
  @terminal_states Intent.terminal_states()

  @doc "Requests a closed operational goal for Manual Control or a Job."
  def request(agent, owner, ship_symbol, %Navigate{} = goal) do
    with :ok <- token_present(agent),
         {:ok, owner} <- normalize_owner(owner),
         :ok <- valid_goal_parameters(goal.parameters),
         {:ok, waypoint} <- valid_goal_waypoint(goal.waypoint) do
      case owner do
        :manual ->
          Fleet.navigate_intent_legacy(agent, ship_symbol, waypoint, goal.parameters)

        %JobOwner{job: %Job{type: type} = job} when type in ["procurement", "market_trading"] ->
          Fleet.request_job_navigate_legacy(agent, job, ship_symbol, waypoint, goal.parameters)

        %JobOwner{} ->
          {:error, :unsupported_job_navigate}
      end
    end
  end

  def request(_agent, _owner, _ship_symbol, _goal), do: {:error, :unsupported_intent_goal}

  @doc "Persists a reviewed Navigate Intent without dispatching a mutation."
  def review(agent, owner, ship_symbol, waypoint, preview) when is_map(preview) do
    with {:ok, :manual} <- normalize_owner(owner) do
      Fleet.review_navigation_intent(agent, ship_symbol, waypoint, preview)
    end
  end

  def review(_agent, _owner, _ship_symbol, _waypoint, _preview),
    do: {:error, :unsupported_intent_review}

  @doc "Persists a blocked Navigate Intent after preview rejects the route."
  def block_review(agent, owner, ship_symbol, waypoint, reason) do
    with {:ok, :manual} <- normalize_owner(owner) do
      Fleet.block_jump_preview(agent, ship_symbol, waypoint, reason)
    end
  end

  @doc "Confirms a persisted reviewed Navigate Intent by identity and revision."
  def confirm(agent, owner, intent_id, review_revision) do
    with {:ok, :manual} <- normalize_owner(owner) do
      Fleet.confirm_navigation_intent(agent, intent_id, review_revision)
    end
  end

  @doc "Stops one owned Intent without hiding unresolved mutation evidence."
  def stop(agent, owner, intent_id) do
    with {:ok, owner} <- normalize_owner(owner),
         %Intent{} = intent <- owned_intent(agent, intent_id),
         :ok <- owner_matches?(owner, intent) do
      Fleet.stop_intent_legacy(agent, intent_id, owner)
    else
      nil -> {:error, :intent_not_found}
      error -> error
    end
  end

  @doc "Re-enters the shared reconciliation path for a fresh Ship observation."
  def reconcile(agent, ship_symbol, live_ship, expected_intent_id) do
    Fleet.revalidate_intents_arrival(agent.id, ship_symbol, live_ship, expected_intent_id)
  end

  defp normalize_owner(:manual), do: {:ok, :manual}
  defp normalize_owner(%ManualControl{}), do: {:ok, :manual}
  defp normalize_owner(%JobOwner{job: %Job{} = job}), do: {:ok, %JobOwner{job: job}}
  defp normalize_owner(%Job{} = job), do: {:ok, %JobOwner{job: job}}
  defp normalize_owner(_owner), do: {:error, :invalid_intent_owner}

  defp token_present(%AgentRecord{agent_token: token}) when is_binary(token) and token != "",
    do: :ok

  defp token_present(_agent), do: {:error, :agent_token_missing}

  defp valid_goal_waypoint(waypoint) when is_binary(waypoint) do
    case String.trim(waypoint) do
      "" -> {:error, :invalid_waypoint}
      waypoint -> {:ok, waypoint}
    end
  end

  defp valid_goal_waypoint(_waypoint), do: {:error, :invalid_waypoint}

  defp valid_goal_parameters(parameters) when is_map(parameters), do: :ok
  defp valid_goal_parameters(_parameters), do: {:error, :invalid_intent_parameters}

  defp owner_matches?(:manual, %Intent{caller: "manual"}), do: :ok

  defp owner_matches?(%JobOwner{job: %Job{id: job_id}}, %Intent{caller: "job", job_id: job_id}),
    do: :ok

  defp owner_matches?(_owner, _intent), do: {:error, :invalid_intent_owner}

  defp owned_intent(%AgentRecord{id: agent_id}, intent_id) do
    Repo.one(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: intent.id == ^intent_id and ship.agent_id == ^agent_id
    )
  end

  @doc "Lists unfinished Intents for all Ships owned by the Agent."
  def current(%AgentRecord{id: agent_id}) do
    Repo.all(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: ship.agent_id == ^agent_id and intent.status in ^@unfinished_states,
        order_by: [asc: intent.id]
    )
  end

  @doc "Lists completed and stopped Intents for all Ships owned by the Agent."
  def history(%AgentRecord{id: agent_id}) do
    Repo.all(
      from intent in Intent,
        join: ship in Ship,
        on: ship.id == intent.ship_id,
        where: ship.agent_id == ^agent_id and intent.status in ^@terminal_states,
        order_by: [desc: intent.finished_at, desc: intent.id]
    )
  end
end
