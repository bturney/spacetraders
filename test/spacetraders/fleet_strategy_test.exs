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
                 "kind" => "continuous",
                 "evaluation" => "Maximize net credit growth over time",
                 "scope" => "recurring"
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
             save_draft(scope, original)

    assert {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
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

    assert {:ok, _draft} = save_draft(scope, active_document)
    assert {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert {:ok, _draft} =
             save_draft(scope, document("Chart waypoints", "No scrap"))

    assert {:ok, %{draft: nil, active_revision: active}} =
             FleetStrategy.discard_draft(scope, FleetStrategy.get(scope).draft_version)

    assert active.id == revision.id
    assert active.document == active_document
  end

  test "an Operator cannot read or activate another Operator's Fleet Strategy" do
    owner_scope = operator_fixture() |> Scope.for_operator()
    other_scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, _draft} =
             save_draft(owner_scope, document("Grow credits", "No scrap"))

    assert %{draft: nil, active_revision: nil} = FleetStrategy.get(other_scope)
    assert {:error, :draft_not_found} = FleetStrategy.activate(other_scope, 0)
  end

  test "preset selection cannot silently replace an existing draft" do
    scope = operator_fixture() |> Scope.for_operator()
    original = document("Grow credits", "No scrap")

    assert {:ok, _draft} = save_draft(scope, original)
    assert {:error, :draft_exists} = FleetStrategy.select_preset(scope, "steady_growth")
    assert FleetStrategy.get(scope).draft == original
  end

  test "documents reject credential fields and incomplete Strategic Objectives" do
    scope = operator_fixture() |> Scope.for_operator()

    assert {:error, :invalid_document} =
             save_draft(
               scope,
               Map.put(document("Grow credits", "No scrap"), "account_token", "secret")
             )

    assert {:ok, _draft} =
             save_draft(scope, %{
               "objectives" => [%{"objective" => "Grow credits"}],
               "hard_constraints" => ["No scrap"],
               "preferences" => [],
               "consequences" => "Not yet specified"
             })

    assert {:error, :invalid_document} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
  end

  test "activation rejects a stale draft version" do
    scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, first} = save_draft(scope, document("Grow credits", "No scrap"))

    assert {:ok, current} =
             save_draft(scope, document("Chart waypoints", "No scrap"))

    assert current.draft_version > first.draft_version
    assert {:error, :stale_draft} = FleetStrategy.activate(scope, first.draft_version)
    assert FleetStrategy.get(scope).active_revision == nil
  end

  test "draft edits and discard reject a stale draft version" do
    scope = operator_fixture() |> Scope.for_operator()
    original = document("Grow credits", "No scrap")
    current = document("Chart waypoints", "No scrap")

    assert {:ok, first} = save_draft(scope, original)
    assert {:ok, latest} = FleetStrategy.save_draft(scope, current, first.draft_version)

    assert {:error, :stale_draft} =
             FleetStrategy.save_draft(scope, original, first.draft_version)

    assert {:error, :stale_draft} =
             FleetStrategy.discard_draft(scope, first.draft_version)

    assert FleetStrategy.get(scope).draft == current
    assert FleetStrategy.get(scope).draft_version == latest.draft_version
  end

  defp document(objective, constraint) do
    %{
      "objectives" => [
        %{
          "objective" => objective,
          "kind" => "continuous",
          "evaluation" => "Measure progress",
          "scope" => "recurring"
        }
      ],
      "hard_constraints" => [constraint],
      "preferences" => ["Prefer efficient plans"],
      "consequences" => "The Fleet will pursue the listed outcomes within every Hard Constraint."
    }
  end

  defp save_draft(scope, document) do
    FleetStrategy.save_draft(scope, document, FleetStrategy.get(scope).draft_version)
  end
end
