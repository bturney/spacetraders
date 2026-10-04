# Invoked by ordinary regression coverage in recorded_ship_fixture_order_test.exs.
# Separate VM, but all ordered cases run in that SAME VM/database: actual ExUnit
# setup/on_exit boundaries, not an imitation of the qualification lifecycle.
Code.require_file("test/test_helper.exs")
ExUnit.configure(autorun: false, seed: 0, max_cases: 1)

keys = [:clock, SpaceTraders.RuntimeAuthority]
baseline = Map.new(keys, &{&1, Application.fetch_env(:spacetraders, &1)})
runtime = "test/spacetraders/recorded_ship_runtime_test.exs"
evidence = "test/spacetraders/evidence_scheduling_test.exs"
resources = "test/spacetraders/resource_acquisition_test.exs"

for iteration <- 1..2,
    order <- [[runtime, evidence, resources], [resources, evidence, runtime]],
    file <- order do
  IO.puts("fixture order receipt: iteration=#{iteration} file=#{file}")
  Code.compile_file(file)
  result = ExUnit.run()
  if result.failures != 0, do: raise("ordered suite failed: #{file}")

  for {key, value} <- baseline do
    actual = Application.fetch_env(:spacetraders, key)

    if actual != value,
      do:
        raise(
          "fixture leaked application key #{inspect(key)}: #{inspect(actual)} != #{inspect(value)}"
        )
  end

  for module <- [
        SpaceTraders.TestClock,
        SpaceTraders.RuntimeAuthority,
        SpaceTraders.FleetAllocation.Reconciler,
        SpaceTraders.Evidence.DemandScheduler
      ] do
    if Process.whereis(module), do: raise("fixture left runtime process #{inspect(module)}")
  end

  if DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor) != [],
    do: raise("fixture left ShipServers")

  if file == runtime do
    :ok = SpaceTraders.EmergencyStopAdmission.mutation_allowed?("BASELINE_AGENT_TOKEN")
    :ok = SpaceTraders.FleetGenerationAdmission.mutation_allowed?("BASELINE_AGENT_TOKEN")
    capacity = SpaceTraders.API.CapacityGovernor.snapshot()

    if capacity.available_slots != capacity.admitted_capacity or
         capacity.ordinary_delayed_until != nil or capacity.next_outage_probe_at != nil or
         capacity.protocol_rejections != 0,
       do: raise("fixture left volatile API admissions")
  end

  # A fresh shared Sandbox owner must permit a newly spawned observer. This is
  # the ownership boundary needed by the next EvidenceScheduling test's boot.
  owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SpaceTraders.Repo, shared: true)

  try do
    [[1]] = Task.async(fn -> SpaceTraders.Repo.query!("SELECT 1").rows end) |> Task.await()
  after
    Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
  end

  # No unallowed process may inherit a global shared Req stub after this suite.
  Req.Test.stub(SpaceTraders.API, fn conn -> Req.Test.json(conn, %{"private_probe" => true}) end)
  parent = self()
  ref = make_ref()

  spawn(fn ->
    result =
      try do
        Req.Test.call(Plug.Test.conn(:get, "/private-probe"), SpaceTraders.API)
        :leaked_shared_stub
      rescue
        _ -> :private
      end

    send(parent, {ref, result})
  end)

  receive do
    {^ref, :private} -> :ok
    {^ref, :leaked_shared_stub} -> raise "fixture leaked shared Req mode"
  after
    5_000 -> raise "Req isolation probe did not finish"
  end
end

IO.puts("fixture order receipt: both orders repeated twice; global and ownership probes passed")
