defmodule SpaceTraders.RetirementBoundaryTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Repo

  test "legacy Job persistence and ownership columns are absent" do
    assert [[nil]] = Repo.query!("SELECT to_regclass('public.jobs')").rows

    assert [] =
             Repo.query!(
               "SELECT column_name FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'intents' AND column_name = 'job_id'"
             ).rows
  end
end
