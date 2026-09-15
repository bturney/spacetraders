defmodule SpaceTraders.FleetStrategyTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetStrategy

  test "presets disclose ordered objectives, Hard Constraints, Preferences, and consequences" do
    assert [preset | _] = FleetStrategy.presets()

    assert %{
             id: "steady_growth",
             objectives: [
               %{
                 "objective" => "Grow credits",
                 "evaluation" => "Maximize net credit growth over time"
               }
             ],
             hard_constraints: ["Keep at least 50,000 credits available"],
             preferences: ["Prefer lower-risk routes when expected returns are similar"],
             consequences: consequences
           } = preset

    assert consequences =~ "spend credits"
  end

  test "explicit activation snapshots the durable draft as an immutable revision" do
    scope = operator_fixture() |> Scope.for_operator()
    original = document("Grow credits", "Keep 50,000 credits available")
    recommendation = document("Chart waypoints", "Keep 75,000 credits available")

    assert {:ok, %{draft: ^original, active_revision: nil}} =
             FleetStrategy.save_draft(scope, original)

    assert {:ok, revision} = FleetStrategy.activate(scope)
    assert revision.number == 1
    assert revision.document == original

    assert {:ok, %{draft: ^recommendation, active_revision: active}} =
             FleetStrategy.recommend(scope, recommendation)

    assert active.id == revision.id
    assert active.document == original
    assert FleetStrategy.get(scope).active_revision.document == original
  end

  test "discarding a draft leaves the active revision unchanged" do
    scope = operator_fixture() |> Scope.for_operator()
    active_document = document("Grow credits", "Keep 50,000 credits available")

    assert {:ok, _draft} = FleetStrategy.save_draft(scope, active_document)
    assert {:ok, revision} = FleetStrategy.activate(scope)

    assert {:ok, _draft} =
             FleetStrategy.save_draft(scope, document("Chart waypoints", "No scrap"))

    assert {:ok, %{draft: nil, active_revision: active}} = FleetStrategy.discard_draft(scope)
    assert active.id == revision.id
    assert active.document == active_document
  end

  test "an Operator cannot read or activate another Operator's Fleet Strategy" do
    owner_scope = operator_fixture() |> Scope.for_operator()
    other_scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, _draft} =
             FleetStrategy.save_draft(owner_scope, document("Grow credits", "No scrap"))

    assert %{draft: nil, active_revision: nil} = FleetStrategy.get(other_scope)
    assert {:error, :draft_not_found} = FleetStrategy.activate(other_scope)
  end

  defp document(objective, constraint) do
    %{
      "objectives" => [%{"objective" => objective, "evaluation" => "Measure progress"}],
      "hard_constraints" => [constraint],
      "preferences" => ["Prefer efficient plans"]
    }
  end
end
