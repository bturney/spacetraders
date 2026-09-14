defmodule SpaceTraders.OutboxTest do
  use SpaceTraders.DataCase

  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Outbox
  alias SpaceTraders.Outbox.Notification

  test "state publication and its notification commit atomically" do
    assert {:ok, %Operator{id: operator_id}} =
             Outbox.publish(
               %{
                 topic: "runtime",
                 event: "authority_advanced",
                 payload: %{"store" => "postgresql"}
               },
               fn -> Repo.insert!(%Operator{email: "atomic@example.test"}) end
             )

    assert Repo.get!(Operator, operator_id)

    assert %Notification{
             topic: "runtime",
             event: "authority_advanced",
             payload: %{"store" => "postgresql"}
           } = Repo.one!(Notification)
  end

  test "failed state publication leaves neither state nor notification" do
    assert {:error, :forced_failure} =
             Outbox.publish(
               %{topic: "runtime", event: "authority_advanced", payload: %{}},
               fn ->
                 Repo.insert!(%Operator{email: "rolled-back@example.test"})
                 Repo.rollback(:forced_failure)
               end
             )

    refute Repo.get_by(Operator, email: "rolled-back@example.test")
    refute Repo.exists?(Notification)
  end
end
