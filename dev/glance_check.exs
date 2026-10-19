# Driver for scripts/glance-check (#771): seeds a healthy 120-Ship Fleet, then
# runs the headless-Chromium check while pushing live updates into the running
# server (one sale and one Ship state change per second). Run through
# `scripts/glance-check`; it needs the server enabled (PHX_SERVER=true).
Logger.configure(level: :warning)
alias SpaceTraders.{Fleet, Repo, ScenarioSeeds}
alias SpaceTraders.MissionControl.Channels
alias SpaceTraders.Outcomes.EarningsRecord

seconds = String.to_integer(System.get_env("SECONDS", "20"))
%{generation: generation, agent: agent} = ScenarioSeeds.seed(:healthy, 120)
credentials = ScenarioSeeds.credentials()
ships = Fleet.current_ships(agent.id)

pulse = fn n ->
  ship = Enum.at(ships, rem(n * 7, length(ships)))
  now = DateTime.utc_now()

  Repo.insert!(%EarningsRecord{
    source: "trade",
    fleet_generation_id: generation.id,
    ship_symbol: ship.symbol,
    ship_type: ship.ship_type,
    good: "FABRICS",
    source_waypoint: "X1-UX81-A1",
    destination_waypoint: "X1-UX81-F47",
    units: 20,
    jettisoned_units: 0,
    revenue: 3_000,
    goods_cost: 2_000,
    fuel_cost: 0,
    other_cost: 0,
    net_earnings: 1_000 + n,
    ship_seconds: 600,
    started_at: DateTime.add(now, -600),
    finished_at: now,
    inserted_at: now
  })

  Phoenix.PubSub.broadcast(SpaceTraders.PubSub, "ship_state:#{agent.id}", {:ship_state, ship})
  Channels.broadcast_earnings()
end

check =
  Task.async(fn ->
    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["scripts/glance-check.cjs"],
        env: [
          {~c"EMAIL", String.to_charlist(credentials.email)},
          {~c"PASSWORD", String.to_charlist(credentials.password)}
        ]
      ])

    receive_loop = fn loop ->
      receive do
        {^port, {:data, data}} ->
          IO.write(data)
          loop.(loop)

        {^port, {:exit_status, status}} ->
          status
      end
    end

    receive_loop.(receive_loop)
  end)

# Pulse from the moment the page has had time to settle (login, mount, 2 s).
Process.sleep(8_000)

for n <- 1..(seconds + 4) do
  pulse.(n)
  Process.sleep(1_000)
end

System.halt(Task.await(check, 60_000))
