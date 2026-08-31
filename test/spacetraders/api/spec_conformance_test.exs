defmodule SpaceTraders.API.SpecConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the client's response-envelope assumptions against the bundled
  OpenAPI spec (`priv/spec/SpaceTraders.json`) — the ground truth for what
  each endpoint actually returns.

  Every endpoint the client speaks (`lib/spacetraders/api.ex`) declares an
  envelope via its `as:` option: `:raw` means the body is flat, anything else
  means the body is wrapped in `"data"`. If a declaration disagrees with the
  spec — the root endpoint is the lone flat response; all others wrap in
  `"data"` — the client will mis-decode production traffic while fixtures
  stay green. This test makes that disagreement a test failure.

  Update this table when the client learns a new endpoint. Keep the expected
  envelope in lockstep with the `as:` option on the corresponding `request/4`
  call; the assertions here are the safety net if one drifts.
  """

  alias SpaceTraders.API
  alias SpaceTraders.API.Request

  @spec_path "priv/spec/SpaceTraders.json"

  # {endpoint, method, spec path template, envelope the client expects}
  @endpoints [
    {:get_status, :get, "/", :flat},
    {:register, :post, "/register", :data},
    {:get_agent, :get, "/my/agent", :data},
    {:get_contracts, :get, "/my/contracts", :data},
    {:get_contract, :get, "/my/contracts/{contractId}", :data},
    {:accept_contract, :post, "/my/contracts/{contractId}/accept", :data},
    {:deliver_contract, :post, "/my/contracts/{contractId}/deliver", :data},
    {:fulfill_contract, :post, "/my/contracts/{contractId}/fulfill", :data},
    {:negotiate_contract, :post, "/my/ships/{shipSymbol}/negotiate/contract", :data},
    {:get_ships, :get, "/my/ships", :data},
    {:get_ship, :get, "/my/ships/{shipSymbol}", :data},
    {:navigate_ship, :post, "/my/ships/{shipSymbol}/navigate", :data},
    {:jump_ship, :post, "/my/ships/{shipSymbol}/jump", :data},
    {:warp_ship, :post, "/my/ships/{shipSymbol}/warp", :data},
    {:set_ship_flight_mode, :patch, "/my/ships/{shipSymbol}/nav", :data},
    {:dock_ship, :post, "/my/ships/{shipSymbol}/dock", :data},
    {:orbit_ship, :post, "/my/ships/{shipSymbol}/orbit", :data},
    {:extract_resources, :post, "/my/ships/{shipSymbol}/extract", :data},
    {:siphon_resources, :post, "/my/ships/{shipSymbol}/siphon", :data},
    {:scan_waypoints, :post, "/my/ships/{shipSymbol}/scan/waypoints", :data},
    {:create_chart, :post, "/my/ships/{shipSymbol}/chart", :data},
    {:refuel_ship, :post, "/my/ships/{shipSymbol}/refuel", :data},
    {:sell_cargo, :post, "/my/ships/{shipSymbol}/sell", :data},
    {:purchase_cargo, :post, "/my/ships/{shipSymbol}/purchase", :data},
    {:jettison_cargo, :post, "/my/ships/{shipSymbol}/jettison", :data},
    {:install_ship_module, :post, "/my/ships/{shipSymbol}/modules/install", :data},
    {:remove_ship_module, :post, "/my/ships/{shipSymbol}/modules/remove", :data},
    {:transfer_cargo, :post, "/my/ships/{shipSymbol}/transfer", :data},
    {:purchase_ship, :post, "/my/ships", :data},
    {:get_system, :get, "/systems/{systemSymbol}", :data},
    {:get_waypoints, :get, "/systems/{systemSymbol}/waypoints", :data},
    {:get_waypoint, :get, "/systems/{systemSymbol}/waypoints/{waypointSymbol}", :data},
    {:get_market, :get, "/systems/{systemSymbol}/waypoints/{waypointSymbol}/market", :data},
    {:get_construction, :get, "/systems/{systemSymbol}/waypoints/{waypointSymbol}/construction",
     :data},
    {:get_jump_gate, :get, "/systems/{systemSymbol}/waypoints/{waypointSymbol}/jump-gate", :data},
    {:supply_construction, :post,
     "/systems/{systemSymbol}/waypoints/{waypointSymbol}/construction/supply", :data},
    {:get_shipyard, :get, "/systems/{systemSymbol}/waypoints/{waypointSymbol}/shipyard", :data},
    {:get_factions, :get, "/factions", :data},
    {:get_faction, :get, "/factions/{factionSymbol}", :data}
  ]

  # {client endpoint, method, spec path template, generated request struct}
  @request_endpoints [
    {:register, :post, "/register", Request.RegisterRequest},
    {:deliver_contract, :post, "/my/contracts/{contractId}/deliver",
     Request.DeliverContractRequest},
    {:navigate_ship, :post, "/my/ships/{shipSymbol}/navigate", Request.NavigateRequest},
    {:jump_ship, :post, "/my/ships/{shipSymbol}/jump", Request.NavigateRequest},
    {:warp_ship, :post, "/my/ships/{shipSymbol}/warp", Request.NavigateRequest},
    {:set_ship_flight_mode, :patch, "/my/ships/{shipSymbol}/nav", Request.ShipNavRequest},
    {:sell_cargo, :post, "/my/ships/{shipSymbol}/sell", Request.SellCargoRequest},
    {:purchase_cargo, :post, "/my/ships/{shipSymbol}/purchase", Request.PurchaseCargoRequest},
    {:jettison_cargo, :post, "/my/ships/{shipSymbol}/jettison", Request.JettisonCargoRequest},
    {:install_ship_module, :post, "/my/ships/{shipSymbol}/modules/install",
     Request.InstallShipModuleRequest},
    {:remove_ship_module, :post, "/my/ships/{shipSymbol}/modules/remove",
     Request.RemoveShipModuleRequest},
    {:transfer_cargo, :post, "/my/ships/{shipSymbol}/transfer", Request.TransferCargoRequest},
    {:purchase_ship, :post, "/my/ships", Request.PurchaseShipRequest},
    {:supply_construction, :post,
     "/systems/{systemSymbol}/waypoints/{waypointSymbol}/construction/supply",
     Request.SupplyConstructionRequest}
  ]

  describe "client envelope declarations match the bundled spec" do
    test "every endpoint the client speaks is present in the spec" do
      for {endpoint, _method, path, _envelope} <- @endpoints do
        assert spec_paths()[path], "client endpoint #{endpoint} (#{path}) missing from spec"
      end
    end

    test "root GET / is the one flat response — no `data` wrapper" do
      props = success_schema("/", :get)

      refute Map.has_key?(props, "data"),
             "spec says GET / is flat; client must decode :raw, not demand `data`"

      for required <- ["status", "version", "resetDate"] do
        assert Map.has_key?(props, required), "GET / schema missing required field #{required}"
      end
    end

    test "data-wrapped endpoints carry a `data` property; flat endpoints do not" do
      for {endpoint, method, path, envelope} <- @endpoints do
        props = success_schema(path, method)

        case envelope do
          :data ->
            assert Map.has_key?(props, "data"),
                   "#{endpoint} (#{path}) declares a `data` envelope but the spec is flat"

          :flat ->
            refute Map.has_key?(props, "data"),
                   "#{endpoint} (#{path}) declares a flat envelope but the spec wraps in `data`"
        end
      end
    end

    test "every declared endpoint has a success schema in the spec" do
      for {endpoint, method, path, _envelope} <- @endpoints do
        refute success_schema(path, method) == nil,
               "no success response schema for #{endpoint} (#{path}) in spec"
      end
    end
  end

  describe "API client surface" do
    test "public functions exist for every declared endpoint" do
      Code.ensure_loaded!(API)

      for {endpoint, _method, _path, _envelope} <- @endpoints do
        assert function_exported?(API, endpoint, arity_of(endpoint)),
               "expected SpaceTraders.API.#{endpoint}/#{arity_of(endpoint)} to exist"
      end
    end
  end

  describe "request payload declarations" do
    test "every state-changing endpoint with a client payload has a request schema and encoder" do
      for {endpoint, method, path, request_module} <- @request_endpoints do
        assert request_schema(path, method),
               "#{endpoint} (#{path}) has no request schema in the spec"

        Code.ensure_loaded!(request_module)
        assert function_exported?(request_module, :new, 1)
        assert function_exported?(request_module, :to_json, 1)
      end
    end
  end

  defp arity_of(:get_status), do: 0
  defp arity_of(:register), do: 4
  defp arity_of(:get_agent), do: 1
  defp arity_of(:get_contracts), do: 1
  defp arity_of(:get_contract), do: 2
  defp arity_of(:accept_contract), do: 2
  defp arity_of(:deliver_contract), do: 5
  defp arity_of(:fulfill_contract), do: 2
  defp arity_of(:negotiate_contract), do: 2
  defp arity_of(:get_ships), do: 1
  defp arity_of(:get_ship), do: 2
  defp arity_of(:navigate_ship), do: 3
  defp arity_of(:jump_ship), do: 3
  defp arity_of(:warp_ship), do: 3
  defp arity_of(:set_ship_flight_mode), do: 3
  defp arity_of(:dock_ship), do: 2
  defp arity_of(:orbit_ship), do: 2
  defp arity_of(:extract_resources), do: 2
  defp arity_of(:siphon_resources), do: 2
  defp arity_of(:scan_waypoints), do: 2
  defp arity_of(:create_chart), do: 2
  defp arity_of(:refuel_ship), do: 2
  defp arity_of(:sell_cargo), do: 4
  defp arity_of(:purchase_cargo), do: 4
  defp arity_of(:jettison_cargo), do: 4
  defp arity_of(:install_ship_module), do: 3
  defp arity_of(:remove_ship_module), do: 3
  defp arity_of(:transfer_cargo), do: 5
  defp arity_of(:purchase_ship), do: 3
  defp arity_of(:get_system), do: 2
  defp arity_of(:get_waypoints), do: 3
  defp arity_of(:get_waypoint), do: 3
  defp arity_of(:get_market), do: 3
  defp arity_of(:get_construction), do: 3
  defp arity_of(:get_jump_gate), do: 3
  defp arity_of(:supply_construction), do: 6
  defp arity_of(:get_shipyard), do: 3
  defp arity_of(:get_factions), do: 1
  defp arity_of(:get_faction), do: 2

  defp spec_paths do
    @spec_path |> File.read!() |> Jason.decode!() |> Map.fetch!("paths")
  end

  defp success_schema(path, method) do
    operation = spec_paths()[path][to_string(method)]

    operation
    |> Map.fetch!("responses")
    |> then(fn responses ->
      Enum.find_value(["200", "201"], fn code ->
        responses
        |> Map.get(code, %{})
        |> get_in(["content", "application/json", "schema"])
      end)
    end)
    |> case do
      nil -> nil
      schema -> schema |> Map.get("properties", %{})
    end
  end

  defp request_schema(path, method) do
    get_in(spec_paths(), [
      path,
      to_string(method),
      "requestBody",
      "content",
      "application/json",
      "schema"
    ])
  end
end
