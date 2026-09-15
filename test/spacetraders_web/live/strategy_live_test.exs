defmodule SpaceTradersWeb.StrategyLiveTest do
  use SpaceTradersWeb.ConnCase

  import Phoenix.LiveViewTest
  alias SpaceTraders.FleetStrategy

  setup :register_and_log_in_operator

  test "requires authentication", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn()

    assert {:error, {:redirect, %{to: "/operators/log-in"}}} = live(conn, ~p"/strategy")
  end

  test "discloses each preset's ordered objectives, Hard Constraints, Preferences, and consequences",
       %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/strategy")

    assert html =~ "Steady growth"
    assert has_element?(view, "#preset-steady_growth ol li:first-child strong", "Grow credits")
    assert html =~ "Maximize net credit growth over time"
    assert html =~ "Continuous"
    assert html =~ "Recurring"
    assert html =~ "Keep at least 50,000 credits available"
    assert html =~ "Prefer lower-risk routes when expected returns are similar"
    assert html =~ "may spend credits"
  end

  test "draft edits survive recurring patches and reconnects without activation", %{
    conn: conn,
    operator: operator,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/strategy")

    html =
      view
      |> form("#strategy-draft-form", %{
        "strategy" => %{
          "objectives" =>
            "Protect liquidity | maintain | Maintain at least 90,000 credits | recurring\nGrow credits | continuous | Maximize net credit growth | recurring",
          "hard_constraints" => "Keep at least 90,000 credits available",
          "preferences" => "Prefer shorter routes",
          "consequences" => "Growth may slow while liquidity is protected"
        }
      })
      |> render_change()

    assert html =~ "Protect liquidity"
    assert FleetStrategy.get(scope).active_revision == nil

    send(view.pid, {:fleet_strategy_updated, operator.id})
    assert render(view) =~ "Protect liquidity"

    GenServer.stop(view.pid, :normal)
    {:ok, _reconnected_view, reconnected_html} = live(conn, ~p"/strategy")
    assert reconnected_html =~ "Protect liquidity"
    assert reconnected_html =~ "Keep at least 90,000 credits available"
    assert reconnected_html =~ "Maintain at least 90,000 credits"
  end

  test "an external draft update preserves local form text and requires renewed review", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/strategy")

    view
    |> form("#strategy-draft-form", %{
      "strategy" => %{
        "objectives" => "Grow credits | continuous | Measure growth | recurring",
        "hard_constraints" => "Keep 50,000 credits available",
        "preferences" => "Prefer short routes",
        "consequences" => "Credits may be spent above the floor"
      }
    })
    |> render_change()

    assert {:ok, _updated} =
             FleetStrategy.save_draft(scope, %{
               "objectives" => [
                 %{
                   "objective" => "Chart waypoints",
                   "kind" => "attain",
                   "evaluation" => "Increase chart coverage",
                   "scope" => "fleet_generation"
                 }
               ],
               "hard_constraints" => ["Keep 75,000 credits available"],
               "preferences" => ["Prefer nearby systems"],
               "consequences" => "Near-term growth may slow"
             })

    html = render(view)
    assert html =~ "Draft changed elsewhere"
    assert html =~ "Grow credits | continuous | Measure growth | recurring"
    assert has_element?(view, "#activate-strategy[disabled]")

    render_change(view, "save_draft", %{
      "strategy" => %{
        "objectives" => "Replace remote draft | attain | Should not save | recurring",
        "hard_constraints" => "No constraints",
        "preferences" => "No preferences",
        "consequences" => "Should not save"
      }
    })

    assert FleetStrategy.get(scope).draft["objectives"] |> hd() |> Map.fetch!("objective") ==
             "Chart waypoints"

    assert render(view) =~ "Draft changed elsewhere"
    assert has_element?(view, "#activate-strategy[disabled]")

    view |> element("#review-latest-draft") |> render_click()
    assert render(view) =~ "Chart waypoints | attain | Increase chart coverage | fleet_generation"
    refute has_element?(view, "#activate-strategy[disabled]")
  end

  test "preset selection creates a draft and activation requires an explicit action", %{
    conn: conn,
    scope: scope
  } do
    {:ok, view, _html} = live(conn, ~p"/strategy")

    view |> element("#select-preset-steady_growth") |> render_click()
    assert FleetStrategy.get(scope).active_revision == nil
    assert render(view) =~ "Review this draft before activation"

    view |> element("#activate-strategy") |> render_click()

    projection = FleetStrategy.get(scope)
    assert projection.draft == nil
    assert projection.active_revision.number == 1
    assert render(view) =~ "Active revision 1"
  end

  test "discard removes the persistent draft without changing active intent", %{
    conn: conn,
    scope: scope
  } do
    assert {:ok, _draft} = FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, active} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    assert {:ok, _draft} = FleetStrategy.select_preset(scope, "charted_expansion")

    {:ok, view, _html} = live(conn, ~p"/strategy")
    assert render(view) =~ "Revision changes"
    assert render(view) =~ "Current active"
    assert render(view) =~ "Proposed draft"
    view |> element("#discard-strategy-draft") |> render_click()

    projection = FleetStrategy.get(scope)
    assert projection.draft == nil
    assert projection.active_revision.id == active.id
    refute render(view) =~ "Review this draft before activation"
  end
end
