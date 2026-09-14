defmodule SpaceTraders.CutoverTest do
  use SpaceTraders.DataCase

  alias SpaceTraders.Agent.{Agent, Operator}
  alias SpaceTraders.Cutover
  alias SpaceTraders.Fleet.{Intent, JobBlocker, Ship}

  test "refuses cutover while admitted mutations are neither settled nor safety-fenced" do
    intent = insert_intent!("active", nil)

    Repo.update_all(Intent, set: [in_flight_action: %{"kind" => "navigate"}])

    assert {:error, {:unprotected_mutations, %{intents: 1, jobs: 0}}} = Cutover.assess()

    fence_intent!(intent, "ordinary_blocker")

    assert {:error, {:unprotected_mutations, %{intents: 1, jobs: 0}}} = Cutover.assess()

    Repo.delete!(Repo.reload!(intent))
    intent = insert_intent!("active", nil)

    Repo.update_all(from(record in Intent, where: record.id == ^intent.id),
      set: [in_flight_action: %{"kind" => "navigate"}]
    )

    fence_intent!(intent, "ambiguous_unrecognized")

    assert {:error, {:unprotected_mutations, %{intents: 1, jobs: 0}}} = Cutover.assess()

    Repo.delete!(Repo.reload!(intent))
    intent = insert_intent!("active", nil)

    Repo.update_all(from(record in Intent, where: record.id == ^intent.id),
      set: [in_flight_action: %{"kind" => "navigate"}]
    )

    fence_intent!(intent, "mutation_outcome_unknown")

    assert :ok = Cutover.assess()
  end

  defp fence_intent!(intent, reason) do
    intent = Repo.reload!(intent)

    blocker =
      if intent.blocker do
        Ecto.Changeset.change(intent.blocker, reason: reason)
      else
        %JobBlocker{
          reason: reason,
          summary: "Authoritative reconciliation is required",
          evidence: "intent_id=#{intent.id}",
          retry_condition: "authoritative_mutation_outcome_available"
        }
      end

    intent
    |> Ecto.Changeset.change(status: "blocked")
    |> Ecto.Changeset.put_embed(:blocker, blocker)
    |> Repo.update!()
  end

  defp insert_intent!(status, blocker) do
    suffix = System.unique_integer([:positive])
    operator = Repo.insert!(%Operator{email: "cutover-#{System.unique_integer()}@example.test"})

    agent =
      Repo.insert!(%Agent{
        symbol: "CUTOVER-#{suffix}",
        faction: "COSMIC",
        headquarters: "X1-TEST-A1",
        operator_id: operator.id
      })

    ship =
      Repo.insert!(%Ship{
        symbol: "CUTOVER-#{suffix}-1",
        ship_type: "SHIP_PROBE",
        agent_id: agent.id
      })

    Repo.insert!(%Intent{
      ship_id: ship.id,
      type: "navigate",
      target_waypoint: "X1-TEST-A1",
      status: status,
      blocker: blocker
    })
  end
end
