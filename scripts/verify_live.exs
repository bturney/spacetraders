# Live smoke for the SpaceTraders API client.
#
# Runs the real `SpaceTraders.API.get_status/0` against the live game and
# asserts it decodes the root endpoint's FLAT body (the game's one response
# that has no `data` wrapper — see `test/spacetraders/api/spec_conformance_test.exs`).
#
# This is the opt-in real-surface leg of verification: the hermetic `mix verify`
# gate never touches the network, so a client that decodes stubbed fixtures fine
# can still be broken against the live game. Run it after touching
# `lib/spacetraders/api.ex` or the bundled spec:
#
#     scripts/verify-live
#
# Requires network access to https://api.spacetraders.io/v2/. Not part of CI.

result = SpaceTraders.API.get_status()

case result do
  {:ok, %{"status" => status, "version" => version} = body} when is_map(body) ->
    if Map.has_key?(body, "data") do
      IO.puts(:stderr,
        "verify-live: FAIL — GET / wrapped the body in `data`; the flat-decode contract is broken"
      )

      System.halt(1)
    else
      IO.puts("verify-live: OK — GET / decoded flat payload (status: #{status}, version: #{version})")
    end

  {:ok, other} ->
    IO.puts(:stderr, "verify-live: FAIL — unexpected decoded shape: #{inspect(other)}")
    System.halt(1)

  {:error, error} ->
    IO.puts(:stderr, "verify-live: FAIL — #{inspect(error)}")
    System.halt(1)
end
