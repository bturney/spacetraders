defmodule SpaceTraders.API.ErrorTest do
  # This module asserts application-wide CapacityGovernor state after protocol
  # responses, so concurrent API tests could erase the rejection window.
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.API
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.API.Error
  alias SpaceTraders.API.GameplayError

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RecordedDispatchFixtures

  defp stub_error(status, error_payload) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => error_payload})
    end)
  end

  describe "gameplay 4xx errors" do
    test "redacts an AgentToken echoed by an API error" do
      stub_error(401, %{
        "code" => 4100,
        "message" => "Rejected AGENT_TOKEN_SECRET",
        "data" => %{"authorization" => "Bearer AGENT_TOKEN_SECRET"}
      })

      assert {:error, %GameplayError{} = error} =
               API.get_agent(agent_token_reference("AGENT_TOKEN_SECRET"))

      refute inspect(error) =~ "AGENT_TOKEN_SECRET"
      assert error.message == "Rejected [REDACTED]"
    end

    test "in transit surfaces as %GameplayError{type: :in_transit}" do
      stub_error(409, %{"code" => 4200, "message" => "Ship is in transit.", "data" => %{}})

      assert {:error,
              %GameplayError{type: :in_transit, code: 4200, message: "Ship is in transit."}} =
               dispatch_action("SHIP-1", %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"})
    end

    test "cooldown surfaces as %GameplayError{type: :cooldown}" do
      stub_error(409, %{"code" => 4000, "message" => "Ship is in cooldown.", "data" => %{}})

      assert {:error, %GameplayError{type: :cooldown}} =
               dispatch_action("SHIP-1", %{"kind" => "extract"})
    end

    test "expired contract surfaces as %GameplayError{type: :contract_expired}" do
      stub_error(409, %{"code" => 4503, "message" => "Contract has expired.", "data" => %{}})

      assert {:error, %GameplayError{type: :contract_expired}} =
               API.accept_contract(agent_token_reference(), "c1")
    end

    test "insufficient credits surfaces as %GameplayError{type: :insufficient_credits}" do
      stub_error(400, %{"code" => 4600, "message" => "Not enough credits.", "data" => %{}})

      assert {:error, %GameplayError{type: :insufficient_credits}} =
               dispatch_action("SHIP-1", %{
                 "kind" => "sell",
                 "trade_symbol" => "IRON_ORE",
                 "units" => 10
               })
    end

    test "unknown code falls back to type :other but stays a GameplayError" do
      stub_error(400, %{"code" => 9999, "message" => "Unknown thing.", "data" => %{}})

      assert {:error, %GameplayError{type: :other, code: 9999}} =
               API.get_ship(agent_token_reference(), "SHIP-1")
    end
  end

  describe "fatal errors" do
    test "5xx surfaces as %Error{} — distinguishable from gameplay" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"code" => 5000, "message" => "boom", "data" => %{}}})
      end)

      assert {:error, %Error{status: 500}} = API.get_agent(agent_token_reference())
    end

    test "transport error surfaces as %Error{} with reason" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Error{reason: %Req.TransportError{reason: :timeout}}} =
               API.get_agent(agent_token_reference())
    end

    test "4xx without an error envelope surfaces as %Error{}" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.text("not found")
      end)

      assert {:error, %Error{status: 404}} = API.get_agent(agent_token_reference())
    end

    test "a 200 without a decodable `data` body surfaces as %Error{}, not a crash" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.text(conn, "")
      end)

      assert {:error, %Error{status: 200}} = API.get_agent(agent_token_reference())
    end
  end

  describe "429 Retry-After backoff" do
    test "a 429 with Retry-After is retried and the retry succeeds" do
      Req.Test.expect(SpaceTraders.API, 2, fn conn ->
        retries = Map.get(conn.private, :req_private, %{})[:req_retry_count] || 0

        if retries > 0 do
          Req.Test.json(conn, %{"data" => %{"symbol" => "ORBITALIST", "credits" => 1}})
        else
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.put_status(429)
          |> Req.Test.json(%{
            "error" => %{"code" => 429, "message" => "rate limited", "data" => %{}}
          })
        end
      end)

      assert {:ok, %{symbol: "ORBITALIST"}} = API.get_agent(agent_token_reference())
    end

    test "a 429 on a read that cannot retry still reports protocol pressure to the governor" do
      Req.Test.expect(SpaceTraders.API, 1, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
      end)

      assert {:error, %GameplayError{code: 429}} =
               API.get_ship(agent_token_reference(), "SHIP-1", retry: false)

      assert %{protocol_rejections: rejections} = SpaceTraders.API.CapacityGovernor.diagnostics()

      assert rejections >= 1
    end

    # #589: Req reports Retry-After in milliseconds; passing that to the
    # governor as seconds turned a 2-second window into the 60-second clamp.
    test "the governor defers ordinary work for the server's Retry-After seconds" do
      Req.Test.expect(SpaceTraders.API, 1, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
      end)

      before = DateTime.utc_now()

      assert {:error, %GameplayError{code: 429}} =
               API.get_ship(agent_token_reference(), "SHIP-1", retry: false)

      assert %{retry_after_until: %DateTime{} = until} =
               SpaceTraders.API.CapacityGovernor.diagnostics()

      assert DateTime.diff(until, before, :millisecond) in 1_000..3_000
    end

    test "does not replay a failed mutation" do
      Req.Test.expect(SpaceTraders.API, 1, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => %{"code" => 503, "message" => "unavailable"}})
      end)

      assert {:error, %Error{status: 503}} =
               dispatch_action("SHIP-1", %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"})
    end

    test "a rate-limited Ship action defers under one committed attempt without a private retry" do
      agent = operator_fixture() |> agent_fixture()

      %{intent: intent, attempt: attempt} =
        prepare_action(agent, "SHIP-1", %{"kind" => "navigate", "waypoint" => "X1-UX81-A2"})

      test_pid = self()

      Req.Test.expect(SpaceTraders.API, 1, fn conn ->
        attempts = SpaceTraders.MutationAttempts.list_for_agent(agent)
        send(test_pid, {conn.request_path, attempts})

        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => 429, "message" => "rate limited"}})
      end)

      assert {:error, %GameplayError{code: 429}} = API.dispatch_recorded(attempt)

      assert_received {path, [%{state: "sent_or_unknown", id: attempt_id}]}
      assert path == "/v2/my/ships/SHIP-1/navigate"
      assert attempt_id == attempt.id
      assert Repo.get!(SpaceTraders.Fleet.Intent, intent.id).mutation_attempt_id == attempt.id

      assert [%{state: "rejected", sent_or_unknown_at: sent, retry_authorized: false}] =
               SpaceTraders.MutationAttempts.list_for_agent(agent)

      assert %DateTime{} = sent
      assert SpaceTraders.API.CapacityGovernor.diagnostics().protocol_rejections >= 1
      assert Repo.get!(SpaceTraders.Fleet.Intent, intent.id).mutation_attempt_id == attempt.id
    end
  end

  defp agent_token_reference(token \\ "TOKEN") do
    operator_fixture()
    |> agent_fixture(%{agent_token: token})
    |> AgentTokenReference.new()
  end
end
