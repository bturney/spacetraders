# Seeds the existing agent ORBITALIST and its starter fleet (ticket #17).
#
# The agent's token is read from the SPACETRADERS_AGENT_TOKEN environment
# variable at seed time ONLY — the app never reads it, and it is never stored
# in `.env` or config. Set it when seeding so the dev database has a usable
# agent:
#
#     SPACETRADERS_AGENT_TOKEN=<token> mix run priv/repo/seeds.exs
#
# Without it, a clearly-fake placeholder token is stored (the row exists, but
# game actions for the seeded agent won't be authorized until the token is
# replaced). Idempotent: no-op once agents exist.

alias SpaceTraders.Agent.Agent
alias SpaceTraders.Fleet.Ship
alias SpaceTraders.Repo

if Repo.aggregate(Agent, :count, :id) > 0 do
  IO.puts("Agents already present — seed skipped.")
else
  token = System.get_env("SPACETRADERS_AGENT_TOKEN") || "dev-placeholder-agent-token"

  {:ok, agent} =
    Repo.insert(%Agent{
      symbol: "ORBITALIST",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: token
    })

  # Starter fleet (roles COMMAND + SATELLITE, per ticket #17): the two ships a
  # fresh agent is registered with.
  for {symbol, ship_type} <- [
        {"ORBITALIST-1", "SHIP_COMMAND_FRIGATE"},
        {"ORBITALIST-2", "SHIP_PROBE"}
      ] do
    Repo.insert!(%Ship{symbol: symbol, ship_type: ship_type, agent_id: agent.id})
  end

  IO.puts("Seeded agent ORBITALIST + starter fleet (COMMAND_FRIGATE, PROBE).")
end
