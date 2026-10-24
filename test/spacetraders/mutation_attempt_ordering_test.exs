defmodule SpaceTraders.MutationAttemptOrderingTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Fleet.Intent

  @same_tick ~U[2026-10-22 00:00:00.000000Z]
  @first_id "ffffffff-ffff-4fff-8fff-ffffffffffff"
  @second_id "00000000-0000-4000-8000-000000000001"

  test "latest registration preserves insertion order when game timestamps tie and UUID order disagrees" do
    operator = operator_fixture()
    first = attempt(@first_id, operator_id: operator.id, state: "rejected")
    second = attempt(@second_id, operator_id: operator.id, state: "succeeded")
    assert first.prepared_at == second.prepared_at
    assert MutationAttempts.latest_registration(operator.id).id == second.id
  end

  test "Ship history and latest recovery attempt retain causal order within one game-clock tick" do
    agent = operator_fixture() |> agent_fixture()
    intent = %Intent{id: 17}
    provenance = %{"intent_id" => intent.id, "selected_action_fingerprint" => nil}

    first =
      attempt(@first_id,
        agent_id: agent.id,
        operation_id: "purchase-cargo",
        state: "rejected",
        provenance: provenance
      )

    second =
      attempt(@second_id,
        agent_id: agent.id,
        operation_id: "install-ship-module",
        state: "succeeded",
        provenance: provenance
      )

    assert Enum.map(MutationAttempts.list_for_agent(agent), & &1.id) == [first.id, second.id]
    assert MutationAttempts.latest_for_intent(intent).id == second.id
  end

  defp attempt(id, attrs) do
    attrs = Map.new(attrs)

    Repo.insert!(
      struct!(
        Attempt,
        Map.merge(
          %{
            id: id,
            operation_id: "register",
            operation_owner: "registration",
            state: "prepared",
            request_fingerprint: id,
            prepared_evidence: %{},
            expected_effects: [],
            consequence_bounds: [],
            provenance: %{},
            prepared_at: @same_tick,
            inserted_at: @same_tick,
            updated_at: @same_tick
          },
          attrs
        )
      )
    )
  end
end
