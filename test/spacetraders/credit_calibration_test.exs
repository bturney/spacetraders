defmodule SpaceTraders.CreditCalibrationTest do
  use SpaceTraders.DataCase, async: false

  import Ecto.Query
  import SpaceTraders.CreditSpendingFixtures
  import SpaceTraders.RecordedDispatchFixtures, only: [prepare_action: 3]

  alias SpaceTraders.API
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.CreditCalibration
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.OperatorConditions
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.TestClock

  setup do
    start_supervised!({TestClock, DateTime.utc_now()})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    :ok
  end

  test "the initial calibration version is durable at 25% and cannot be superseded below 10%" do
    initial = CreditCalibration.active()
    assert %{version: "market-purchase-v1-25pct", margin_percent: 25, basis: "initial"} = initial

    assert {:error, :below_hard_lower_bound} =
             CreditCalibration.supersede(9, "evidence_narrowing", %{})

    assert CreditCalibration.active().id == initial.id

    assert {:ok, %{margin_percent: 10, previous_version_id: previous}} =
             CreditCalibration.supersede(10, "evidence_narrowing", %{})

    assert previous == initial.id
    assert %{margin_percent: 10} = CreditCalibration.active()
  end

  test "preparation binds the active version; a superseded version withdraws before the marker" do
    {agent, [first, second], _portfolio} = claimed_purchases([0, 0])
    stub_quote(agent, 10, 2_000)
    assert {:ok, %{attempt: stale}} = RecordedAction.prepare(agent, first, buy())

    assert {:ok, widened} = CreditCalibration.supersede(40, "pricing_model_miss", %{})

    assert {:ok, %{attempt: fresh}} = RecordedAction.prepare(agent, second, buy())

    assert %{
             "calibration_version" => version,
             "margin_percent" => 40,
             "worst_case_exposure" => 70
           } =
             fresh.prepared_evidence["spending"]

    assert version == widened.version

    Req.Test.stub(API, fn _ -> flunk("superseded calibration reached transport") end)
    assert {:error, :credit_calibration_superseded} = API.dispatch_recorded(stale)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(stale.id)
  end

  test "an attributable charge above its bound records a breach, widens, raises Degraded Attention, and pauses spending" do
    {agent, [first, second], _portfolio} = claimed_purchases([0, 0])
    initial = CreditCalibration.active()
    stub_quote(agent, 10, 1_063)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, first, buy())

    # Quoted 10 x 5 = 50, bound 63; the game charges 14 x 5 = 70.
    stub_purchase(agent, "BUYER-0", 14, 993)
    assert {:ok, _response} = API.dispatch_recorded(attempt)

    assert [
             %{
               kind: "pricing_model_miss",
               mutation_attempt_id: attempt_id,
               calibration_version_id: initial_id,
               worst_case_exposure: 63,
               realized_charge: 70,
               credits: 993,
               credit_floor: 1_000,
               released_at: nil
             } = breach
           ] = CreditCalibration.shortfalls(agent)

    assert attempt_id == attempt.id
    assert initial_id == initial.id

    assert %{within_bound: false, realized_charge: 70, worst_case_exposure: 63} =
             realization = CreditCalibration.realization(attempt)

    assert realization.calibration_version_id == initial.id
    assert realization.credit_shortfall_id == breach.id

    widened = CreditCalibration.active()
    assert widened.previous_version_id == initial.id
    assert widened.basis == "pricing_model_miss"
    assert widened.mutation_attempt_id == attempt.id
    # 70 is 40% over the 50 quote; widening clears it by the 10-point step.
    assert widened.margin_percent == 50

    assert [%{kind: :attention, summary: summary, resolved_at: nil}] =
             OperatorConditions.unresolved(scope(agent))

    assert summary =~ "Degraded Operation"
    assert summary =~ "70 credits"
    assert summary =~ "63"
    refute summary =~ ~r/acknowledg/i

    # A newer authoritative balance still below the floor keeps spending paused.
    TestClock.advance(1)
    stub_quote(agent, 10, 993)
    assert {:ok, %{attempt: paused}} = RecordedAction.prepare(agent, second, buy())
    Req.Test.stub(API, fn _ -> flunk("paused spending reached transport") end)
    assert {:error, :credit_spending_paused} = API.dispatch_recorded(paused)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(paused.id)
    assert [%{id: id, released_at: nil}] = CreditCalibration.shortfalls(agent)
    assert id == breach.id
  end

  test "a charge within its bound is retained as calibration evidence without a shortfall" do
    {agent, [first], _portfolio} = claimed_purchases([0])
    initial = CreditCalibration.active()
    stub_quote(agent, 10, 1_200)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, first, buy())
    stub_purchase(agent, "BUYER-0", 12, 1_140)
    assert {:ok, _} = API.dispatch_recorded(attempt)

    assert %{within_bound: true, realized_charge: 60, credit_shortfall_id: nil} =
             CreditCalibration.realization(attempt)

    assert CreditCalibration.shortfalls(agent) == []
    assert CreditCalibration.active().id == initial.id
  end

  test "a paused Agent keeps non-spending work moving, sells nothing, and refuses fuel through the floor" do
    {agent, [first], _portfolio} = claimed_purchases([0])
    stub_quote(agent, 10, 1_063)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, first, buy())
    stub_purchase(agent, "BUYER-0", 14, 993)
    assert {:ok, _} = API.dispatch_recorded(attempt)
    assert [%{released_at: nil}] = CreditCalibration.shortfalls(agent)

    %{attempt: dock} = prepare_action(agent, "PILOT-1", %{"kind" => "dock"})
    assert {:ok, %{state: "sent_or_unknown"}} = RecordedAction.admit_send(dock)

    %{attempt: refuel} =
      prepare_action(agent, "PILOT-2", %{"kind" => "refuel", "fuel_before" => 20})

    assert {:error, :credit_spending_paused} = RecordedAction.admit_send(refuel)
    assert %{state: "not_sent", sent_or_unknown_at: nil} = MutationAttempts.get!(refuel.id)

    refute Repo.exists?(from i in Intent, where: i.type == "sell")

    refute Enum.any?(
             MutationAttempts.list_for_agent(agent),
             &(&1.operation_id == "sell-cargo")
           )
  end

  test "a newer authoritative balance at the floor releases the pause and resolves the Attention" do
    {agent, [first, second], _portfolio} = claimed_purchases([0, 0])
    stub_quote(agent, 10, 1_063)
    assert {:ok, %{attempt: attempt}} = RecordedAction.prepare(agent, first, buy())
    stub_purchase(agent, "BUYER-0", 14, 993)
    assert {:ok, _} = API.dispatch_recorded(attempt)

    TestClock.advance(1)
    stub_quote(agent, 10, 1_200)
    assert {:ok, %{attempt: resumed}} = RecordedAction.prepare(agent, second, buy())
    assert {:ok, %{state: "sent_or_unknown"}} = RecordedAction.admit_send(resumed)

    assert [%{kind: "pricing_model_miss", released_at: %DateTime{}}] =
             CreditCalibration.shortfalls(agent)

    assert OperatorConditions.unresolved(scope(agent)) == []
    assert [%{resolved_at: %DateTime{}}] = OperatorConditions.history(scope(agent))
  end

  test "an unattributable shortfall behind a Bounded Unknown spend pauses without recalibrating" do
    {agent, [first, second], _portfolio} = claimed_purchases([0, 0])
    initial = CreditCalibration.active()
    stub_quote(agent, 10, 1_200)
    assert {:ok, %{attempt: one}} = RecordedAction.prepare(agent, first, buy())
    assert {:ok, %{attempt: two}} = RecordedAction.prepare(agent, second, buy())
    assert {:ok, one} = RecordedAction.admit_send(one)
    TestClock.advance(1)

    # The response was lost; recovery bounds it inside the floor.
    stub_ship_and_credits(agent, "BUYER-0", 1_100)
    assert {:ok, ship} = Evidence.get_ship_binding(agent, "BUYER-0")
    assert {:ok, credits} = Evidence.get_agent_binding(agent)

    assert {:ok, proof} =
             Evidence.recovery_proof(
               one,
               :bounded_unknown,
               "At most one purchase at the retained exposure bound",
               [ship, credits]
             )

    accounting =
      Evidence.constraint_accounting("At most 63 credits", [
        %{
          constraint: "Keep at least 1,000 credits available",
          satisfied: true,
          evidence: "1,100 minus 63 leaves 1,037"
        }
      ])

    assert {:ok, %{state: "bounded_unknown"}} =
             MutationAttempts.reconcile(one, :bounded_unknown, proof,
               constraint_accounting: accounting
             )

    # A later credits read shows a shortfall no single bound can be charged with.
    TestClock.advance(1)
    stub_ship_and_credits(agent, "BUYER-0", 900)
    assert {:ok, _} = Evidence.get_agent_binding(agent)

    Req.Test.stub(API, fn _ -> flunk("paused spending acquired facts or sent") end)

    assert {:error, :credit_spending_paused} =
             API.dispatch_recorded(MutationAttempts.get!(two.id))

    assert [%{kind: "unattributable_shortfall", mutation_attempt_id: nil, credits: 900}] =
             CreditCalibration.shortfalls(agent)

    assert CreditCalibration.active().id == initial.id
    assert CreditCalibration.realization(one) == nil
    assert OperatorConditions.unresolved(scope(agent)) == []
  end

  test "a revision that raises the floor above credits pauses as a revision shortfall, not a miss" do
    {agent, _intents, _portfolio} = claimed_purchases([0])
    initial = CreditCalibration.active()
    raised = activate_floor_revision(agent, 2, "Keep at least 2,000 credits available")
    stub_quote(agent, 10, 1_500)
    assert {:ok, credits} = Evidence.get_agent_binding(agent)

    assert {:ok, {:error, :credit_spending_paused}} =
             Repo.transaction(fn ->
               CreditCalibration.spending_pause(agent, credits, 2_000, raised)
             end)

    assert [%{kind: "revision_floor", credits: 1_500, credit_floor: 2_000}] =
             CreditCalibration.shortfalls(agent)

    assert CreditCalibration.active().id == initial.id
    assert OperatorConditions.unresolved(scope(agent)) == []
  end

  test "a below-floor balance with no bound exceeded and no unknown spend is a non-pricing shortfall" do
    {agent, _intents, _portfolio} = claimed_purchases([0])
    initial = CreditCalibration.active()
    revision = Repo.get!(Revision, active_revision_id(agent))
    stub_quote(agent, 10, 900)
    assert {:ok, credits} = Evidence.get_agent_binding(agent)

    assert {:ok, {:error, :credit_spending_paused}} =
             Repo.transaction(fn ->
               CreditCalibration.spending_pause(agent, credits, 1_000, revision)
             end)

    assert [%{kind: "non_pricing_shortfall"}] = CreditCalibration.shortfalls(agent)
    assert CreditCalibration.active().id == initial.id
  end

  defp active_revision_id(agent) do
    Repo.one!(
      from s in Strategy, where: s.operator_id == ^agent.operator_id, select: s.active_revision_id
    )
  end

  defp activate_floor_revision(agent, number, floor) do
    strategy = Repo.get_by!(Strategy, operator_id: agent.operator_id)

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: number,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => [floor]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))
    revision
  end

  defp stub_ship_and_credits(agent, ship_symbol, credits) do
    Req.Test.stub(API, fn conn ->
      data =
        case conn.request_path do
          "/v2/my/agent" -> %{"symbol" => agent.symbol, "credits" => credits}
          _ -> SpaceTraders.ShipBody.ship_body(ship_symbol)
        end

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  defp scope(agent),
    do: Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
end
