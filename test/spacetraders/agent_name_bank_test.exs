defmodule SpaceTraders.AgentNameBankTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.AgentNameBank

  test "the migrated bank holds the approved defaults in order" do
    assert AgentNameBank.list() == ~w(ORBITALIST PARALLAX APHELION SIDEREAL LIMINAL)
    assert AgentNameBank.defaults() == AgentNameBank.list()
  end

  test "save persists explicit choice and order; defaults never overwrite it" do
    assert {:ok, ["ZENITH", "ORBITALIST", "NADIR"]} =
             AgentNameBank.save(["zenith", " orbitalist ", "Nadir"])

    assert AgentNameBank.list() == ["ZENITH", "ORBITALIST", "NADIR"]

    :ok = AgentNameBank.ensure_defaults()
    assert AgentNameBank.list() == ["ZENITH", "ORBITALIST", "NADIR"]

    # A reorder is retained too, read from a different process as after a restart.
    assert {:ok, _} = AgentNameBank.save(["NADIR", "ZENITH"])
    owner = self()

    task =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(SpaceTraders.Repo, owner, self())
        AgentNameBank.list()
      end)

    assert Task.await(task) == ["NADIR", "ZENITH"]
  end

  test "ensure_defaults seeds an empty table only" do
    SpaceTraders.Repo.delete_all(AgentNameBank.Entry)
    assert AgentNameBank.list() == []
    :ok = AgentNameBank.ensure_defaults()
    assert AgentNameBank.list() == ~w(ORBITALIST PARALLAX APHELION SIDEREAL LIMINAL)
  end

  describe "validation against the registration contract" do
    test "normalizes to uppercase and ignores blank entries" do
      assert {:ok, ["ABC", "ABCDEFGHIJKLMN"]} =
               AgentNameBank.save(["abc", "", "  ", "abcdefghijklmn"])
    end

    test "rejects names outside 3..14 characters and keeps the stored bank" do
      assert {:error, errors} = AgentNameBank.save(["AB", "ABCDEFGHIJKLMNO", "FINE"])
      assert Enum.any?(errors, &(&1 =~ "AB" and &1 =~ "3"))
      assert Enum.any?(errors, &(&1 =~ "ABCDEFGHIJKLMNO" and &1 =~ "14"))
      assert AgentNameBank.list() == ~w(ORBITALIST PARALLAX APHELION SIDEREAL LIMINAL)
    end

    test "does not invent a hyphen prohibition" do
      assert {:ok, ["DEEP-SPACE"]} = AgentNameBank.save(["deep-space"])
    end

    test "rejects duplicates after normalization" do
      assert {:error, [error]} = AgentNameBank.save(["Nadir", "NADIR"])
      assert error =~ "NADIR" and error =~ "once"
      assert AgentNameBank.list() == ~w(ORBITALIST PARALLAX APHELION SIDEREAL LIMINAL)
    end

    test "rejects an empty bank" do
      assert {:error, [error]} = AgentNameBank.save(["", " "])
      assert error =~ "at least one"
    end
  end
end
