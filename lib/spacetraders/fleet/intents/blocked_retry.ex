defmodule SpaceTraders.Fleet.Intents.BlockedRetry do
  @moduledoc """
  The durable retry of a blocked execution step (#767).

  Entering `blocked` stores `next_attempt_at` and schedules one `:intent_retry`
  Timeline event for that moment; the Ship's server re-enters the shared Intent
  reconciliation then, exactly as boot recovery does. Each retry that finds the
  step still blocked counts one more retry and doubles the wait, from one
  minute up to fifteen. Leaving `blocked` clears both. Entering and leaving stamp `blocked_at` and
  `recovered_at`, which feed Glance's Just happened events.

  The Timeline event commits with the Intent. The Ship server is armed only
  outside a transaction: inside one, the arm waits until the caller's
  transaction returns (`flush/0`). A missed arm is still rearmed on boot.
  """

  alias SpaceTraders.Clock
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Ship, ShipServer}
  alias SpaceTraders.Repo
  alias SpaceTraders.Timeline

  @first_wait_seconds 60
  @max_wait_seconds 15 * 60
  @pending {__MODULE__, :pending}

  @doc "Seconds before the retry after `retries` earlier retries."
  def wait_seconds(retries),
    do: min(@first_wait_seconds * Integer.pow(2, retries), @max_wait_seconds)

  @doc "Adds the retry fields an Intent update implies."
  def changes(%Ecto.Changeset{data: %Intent{} = before} = changeset) do
    case Ecto.Changeset.get_field(changeset, :status) do
      "blocked" when before.status == "blocked" ->
        if retried?(changeset),
          do: put_next(changeset, (before.retries || 0) + 1),
          else: changeset

      "blocked" ->
        changeset
        |> put_next(0)
        |> Ecto.Changeset.change(blocked_at: now(), blocked_reason: reason(changeset))

      status when before.status == "blocked" ->
        changeset
        |> Ecto.Changeset.change(next_attempt_at: nil, retries: 0)
        |> recovered(status)

      _ ->
        changeset
    end
  end

  defp reason(changeset) do
    case Ecto.Changeset.get_field(changeset, :blocker) do
      %{summary: summary} when is_binary(summary) and summary != "" -> summary
      %{reason: reason} when is_binary(reason) -> reason |> String.replace("_", " ")
      _ -> nil
    end
  end

  # Getting going again (not ending as failed) is a recovery.
  defp recovered(changeset, status) when status in ["infeasible", "stopped", "superseded"],
    do: changeset

  defp recovered(changeset, _status), do: Ecto.Changeset.change(changeset, recovered_at: now())

  defp now, do: Clock.utc_now() |> DateTime.truncate(:second)

  # A step re-blocked by any write while blocked is a retry that failed again.
  defp retried?(changeset), do: changeset.changes != %{}

  defp put_next(changeset, retries) do
    next = Clock.utc_now() |> DateTime.add(wait_seconds(retries)) |> DateTime.truncate(:second)
    Ecto.Changeset.change(changeset, next_attempt_at: next, retries: retries)
  end

  @doc "Schedules the retry an updated Intent stores, if its `next_attempt_at` changed."
  def schedule(%Intent{next_attempt_at: nil}, _before), do: :ok
  def schedule(%Intent{next_attempt_at: at}, %Intent{next_attempt_at: at}), do: :ok

  def schedule(%Intent{status: "blocked", next_attempt_at: at} = intent, _before) do
    ship = Repo.get!(Ship, intent.ship_id)

    {:ok, event} =
      Timeline.schedule_event(:ship, ship.symbol, :intent_retry, at, %{"intent_id" => intent.id})

    arm = {ship.symbol, event}

    if Repo.in_transaction?(),
      do: Process.put(@pending, [arm | Process.get(@pending, [])]),
      else: arm(arm)

    :ok
  end

  def schedule(_intent, _before), do: :ok

  @doc "Arms retries scheduled inside a now-finished transaction."
  def flush do
    unless Repo.in_transaction?() do
      @pending |> Process.delete() |> List.wrap() |> Enum.reverse() |> Enum.each(&arm/1)
    end

    :ok
  end

  defp arm({symbol, event}) do
    with {:ok, agent} <- Fleet.ship_agent(symbol) do
      ShipServer.arm(agent, symbol, event)
    end
  end
end
