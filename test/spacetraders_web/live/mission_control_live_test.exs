defmodule SpaceTradersWeb.MissionControlLiveTest do
  @moduledoc """
  Glance (#769) opens with Plan Health, read from stored facts on the scenario
  seeds (#768). Seam: the `/mission-control` LiveView.
  """
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.{Fleet, Liveness, Repo, ScenarioSeeds}
  alias SpaceTraders.MissionControl.PlanHealth

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

  test "requires authentication" do
    assert {:error, {:redirect, %{to: "/operators/log-in"}}} =
             live(Phoenix.ConnTest.build_conn(), ~p"/mission-control")
  end

  for {situation, state, label} <- [
        {:healthy, :on, "On plan"},
        {:busy_not_earning, :setback, "Small setback, recoverable"},
        {:waiting, :on, "On plan"},
        {:stuck, :off, "Off plan, real blocker"}
      ] do
    test "#{situation} opens with #{label}", %{conn: conn} do
      {view, _html, _seeded} = glance(conn, unquote(situation), 2)

      assert has_element?(view, "#plan-health[data-state='#{unquote(state)}']", unquote(label))

      for check <- ~w(earning ships_moving prices_fresh trades_as_expected) do
        assert has_element?(view, "#plan-health-check-#{check}")
      end
    end
  end

  test "a signed-in Operator without a current Fleet can't tell, and is not asked to act", %{
    conn: conn
  } do
    %{conn: conn} = register_and_log_in_operator(%{conn: conn})
    {:ok, view, html} = live(conn, ~p"/mission-control")

    assert has_element?(view, "#plan-health[data-state='unknown']", "Can't tell right now")
    assert has_element?(view, "#plan-health-reason", "No current Fleet yet.")
    refute has_element?(view, "#glance button")
    refute has_element?(view, "#glance a")
    refute html =~ "Mint an Agent"
    refute html =~ "Retry"
  end

  test "the old overview and briefing are gone", %{conn: conn} do
    {_view, html, _seeded} = glance(conn, :healthy, 2)

    for id <- ~w(operating-health strategy-context objective-evaluations market-execution
                 fleet-health notable-activity mission-onboarding) do
      refute html =~ ~s(id="#{id}")
    end
  end

  test "every update re-reads at most once per second and calls no game", %{conn: conn} do
    {view, _html, seeded} = glance(conn, :healthy, 2)
    [ship | _] = Fleet.current_ships(seeded.agent.id)

    send(view.pid, {:ship_state, ship})
    send(view.pid, :earnings_recorded)
    send(view.pid, {:intent_changed, ship.id})
    send(view.pid, :fleet_strategy_updated)
    assert %{refresh: ref} = :sys.get_state(view.pid).socket.assigns
    assert is_reference(ref)

    # The coalesced recompute lands once; the page still reads the same.
    send(view.pid, :recompute)
    assert has_element?(view, "#plan-health[data-state='on']")
    assert %{refresh: nil} = :sys.get_state(view.pid).socket.assigns
  end

  test "a change after mount moves Plan Health without a reload", %{conn: conn} do
    {view, _html, seeded} = glance(conn, :healthy, 2)
    assert has_element?(view, "#plan-health[data-state='on']")

    [ship | _] = Fleet.current_ships(seeded.agent.id)
    intent = Repo.get_by!(SpaceTraders.Fleet.Intent, ship_id: ship.id)

    intent
    |> Ecto.Changeset.change(status: "blocked", retries: 1)
    |> Ecto.Changeset.put_embed(:blocker, %SpaceTraders.Fleet.IntentBlocker{
      reason: "insufficient_unreserved_headroom",
      summary: "Short of credits."
    })
    |> Repo.update!()

    send(view.pid, {:intent_changed, ship.id})
    send(view.pid, :recompute)

    assert has_element?(view, "#plan-health[data-state='off']", "Off plan, real blocker")
    assert has_element?(view, "#plan-health-reason", "is stuck: Short of credits.")
  end

  test "the earliest overdue moment re-judges a silent Fleet", %{conn: conn} do
    {view, _html, _seeded} = glance(conn, :healthy, 2)
    assert %{next_change: ref} = :sys.get_state(view.pid).socket.assigns
    assert is_reference(ref)

    send(view.pid, :next_change)
    assert has_element?(view, "#plan-health")
  end

  describe "at 120 Ships" do
    test "Glance reads from a fixed number of queries inside 50 ms", %{conn: conn} do
      small = ScenarioSeeds.seed(:healthy, 2)
      small_count = count_queries(fn -> read(small) end)

      {view, _html, large} = glance(conn, :stuck, 120)
      assert has_element?(view, "#plan-health[data-state='off']")

      assert count_queries(fn -> read(large) end) == small_count

      # Best of three, so a loaded test machine measures the read, not the queue.
      best =
        for _ <- 1..3 do
          {micros, _health} = :timer.tc(fn -> read(large) end)
          micros
        end
        |> Enum.min()

      assert best < 50_000, "Plan Health took #{div(best, 1000)} ms at 120 Ships"
    end
  end

  defp read(seeded) do
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    PlanHealth.read(SpaceTraders.Agent.Scope.for_operator(operator), seeded.now)
  end

  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = "glance-queries-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:spacetraders, :repo, :query],
      fn _, _, _, _ -> send(parent, {ref, :query}) end,
      nil
    )

    fun.()
    :telemetry.detach(handler)

    Stream.repeatedly(fn -> receive do: ({^ref, :query} -> 1), after: (0 -> nil) end)
    |> Enum.take_while(& &1)
    |> length()
  end
end
