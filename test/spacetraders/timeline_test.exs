defmodule SpaceTraders.TimelineTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  describe "schedule_event/5" do
    test "persists a pending event for the given owner" do
      due_at = DateTime.add(DateTime.utc_now(), 300, :second)

      assert {:ok, %Event{} = event} =
               Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, due_at, %{
                 destination: "X1-UX81-A2"
               })

      assert event.owner_type == "ship"
      assert event.owner_id == "ORBITALIST-1"
      assert event.event_type == "arrival"
      assert event.status == "pending"
      assert event.due_at == due_at
      assert event.payload == %{destination: "X1-UX81-A2"}
    end

    test "cancels the outstanding pending event of the same owner and type" do
      {:ok, first} =
        Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())

      assert [_] = Timeline.pending_events(:ship, "ORBITALIST-1")

      {:ok, second} =
        Timeline.schedule_event(
          :ship,
          "ORBITALIST-1",
          :arrival,
          DateTime.add(DateTime.utc_now(), 300, :second)
        )

      assert Timeline.pending_events(:ship, "ORBITALIST-1") == [second]
      assert Repo.get(Event, first.id).status == "cancelled"
    end

    test "keeps pending events of other types and owners" do
      {:ok, arrival} =
        Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())

      {:ok, other} =
        Timeline.schedule_event(:ship, "ORBITALIST-2", :arrival, DateTime.utc_now())

      {:ok, cooldown} =
        Timeline.schedule_event(
          :ship,
          "ORBITALIST-1",
          :cooldown,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      assert Enum.map(Timeline.pending_events(:ship, "ORBITALIST-1"), & &1.id) |> Enum.sort() ==
               Enum.sort([arrival.id, cooldown.id])

      assert [%Event{id: id}] = Timeline.pending_events(:ship, "ORBITALIST-2")
      assert id == other.id
    end
  end

  describe "cancel_events/3" do
    test "cancels pending events for the owner" do
      {:ok, arrival} =
        Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())

      {:ok, cooldown} =
        Timeline.schedule_event(
          :ship,
          "ORBITALIST-1",
          :cooldown,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      :ok = Timeline.cancel_events(:ship, "ORBITALIST-1")

      assert Timeline.pending_events(:ship, "ORBITALIST-1") == []
      assert Repo.get(Event, arrival.id).status == "cancelled"
      assert Repo.get(Event, cooldown.id).status == "cancelled"
    end

    test "only cancels events of the given type" do
      {:ok, arrival} =
        Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())

      {:ok, cooldown} =
        Timeline.schedule_event(
          :ship,
          "ORBITALIST-1",
          :cooldown,
          DateTime.add(DateTime.utc_now(), 60, :second)
        )

      :ok = Timeline.cancel_events(:ship, "ORBITALIST-1", :cooldown)

      assert [%Event{id: id}] = Timeline.pending_events(:ship, "ORBITALIST-1")
      assert id == arrival.id
      assert Repo.get(Event, cooldown.id).status == "cancelled"
    end

    test "does not touch events that already fired" do
      {:ok, event} =
        Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())

      :ok = Timeline.fire_event(event)
      :ok = Timeline.cancel_events(:ship, "ORBITALIST-1")

      assert Repo.get(Event, event.id).status == "done"
    end
  end

  describe "pending_events/2" do
    test "returns pending events soonest first, skipping done and cancelled" do
      later = DateTime.add(DateTime.utc_now(), 300, :second)
      sooner = DateTime.add(DateTime.utc_now(), 60, :second)

      {:ok, first} = Timeline.schedule_event(:ship, "ORBITALIST-1", :cooldown, later)
      {:ok, second} = Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, sooner)

      assert Timeline.pending_events(:ship, "ORBITALIST-1") == [second, first]

      :ok = Timeline.fire_event(second)

      assert [%Event{id: id}] = Timeline.pending_events(:ship, "ORBITALIST-1")
      assert id == first.id
    end

    test "returns an empty list when there are no pending events" do
      assert Timeline.pending_events(:ship, "ORBITALIST-1") == []
    end
  end

  describe "pending_owners/1" do
    test "lists distinct owners with at least one pending event" do
      Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())
      Timeline.schedule_event(:ship, "ORBITALIST-1", :cooldown, DateTime.utc_now())
      Timeline.schedule_event(:ship, "ORBITALIST-2", :arrival, DateTime.utc_now())

      assert Timeline.pending_owners(:ship) |> Enum.sort() ==
               [
                 %{owner_type: "ship", owner_id: "ORBITALIST-1"},
                 %{owner_type: "ship", owner_id: "ORBITALIST-2"}
               ]
               |> Enum.sort()
    end

    test "filters by owner type when given" do
      Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())
      Timeline.schedule_event(:contract, "CONT-1", :deadline, DateTime.utc_now())

      assert Timeline.pending_owners(:ship) == [%{owner_type: "ship", owner_id: "ORBITALIST-1"}]
      assert Timeline.pending_owners() |> length() == 2
    end

    test "excludes owners whose events all fired" do
      {:ok, event} = Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())
      :ok = Timeline.fire_event(event)

      assert Timeline.pending_owners(:ship) == []
    end
  end

  describe "fire_event/1" do
    test "marks a pending event as done, idempotently" do
      {:ok, event} =
        Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, DateTime.utc_now())

      assert :ok = Timeline.fire_event(event)
      assert Repo.get(Event, event.id).status == "done"
      assert :ok = Timeline.fire_event(event)
    end
  end

  describe "due?/2" do
    test "a past event is due, a future event is not" do
      past = DateTime.add(DateTime.utc_now(), -10, :second)
      future = DateTime.add(DateTime.utc_now(), 10, :second)

      {:ok, past_event} = Timeline.schedule_event(:ship, "ORBITALIST-1", :arrival, past)
      {:ok, future_event} = Timeline.schedule_event(:ship, "ORBITALIST-1", :cooldown, future)

      assert Timeline.due?(past_event)
      refute Timeline.due?(future_event)
    end
  end
end
