defmodule SpaceTraders.API.ShadowAdmissionTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.ShadowAdmission
  alias SpaceTraders.API.ShadowAdmission.Candidate
  alias SpaceTraders.API.ShadowAdmission.Capacity

  test "identical demand, capacity, and evidence snapshots produce identical explained ordering" do
    snapshot = %Capacity{
      observed_at: ~U[2030-01-01 00:00:00Z],
      available_slots: 3,
      evidence_fingerprint: "evidence-v1",
      next_outage_probe_at: nil,
      backpressure: :none
    }

    candidates = [
      candidate("discovery",
        lane: :standard,
        deadline_at: ~U[2030-01-01 00:05:00Z],
        discovery: true
      ),
      candidate("value",
        lane: :standard,
        deadline_at: ~U[2030-01-01 00:05:00Z],
        expected_value: 10
      ),
      candidate("priority",
        lane: :standard,
        deadline_at: ~U[2030-01-01 00:05:00Z],
        strategic_priority: 1
      ),
      candidate("deadline", lane: :standard, deadline_at: ~U[2030-01-01 00:01:00Z]),
      candidate("reconciliation", lane: :reconciliation),
      candidate("safety", lane: :safety)
    ]

    first = ShadowAdmission.compare(candidates, snapshot)
    second = ShadowAdmission.compare(Enum.reverse(candidates), snapshot)

    assert first == second

    assert Enum.map(first, & &1.candidate_id) ==
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
             expected_value: nil,
             discovery: false
           ]

    assert Enum.all?(first, &(&1.evidence_fingerprint == "evidence-v1"))
    assert Enum.all?(first, &(&1.available_slots == 3))
  end

  test "outage pacing and sustained backpressure are reported without admitting demand" do
    snapshot = %Capacity{
      observed_at: ~U[2030-01-01 00:00:00Z],
      available_slots: 5,
      evidence_fingerprint: "evidence-v2",
      next_outage_probe_at: ~U[2030-01-01 00:00:30Z],
      backpressure: :sustained
    }

    assert [decision] = ShadowAdmission.compare([candidate("safety", lane: :safety)], snapshot)
    assert decision.disposition == :would_delay
    assert decision.reason == :outage_pacing
    assert decision.backpressure == :sustained
  end

  test "shadow lanes share the governor's protection meaning, so unknown lanes cannot crash it" do
    name = :"shadow_admission_#{System.unique_integer([:positive])}"
    {:ok, pid} = ShadowAdmission.start_link(name: name, burst: 1, rate: 0.0)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    handler_id = "shadow-admission-lanes-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:spacetraders, :api, :capacity, :admission],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:shadow, metadata.correlation_id, metadata.lane})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    invented = ShadowAdmission.observe_request(operation, %{lane: :invented}, name)
    assert_receive {:shadow, ^invented, :standard}

    recovery = ShadowAdmission.observe_request(operation, %{purpose: :recovery}, name)
    assert_receive {:shadow, ^recovery, :reconciliation}
    assert Process.alive?(pid)
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
                    %{correlation_id: ^correlation_id} = admission}

    assert admission.disposition == :would_admit

    safety_id = ShadowAdmission.observe_request(operation, %{lane: :safety}, name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :admission], %{count: 1},
                    %{
                      correlation_id: ^safety_id,
                      rank: 1,
                      disposition: :would_admit,
                      ordering: [
                        lane: :safety,
                        deadline_at: nil,
                        strategic_priority: nil,
                        expected_value: nil,
                        discovery: false
                      ]
                    }}

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :admission], %{count: 1},
                    %{
                      correlation_id: ^correlation_id,
                      rank: 2,
                      disposition: :would_delay,
                      fingerprint: revised_fingerprint
                    }}

    Process.sleep(15)
    ShadowAdmission.observe_dispatch(correlation_id, name)
    ShadowAdmission.observe_outcome(correlation_id, 200, :ok, name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :actual], measurements,
                    %{correlation_id: ^correlation_id} = actual}

    assert measurements.count == 1

    # queue_time spans observation to dispatch, so any capacity wait performed
    # between observing and dispatching (the production RateLimiter) is included.
    assert measurements.queue_time >= 15
    assert measurements.request_time >= 0
    assert actual.correlation_id == correlation_id
    assert actual.shadow_fingerprint == revised_fingerprint
    assert actual.status == 200
    assert actual.outcome == :ok

    ShadowAdmission.observe_dispatch(safety_id, name)
    ShadowAdmission.observe_outcome(safety_id, 200, :ok, name)
  end

  test "a single protocol rejection is reported as transient backpressure" do
    name = :"shadow_admission_#{System.unique_integer([:positive])}"
    {:ok, pid} = ShadowAdmission.start_link(name: name, burst: 1, rate: 0.0)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    test_pid = self()

    handler_id = "shadow-transient-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:spacetraders, :api, :capacity, :admission],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    first = ShadowAdmission.observe_request(operation, %{}, name)
    ShadowAdmission.observe_dispatch(first, name)
    ShadowAdmission.observe_outcome(first, 429, :backpressure, name)
    Process.sleep(5)

    second = ShadowAdmission.observe_request(operation, %{lane: :safety}, name)

    assert_receive {:telemetry, %{count: 1}, %{correlation_id: ^second, backpressure: :transient}}
  end

  defp candidate(id, attrs) do
    struct!(Candidate, Keyword.merge([id: id, operation_id: "get-my-agent"], attrs))
  end
end
