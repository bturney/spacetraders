defmodule SpaceTraders.CreditFloorWatchTest do
  @moduledoc """
  Any authoritative balance below the active credit floor pauses new
  credit-bearing admission when it is observed, and Strategy revision
  activation revalidates the floor at once (#579, ADR 0013).
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.CreditSpendingFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.CreditCalibration
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.OperatorConditions
  alias SpaceTraders.TestClock

  setup do
    start_supervised!({TestClock, DateTime.utc_now()})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    :ok
  end

  test "an idle Agent observed below the floor pauses spending before any spend is attempted" do
    {agent, _intents, _portfolio} = claimed_purchases([0])
    initial = CreditCalibration.active()
    stub_quote(agent, 10, 900)

    assert {:ok, %{credits: 900}} = SpaceTraders.Agent.agent_overview(agent)

    assert [%{kind: "non_pricing_shortfall", credits: 900, credit_floor: 1_000, released_at: nil}] =
             CreditCalibration.shortfalls(agent)

    # Pausing is scoped to spending: no recalibration and no Attention.
    assert CreditCalibration.active().id == initial.id
    assert OperatorConditions.unresolved(scope(agent)) == []

    # A newer authoritative balance at the floor releases the pause.
    TestClock.advance(1)
    stub_quote(agent, 10, 1_000)
    assert {:ok, %{credits: 1_000}} = SpaceTraders.Agent.agent_overview(agent)
    assert [%{released_at: %DateTime{}}] = CreditCalibration.shortfalls(agent)
  end

  test "activating a revision that raises the floor above credits pauses as a revision shortfall" do
    {agent, _intents, _portfolio} = claimed_purchases([0])
    stub_quote(agent, 10, 1_500)
    assert {:ok, %{credits: 1_500}} = SpaceTraders.Agent.agent_overview(agent)
    assert CreditCalibration.shortfalls(agent) == []

    scope = scope(agent)
    %{draft_version: version} = FleetStrategy.get(scope)

    {:ok, %{draft_version: version}} =
      FleetStrategy.save_draft(
        scope,
        %{
          "objectives" => [
            %{
              "objective" => "Grow credits",
              "kind" => "continuous",
              "evaluation" => "Net credits",
              "scope" => "recurring"
            }
          ],
          "hard_constraints" => ["Keep at least 2,000 credits available"],
          "preferences" => [],
          "consequences" => "Spending pauses below the raised floor."
        },
        version
      )

    assert {:ok, _revision} = FleetStrategy.activate(scope, version)

    assert [%{kind: "revision_floor", credits: 1_500, credit_floor: 2_000, released_at: nil}] =
             CreditCalibration.shortfalls(agent)
  end

  defp scope(agent),
    do: Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
end
