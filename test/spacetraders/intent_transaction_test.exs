defmodule SpaceTraders.IntentTransactionTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.Fleet.{Intent, Intents}
  alias SpaceTraders.Repo

  test "an intent transition can begin a PostgreSQL transaction outside the sandbox" do
    assert :intent_no_longer_owned =
             Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
               Intents.with_current_intent(%Intent{id: -1}, fn _ -> flunk("missing intent") end)
             end)
  end
end
