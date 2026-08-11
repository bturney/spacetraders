defmodule SpaceTraders.ContractsTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Contracts
  alias SpaceTraders.Contracts.DeadlineServer
  alias SpaceTraders.Timeline

  defp agent(token \\ "AGENT_TOKEN"), do: %AgentRecord{agent_token: token}

  setup do
    on_exit(&DeadlineServer.stop_all/0)
    :ok
  end

  defp contract_body(overrides \\ %{}) do
    deadline = Map.get(overrides, "deadline", future_iso(3_600))

    Map.merge(
      %{
        "id" => "ctr-1",
        "accepted" => false,
        "fulfilled" => false,
        "deadlineToAccept" => "2026-08-09T00:00:00.000Z",
        "expiration" => "2026-08-12T00:00:00.000Z",
        "factionSymbol" => "COSMIC",
        "type" => "PROCUREMENT",
        "terms" => %{
          "deadline" => deadline,
          "deliver" => [
            %{
              "tradeSymbol" => "IRON_ORE",
              "destinationSymbol" => "X1-UX81-A2",
              "unitsRequired" => 10,
              "unitsFulfilled" => 0
            }
          ],
          "payment" => %{"onAccepted" => 1000, "onFulfilled" => 5000}
        }
      },
      Map.delete(overrides, "deadline")
    )
  end

  defp future_iso(seconds) do
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  test "accepting a contract schedules its persisted fulfillment deadline" do
    deadline = future_iso(3_600)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/contracts/ctr-1/accept"

      Req.Test.json(conn, %{
        "data" => %{
          "agent" => %{},
          "contract" => contract_body(%{"accepted" => true, "deadline" => deadline})
        }
      })
    end)

    assert {:ok, %{contract: %{id: "ctr-1"}}} = Contracts.accept_contract(agent(), "ctr-1")
    assert [%{owner_type: "contract", owner_id: "ctr-1"}] = Timeline.pending_owners(:contract)
    assert [%{due_at: due_at}] = Timeline.pending_events(:contract, "ctr-1")
    assert DateTime.compare(due_at, DateTime.from_iso8601(deadline) |> elem(1)) == :eq
  end

  test "delivering goods and fulfilling a contract delegate to the API" do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/contracts/ctr-1/deliver" ->
          Req.Test.json(conn, %{"data" => %{"contract" => contract_body(), "cargo" => %{}}})

        "/v2/my/contracts/ctr-1/fulfill" ->
          Req.Test.json(conn, %{
            "data" => %{"agent" => %{}, "contract" => contract_body(%{"fulfilled" => true})}
          })
      end
    end)

    assert {:ok, %{contract: _}} =
             Contracts.deliver_goods(agent(), "ctr-1", "SHIP-1", "IRON_ORE", 10)

    assert {:ok, %{contract: _}} = Contracts.fulfill_contract(agent(), "ctr-1")
  end

  test "negotiating a contract delegates to the API" do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/ships/SHIP-1/negotiate/contract"
      Req.Test.json(conn, %{"data" => %{"contract" => contract_body()}})
    end)

    assert {:ok, %{contract: %{id: "ctr-1"}}} = Contracts.negotiate_contract(agent(), "SHIP-1")
    assert {:error, :agent_token_missing} = Contracts.negotiate_contract(agent(nil), "SHIP-1")
  end

  test "returns readable local errors for missing credentials and invalid units" do
    assert {:error, :agent_token_missing} = Contracts.list_contracts(agent(nil))

    assert {:error, :invalid_units} =
             Contracts.deliver_goods(agent(), "ctr-1", "SHIP-1", "IRON_ORE", 0)
  end
end
