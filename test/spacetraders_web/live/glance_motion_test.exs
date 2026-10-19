defmodule SpaceTradersWeb.GlanceMotionTest do
  @moduledoc """
  Glance's Ships in motion and Just happened feed (#771), on the scenario
  seeds (#768). Seam: the `/mission-control` LiveView; zero game requests.
  """
  use SpaceTradersWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Fleet.{Intent, Intents.BlockedRetry, Ship}
  alias SpaceTraders.MissionControl.Happenings
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.{Liveness, Repo, ScenarioSeeds}

  setup do
    Liveness.reset()
    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("Glance calls the game") end)
    :ok
  end

  defp glance(conn, situation, ships) do
    seeded = ScenarioSeeds.seed(situation, ships)
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    {:ok, view, html} = live(log_in_operator(conn, operator), ~p"/mission-control")
    {view, html, seeded}
  end

  defp record(seeded, attrs) do
    now = DateTime.utc_now()

    base = %{
      source: "trade",
      fleet_generation_id: seeded.generation.id,
      ship_symbol: "SEEDED-1",
      ship_type: "SHIP_LIGHT_HAULER",
      good: "FABRICS",
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-F47",
      units: 20,
      jettisoned_units: 0,
      revenue: 3_000,
      goods_cost: 1_000,
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: 2_000,
      ship_seconds: 600,
      started_at: DateTime.add(now, -600),
      finished_at: now,
      inserted_at: now
    }

    Repo.insert!(struct(EarningsRecord, Map.merge(base, attrs)))
  end

  describe "Ships in motion" do
    test "a small Fleet shows one route card per Ship", %{conn: conn} do
      {view, _html, seeded} = glance(conn, :healthy, 2)

      assert has_element?(view, "#ships-in-motion")
      assert has_element?(view, "#motion-cards")
      refute has_element?(view, "#motion-grid")

      for ship <- SpaceTraders.Fleet.current_ships(seeded.agent.id) do
        assert has_element?(view, "#ship-card-#{ship.id}", ship.symbol)
        assert has_element?(view, "#ship-card-route-#{ship.id}")
      end
    end

    test "120 Ships show progress cells with counts and Not earning rows", %{conn: conn} do
      {view, _html, _seeded} = glance(conn, :stuck, 120)

      refute has_element?(view, "#motion-cards")
      assert has_element?(view, "#fleet-grid")

      assert view
             |> element("#fleet-grid")
             |> render()
             |> String.split("data-status=")
             |> length() == 121

      assert has_element?(view, "#fleet-grid-count-stuck", "30")
      assert has_element?(view, "#fleet-grid-count-trading", "78")

      # Two listed, the rest counted.
      assert view |> render() |> String.split(~s(id="not-earning-)) |> length() == 4
      assert has_element?(view, "#not-earning-more", "+28 more")
    end

    test "a healthy 120-Ship Fleet has nothing under Not earning", %{conn: conn} do
      {view, _html, _seeded} = glance(conn, :healthy, 120)

      assert has_element?(view, "#not-earning-none")
      refute has_element?(view, "#not-earning-more")
    end

    test "the page makes no game request and re-reads at most once a second", %{conn: conn} do
      {view, _html, seeded} = glance(conn, :healthy, 120)
      [ship | _] = SpaceTraders.Fleet.current_ships(seeded.agent.id)

      for _ <- 1..20, do: send(view.pid, {:ship_state, ship})
      assert %{refresh: ref} = :sys.get_state(view.pid).socket.assigns
      assert is_reference(ref)
    end
  end

  describe "Just happened" do
    test "an empty Fleet says so", %{conn: conn} do
      %{conn: conn} = register_and_log_in_operator(%{conn: conn})
      {:ok, view, _html} = live(conn, ~p"/mission-control")

      assert has_element?(view, "#happenings-empty")
      refute has_element?(view, "#ships-in-motion")
    end

    test "shows the last 8 events, newest first", %{conn: conn} do
      seeded = ScenarioSeeds.seed(:healthy, 2)
      for n <- 1..10, do: record(seeded, %{finished_at: DateTime.add(DateTime.utc_now(), -n)})

      events = Happenings.read(seeded.agent)
      assert length(events) == 8
      assert events == Enum.sort_by(events, &DateTime.to_unix(&1.at, :microsecond), :desc)

      operator = Repo.get!(Operator, seeded.generation.operator_id)
      {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/mission-control")
      assert view |> render() |> String.split(~s(data-kind=")) |> length() == 9
    end

    test "shows the five kinds with their reasons and profit", %{conn: conn} do
      seeded = ScenarioSeeds.seed(:stuck, 2)
      now = DateTime.utc_now()
      stuck_ship = Repo.one!(from s in Ship, where: s.symbol == ^hd(seeded.affected))
      other = Repo.one!(from s in Ship, where: s.symbol == "SEEDED-2")

      # sale lands, with profit; then a new best
      record(seeded, %{net_earnings: 1_234, finished_at: DateTime.add(now, -50)})
      record(seeded, %{net_earnings: 9_876, finished_at: DateTime.add(now, -40)})

      # buy skipped, with its reason
      intent = Repo.one!(from i in Intent, where: i.ship_id == ^other.id)

      Repo.update_all(from(i in Intent, where: i.id == ^intent.id),
        set: [
          type: "buy",
          status: "infeasible",
          finished_at: DateTime.truncate(DateTime.add(now, -30), :second),
          parameters: %{"trade_symbol" => "IRON_ORE"},
          last_action_result: %{
            "outcome" => "infeasible",
            "evidence" => %{"reason" => "price_moved_past_limit"}
          }
        ]
      )

      # a Ship joins after the opening Fleet
      Repo.insert!(%Ship{
        symbol: "SEEDED-NEW",
        ship_type: "SHIP_LIGHT_HAULER",
        agent_id: seeded.agent.id,
        inserted_at: DateTime.truncate(DateTime.add(now, -20), :second),
        updated_at: DateTime.truncate(DateTime.add(now, -20), :second)
      })

      # the seeded stuck step recovers
      stuck_intent = Repo.one!(from i in Intent, where: i.ship_id == ^stuck_ship.id)

      Repo.update_all(from(i in Intent, where: i.id == ^stuck_intent.id),
        set: [recovered_at: DateTime.truncate(DateTime.add(now, -10), :second)]
      )

      operator = Repo.get!(Operator, seeded.generation.operator_id)
      {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/mission-control")

      assert has_element?(view, "#happenings [data-kind=sale]", "+1,234")
      assert has_element?(view, "#happenings [data-kind=best]", "+9,876")
      assert has_element?(view, "#happenings [data-kind=best]", "New best trade")

      assert has_element?(
               view,
               "#happenings [data-kind=skipped_buy]",
               "skipped buying Iron ore: price moved past limit"
             )

      assert has_element?(view, "#happenings [data-kind=joined]", "SEEDED-NEW joined the Fleet")

      assert has_element?(
               view,
               "#happenings [data-kind=stuck]",
               "Not enough credits above the floor."
             )

      assert has_element?(view, "#happenings [data-kind=recovered]", "recovered")
    end

    test "the first trade is a sale, not a new best", %{conn: _conn} do
      seeded = ScenarioSeeds.seed(:healthy, 2)
      Repo.delete_all(EarningsRecord)
      record(seeded, %{})

      kinds = seeded.agent |> Happenings.read() |> Enum.map(& &1.kind)
      assert :sale in kinds
      refute :best in kinds
    end

    test "blocking and recovering a step stamp the feed's times" do
      seeded = ScenarioSeeds.seed(:healthy, 2)
      intent = Repo.one!(from i in Intent, limit: 1)

      blocked =
        intent
        |> Ecto.Changeset.change(status: "blocked")
        |> Ecto.Changeset.put_embed(:blocker, %SpaceTraders.Fleet.IntentBlocker{
          reason: "no_fuel",
          summary: "Out of fuel."
        })
        |> BlockedRetry.changes()
        |> Repo.update!()

      assert blocked.blocked_at
      assert blocked.blocked_reason == "Out of fuel."
      refute blocked.recovered_at

      recovered =
        blocked
        |> Ecto.Changeset.change(status: "active")
        |> BlockedRetry.changes()
        |> Repo.update!()

      assert recovered.recovered_at
      assert recovered.blocked_at == blocked.blocked_at

      failed =
        recovered
        |> Ecto.Changeset.change(status: "blocked", recovered_at: nil)
        |> BlockedRetry.changes()
        |> Repo.update!()
        |> Ecto.Changeset.change(status: "infeasible")
        |> BlockedRetry.changes()
        |> Repo.update!()

      refute failed.recovered_at
      assert seeded.agent
    end
  end

  describe "live moments" do
    test "a sale pushes one SOLD pop-up and flashes its Ship for 4.5 s", %{conn: conn} do
      {view, _html, seeded} = glance(conn, :healthy, 2)
      symbol = "SEEDED-1"
      ship = Repo.one!(from s in Ship, where: s.symbol == ^symbol)

      refute has_element?(view, "#ship-card-#{ship.id}[data-sold]")

      saved = record(seeded, %{net_earnings: 777})
      send(view.pid, :earnings_recorded)
      send(view.pid, :recompute)
      _ = render(view)

      assert_push_event(view, "sold", %{amount: 777, detail: detail})
      assert detail =~ symbol
      assert has_element?(view, "#ship-card-#{ship.id}[data-sold]", "+777")
      assert has_element?(view, "#ship-card-#{ship.id}[data-tone=on]")

      send(view.pid, {:unflash, symbol, saved.id})
      refute has_element?(view, "#ship-card-#{ship.id}[data-sold]")
    end

    test "sales already on the page at mount are not announced", %{conn: conn} do
      {view, _html, _seeded} = glance(conn, :healthy, 2)

      send(view.pid, :recompute)
      _ = render(view)

      refute_push_event(view, "sold", _, 50)
    end

    test "in a large Fleet the sold Ship's cell gets the outline", %{conn: conn} do
      {view, _html, seeded} = glance(conn, :healthy, 120)
      symbol = "SEEDED-1"
      ship = Repo.one!(from s in Ship, where: s.symbol == ^symbol)
      record(seeded, %{net_earnings: 500})

      send(view.pid, :recompute)
      _ = render(view)

      assert has_element?(view, "#fleet-grid-cell-#{ship.id}[data-sold]")
    end
  end
end
