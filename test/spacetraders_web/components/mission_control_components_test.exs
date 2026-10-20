defmodule SpaceTradersWeb.MissionControlComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import SpaceTradersWeb.MissionControlComponents

  @t0 ~U[2026-10-18 12:00:00Z]

  describe "number formatting" do
    test "groups thousands and uses a true minus" do
      assert format_int(1340) == "1,340"
      assert format_int(-2_870_000) == "−2,870,000"
      assert format_int(nil) == "—"
      assert format_signed(560) == "+560"
      assert format_signed(-5) == "−5"
      assert format_signed(0) == "+0"
      assert format_signed(nil) == "—"
    end

    test "clock is m:ss, clamped, and dash when unknown" do
      assert format_clock(125) == "2:05"
      assert format_clock(-3) == "0:00"
      assert format_clock(nil) == "—"
    end
  end

  test "card renders default, inner and toned states" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.card id="a">plain</.card>
      <.card id="b" inner>inner</.card>
      <.card id="c" tone={:on}>on plan</.card>
      """)

    assert html =~ "bg-base-200"
    assert html =~ "rounded-[10px]"
    assert html =~ "bg-success/9 border-success/35"
    assert html =~ ~s(data-tone="on")
  end

  test "eyebrow renders label and optional right text" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.eyebrow>
        Credits<:right>since 06:10</:right>
      </.eyebrow>
      <.eyebrow>Alone</.eyebrow>
      """)

    assert html =~ "uppercase"
    assert html =~ "Credits"
    assert html =~ "since 06:10"
    assert html =~ "Alone"
  end

  test "status chip uses the fixed wording for all six statuses" do
    labels = %{
      trading: "Trading",
      busy: "Busy, not earning",
      skipping: "Busy, skipping buys",
      waiting: "Waiting on purpose",
      stuck: "Stuck",
      scouting: "Scouting prices"
    }

    assert Enum.sort(statuses()) == Enum.sort(Map.keys(labels))

    for {status, label} <- labels do
      assigns = %{status: status}
      html = rendered_to_string(~H"<.status_chip status={@status} />")
      assert html =~ label
      assert html =~ "data-status=\"#{status}\""
    end

    assigns = %{}

    html =
      rendered_to_string(~H|<.status_chip status={:trading} small label="Hauling 20 Fabrics" />|)

    assert html =~ "Hauling 20 Fabrics"
    assert html =~ "text-[11px]"
  end

  test "data badge distinguishes real from sample and short" do
    assigns = %{}

    assert rendered_to_string(~H"<.data_badge />") =~ "REAL DATA"
    assert rendered_to_string(~H"<.data_badge sample />") =~ "SAMPLE DATA"
    html = rendered_to_string(~H"<.data_badge sample short />")
    assert html =~ "SAMPLE"
    refute html =~ "DATA"
  end

  test "money shows gain, loss, est, stale and unknown" do
    assigns = %{}
    gain = rendered_to_string(~H"<.money value={1340} />")
    assert gain =~ "+1,340"
    assert gain =~ "num"

    loss = rendered_to_string(~H"<.money value={-5000} />")
    assert loss =~ "−5,000"
    assert loss =~ "text-error"

    est = rendered_to_string(~H"<.money value={560} est stale />")
    assert est =~ "~+560"
    assert est =~ "est."

    unknown = rendered_to_string(~H"<.money value={nil} />")
    assert unknown =~ "—"
    refute unknown =~ "+0"
  end

  describe "route bar" do
    test "marker sits at the elapsed share and carries timestamps for the hook" do
      assigns = %{d: @t0, a: DateTime.add(@t0, 100, :second), now: DateTime.add(@t0, 25, :second)}

      html =
        rendered_to_string(~H"""
        <.route_bar id="r1" from="F47" to="E45" depart_at={@d} arrive_at={@a} now={@now} />
        """)

      assert html =~ "F47"
      assert html =~ "E45"
      assert html =~ "width:25.0%"
      assert html =~ ~s(data-depart="#{DateTime.to_unix(@t0, :millisecond)}")
      assert html =~ ~s(phx-hook="SpaceTradersWeb.MissionControlComponents.RouteBar")
      assert html =~ "data-marker"
    end

    test "parked shows the waypoint and a draining bar without a marker" do
      assigns = %{}
      html = rendered_to_string(~H|<.route_bar id="r2" at="G49" status={:waiting} />|)
      assert html =~ "G49"
      refute html =~ "data-marker"
      assert html =~ "width:100.0%"
    end

    test "progress clamps to the trip" do
      a = DateTime.add(@t0, 60, :second)
      assert progress(@t0, a, DateTime.add(@t0, -5, :second)) == 0.0
      assert progress(@t0, a, DateTime.add(@t0, 90, :second)) == 1.0
      assert progress(nil, nil, @t0) == 0.0
    end
  end

  describe "countdown" do
    test "shows time remaining, a caption, and an em dash when unknown" do
      assigns = %{u: DateTime.add(@t0, 125, :second), now: @t0}

      html =
        rendered_to_string(~H"""
        <.countdown id="c1" until={@u} now={@now} caption="arrives" />
        """)

      assert html =~ "2:05"
      assert html =~ "arrives"
      assert html =~ "data-until"

      none = rendered_to_string(~H|<.countdown id="c2" />|)
      assert none =~ "—"
    end

    test "overdue clamps to 0:00" do
      assigns = %{u: DateTime.add(@t0, -30, :second), now: @t0}
      assert rendered_to_string(~H|<.countdown id="c3" until={@u} now={@now} />|) =~ "0:00"
    end
  end

  describe "sold toast" do
    test "gain, loss and folded sales" do
      assigns = %{}

      gain =
        rendered_to_string(~H|<.sold_toast amount={1200} detail="20 Fabrics · F47" more={3} />|)

      assert gain =~ "SOLD"
      assert gain =~ "+1,200"
      assert gain =~ "+3 more"
      assert gain =~ ~s(data-visible="true")

      loss = rendered_to_string(~H"<.sold_toast amount={-40} visible={false} />")
      assert loss =~ "−40"
      assert loss =~ ~s(data-visible="false")
    end

    test "host is an ignored hook container" do
      assigns = %{}
      html = rendered_to_string(~H|<.sold_toast_host id="toasts" />|)
      assert html =~ ~s(phx-update="ignore")
      assert html =~ "SoldToastHost"
    end
  end

  test "credits ticker shows the balance with separators, with and without a gain" do
    assigns = %{}
    plain = rendered_to_string(~H|<.credits_ticker id="t1" value={2_870_412} />|)
    assert plain =~ "2,870,412"
    assert plain =~ ~s(data-value="2870412")
    refute plain =~ "text-success"

    flash = rendered_to_string(~H|<.credits_ticker id="t2" value={2_870_412} flash={560} />|)
    assert flash =~ "+560"
    assert flash =~ "text-success"
  end
end
