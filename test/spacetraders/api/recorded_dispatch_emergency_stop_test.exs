defmodule SpaceTraders.API.RecordedDispatchEmergencyStopTest do
  # Emergency Stop dispatch admission is backed by an application-wide cache.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RecordedDispatchFixtures

  alias SpaceTraders.API
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.MutationAttempts

  test "an Emergency Stop refuses recorded dispatch before any Revision check" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    assert {:ok, _} = SpaceTraders.FleetStrategy.engage_emergency_stop(scope)

    Req.Test.stub(API, fn _ -> flunk("dispatched under Emergency Stop") end)

    assert %{error: {:error, :emergency_stopped}} =
             prepare_action(agent, "STOPPED", %{"kind" => "orbit", "waypoint" => "X1-TEST-A1"})

    assert MutationAttempts.list_for_agent(agent) == []
  end
end
