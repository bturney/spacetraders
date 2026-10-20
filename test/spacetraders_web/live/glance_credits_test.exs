defmodule SpaceTradersWeb.GlanceCreditsTest do
  @moduledoc """
  Glance credits card (#770, spec #757): balance, growth line and the 6 h
  Net Earnings rate from stored data, on the scenario seeds (#768).
  Seam: the `/mission-control` LiveView.
  """
  use SpaceTradersWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.{Liveness, Repo, ScenarioSeeds}

  setup do
    Liveness.reset()
    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("Glance calls the game") end)
    :ok
  end

  defp glance(conn, situation) do
    seeded = ScenarioSeeds.seed(situation, 2)
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    {:ok, view, html} = live(log_in_operator(conn, operator), ~p"/mission-control")
    {view, html, seeded}
  end

  test "shows the balance, its growth line and the 6 h Net Earnings from stored data", %{
    conn: conn
  } do
    {view, _html, seeded} = glance(conn, :healthy)

    expected_net =
      Repo.one(
        from r in EarningsRecord,
          where:
            r.fleet_generation_id == ^seeded.generation.id and
              r.finished_at >= ^DateTime.add(seeded.now, -6 * 3600),
          select: type(sum(r.net_earnings), :integer)
      )

    assert has_element?(view, "#credits-balance[data-value='206200']")
    assert has_element?(view, "#credits-growth", "+31,200")
    assert has_element?(view, "#credits-growth-line polyline")

    assert has_element?(
             view,
             "#credits-rate",
             SpaceTradersWeb.MissionControlComponents.format_signed(expected_net)
           )

    assert has_element?(view, "#credits-rate-window", "last 6 h")
    refute has_element?(view, "#credits-rate-window", "since")
  end

  test "a young Generation reads since HH:MM, not unknown", %{conn: conn} do
    seeded = ScenarioSeeds.seed(:healthy, 2)
    since = DateTime.utc_now(:second) |> DateTime.add(-2 * 3600)

    Repo.update_all(from(g in Generation, where: g.id == ^seeded.generation.id),
      set: [inserted_at: since]
    )

    operator = Repo.get!(Operator, seeded.generation.operator_id)
    {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/mission-control")

    assert has_element?(
             view,
             "#credits-rate-window",
             "since #{Calendar.strftime(since, "%H:%M")}"
           )
  end

  test "an unknown balance shows an em dash, never 0", %{conn: conn} do
    seeded = ScenarioSeeds.seed(:healthy, 2)
    Repo.delete_all(from o in Observation, where: o.operation_id == "get-my-agent")
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/mission-control")

    assert has_element?(view, "#credits-card", "—")
    refute has_element?(view, "#credits-balance")
  end

  test "a new balance after an update flashes the gain", %{conn: conn} do
    {view, _html, seeded} = glance(conn, :healthy)

    Repo.insert!(%Observation{
      agent_id: seeded.agent.id,
      subject: "agent:#{seeded.agent.symbol}",
      operation_id: "get-my-agent",
      dependency_keys: [],
      facts: %{"response" => %{"credits" => 208_000}},
      response_fingerprint: "later",
      observed_at: DateTime.utc_now(),
      fleet_generation_id: seeded.generation.id
    })

    send(view.pid, :earnings_recorded)
    send(view.pid, :recompute)

    assert has_element?(view, "#credits-balance[data-value='208000']")
    assert has_element?(view, "#credits-card", "+1,800")
  end
end
