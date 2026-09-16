# Req.Test stubs are process-local while runtime servers execute in separate
# processes, so serial cases prevent unrelated tests from replacing a fixture.
ExUnit.start(max_cases: 1)
Ecto.Adapters.SQL.Sandbox.mode(SpaceTraders.Repo, :manual)
