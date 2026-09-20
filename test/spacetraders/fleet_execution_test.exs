defmodule SpaceTraders.FleetExecutionTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetStrategy.Revision

  describe "worst_case_exposure/1" do
    test "covers the credit reservation, fuel allowance, and bounded-loss allowance" do
      assert FleetExecution.worst_case_exposure(0) == 750
      assert FleetExecution.worst_case_exposure(1_000) == 1_750
    end
  end

  describe "reservation_covers_exposure?/3" do
    test "accepts a reservation that covers worst-case exposure within the floor" do
      commitment = commitment(%{credits: 200})
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      availability = %{reservations: %{credits: 2_000}}

      assert FleetExecution.reservation_covers_exposure?(commitment, revision, availability)
    end

    test "rejects a reservation that would cross the Hard Constraint floor" do
      commitment = commitment(%{credits: 900})
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      availability = %{reservations: %{credits: 1_000}}

      refute FleetExecution.reservation_covers_exposure?(commitment, revision, availability)
    end

    test "rejects a commitment without a numeric credit reservation" do
      commitment = commitment(%{})
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      refute FleetExecution.reservation_covers_exposure?(commitment, revision, %{
               reservations: %{credits: 1_000}
             })
    end

    test "rejects when no enforceable credit floor is declared" do
      commitment = commitment(%{credits: 200})

      refute FleetExecution.reservation_covers_exposure?(commitment, revision(%{}), %{
               reservations: %{credits: 1_000}
             })
    end
  end

  describe "eligible_market_commitment/4" do
    test "returns the shadow-validated proposed choice that claims an owned Ship" do
      agent = agent_fixture(operator_fixture())
      owned = %{claims: ["SHIP-1"], reservations: %{credits: 200}, candidate_id: "candidate-1"}

      other = %{
        claims: ["SHIP-OTHER"],
        reservations: %{credits: 200},
        candidate_id: "candidate-2"
      }

      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [%{"symbol" => "SHIP-1"}]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      comparison = %{proposed_choices: [other, owned]}

      assert %{claims: ["SHIP-1"]} =
               FleetExecution.eligible_market_commitment(
                 comparison,
                 agent,
                 revision,
                 %{reservations: %{credits: 2_000}}
               )
    end

    test "returns nil when no proposed choice claims an owned Ship" do
      agent = agent_fixture(operator_fixture())
      other = %{claims: ["SHIP-OTHER"], reservations: %{credits: 200}}
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [%{"symbol" => "SHIP-1"}]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert nil ==
               FleetExecution.eligible_market_commitment(
                 %{proposed_choices: [other]},
                 agent,
                 revision,
                 %{reservations: %{credits: 2_000}}
               )
    end

    test "returns nil when the proposed choice's reservation crosses the floor" do
      agent = agent_fixture(operator_fixture())
      choice = %{claims: ["SHIP-1"], reservations: %{credits: 900}}
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [%{"symbol" => "SHIP-1"}]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert nil ==
               FleetExecution.eligible_market_commitment(
                 %{proposed_choices: [choice]},
                 agent,
                 revision,
                 %{reservations: %{credits: 2_000}}
               )
    end
  end

  describe "credit_floor/1" do
    test "returns the floor declared as a Hard Constraint" do
      assert {:ok, 50_000} =
               FleetExecution.credit_floor(
                 revision(%{"hard_constraints" => ["Keep at least 50,000 credits available"]})
               )
    end
  end

  defp commitment(reservations) do
    %{
      candidate_id: "candidate-1",
      claims: ["SHIP-1"],
      reservations: reservations
    }
  end

  defp revision(document) do
    %Revision{id: 42, document: document}
  end
end
