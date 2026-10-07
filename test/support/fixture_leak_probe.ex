defmodule SpaceTraders.FixtureLeakProbe do
  @moduledoc """
  In-VM probe of what a stateful fixture must leave behind. Suites that touch
  application-wide state call `baseline/0` in `setup_all` and `assert_clean!/2`
  from that `setup_all`'s `on_exit`, so a leak fails the suite that called the
  probe. Suites that never call it are not checked: their leaks surface in the
  next probed suite, so the ShipServer check is a backstop. `DataCase` stops
  ShipServers after every non-async test, so they should not leak.
  """

  @env_keys [:clock, SpaceTraders.RuntimeAuthority]
  @processes [
    SpaceTraders.TestClock,
    SpaceTraders.RuntimeAuthority,
    SpaceTraders.FleetAllocation.Reconciler,
    SpaceTraders.Evidence.DemandScheduler
  ]

  def baseline, do: Map.new(@env_keys, &{&1, Application.fetch_env(:spacetraders, &1)})

  def assert_clean!(baseline, opts \\ []) do
    case leaks(baseline, opts) do
      [] -> :ok
      leaks -> raise "fixture leaked state:\n  " <> Enum.join(leaks, "\n  ")
    end
  end

  @doc "Names every leak found; `[]` means the fixture tore down cleanly."
  def leaks(baseline, opts \\ []) do
    env_leaks(baseline) ++
      process_leaks() ++
      ship_server_leaks() ++
      if(opts[:capacity], do: capacity_leaks(), else: []) ++
      ownership_leaks() ++
      req_mode_leaks()
  end

  defp env_leaks(baseline) do
    for {key, expected} <- baseline,
        actual = Application.fetch_env(:spacetraders, key),
        actual != expected,
        do: "application key #{inspect(key)}: #{inspect(actual)} != #{inspect(expected)}"
  end

  defp process_leaks do
    for module <- @processes, Process.whereis(module), do: "runtime process #{inspect(module)}"
  end

  defp ship_server_leaks do
    if DynamicSupervisor.which_children(SpaceTraders.Fleet.ShipSupervisor) == [],
      do: [],
      else: ["ShipServers left running"]
  end

  defp capacity_leaks do
    capacity = SpaceTraders.API.CapacityGovernor.diagnostics()

    admissions =
      SpaceTraders.EmergencyStopAdmission.mutation_allowed?("BASELINE_AGENT_TOKEN") == :ok and
        SpaceTraders.FleetGenerationAdmission.mutation_allowed?("BASELINE_AGENT_TOKEN") == :ok

    if admissions and capacity.in_flight == 0 and capacity.deferred == %{} and
         capacity.retry_after_until == nil and capacity.outage == nil and
         capacity.scoped_failures == [] and capacity.protocol_rejections == 0,
       do: [],
       else: ["volatile API admissions"]
  end

  # A fresh shared Sandbox owner must permit a newly spawned observer: the
  # ownership boundary the next suite's boot depends on.
  defp ownership_leaks do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(SpaceTraders.Repo, shared: true)

    try do
      case Task.async(fn -> SpaceTraders.Repo.query!("SELECT 1").rows end) |> Task.await() do
        [[1]] -> []
        other -> ["Sandbox ownership probe returned #{inspect(other)}"]
      end
    after
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end
  end

  # No unallowed process may inherit a global shared Req stub.
  defp req_mode_leaks do
    Req.Test.stub(SpaceTraders.API, fn conn -> Req.Test.json(conn, %{"private_probe" => true}) end)

    # Plain spawn: Task would inherit the stub through `$callers`.
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

    result =
      receive do
        {^ref, result} -> result
      after
        5_000 -> :timeout
      end

    if result == :private, do: [], else: ["shared Req stub mode"]
  end
end
