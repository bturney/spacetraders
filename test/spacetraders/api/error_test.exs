defmodule SpaceTraders.API.ErrorTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API
  alias SpaceTraders.API.Error
  alias SpaceTraders.API.GameplayError

  defp stub_error(status, error_payload) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(status)
      |> Req.Test.json(%{"error" => error_payload})
    end)
  end

  describe "gameplay 4xx errors" do
    test "in transit surfaces as %GameplayError{type: :in_transit}" do
      stub_error(409, %{"code" => 4200, "message" => "Ship is in transit.", "data" => %{}})

      assert {:error,
              %GameplayError{type: :in_transit, code: 4200, message: "Ship is in transit."}} =
               API.navigate_ship("TOKEN", "SHIP-1", "X1-UX81-A2")
    end

    test "cooldown surfaces as %GameplayError{type: :cooldown}" do
      stub_error(409, %{"code" => 4000, "message" => "Ship is in cooldown.", "data" => %{}})

      assert {:error, %GameplayError{type: :cooldown}} =
               API.extract_resources("TOKEN", "SHIP-1")
    end

    test "expired contract surfaces as %GameplayError{type: :contract_expired}" do
      stub_error(409, %{"code" => 4503, "message" => "Contract has expired.", "data" => %{}})

      assert {:error, %GameplayError{type: :contract_expired}} =
               API.accept_contract("TOKEN", "c1")
    end

    test "insufficient credits surfaces as %GameplayError{type: :insufficient_credits}" do
      stub_error(400, %{"code" => 4600, "message" => "Not enough credits.", "data" => %{}})

      assert {:error, %GameplayError{type: :insufficient_credits}} =
               API.sell_cargo("TOKEN", "SHIP-1", "IRON_ORE", 10)
    end

    test "unknown code falls back to type :other but stays a GameplayError" do
      stub_error(400, %{"code" => 9999, "message" => "Unknown thing.", "data" => %{}})

      assert {:error, %GameplayError{type: :other, code: 9999}} =
               API.get_ship("TOKEN", "SHIP-1")
    end
  end

  describe "fatal errors" do
    test "5xx surfaces as %Error{} — distinguishable from gameplay" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => %{"code" => 5000, "message" => "boom", "data" => %{}}})
      end)

      assert {:error, %Error{status: 500}} = API.get_agent("TOKEN")
    end

    test "transport error surfaces as %Error{} with reason" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Error{reason: %Req.TransportError{reason: :timeout}}} =
               API.get_agent("TOKEN")
    end

    test "4xx without an error envelope surfaces as %Error{}" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.text("not found")
      end)

      assert {:error, %Error{status: 404}} = API.get_agent("TOKEN")
    end

    test "a 200 without a decodable `data` body surfaces as %Error{}, not a crash" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.text(conn, "")
      end)

      assert {:error, %Error{status: 200}} = API.get_agent("TOKEN")
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

      assert {:ok, %{symbol: "ORBITALIST"}} = API.get_agent("TOKEN")
    end
  end
end
