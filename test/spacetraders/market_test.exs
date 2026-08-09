defmodule SpaceTraders.MarketTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Market

  import SpaceTraders.ShipBody

  test "lists market prices only for marketplaces where a ship is docked" do
    agent = %AgentRecord{agent_token: "AGENT_TOKEN"}

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/systems/X1-UX81/waypoints" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "ORBITAL_STATION",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              },
              %{
                "symbol" => "X1-UX81-A2",
                "systemSymbol" => "X1-UX81",
                "type" => "PLANET",
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            ]
          })

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "EXPORT",
                  "sellPrice" => 80,
                  "purchasePrice" => 100,
                  "supply" => "HIGH",
                  "tradeVolume" => 20
                }
              ]
            }
          })
      end
    end)

    ships = [
      ship_body("FLEET-SHIP", %{"nav" => nav_body("DOCKED", destination: "X1-UX81-A1")}),
      ship_body("ORBIT-SHIP", %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
    ]

    ships = Enum.map(ships, &Model.Ship.from_json/1)

    assert {:ok, [%{waypoint: "X1-UX81-A1", ships: [ship], market: market}]} =
             Market.listings(agent, ships)

    assert ship.symbol == "FLEET-SHIP"
    assert market.symbol == "X1-UX81-A1"
  end
end
