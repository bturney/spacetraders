defmodule SpaceTraders.API.ShadowAdmissionTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.ShadowAdmission

  test "identical demand, capacity, and evidence snapshots produce identical explained ordering" do
    snapshot = %{
      observed_at: ~U[2030-01-01 00:00:00Z],
      available_slots: 3,
      evidence_fingerprint: "evidence-v1",
      next_outage_probe_at: nil,
      backpressure: :none
    }

    demands = [
      demand("discovery", lane: :standard, deadline_at: ~U[2030-01-01 00:05:00Z], discovery: true),
      demand("value", lane: :standard, deadline_at: ~U[2030-01-01 00:05:00Z], value: 10),
      demand("priority",
        lane: :standard,
        deadline_at: ~U[2030-01-01 00:05:00Z],
        strategic_priority: 1
      ),
      demand("deadline", lane: :standard, deadline_at: ~U[2030-01-01 00:01:00Z]),
      demand("reconciliation", lane: :reconciliation),
      demand("safety", lane: :safety)
    ]

    first = ShadowAdmission.compare(demands, snapshot)
    second = ShadowAdmission.compare(Enum.reverse(demands), snapshot)

    assert first == second

    assert Enum.map(first, & &1.demand_id) ==
             ~w(safety reconciliation deadline priority value discovery)

    assert Enum.map(first, & &1.disposition) == [
             :would_admit,
             :would_admit,
             :would_admit,
             :would_delay,
             :would_delay,
             :would_delay
           ]

    assert Enum.at(first, 0).ordering == [
             lane: :safety,
             deadline_at: nil,
             strategic_priority: nil,
             value: nil,
             discovery: false
           ]

    assert Enum.all?(first, &(&1.evidence_fingerprint == "evidence-v1"))
    assert Enum.all?(first, &(&1.available_slots == 3))
  end

  test "outage pacing and sustained backpressure are reported without admitting demand" do
    snapshot = %{
      observed_at: ~U[2030-01-01 00:00:00Z],
      available_slots: 5,
      evidence_fingerprint: "evidence-v2",
      next_outage_probe_at: ~U[2030-01-01 00:00:30Z],
      backpressure: :sustained
    }

    assert [decision] = ShadowAdmission.compare([demand("safety", lane: :safety)], snapshot)
    assert decision.disposition == :would_delay
    assert decision.reason == :outage_pacing
    assert decision.backpressure == :sustained
  end

  test "shadow output is correlated with actual request timing and outcomes" do
    name = :"shadow_admission_#{System.unique_integer([:positive])}"
    {:ok, pid} = ShadowAdmission.start_link(name: name, burst: 1, rate: 0.0)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    handler_id = "shadow-admission-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:spacetraders, :api, :capacity, :admission],
          [:spacetraders, :api, :capacity, :actual]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")
    correlation_id = ShadowAdmission.observe_request(operation, %{}, name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :admission], %{count: 1},
                    admission}

    assert admission.correlation_id == correlation_id
    assert admission.disposition == :would_admit

    ShadowAdmission.observe_dispatch(correlation_id, name)
    ShadowAdmission.observe_outcome(correlation_id, 200, "ok", name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :actual], measurements, actual}
    assert measurements.count == 1
    assert measurements.queue_time >= 0
    assert measurements.request_time >= 0
    assert actual.correlation_id == correlation_id
    assert actual.shadow_fingerprint == admission.fingerprint
    assert actual.status == 200
    assert actual.outcome == "ok"
  end

  defp demand(id, attrs) do
    %{
      id: id,
      operation_id: "get-my-agent",
      lane: :standard,
      deadline_at: nil,
      strategic_priority: nil,
      value: nil,
      discovery: false
    }
    |> Map.merge(Map.new(attrs))
  end
end
