defmodule SpaceTraders.API.RequestTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.Request.{
    DeliverContractRequest,
    JettisonCargoRequest,
    NavigateRequest,
    PurchaseCargoRequest,
    PurchaseShipRequest,
    RegisterRequest,
    SellCargoRequest
  }

  @requests [
    {RegisterRequest, %{symbol: "ORBITALIST", faction: "COSMIC", email: "operator@example.com"},
     %{"symbol" => "ORBITALIST", "faction" => "COSMIC", "email" => "operator@example.com"},
     :symbol},
    {DeliverContractRequest, %{ship_symbol: "SHIP-1", trade_symbol: "IRON_ORE", units: 3},
     %{"shipSymbol" => "SHIP-1", "tradeSymbol" => "IRON_ORE", "units" => 3}, :ship_symbol},
    {NavigateRequest, %{waypoint_symbol: "X1-UX81-A1"}, %{"waypointSymbol" => "X1-UX81-A1"},
     :waypoint_symbol},
    {SellCargoRequest, %{symbol: "IRON_ORE", units: 3}, %{"symbol" => "IRON_ORE", "units" => 3},
     :symbol},
    {PurchaseCargoRequest, %{symbol: "IRON_ORE", units: 3},
     %{"symbol" => "IRON_ORE", "units" => 3}, :symbol},
    {JettisonCargoRequest, %{symbol: "IRON_ORE", units: 3},
     %{"symbol" => "IRON_ORE", "units" => 3}, :symbol},
    {PurchaseShipRequest, %{ship_type: "SHIP_MINING_DRONE", waypoint_symbol: "X1-UX81-A1"},
     %{"shipType" => "SHIP_MINING_DRONE", "waypointSymbol" => "X1-UX81-A1"}, :ship_type}
  ]

  test "request encoders use the spec's JSON property names" do
    for {module, attrs, expected_json, _required_field} <- @requests do
      assert module.new(attrs) |> module.to_json() == expected_json
    end
  end

  test "request encoders reject nil required fields" do
    for {module, attrs, expected_json, required_field} <- @requests do
      request = module.new(Map.put(attrs, required_field, nil))

      {json_field, _value} =
        Enum.find(expected_json, fn {_field, value} -> value == attrs[required_field] end)

      assert_raise ArgumentError, ~r/#{json_field}/, fn -> module.to_json(request) end
    end
  end

  test "request encoders omit nil optional fields" do
    assert RegisterRequest.new(%{symbol: "ORBITALIST", faction: "COSMIC", email: nil})
           |> RegisterRequest.to_json() == %{"symbol" => "ORBITALIST", "faction" => "COSMIC"}
  end
end
