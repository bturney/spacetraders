defmodule SpaceTraders.API.RecordedDispatchTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures
  import SpaceTraders.RecordedDispatchFixtures

  alias SpaceTraders.API
  alias SpaceTraders.API.{AgentTokenReference, OperationInventory, RecordedDispatch, ShipAction}
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.MutationAttempts

  # Existing operation parameters, independent of the adapter's implementation.
  # These exercise admission through its public interface, not Fleet reachability.
  @actions [
    {"orbit-ship",
     %{"kind" => "orbit", "waypoint" => "X1-TEST-A1", "expected" => %{"status" => "IN_ORBIT"}}},
    {"dock-ship", %{"kind" => "dock", "waypoint" => "X1-TEST-A1"}},
    {"navigate-ship", %{"kind" => "navigate", "waypoint" => "X1-TEST-B2"}},
    {"warp-ship", %{"kind" => "warp", "waypoint" => "X2-TEST-A1"}},
    {"jump-ship",
     %{
       "kind" => "jump",
       "waypoint" => "X2-TEST-A1",
       "credits_before" => 2000,
       "antimatter_cost" => 50
     }},
    {"patch-ship-nav", %{"kind" => "set_flight_mode", "flight_mode" => "DRIFT"}},
    {"refuel-ship", %{"kind" => "refuel", "fuel_before" => 20}},
    {"purchase-cargo",
     %{"kind" => "buy", "trade_symbol" => "IRON_ORE", "units" => 5, "listing_price" => 10}},
    {"sell-cargo", %{"kind" => "sell", "trade_symbol" => "IRON_ORE", "units" => 5}},
    {"deliver-contract",
     %{
       "kind" => "deliver",
       "trade_symbol" => "IRON_ORE",
       "units" => 5,
       "recipient" => %{"type" => "contract", "contract_id" => "contract-1"}
     }},
    {"supply-construction",
     %{
       "kind" => "deliver",
       "trade_symbol" => "IRON_ORE",
       "units" => 5,
       "recipient" => %{
         "type" => "construction",
         "system" => "X1-TEST",
         "waypoint" => "X1-TEST-A1"
       }
     }},
    {"transfer-cargo",
     %{
       "kind" => "transfer",
       "trade_symbol" => "IRON_ORE",
       "units" => 5,
       "target_ship" => "RECEIVER"
     }},
    {"jettison", %{"kind" => "jettison", "trade_symbol" => "IRON_ORE", "units" => 5}},
    {"create-chart", %{"kind" => "chart", "waypoint" => "X1-TEST-A1"}},
    {"create-ship-waypoint-scan", %{"kind" => "scan_waypoints"}},
    {"create-survey", %{"kind" => "survey"}},
    {"extract-resources", %{"kind" => "extract"}},
    {"extract-resources-with-survey",
     %{
       "kind" => "extract",
       "survey" => %{
         "signature" => "survey",
         "symbol" => "X1-TEST-A1",
         "expiration" => "2099-01-01T00:00:00Z",
         "deposits" => [%{"symbol" => "IRON_ORE"}],
         "size" => "SMALL"
       }
     }},
    {"siphon-resources", %{"kind" => "siphon"}},
    {"ship-refine", %{"kind" => "refine", "produce" => "IRON"}},
    {"install-ship-module",
     %{"kind" => "install_module", "module_symbol" => "MODULE_CARGO_HOLD_I"}},
    {"remove-ship-module", %{"kind" => "remove_module", "module_symbol" => "MODULE_CARGO_HOLD_I"}}
  ]

  test "every generated Ship operation is implemented or explicitly unsupported" do
    ship_operations = OperationInventory.all() |> Enum.filter(&(&1.owner == :ship_execution))

    declared =
      ShipAction.implemented_operations() ++ Map.keys(ShipAction.unsupported_operations())

    assert length(declared) == length(Enum.uniq(declared))
    assert MapSet.new(declared) == MapSet.new(ship_operations, & &1.id)
    assert MapSet.new(ShipAction.implemented_operations()) == MapSet.new(@actions, &elem(&1, 0))

    assert Enum.all?(
             Map.values(ShipAction.unsupported_operations()),
             &(is_binary(&1) and &1 != "")
           )
  end

  for {id, action} <- @actions do
    @id id
    @action action
    test "#{id} cannot escape an enclosing caller transaction" do
      agent = operator_fixture() |> agent_fixture()
      %{intent: intent, attempt: attempt} = prepare_action(agent, "RECORDED", @action)
      assert attempt.operation_id == @id
      Req.Test.stub(API, fn _conn -> flunk("uncommitted Ship request reached transport") end)

      assert {:error, :caller_rollback} =
               Repo.transaction(fn ->
                 assert {:error, :recorded_dispatch_requires_commit} =
                          API.dispatch_recorded(attempt)

                 assert {:error, :recorded_dispatch_requires_commit} =
                          API.dispatch_recorded(intent)

                 assert {:error, :recorded_dispatch_requires_commit} =
                          RecordedDispatch.prepare(agent, intent, @action)

                 assert {:error, :recorded_dispatch_requires_commit} =
                          RecordedDispatch.prepare_retry(agent, intent, attempt)

                 Repo.rollback(:caller_rollback)
               end)

      assert %{state: "prepared", sent_or_unknown_at: nil} = MutationAttempts.get!(attempt.id)
    end
  end

  test "a raw ledger attempt without selected-action linkage cannot dispatch" do
    agent = operator_fixture() |> agent_fixture()

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("navigate-ship"),
        "/my/ships/UNRECORDED/navigate",
        agent_id: agent.id,
        json: %{"waypointSymbol" => "X1-TEST-A1"}
      )

    Req.Test.stub(API, fn _ -> flunk("unlinked mutation reached transport") end)
    assert {:error, :recorded_action_no_longer_selected} = API.dispatch_recorded(attempt)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(attempt.id)
  end

  test "changed recorded request parameters cannot dispatch under an unchanged selection" do
    agent = operator_fixture() |> agent_fixture()

    %{attempt: attempt} =
      prepare_action(agent, "RECORDED", %{"kind" => "navigate", "waypoint" => "X1-TEST-A1"})

    evidence =
      put_in(attempt.prepared_evidence, ["request", "body", "waypointSymbol"], "X1-TEST-B2")

    attempt |> Ecto.Changeset.change(prepared_evidence: evidence) |> Repo.update!()
    Req.Test.stub(API, fn _ -> flunk("altered recorded request reached transport") end)
    assert {:error, :recorded_action_no_longer_selected} = API.dispatch_recorded(attempt)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(attempt.id)
  end

  for loss <- [:receiver_claim, :receiver_capacity] do
    @loss loss
    test "transfer revalidates #{@loss} after preparation" do
      agent = operator_fixture() |> agent_fixture()

      %{intent: intent, attempt: attempt} =
        prepare_action(agent, "SOURCE", %{
          "kind" => "transfer",
          "target_ship" => "RECEIVER",
          "trade_symbol" => "IRON_ORE",
          "units" => 5
        })

      assert attempt.dependency_keys == ["ship:#{agent.id}:SOURCE", "ship:#{agent.id}:RECEIVER"]
      assert intent.in_flight_action["target_claim"]["fleet_commitment_id"]

      if @loss == :receiver_claim do
        Repo.query!(
          "DELETE FROM fleet_commitment_claims WHERE resource = $1 AND fleet_commitment_portfolio_id = $2",
          ["RECEIVER", intent.fleet_commitment_portfolio_id]
        )
      else
        Repo.get!(Commitment, intent.fleet_commitment_id)
        |> Ecto.Changeset.change(reservations: %{"cargo_capacity:RECEIVER" => 0})
        |> Repo.update!()
      end

      Req.Test.stub(API, fn _ -> flunk("transfer lost receiving authority") end)
      assert {:error, :transfer_authority_unavailable} = API.dispatch_recorded(attempt)
      assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(attempt.id)
    end
  end

  test "neither raw credentials nor callback retries are Ship dispatch entry points" do
    Req.Test.stub(API, fn _ -> flunk("unrecorded mutation reached transport") end)
    assert_raise FunctionClauseError, fn -> API.dispatch_recorded("TOKEN") end

    assert_raise FunctionClauseError, fn ->
      API.dispatch_recorded(%AgentTokenReference{agent_id: 1})
    end

    refute function_exported?(API, :reconcile_absent_and_retry, 3)
    refute function_exported?(MutationAttempts, :with_retry, 2)
    refute function_exported?(MutationAttempts, :prepare_for_dispatch, 3)
  end

  test "an authenticated Intervention dispatches before the Fleet has an active Revision" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    Req.Test.stub(API, fn conn ->
      assert conn.request_path == "/v2/my/ships/INTERVENTION-1/orbit"
      Req.Test.json(conn, %{"data" => %{"nav" => %{"status" => "IN_ORBIT"}}})
    end)

    # Pre-Strategy generations are exactly the state #504's Intervention path covered.
    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: nil,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction
    })

    %{agent: agent, attempt: attempt} =
      prepare_action(agent, "INTERVENTION-1", %{
        "kind" => "orbit",
        "waypoint" => "X1-TEST-A1",
        "expected" => %{"status" => "IN_ORBIT"}
      })

    refute strategy.active_revision_id
    assert {:ok, %{nav: %{status: "IN_ORBIT"}}} = API.dispatch_recorded(attempt)
  end

  test "a Fleet Commitment without an active Revision cannot prepare recorded work" do
    agent = operator_fixture() |> agent_fixture()

    %{attempt: prepared} =
      prepare_action(agent, "SOURCE", %{
        "kind" => "transfer",
        "target_ship" => "RECEIVER",
        "trade_symbol" => "IRON_ORE",
        "units" => 5
      })

    before = MutationAttempts.list_for_agent(agent)
    assert prepared.id == List.last(before).id

    Req.Test.stub(API, fn _ -> flunk("commitment dispatched without an active Revision") end)
    :ok = without_active_revision(agent)

    assert {:error, :strategy_revision_absent} = API.dispatch_recorded(prepared)

    assert [%{state: "not_sent", sent_or_unknown_at: nil} = refused] =
             MutationAttempts.list_for_agent(agent)

    assert refused.id == prepared.id
    assert length(MutationAttempts.list_for_agent(agent)) == length(before)
  end
end
