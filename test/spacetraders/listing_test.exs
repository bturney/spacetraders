defmodule SpaceTraders.ListingTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Listing

  import SpaceTraders.ShipBody

  test "keeps prior trait-filtered Waypoints as partial after a later page fails" do
    agent = %AgentRecord{
      agent_token: "AGENT_TOKEN",
      headquarters: "X1-UX81-A1"
    }

    ship =
      ship_body("FLEET-SHIP", %{
        "nav" => nav_body("DOCKED", destination: "X1-UX81-A1")
      })
      |> Model.Ship.from_json()

    first_page =
      [%{"symbol" => "X1-UX81-A1", "systemSymbol" => "X1-UX81", "traits" => []}] ++
        Enum.map(2..20, fn index ->
          %{
            "symbol" => "X1-UX81-A#{index}",
            "systemSymbol" => "X1-UX81",
            "traits" => []
          }
        end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.query_params["traits"], conn.query_params["page"]} do
        {"/v2/systems/X1-UX81/waypoints", trait, "1"} when trait in ["MARKETPLACE", "SHIPYARD"] ->
          Req.Test.json(conn, %{"data" => first_page_with_trait(first_page, trait)})

        {"/v2/systems/X1-UX81/waypoints", trait, "2"} when trait in ["MARKETPLACE", "SHIPYARD"] ->
          conn
          |> Map.put(:status, 503)
          |> Req.Test.json(%{"error" => %{"message" => "unavailable"}})

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", _, _} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "tradeGoods" => []}})

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard", _, _} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A1", "ships" => []}})
      end
    end)

    result = Listing.for_ships(agent, [ship], {:error, :unavailable})

    assert {:partial, [%{waypoint: "X1-UX81-A1"}]} = result.markets
    assert {:partial, [%{waypoint: "X1-UX81-A1"}]} = result.shipyards
  end

  defp first_page_with_trait(page, trait) do
    Enum.map(page, &Map.put(&1, "traits", [%{"symbol" => trait}]))
  end
end
