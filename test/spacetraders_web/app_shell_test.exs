defmodule SpaceTradersWeb.AppShellTest do
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_operator

  test "one theme and no theme toggle", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mission-control")

    assert html =~ ~s(data-theme="spacetraders")
    refute html =~ "theme-switcher"
    refute html =~ "phx:set-theme"
    refute html =~ "data-phx-theme"
    refute File.read!("assets/css/app.css") =~ ~s(name: "light")
    refute File.read!("assets/css/app.css") =~ ~s(name: "dark")
  end

  test "phone tab bar has Glance, Ships and Stats; desktop bar has Mission Control and Ships", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#phone-tabs.md\\:hidden")

    assert has_element?(
             view,
             "#phone-tabs a[href='/mission-control'][aria-current='page']",
             "Glance"
           )

    assert has_element?(view, "#phone-tabs a[href='/ships']", "Ships")
    assert has_element?(view, "#phone-tabs a[href='/stats']", "Stats")

    assert has_element?(view, "#top-bar.md\\:flex a[href='/mission-control']", "Mission Control")
    assert has_element?(view, "#top-bar a[href='/ships']", "Ships")
    refute has_element?(view, "#top-bar a", "World")
  end

  test "World, Strategy and Generations are in the menu", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#app-menu a[href='/world']", "World")
    assert has_element?(view, "#app-menu a[href='/strategy']", "Strategy")
    assert has_element?(view, "#app-menu a[href='/generations']", "Generations")
  end
end
