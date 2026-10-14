defmodule SpaceTraders.CreditFloorWatch do
  @moduledoc """
  Eager credit-floor revalidation (ADR 0013, #579).

  Any authoritative balance below the active credit floor pauses new
  credit-bearing admission when it is observed, not only when the next spend
  is attempted, and activating a Strategy revision revalidates the new floor
  at once. Both record or release Shortfalls through
  `CreditCalibration.spending_pause/4` under the Agent spending lock, so the
  classification (revision floor, unattributable, non-pricing) matches the
  admission checkpoint's. Nothing here spends, sells, recalibrates, or raises
  Attention; unsent work is still refused at its own send boundary.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.{CreditCalibration, CreditSpending, Repo}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority, Strategy}

  @doc """
  Revalidates one Agent's latest authoritative balance against its active
  floor. Skipped inside a caller's transaction so it never takes the Agent
  lock out of order.
  """
  def observe(%Agent{} = agent) do
    if Repo.in_transaction?(), do: :skipped, else: revalidate(agent)
  end

  @doc "Revalidates only the published Fleet after a Revision activates."
  def revalidate_current do
    agent =
      Repo.one(
        from a in Agent,
          join: g in Generation,
          on: g.agent_id == a.id,
          join: i in "current_fleet_identity",
          on: i.id == 1 and i.fleet_generation_id == g.id,
          where:
            is_nil(g.fenced_at) and is_nil(g.retired_at) and
              is_nil(a.stale_at)
      )

    if agent, do: observe(agent)
    :ok
  end

  defp revalidate(agent) do
    {:ok, result} =
      Repo.transaction(fn ->
        CreditSpending.lock_agent(agent.id)

        with %Revision{} = revision <- active_revision(agent),
             {:ok, credits} <- CreditSpending.authoritative_credits(agent) do
          CreditCalibration.spending_pause(agent, credits, credit_floor(revision), revision)
        else
          _ -> :no_authoritative_floor
        end
      end)

    result
  end

  defp active_revision(_agent) do
    Repo.one(
      from r in Revision,
        join: s in Strategy,
        on: s.active_revision_id == r.id
    )
  end

  defp credit_floor(revision) do
    case StandingAuthority.credit_floor(revision) do
      {:ok, floor} -> floor
      _ -> 0
    end
  end
end
