defmodule SpaceTraders.IntentChangeBroadcastTest do
  @moduledoc """
  Intent change prompts reach readers only after the change commits, so a
  reader re-reading at once sees it. Seam: `Fleet.subscribe_intent_changes/0`
  over `Intents.transition_intent/2`.
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.CreditSpendingFixtures

  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intents

  setup do
    {_agent, [intent], _portfolio} = claimed_purchases([0])
    Fleet.subscribe_intent_changes()
    %{intent: intent}
  end

  test "a status change inside a transaction is announced after it commits", %{intent: intent} do
    ship_id = intent.ship_id

    Repo.transaction(fn ->
      assert {:ok, _} = Intents.transition_intent(intent, status: "waiting")
      refute_received {:intent_changed, _}
    end)

    assert_receive {:intent_changed, ^ship_id}
  end

  test "a rolled-back status change is never announced", %{intent: intent} do
    Repo.transaction(fn ->
      assert {:ok, _} = Intents.transition_intent(intent, status: "waiting")
      Repo.rollback(:undo)
    end)

    refute_receive {:intent_changed, _}, 100
  end

  test "a status change on its own is announced", %{intent: intent} do
    ship_id = intent.ship_id
    assert {:ok, _} = Intents.transition_intent(intent, status: "waiting")
    assert_receive {:intent_changed, ^ship_id}
  end
end
