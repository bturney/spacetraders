defmodule SpaceTradersWeb.ShipsLiveSeedsTest do
  @moduledoc "The Ships list reads the scenario seeds (#768): same Fleet the Operator check uses."
  use SpaceTradersWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias SpaceTraders.ScenarioSeeds

  setup %{conn: conn} do
    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("the Ships list calls the game") end)
    %{conn: conn}
  end

  for {situation, status, affected} <- [
        {:busy_not_earning, :busy_not_earning, 30},
        {:waiting, :waiting, 30},
        {:stuck, :stuck, 30},
        {:old_information, :trading, 108},
        {:healthy, :trading, 108}
      ] do
    test "#{situation} at 120 Ships shows #{status} on the Ships list", %{conn: conn} do
      seeded = ScenarioSeeds.seed(unquote(situation), 120)

      operator =
        SpaceTraders.Repo.get!(SpaceTraders.Agent.Operator, seeded.generation.operator_id)

      {:ok, view, _html} = live(log_in_operator(conn, operator), ~p"/ships")

      assert has_element?(view, "#status-filter-all", "120")
      assert has_element?(view, "#status-filter-#{unquote(status)}", "#{unquote(affected)}")
    end
  end
end
