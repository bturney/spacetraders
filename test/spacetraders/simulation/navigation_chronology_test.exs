defmodule SpaceTraders.Simulation.NavigationChronologyTest do
  use SpaceTraders.DataCase, async: false
  import SpaceTraders.AgentFixtures
  alias SpaceTraders.{MutationAttempts, Clock}
  alias SpaceTraders.Simulation.NavigationClock

  test "navigation attempt selection, send and outcome use the supported semantic instant" do
    previous = Application.get_env(:spacetraders, :clock)
    start_supervised!({NavigationClock, epoch: ~U[2026-01-01 00:00:00.000Z]})
    Application.put_env(:spacetraders, :clock, NavigationClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    agent = agent_fixture(operator_fixture())
    operation = SpaceTraders.API.OperationInventory.fetch!("navigate-ship")

    {:ok, attempt} =
      MutationAttempts.prepare(operation, "/my/ships/TEST-1/navigate",
        agent_id: agent.id,
        json: %{waypointSymbol: "X1-TEST-A2"}
      )

    assert attempt.prepared_at == Clock.utc_now()
    {:ok, sent} = MutationAttempts.mark_sent_or_unknown(attempt)
    assert sent.sent_or_unknown_at == Clock.utc_now()
    {:ok, completed} = MutationAttempts.record_outcome(sent, :succeeded, %{"status" => 200})
    assert Enum.all?(completed.outcomes, &(&1.recorded_at == Clock.utc_now()))
  end
end
