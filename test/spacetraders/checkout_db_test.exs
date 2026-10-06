defmodule SpaceTraders.CheckoutDbTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.CheckoutDb

  @main "/home/ben/src/spacetraders"

  test "the main checkout keeps the stable per-env names" do
    assert CheckoutDb.name(:dev, @main, @main) == "spacetraders_dev"
    assert CheckoutDb.name(:test, @main, @main) == "spacetraders_test"
  end

  test "a worktree gets env, directory basename, and a 6-char path hash" do
    path = @main <> "/.claude/worktrees/agent-1"

    assert "spacetraders_test_agent_1_" <> hash = CheckoutDb.name(:test, path, @main)
    assert hash =~ ~r/\A[0-9a-f]{6}\z/
  end

  test "each env gets its own database for the same worktree" do
    path = @main <> "/.claude/worktrees/w"

    refute CheckoutDb.name(:dev, path, @main) == CheckoutDb.name(:test, path, @main)
  end

  test "the name is stable and distinguishes same-basename worktrees" do
    a = "/work/a/feature"
    b = "/work/b/feature"

    assert CheckoutDb.name(:test, a, @main) == CheckoutDb.name(:test, a, @main)
    refute CheckoutDb.name(:test, a, @main) == CheckoutDb.name(:test, b, @main)
  end

  test "long directory names are truncated to the 63-character limit and keep the hash" do
    long = "/work/" <> String.duplicate("x", 200)
    other = "/work/" <> String.duplicate("x", 199) <> "y"

    name = CheckoutDb.name(:test, long, @main)

    assert byte_size(name) == 63
    assert String.slice(name, -6, 6) =~ ~r/\A[0-9a-f]{6}\z/
    refute name == CheckoutDb.name(:test, other, @main)
  end

  test "directory names are made safe for a Postgres identifier" do
    name = CheckoutDb.name(:dev, "/work/My Feature-1.x", @main)

    assert name =~ ~r/\Aspacetraders_dev_[a-z0-9_]+_[0-9a-f]{6}\z/
  end

  test "DATABASE_URL overrides the derived name" do
    assert CheckoutDb.url(:test, "/w/x", @main, "postgres://u:p@h/custom") ==
             "postgres://u:p@h/custom"
  end

  test "without DATABASE_URL the url targets the shared dev Postgres" do
    assert CheckoutDb.url(:test, @main, @main, nil) ==
             "postgres://postgres:postgres@127.0.0.1:5432/spacetraders_test"
  end
end
