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

  Every request first waits on `SpaceTraders.API.RateLimiter.acquire/0`, a
  dual-pool token bucket modelled on the game's granted budget: 2 req/s steady
  plus a separate pool of 30 requests per minute (≈2.5 req/s sustained
  average). Admission is ordered by the API Capacity Governor, which also
  delays new ordinary admissions when the game returns `Retry-After`. Req's
  built-in 429 retry is a safety net, not the primary throughput shaper.

  In `test` env the client is pointed at `Req.Test` via config (`:plug`), so no
  network is touched; tests register stubs with `Req.Test.stub(SpaceTraders.API, ...)`.
  """

  alias SpaceTraders.API.RateLimiter
  alias SpaceTraders.API.CapacityGovernor
  alias SpaceTraders.API.ShadowAdmission
  alias SpaceTraders.API.Pagination
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.API.RecordedDispatch
  alias SpaceTraders.API.ShipAction
  alias SpaceTraders.Evidence.Demand
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  alias SpaceTraders.API.Model.{
    Agent,
    Construction,
    Contract,
    Faction,
    JumpGate,
    Market,
    Ship
  }

  alias SpaceTraders.API.Model.{
    Shipyard,
    ShipyardTransaction,
    System,
    Waypoint
  }

  alias SpaceTraders.API.Request.{
    PurchaseShipRequest,
    RegisterRequest
  }

  @type token() :: AgentTokenReference.t()
  @type account_token() :: String.t()
  @type result() ::
          {:ok, term()}
          | {:error, :agent_token_missing}
          | {:error, SpaceTraders.API.GameplayError.t() | SpaceTraders.API.Error.t()}

  defmodule MutationSuppressedError do
    @moduledoc false
    defexception [:reason, message: "gameplay mutation suppressed"]
  end

  @doc "GET / — server status and global data."
  @spec get_status() :: result()
  def get_status do
    request(:get, "/", nil, as: :raw)
  end

  @doc "POST /register — mint a new agent under the given account token."
  @spec register(account_token(), String.t(), String.t(), String.t()) :: result()
  def register(account_token, symbol, faction, email) do
    request_with_token(:post, "/register", account_token,
      json:
        RegisterRequest.new(%{symbol: symbol, faction: faction, email: email})
        |> RegisterRequest.to_json(),
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
  @spec get_agent(token(), keyword()) :: result()
  def get_agent(token, opts \\ []) when is_list(opts) do
    request(:get, "/my/agent", token, Keyword.merge(opts, as: {:model, Agent}))
  end

  @doc "GET /my/contracts"
  @spec get_contracts(token()) :: result()
  def get_contracts(token, opts \\ []) when is_list(opts) do
    request(:get, "/my/contracts", token, Keyword.merge(opts, as: {:list, Contract}))
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
  @spec get_ships(token(), keyword()) :: result()
  def get_ships(token, opts \\ []) when is_list(opts) do
    request(:get, "/my/ships", token, Keyword.merge(opts, as: {:list, Ship}))
  end

  @doc "GET /my/ships/{symbol}"
  @spec get_ship(token(), String.t()) :: result()
  def get_ship(token, ship_symbol), do: get_ship(token, ship_symbol, [])

  @doc false
  def get_ship(token, ship_symbol, opts) when is_list(opts) do
    request(:get, "/my/ships/#{ship_symbol}", token,
      as: {:model, Ship},
      retry: Keyword.get(opts, :retry, :default)
    )
  end

  @doc "Sends one linked recorded Ship attempt after independently committed admission."
  def dispatch_recorded(%SpaceTraders.Fleet.Intent{mutation_attempt_id: id}) when is_binary(id),
    do: dispatch_recorded(%Attempt{id: id})

  def dispatch_recorded(%SpaceTraders.Fleet.Intent{}), do: {:error, :recorded_dispatch_required}

  def dispatch_recorded(%Attempt{id: id}) do
    with :ok <- RecordedDispatch.require_commit_boundary() do
      attempt = MutationAttempts.get!(id)

      with {:ok, schema} <- ShipAction.response_schema(attempt.operation_id),
           {:ok, token} <- resolve_agent_token(%AgentTokenReference{agent_id: attempt.agent_id}) do
        operation = OperationInventory.fetch!(attempt.operation_id)
        request = attempt.prepared_evidence["request"]

        opts = [
          agent_id: attempt.agent_id,
          recorded_attempt: attempt,
          retry: false,
          as: schema
        ]

        opts =
          if is_nil(request["body"]), do: opts, else: Keyword.put(opts, :json, request["body"])

        context =
          Map.new(
            ~w(request_id operator_id agent_id fleet_generation_id strategy_revision_id decision_episode_id commitment_id ship_id ship_symbol intent_id)a,
            fn key -> {key, attempt.provenance[Atom.to_string(key)]} end
          )
          |> Map.reject(fn {_key, value} -> is_nil(value) end)

        SpaceTraders.Observability.with_context(Map.to_list(context), fn ->
          admit_and_send(operation.method, request["path"], token, opts)
        end)
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :recorded_operation_not_activated}
      end
    end
  end

  @doc "POST /my/ships — purchase a ship at a shipyard waypoint."
  @spec purchase_ship(token(), String.t(), String.t()) :: result()
  def purchase_ship(token, ship_type, waypoint_symbol) do
    request(:post, "/my/ships", token,
      json:
        PurchaseShipRequest.new(%{ship_type: ship_type, waypoint_symbol: waypoint_symbol})
        |> PurchaseShipRequest.to_json(),
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
  @spec get_system(token(), String.t(), keyword()) :: result()
  def get_system(token, system_symbol, opts \\ []) when is_list(opts) do
    request(:get, "/systems/#{system_symbol}", token, Keyword.merge(opts, as: {:model, System}))
  end

  @doc "GET /systems/{symbol}/waypoints — optional `:type`, `:traits`, `:limit`, `:page` params."
  @spec get_waypoints(token(), String.t(), keyword(), keyword()) :: result()
  def get_waypoints(token, system_symbol, params \\ [], opts \\ [])
      when is_list(params) and is_list(opts) do
    request(
      :get,
      "/systems/#{system_symbol}/waypoints",
      token,
      Keyword.merge(opts, params: params, as: {:list, Waypoint})
    )
  end

  @doc "GET /systems/{symbol}/waypoints across every page."
  @spec get_waypoints_paginated(token(), String.t(), keyword(), keyword()) ::
          {:ok, list()} | {:error, term(), list()}
  def get_waypoints_paginated(token, system_symbol, params \\ [], opts \\ [])
      when is_list(params) and is_list(opts) do
    Pagination.waypoints(token, system_symbol, params, opts)
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}"
  @spec get_waypoint(token(), String.t(), String.t(), keyword()) :: result()
  def get_waypoint(token, system_symbol, waypoint_symbol, opts \\ []) when is_list(opts) do
    request(
      :get,
      "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}",
      token,
      Keyword.merge(opts, as: {:model, Waypoint})
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}/market"
  @spec get_market(token(), String.t(), String.t(), keyword()) :: result()
  def get_market(token, system_symbol, waypoint_symbol, opts \\ []) when is_list(opts) do
    request(
      :get,
      "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}/market",
      token,
      Keyword.merge(opts, as: {:model, Market})
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}/construction"
  @spec get_construction(token(), String.t(), String.t(), keyword()) :: result()
  def get_construction(token, system_symbol, waypoint_symbol, opts \\ []) when is_list(opts) do
    request(
      :get,
      "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}/construction",
      token,
      Keyword.merge(opts, as: {:model, Construction})
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}/jump-gate"
  @spec get_jump_gate(token(), String.t(), String.t(), keyword()) :: result()
  def get_jump_gate(token, system_symbol, waypoint_symbol, opts \\ []) when is_list(opts) do
    request(
      :get,
      "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}/jump-gate",
      token,
      Keyword.merge(opts, as: {:model, JumpGate})
    )
  end

  @doc "GET /systems/{symbol}/waypoints/{waypoint}/shipyard"
  @spec get_shipyard(token(), String.t(), String.t(), keyword()) :: result()
  def get_shipyard(token, system_symbol, waypoint_symbol, opts \\ []) when is_list(opts) do
    request(
      :get,
      "/systems/#{system_symbol}/waypoints/#{waypoint_symbol}/shipyard",
      token,
      Keyword.merge(opts, as: {:model, Shipyard})
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

  defp request(method, path, %AgentTokenReference{} = credential_ref, opts) do
    with :ok <- runtime_authorized?(method),
         {:ok, token} <- resolve_agent_token(credential_ref),
         :ok <- mutation_authorized?(method, token) do
      admit_and_send(method, path, token, Keyword.put(opts, :agent_id, credential_ref.agent_id))
    end
  end

  defp request(method, path, nil, opts), do: request_with_token(method, path, nil, opts)

  defp request_with_token(method, path, token, opts) do
    with :ok <- mutation_authorized?(method, token) do
      do_request(method, path, token, opts)
    end
  end

  defp do_request(method, path, token, opts) do
    with :ok <- mutation_authorized?(method, token) do
      admit_and_send(method, path, token, opts)
    end
  end

  defp admit_and_send(method, path, token, opts) do
    with {operation, shadow} <- observe_request(method, path, opts),
         {:ok, capacity} <- admit_capacity(operation, opts) do
      # Observe before waiting for capacity so shadow queue_time spans the real
      # limiter wait. Recorded and legacy dispatch recheck authorization at send.
      RateLimiter.acquire()

      send_request(method, path, token, opts, operation, shadow, capacity)
    end
  end

  defp observe_request(method, path, opts) do
    operation = OperationInventory.fetch_by_request!(method, path)
    {operation, ShadowAdmission.observe_request(operation, admission_attrs(opts))}
  end

  defp admit_capacity(operation, opts),
    do: CapacityGovernor.admit(operation, admission_attrs(opts))

  defp admission_attrs(opts) do
    demand_attrs =
      case Keyword.get(opts, :demand) do
        %Demand{} = demand ->
          demand
          |> Map.from_struct()
          |> Map.take([:lane, :deadline_at, :strategic_priority, :expected_value, :discovery])

        _ ->
          %{}
      end

    Map.merge(logger_admission_context(), demand_attrs)
  end

  defp logger_admission_context do
    Logger.metadata()
    |> Map.new()
    |> Map.take([
      :lane,
      :deadline_at,
      :strategic_priority,
      :expected_value,
      :discovery,
      :evidence_fingerprint
    ])
  end

  defp send_request(method, path, token, opts, operation, shadow, capacity) do
    with {:ok, attempt} <- prepare_mutation_attempt(operation, path, opts) do
      req =
        Req.new(
          build_options(method, path, token)
          |> Keyword.merge(config_req_options())
          |> maybe_put(opts, :json)
          |> maybe_put(opts, :params)
          |> maybe_put_retry(opts)
        )
        |> Req.Request.append_request_steps(
          spacetraders_mutation_admission: fn request ->
            authorize_dispatch(request, method, token, attempt, shadow, opts)
          end
        )

      request_and_record_outcome(
        req,
        attempt,
        path,
        method,
        token,
        opts,
        operation,
        shadow,
        capacity
      )
    else
      {:error, reason} ->
        complete_shadow(
          shadow,
          capacity,
          :not_dispatched,
          :persistence_error,
          {:error, SpaceTraders.API.Error.transport(reason)}
        )
    end
  end

  defp request_and_record_outcome(
         req,
         attempt,
         path,
         method,
         token,
         opts,
         operation,
         shadow,
         capacity
       ) do
    case Req.request(req) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        emit_request_metric(operation, path, status)

        case decode(body, opts[:as]) do
          {:error, %SpaceTraders.API.Error{} = error} ->
            case record_mutation_outcome(attempt, :ambiguous, %{
                   status: status,
                   reason: "response_decode_failed"
                 }) do
              :ok ->
                complete_shadow(shadow, capacity, status, :decode_error, {:error, error})

              {:error, reason} ->
                complete_shadow(
                  shadow,
                  capacity,
                  status,
                  :persistence_error,
                  {:error, SpaceTraders.API.Error.transport(reason)}
                )
            end

          decoded ->
            case record_mutation_outcome(attempt, :succeeded, %{status: status}) do
              :ok ->
                complete_shadow(shadow, capacity, status, :ok, {:ok, decoded})

              {:error, reason} ->
                complete_shadow(
                  shadow,
                  capacity,
                  status,
                  :persistence_error,
                  {:error, SpaceTraders.API.Error.transport(reason)}
                )
            end
        end

      {:ok, %{status: status, body: body} = response} when status in 400..499 ->
        emit_request_metric(operation, path, status)

        case record_mutation_outcome(attempt, :rejected, %{status: status}) do
          :ok ->
            case mutation_authorized_after_response(status, method, token) do
              :ok ->
                # A still-authorized protocol rejection is a real capacity signal.
                # Our own suppression is not, so the Governor never records a
                # Retry-After window for a request it did not have to run.
                if status == 429 and opts[:recorded_attempt] do
                  report_protocol_rejection(Req.Response.get_retry_after(response))
                end

                complete_shadow(
                  shadow,
                  capacity,
                  status,
                  :client_error,
                  {:error, gameplay_error(status, SpaceTraders.Observability.redact(body, token))}
                )

              {:error, reason} ->
                complete_shadow(shadow, capacity, status, :suppressed, {:error, reason})
            end

          {:error, persistence_reason} ->
            complete_shadow(
              shadow,
              capacity,
              status,
              :persistence_error,
              {:error, SpaceTraders.API.Error.transport(persistence_reason)}
            )
        end

      {:ok, %{status: status}} ->
        emit_request_metric(operation, path, status)

        case record_mutation_outcome(attempt, :ambiguous, %{status: status}) do
          :ok ->
            complete_shadow(
              shadow,
              capacity,
              status,
              shadow_outcome(status),
              {:error, SpaceTraders.API.Error.new(status, "unexpected response")}
            )

          {:error, reason} ->
            complete_shadow(
              shadow,
              capacity,
              status,
              :persistence_error,
              {:error, SpaceTraders.API.Error.transport(reason)}
            )
        end

      {:error, reason} ->
        case reason do
          %MutationSuppressedError{reason: suppression_reason} ->
            complete_shadow(
              shadow,
              capacity,
              :not_dispatched,
              :suppressed,
              {:error, suppression_reason}
            )

          reason ->
            emit_request_metric(operation, path, "unknown")
            redacted_reason = SpaceTraders.Observability.redact(reason, token)

            case record_mutation_outcome(attempt, :ambiguous, %{
                   reason: inspect(redacted_reason)
                 }) do
              :ok ->
                complete_shadow(
                  shadow,
                  capacity,
                  :unknown,
                  :unknown,
                  {:error, SpaceTraders.API.Error.transport(redacted_reason)}
                )

              {:error, persistence_reason} ->
                complete_shadow(
                  shadow,
                  capacity,
                  :unknown,
                  :persistence_error,
                  {:error, SpaceTraders.API.Error.transport(persistence_reason)}
                )
            end
        end
    end
  end

  defp authorize_dispatch(request, method, token, attempt, shadow, opts) do
    if opts[:recorded_attempt] do
      case RecordedDispatch.admit_send(attempt) do
        {:ok, _attempt} ->
          ShadowAdmission.observe_dispatch(shadow)
          request

        {:error, reason} ->
          Req.Request.halt(request, %MutationSuppressedError{reason: reason})
      end
    else
      authorize_unrecorded_dispatch(request, method, token, attempt, shadow)
    end
  end

  defp authorize_unrecorded_dispatch(request, method, token, attempt, shadow) do
    with :ok <- mutation_authorized?(method, token),
         {:ok, _attempt} <- mark_mutation_sent(attempt) do
      ShadowAdmission.observe_dispatch(shadow)
      request
    else
      {:error, reason} -> Req.Request.halt(request, %MutationSuppressedError{reason: reason})
    end
  end

  defp prepare_mutation_attempt(%{classification: :read}, _path, _opts), do: {:ok, nil}

  defp prepare_mutation_attempt(%{owner: :ship_execution}, _path, opts) do
    case opts[:recorded_attempt] do
      %Attempt{} = attempt -> {:ok, attempt}
      _ -> {:error, :recorded_dispatch_required}
    end
  end

  defp prepare_mutation_attempt(operation, path, opts) do
    case opts[:recorded_attempt] do
      %Attempt{} = attempt -> {:ok, attempt}
      nil -> MutationAttempts.prepare(operation, path, opts)
    end
  end

  defp complete_shadow(shadow, capacity, status, outcome, result) do
    CapacityGovernor.complete(capacity, status)
    ShadowAdmission.observe_outcome(shadow, status, outcome)
    result
  end

  defp shadow_outcome(status) when status in 500..599, do: :server_error
  defp shadow_outcome(_status), do: :unknown

  defp mark_mutation_sent(nil), do: {:ok, nil}
  defp mark_mutation_sent(attempt), do: MutationAttempts.mark_sent_or_unknown(attempt)

  defp record_mutation_outcome(nil, _classification, _evidence), do: :ok

  defp record_mutation_outcome(attempt, classification, evidence) do
    case MutationAttempts.record_outcome(attempt, classification, evidence) do
      {:ok, _attempt} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mutation_authorized?(:get, _token), do: :ok

  defp mutation_authorized?(_method, token) do
    with :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         :ok <- SpaceTraders.FleetGenerationAdmission.mutation_allowed?(token) do
      SpaceTraders.EmergencyStopAdmission.mutation_allowed?(token)
    end
  end

  defp runtime_authorized?(:get), do: :ok
  defp runtime_authorized?(_method), do: SpaceTraders.RuntimeAuthority.execution_allowed?()

  defp mutation_authorized_after_response(429, method, token),
    do: mutation_authorized?(method, token)

  defp mutation_authorized_after_response(_status, _method, _token), do: :ok

  defp emit_request_metric(operation, path, status) do
    SpaceTraders.Observability.api_request(operation, path, status)
  end

  defp build_options(method, path, token) do
    [
      base_url: base_url(),
      method: method,
      url: path,
      retry: retry_strategy(method, path, token),
      retry_log_level: false
    ] ++ maybe_auth(token)
  end

  defp maybe_auth(nil), do: []
  defp maybe_auth(token), do: [auth: {:bearer, token}]

  defp resolve_agent_token(%AgentTokenReference{agent_id: agent_id}) when is_integer(agent_id) do
    case Repo.get(AgentRecord, agent_id) do
      %AgentRecord{agent_token: token} when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :agent_token_missing}
    end
  end

  defp resolve_agent_token(%AgentTokenReference{temporary_id: temporary_id})
       when is_reference(temporary_id) do
    case Process.delete({AgentTokenReference, temporary_id}) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :agent_token_missing}
    end
  end

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

  defp maybe_put_retry(options, opts) do
    case Keyword.get(opts, :retry, :default) do
      :default -> options
      retry -> Keyword.put(options, :retry, retry)
    end
  end

  # A 429 proves the game rejected the request before applying it, so every
  # method can safely honor Retry-After. Other mutation failures are ambiguous:
  # their caller persists action evidence and reconciles before any retry.
  defp retry_strategy(method, path, token),
    do: fn request, response -> retry(request, response, path, method, token) end

  defp retry(_request, %Req.Response{status: 429} = response, path, method, token) do
    if mutation_authorized?(method, token) != :ok do
      false
    else
      emit_request_metric(operation_for_retry(path, method), path, 429)
      report_protocol_rejection(Req.Response.get_retry_after(response))

      case Req.Response.get_retry_after(response) do
        delay when is_integer(delay) -> {:delay, delay}
        _ -> true
      end
    end
  end

  defp retry(_request, %Req.Response{status: status}, path, :get, _token)
       when status in 500..599 do
    emit_request_metric(operation_for_retry(path, :get), path, status)
    true
  end

  defp retry(_request, %Req.TransportError{}, path, :get, _token) do
    emit_request_metric(operation_for_retry(path, :get), path, "unknown")
    true
  end

  defp retry(_request, _response, _path, _method, _token), do: false

  defp report_protocol_rejection(delay_seconds)
       when is_integer(delay_seconds) and delay_seconds > 0,
       do: CapacityGovernor.protocol_rejected(delay_seconds)

  defp report_protocol_rejection(_delay), do: CapacityGovernor.protocol_rejected(0)

  defp operation_for_retry(path, method),
    do: OperationInventory.fetch_by_request!(method, path)

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
    decode_safely(fn -> decode_data(body, &mod.from_json/1) end)
  end

  defp decode(body, {:list, mod}) do
    decode_safely(fn -> decode_data(body, fn data -> Enum.map(data, &mod.from_json/1) end) end)
  end

  defp decode(body, {:map, fields}) do
    decode_safely(fn ->
      decode_data(body, fn data ->
        Map.new(fields, fn {key, spec} ->
          {key, decode_field(Map.get(data, to_string(key)), spec)}
        end)
      end)
    end)
  end

  defp decode(body, :raw) when is_map(body), do: body

  defp decode_data(%{"data" => data}, decode_fun) when is_map(data), do: decode_fun.(data)
  defp decode_data(%{"data" => data}, decode_fun) when is_list(data), do: decode_fun.(data)

  defp decode_data(_body, _decode_fun) do
    {:error, SpaceTraders.API.Error.new(200, "undecodable response: missing `data`")}
  end

  defp decode_safely(decode_fun) do
    decode_fun.()
  rescue
    _error in [FunctionClauseError, BadMapError, Protocol.UndefinedError] ->
      {:error, SpaceTraders.API.Error.new(200, "undecodable response: invalid model field")}
  end

  defp decode_field(nil, _spec), do: nil

  defp decode_field(data, {:model, mod}), do: mod.from_json(data)
  defp decode_field(data, {:list, mod}), do: Enum.map(data, &mod.from_json/1)
  defp decode_field(data, :raw), do: data
end
