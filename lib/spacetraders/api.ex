defmodule SpaceTraders.API do
  @moduledoc """
  Thin Req client for the SpaceTraders API (v2, Phase-1 operations).

  All game contexts talk to the game through this module — there is no port
  ceremony, callers use the functions directly. Responses are decoded into the
  codegen'd structs in `SpaceTraders.API.Model` via `from_json/1`.

  ## Results

  Successes return `{:ok, decoded}`. Failures never raise:

    * `{:error, %SpaceTraders.API.GameplayError{type: type}}` — a 4xx game-state
      rejection (in transit, cooldown, insufficient cargo/credits, expired
      contract). `type` is a normalised atom for pattern matching.
    * `{:error, %SpaceTraders.API.Error{}}` — a fatal failure: 5xx, transport
      error, or an undecodable response.

  ## Rate limiting

  Every request first calls `SpaceTraders.API.RateLimiter.acquire/0`, a token
  bucket (3 req/s sustained, burst 10). Req's built-in retry with Retry-After
  backoff acts as a safety net on 429 responses.

  In `test` env the client is pointed at `Req.Test` via config (`:plug`), so no
  network is touched; tests register stubs with `Req.Test.stub(SpaceTraders.API, ...)`.
  """

  alias SpaceTraders.API.RateLimiter
  alias SpaceTraders.API.Model.{Agent, Contract, Cooldown, Extraction, Faction, Market, Ship}

  alias SpaceTraders.API.Model.{
    MarketTransaction,
    ShipCargo,
    ShipFuel,
    ShipNav,
    Shipyard,
    ShipyardTransaction,
    System,
    Waypoint
  }

  @type token() :: String.t()
  @type result() ::
          {:ok, term()}
          | {:error, SpaceTraders.API.GameplayError.t() | SpaceTraders.API.Error.t()}

  @doc "GET / — server status and global data."
  @spec get_status() :: result()
  def get_status do
    request(:get, "/", nil, as: :raw)
  end

  @doc "POST /register — mint a new agent under the given account token."
  @spec register(token(), String.t(), String.t(), String.t()) :: result()
  def register(account_token, symbol, faction, email) do
    request(:post, "/register", account_token,
      json: %{symbol: symbol, faction: faction, email: email},
      as:
        {:map,
         %{
           token: :raw,
           agent: {:model, Agent},
           contract: {:model, Contract},
           faction: {:model, Faction},
           ships: {:list, Ship}
         }}
    )
  end

  @doc "GET /my/agent"
  @spec get_agent(token()) :: result()
  def get_agent(token) do
    request(:get, "/my/agent", token, as: {:model, Agent})
  end

  @doc "GET /my/contracts"
  @spec get_contracts(token()) :: result()
  def get_contracts(token) do
    request(:get, "/my/contracts", token, as: {:list, Contract})
  end

  @doc "GET /my/contracts/{id}"
  @spec get_contract(token(), String.t()) :: result()
  def get_contract(token, contract_id) do
    request(:get, "/my/contracts/#{contract_id}", token, as: {:model, Contract})
  end

  @doc "POST /my/contracts/{id}/accept"
  @spec accept_contract(token(), String.t()) :: result()
  def accept_contract(token, contract_id) do
    request(:post, "/my/contracts/#{contract_id}/accept", token,
      as: {:map, %{agent: {:model, Agent}, contract: {:model, Contract}}}
    )
  end

  @doc "POST /my/contracts/{id}/deliver"
  @spec deliver_contract(token(), String.t(), String.t(), String.t(), pos_integer()) :: result()
  def deliver_contract(token, contract_id, ship_symbol, trade_symbol, units) do
    request(:post, "/my/contracts/#{contract_id}/deliver", token,
      json: %{shipSymbol: ship_symbol, tradeSymbol: trade_symbol, units: units},
      as: {:map, %{contract: {:model, Contract}, cargo: {:model, ShipCargo}}}
    )
  end

  @doc "POST /my/contracts/{id}/fulfill"
  @spec fulfill_contract(token(), String.t()) :: result()
  def fulfill_contract(token, contract_id) do
    request(:post, "/my/contracts/#{contract_id}/fulfill", token,
      as: {:map, %{agent: {:model, Agent}, contract: {:model, Contract}}}
    )
  end

  @doc "POST /my/ships/{symbol}/negotiate/contract — offers a new contract from a faction waypoint."
  @spec negotiate_contract(token(), String.t()) :: result()
  def negotiate_contract(token, ship_symbol) do
    request(:post, "/my/ships/#{ship_symbol}/negotiate/contract", token,
      as: {:map, %{contract: {:model, Contract}}}
    )
  end

  @doc "GET /my/ships"
  @spec get_ships(token()) :: result()
  def get_ships(token) do
    request(:get, "/my/ships", token, as: {:list, Ship})
  end

  @doc "GET /my/ships/{symbol}"
  @spec get_ship(token(), String.t()) :: result()
  def get_ship(token, ship_symbol) do
    request(:get, "/my/ships/#{ship_symbol}", token, as: {:model, Ship})
  end

  @doc "POST /my/ships/{symbol}/navigate"
  @spec navigate_ship(token(), String.t(), String.t()) :: result()
  def navigate_ship(token, ship_symbol, waypoint_symbol) do
    request(:post, "/my/ships/#{ship_symbol}/navigate", token,
      json: %{waypointSymbol: waypoint_symbol},
      as: {:map, %{fuel: {:model, ShipFuel}, nav: {:model, ShipNav}}}
    )
  end

  @doc "POST /my/ships/{symbol}/dock"
  @spec dock_ship(token(), String.t()) :: result()
  def dock_ship(token, ship_symbol) do
    request(:post, "/my/ships/#{ship_symbol}/dock", token, as: {:map, %{nav: {:model, ShipNav}}})
  end

  @doc "POST /my/ships/{symbol}/orbit"
  @spec orbit_ship(token(), String.t()) :: result()
  def orbit_ship(token, ship_symbol) do
    request(:post, "/my/ships/#{ship_symbol}/orbit", token, as: {:map, %{nav: {:model, ShipNav}}})
  end

  @doc "POST /my/ships/{symbol}/extract"
  @spec extract_resources(token(), String.t()) :: result()
  def extract_resources(token, ship_symbol) do
    request(:post, "/my/ships/#{ship_symbol}/extract", token,
      as:
        {:map,
         %{
           cooldown: {:model, Cooldown},
           extraction: {:model, Extraction},
           cargo: {:model, ShipCargo}
         }}
    )
  end

  @doc "POST /my/ships/{symbol}/refuel"
  @spec refuel_ship(token(), String.t()) :: result()
  def refuel_ship(token, ship_symbol) do
    request(:post, "/my/ships/#{ship_symbol}/refuel", token,
      as:
        {:map,
         %{
           agent: {:model, Agent},
           cargo: {:model, ShipCargo},
           fuel: {:model, ShipFuel},
           transaction: {:model, MarketTransaction}
         }}
    )
  end

  @doc "POST /my/ships/{symbol}/sell"
  @spec sell_cargo(token(), String.t(), String.t(), pos_integer()) :: result()
  def sell_cargo(token, ship_symbol, trade_symbol, units) do
    request(:post, "/my/ships/#{ship_symbol}/sell", token,
      json: %{tradeSymbol: trade_symbol, units: units},
      as:
        {:map,
         %{
           agent: {:model, Agent},
           cargo: {:model, ShipCargo},
           transaction: {:model, MarketTransaction}
         }}
    )
  end

  @doc "POST /my/ships/{symbol}/purchase — buys cargo from a market the ship is docked at."
  @spec purchase_cargo(token(), String.t(), String.t(), pos_integer()) :: result()
  def purchase_cargo(token, ship_symbol, trade_symbol, units) do
    request(:post, "/my/ships/#{ship_symbol}/purchase", token,
      json: %{symbol: trade_symbol, units: units},
      as:
        {:map,
         %{
           agent: {:model, Agent},
           cargo: {:model, ShipCargo},
           transaction: {:model, MarketTransaction}
         }}
    )
  end

  @doc "POST /my/ships/{symbol}/jettison — discards cargo from a ship's hold."
  @spec jettison_cargo(token(), String.t(), String.t(), pos_integer()) :: result()
  def jettison_cargo(token, ship_symbol, trade_symbol, units) do
    request(:post, "/my/ships/#{ship_symbol}/jettison", token,
      json: %{symbol: trade_symbol, units: units},
      as: {:map, %{cargo: {:model, ShipCargo}}}
    )
  end

  @doc "POST /my/ships — purchase a ship at a shipyard waypoint."
  @spec purchase_ship(token(), String.t(), String.t()) :: result()
  def purchase_ship(token, ship_type, waypoint_symbol) do
    request(:post, "/my/ships", token,
      json: %{shipType: ship_type, waypointSymbol: waypoint_symbol},
      as:
        {:map,
         %{
           agent: {:model, Agent},
           ship: {:model, Ship},
           transaction: {:model, ShipyardTransaction}
         }}
    )
  end

  @doc "GET /systems/{symbol}"
  @spec get_system(token(), String.t()) :: result()
  def get_system(token, system_symbol) do
    request(:get, "/systems/#{system_symbol}", token, as: {:model, System})
  end

  @doc "GET /systems/{symbol}/waypoints — optional `:type`, `:traits`, `:limit`, `:page` params."
  @spec get_waypoints(token(), String.t(), keyword()) :: result()
  def get_waypoints(token, system_symbol, params \\ []) do
    request(:get, "/systems/#{system_symbol}/waypoints", token,
      params: params,
      as: {:list, Waypoint}
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}"
  @spec get_waypoint(token(), String.t(), String.t()) :: result()
  def get_waypoint(token, system_symbol, waypoint_symbol) do
    request(:get, "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}", token,
      as: {:model, Waypoint}
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}/market"
  @spec get_market(token(), String.t(), String.t()) :: result()
  def get_market(token, system_symbol, waypoint_symbol) do
    request(:get, "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}/market", token,
      as: {:model, Market}
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}/shipyard"
  @spec get_shipyard(token(), String.t(), String.t()) :: result()
  def get_shipyard(token, system_symbol, waypoint_symbol) do
    request(:get, "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}/shipyard", token,
      as: {:model, Shipyard}
    )
  end

  @doc "GET /factions"
  @spec get_factions(token()) :: result()
  def get_factions(token) do
    request(:get, "/factions", token, as: {:list, Faction})
  end

  @doc "GET /factions/{symbol}"
  @spec get_faction(token(), String.t()) :: result()
  def get_faction(token, faction_symbol) do
    request(:get, "/factions/#{faction_symbol}", token, as: {:model, Faction})
  end

  ## Request plumbing

  defp request(method, path, token, opts) do
    RateLimiter.acquire()

    req =
      Req.new(
        build_options(method, path, token)
        |> Keyword.merge(config_req_options())
        |> maybe_put(opts, :json)
        |> maybe_put(opts, :params)
      )

    case Req.request(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        emit_request_metric(path, status)

        case decode(body, opts[:as]) do
          {:error, %SpaceTraders.API.Error{} = error} ->
            {:error, error}

          decoded ->
            {:ok, decoded}
        end

      {:ok, %{status: status, body: body}} when status in 400..499 ->
        emit_request_metric(path, status)
        {:error, gameplay_error(status, body)}

      {:ok, %{status: status}} ->
        emit_request_metric(path, status)
        {:error, SpaceTraders.API.Error.new(status, "unexpected response")}

      {:error, reason} ->
        emit_request_metric(path, 0)
        {:error, SpaceTraders.API.Error.transport(reason)}
    end
  end

  defp emit_request_metric(path, status) do
    :telemetry.execute([:spacetraders, :api, :request], %{count: 1}, %{
      endpoint: path,
      status: status
    })
  end

  defp build_options(method, path, token) do
    [
      base_url: base_url(),
      method: method,
      url: path,
      retry: fn request, response -> retry(request, response, path) end,
      retry_log_level: :warning
    ] ++ maybe_auth(token)
  end

  defp maybe_auth(nil), do: []
  defp maybe_auth(token), do: [auth: {:bearer, token}]

  defp config_req_options do
    Application.get_env(:spacetraders, __MODULE__, [])
    |> Keyword.take([:plug])
  end

  defp maybe_put(options, opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(options, key, value)
      :error -> options
    end
  end

  # Safety net on top of the client-side rate limiter: retry only rate-limit
  # responses (429/503), honoring Retry-After. Transport errors are NOT retried —
  # the client is additive and retrying a state-changing POST could double-apply it.
  defp retry(_request, %Req.Response{status: 429}, path) do
    emit_request_metric(path, 429)
    true
  end

  defp retry(_request, %Req.Response{status: 503}, _path), do: true
  defp retry(_request, _, _path), do: false

  defp base_url do
    Application.get_env(:spacetraders, __MODULE__, [])
    |> Keyword.get(:base_url, "https://api.spacetraders.io/v2")
  end

  defp gameplay_error(_status, %{"error" => %{"code" => code, "message" => message} = error}) do
    SpaceTraders.API.GameplayError.new(code, message, Map.get(error, "data"))
  end

  defp gameplay_error(status, body) do
    SpaceTraders.API.Error.new(status, "unexpected 4xx: #{inspect(body)}")
  end

  ## Decoding

  defp decode(body, {:model, mod}) do
    decode_data(body, &mod.from_json/1)
  end

  defp decode(body, {:list, mod}) do
    decode_data(body, fn data -> Enum.map(data, &mod.from_json/1) end)
  end

  defp decode(body, {:map, fields}) do
    decode_data(body, fn data ->
      Map.new(fields, fn {key, spec} ->
        {key, decode_field(Map.get(data, to_string(key)), spec)}
      end)
    end)
  end

  defp decode(body, :raw) when is_map(body), do: body

  defp decode_data(%{"data" => data}, decode_fun) when is_map(data), do: decode_fun.(data)
  defp decode_data(%{"data" => data}, decode_fun) when is_list(data), do: decode_fun.(data)

  defp decode_data(_body, _decode_fun) do
    {:error, SpaceTraders.API.Error.new(200, "undecodable response: missing `data`")}
  end

  defp decode_field(nil, _spec), do: nil

  defp decode_field(data, {:model, mod}), do: mod.from_json(data)
  defp decode_field(data, {:list, mod}), do: Enum.map(data, &mod.from_json/1)
  defp decode_field(data, :raw), do: data
end
