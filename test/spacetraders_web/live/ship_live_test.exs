defmodule SpaceTradersWeb.ShipLiveTest do
  @moduledoc "Ship + Why (#772) through the scenario seeds; the page never calls the game."
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.ScenarioSeeds

  setup do
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:transport_receipt, conn.method, conn.request_path})
      Req.Test.json(conn, %{"data" => []})
    end)

    :ok
  end

  defp open(conn, situation, symbol) do
    seeded = ScenarioSeeds.seed(situation, 2)
    operator = SpaceTraders.Repo.get!(SpaceTraders.Agent.Operator, seeded.generation.operator_id)
    {:ok, view, html} = live(log_in_operator(conn, operator), ~p"/ships/#{symbol}")
    {seeded, view, html}
  end

  # Visible text only: drops tags (so data-* attributes never match) and collapses whitespace.
  defp visible_text(html) do
    html |> String.replace(~r/<[^>]+>/, " ") |> String.replace(~r/\s+/, " ")
  end

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/ships/SEEDED-1")
  end

  test "a trading Ship says what it chose, what it beat and how old the price was", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :healthy, "SEEDED-1")

    sentence = view |> element("#why-sentence") |> render()
    assert sentence =~ "Chose Iron Ore A1→B6"
    assert sentence =~ "~+540 after fuel"
    assert sentence =~ "~22 min"
    assert sentence =~ "~1,473/h"
    assert sentence =~ "over Fuel C37→D42 (~1,315/h) and 1 other"
    assert sentence =~ "price was 10 min old"

    assert has_element?(view, "#ship-gauge")
    assert has_element?(view, "#ship-options [data-chosen=true]", "Iron Ore A1→B6")
    assert has_element?(view, "#ship-options [data-chosen=false]")
    assert has_element?(view, "#ship-history [id^=trade-]")
    assert render(view) =~ "Trading"

    refute_received {:transport_receipt, _, _}
  end

  test "an option list marks only the chosen option, with no stray text", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :healthy, "SEEDED-1")

    options = view |> element("#ship-options") |> render() |> visible_text()
    refute options =~ "false"
    assert options =~ "Iron Ore A1→B6 · chosen"
    refute options =~ "Fuel C37→D42 · chosen"
    refute_received {:transport_receipt, _, _}
  end

  test "trade rows read expected vs actual, matching the card heading", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :healthy, "SEEDED-1")

    history = view |> element("#ship-history") |> render() |> visible_text()
    assert history =~ "expected vs actual"
    assert history =~ "+1,000 vs +900"
    refute history =~ "+900 vs +1,000"
    refute_received {:transport_receipt, _, _}
  end

  test "a trade with no expected value still shows its actual value", %{conn: conn} do
    seeded = ScenarioSeeds.seed(:healthy, 2)
    operator = SpaceTraders.Repo.get!(SpaceTraders.Agent.Operator, seeded.generation.operator_id)

    SpaceTraders.Repo.insert!(%SpaceTraders.Outcomes.EarningsRecord{
      source: "test",
      fleet_generation_id: seeded.generation.id,
      ship_symbol: "SEEDED-1",
      ship_type: "HAULER",
      good: "fuel",
      source_waypoint: "X1-UX81-A1",
      destination_waypoint: "X1-UX81-C37",
      units: 10,
      revenue: 600,
      goods_cost: 100,
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: 500,
      expected_value: nil,
      ship_seconds: 60,
      started_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now()
    })

    {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/ships/SEEDED-1")

    history = view |> element("#ship-history") |> render() |> visible_text()
    assert history =~ "+500"
    refute history =~ "vs +500"
    refute_received {:transport_receipt, _, _}
  end

  test "a Ship that skipped a buy names the good, Waypoint, live price and planned maximum",
       %{conn: conn} do
    seeded = ScenarioSeeds.seed(:healthy, 2)
    ship = SpaceTraders.Repo.get_by!(SpaceTraders.Fleet.Ship, symbol: "SEEDED-1")

    template =
      SpaceTraders.Repo.one!(
        from(i in SpaceTraders.Fleet.Intent, where: i.ship_id == ^ship.id, limit: 1)
      )

    SpaceTraders.Repo.insert!(%{
      template
      | id: nil,
        type: "buy",
        status: "infeasible",
        target_waypoint: "X1-UX81-A1",
        parameters: %{"trade_symbol" => "FUEL"},
        last_action_result: %{
          "outcome" => "infeasible",
          "evidence" => %{
            "reason" => "price_constraint",
            "observed_price" => 66,
            "max_price" => 63
          }
        },
        finished_at: DateTime.utc_now(:second)
    })

    operator = SpaceTraders.Repo.get!(SpaceTraders.Agent.Operator, seeded.generation.operator_id)
    {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/ships/SEEDED-1")

    card = view |> element("#ship-skipped-buy") |> render()
    assert card =~ "Fuel"
    assert card =~ "A1"
    assert card =~ "66"
    assert card =~ "63"
    assert card =~ "price guardrail"
    refute_received {:transport_receipt, _, _}
  end

  test "a waiting Ship names the best option and when it checks again", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :waiting, "SEEDED-1")

    sentence = view |> element("#why-sentence") |> render()
    assert sentence =~ "No trade worth it right now; best was Copper Ore D42→E48"
    assert sentence =~ "checking again at"
    assert render(view) =~ "Waiting on purpose"
    refute has_element?(view, "#ship-options")
    refute_received {:transport_receipt, _, _}
  end

  test "a stuck Ship gives its reason and retry state", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :stuck, "SEEDED-1")

    assert view |> element("#why-sentence") |> render() =~ "Not enough credits above the floor."
    assert view |> element("#why-status") |> render() =~ "Retry 2, next attempt at"
    assert has_element?(view, "#ship-countdown[data-until]")
    refute_received {:transport_receipt, _, _}
  end

  test "a Ship change updates the page without calling the game", %{conn: conn} do
    {seeded, view, _html} = open(conn, :healthy, "SEEDED-2")
    refute render(view) =~ "In transit to X"

    now = DateTime.utc_now()

    assert {:ok, _ship} =
             Fleet.record_ship_state(seeded.agent.id, "SEEDED-2", %{
               nav: %Model.ShipNav{
                 status: "IN_TRANSIT",
                 waypoint_symbol: "X1-UX81-C37",
                 route: %Model.ShipNavRoute{
                   origin: %{symbol: "X1-UX81-A1"},
                   destination: %{symbol: "X1-UX81-C37"},
                   departure_time: DateTime.to_iso8601(DateTime.add(now, -5)),
                   arrival: DateTime.to_iso8601(DateTime.add(now, 300))
                 }
               }
             })

    assert render(view) =~ "In transit to C37"
    refute_received {:transport_receipt, _, _}
  end

  test "links to its Ship's Strategy Outcomes over the last 6 h", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :healthy, "SEEDED-1")

    [_, href] = Regex.run(~r/href="([^"]+)"/, view |> element("#ship-grafana") |> render())
    uri = href |> String.replace("&amp;", "&") |> URI.parse()

    assert uri.path == "/d/spacetraders-strategy-outcomes/strategy-outcomes"

    assert %{"var-ship" => "SEEDED-1", "from" => "now-6h", "to" => "now"} =
             URI.decode_query(uri.query)
  end

  test "an unknown Ship says so", %{conn: conn} do
    {_seeded, view, _html} = open(conn, :healthy, "NOPE-9")
    assert has_element?(view, "#ship-missing", "NOPE-9")
  end

  test "the Ships list links to the page", %{conn: conn} do
    seeded = ScenarioSeeds.seed(:healthy, 2)
    operator = SpaceTraders.Repo.get!(SpaceTraders.Agent.Operator, seeded.generation.operator_id)
    {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/ships")
    assert has_element?(view, "a[href='/ships/SEEDED-1']", "SEEDED-1")
  end
end
