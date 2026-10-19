defmodule SpaceTraders.MissionControl.PlanHealthReadTest do
  @moduledoc """
  Plan Health read from stored facts (#769) on the scenario seeds (#768).
  Seam: `MissionControl.PlanHealth.read/2`.
  """
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.{Liveness, ScenarioSeeds}
  alias SpaceTraders.MissionControl.PlanHealth

  setup do
    Liveness.reset()
    :ok
  end

  defp read(seeded) do
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    PlanHealth.read(Scope.for_operator(operator), seeded.now)
  end

  for {situation, ships, state} <- [
        {:healthy, 2, :on},
        {:healthy, 120, :on},
        {:busy_not_earning, 2, :setback},
        {:busy_not_earning, 120, :setback},
        {:waiting, 2, :on},
        {:waiting, 120, :on},
        {:stuck, 2, :off},
        {:stuck, 120, :off}
      ] do
    test "#{situation} at #{ships} Ships reads #{state}" do
      health = read(ScenarioSeeds.seed(unquote(situation), unquote(ships)))
      assert health.state == unquote(state), health.reason
    end
  end

  test "a waiting Fleet says when it checks again" do
    health = read(ScenarioSeeds.seed(:waiting, 2))
    assert health.reason =~ "Waiting on purpose for a trade worth making; next check"
  end

  test "old information names the Ships that have not reported" do
    health = read(ScenarioSeeds.seed(:old_information, 120))
    ships = Enum.find(health.checks, &(&1.name == :ships_moving))
    assert ships.detail =~ "30 Ships have not reported since"
  end
end
