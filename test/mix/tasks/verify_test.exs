defmodule Mix.Tasks.VerifyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Verify

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  defp messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> messages([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp passing(task, _args) do
    if task == "test",
      do: {"noise\nFinished in 1.0 seconds\n3 tests, 0 failures\n", 0},
      else: {"", 0}
  end

  test "the test alias creates and migrates the checkout database quietly before testing" do
    assert Mix.Project.config()[:aliases][:test] ==
             ["ecto.create --quiet", "ecto.migrate --quiet", "test"]

    refute Mix.Project.config()[:aliases][:precommit]
  end

  test "the gate keeps the cheap deterministic invariants and the product suite" do
    assert Verify.required_checks(true) == [
             {"compile", ["--warnings-as-errors"]},
             {"format", ["--check-formatted"]},
             {"test", ["--raise", "--max-failures", "5"]},
             {"space_traders.gen.models", ["--check"]},
             {"space_traders.gen.operations", ["--check"]},
             {"verify.boundary", []},
             {"verify.boot", []}
           ]
  end

  test "locally the format check fixes instead of checking" do
    assert {"format", []} = List.keyfind(Verify.required_checks(false), "format", 0)
  end

  test "a passing gate prints one line per check, the test summary, and the PASS footer" do
    assert :ok = Verify.run_checks(Verify.required_checks(true), run_check: &passing/2)

    lines = messages()
    assert length(lines) == 7 + 2 + 1
    assert "verify: compile ok 0s" in lines
    assert "Finished in 1.0 seconds" in lines
    assert "3 tests, 0 failures" in lines
    assert List.last(lines) =~ ~r/^verify: PASS 7\/7 \d+s$/
    refute Enum.any?(lines, &(&1 =~ "noise"))
  end

  test "a failing check stops the gate with native output, FAIL footer and rerun command" do
    parent = self()

    runner = fn task, args ->
      send(parent, {:ran, task})

      if task == "test",
        do: {"1) test boom\n6 tests, 5 failures\n", 2},
        else: passing(task, args)
    end

    assert_raise Mix.Error, "verify: FAIL at test", fn ->
      Verify.run_checks(Verify.required_checks(true), run_check: runner)
    end

    assert_received {:ran, "format"}
    assert_received {:ran, "test"}
    refute_received {:ran, "space_traders.gen.models"}

    lines = messages()
    assert "1) test boom\n6 tests, 5 failures" in lines
    assert "verify: FAIL at test" in lines
    assert Enum.any?(lines, &(&1 =~ "stopped at --max-failures 5"))
    assert "verify: rerun with: mix test --failed" in lines
    refute Enum.any?(lines, &(&1 =~ "PASS"))
  end

  test "a failing non-test check reruns that exact task" do
    assert_raise Mix.Error, fn ->
      Verify.run_checks([{"verify.boundary", ["--x"]}], run_check: fn _, _ -> {"bad", 1} end)
    end

    assert "verify: rerun with: mix verify.boundary --x" in messages()
  end

  test "local format fixes are counted and reported on pass" do
    {:ok, snapshots} =
      Agent.start_link(fn -> [%{"a" => 1, "b" => 1}, %{"a" => 2, "b" => 1, "c" => 3}] end)

    snapshot = fn -> Agent.get_and_update(snapshots, fn [h | t] -> {h, t} end) end

    assert :ok = Verify.run_checks([{"format", []}], run_check: &passing/2, snapshot: snapshot)

    lines = messages()
    assert "verify: reformatted 2 files: commit before push" in lines
    assert List.last(lines) =~ "verify: PASS 1/1"
  end

  test "an unchanged tree prints no reformat line, and CI mode never snapshots" do
    same = fn -> %{"a" => 1} end
    assert :ok = Verify.run_checks([{"format", []}], run_check: &passing/2, snapshot: same)
    refute Enum.any?(messages(), &(&1 =~ "reformatted"))

    boom = fn -> flunk("CI mode must not snapshot") end

    assert :ok =
             Verify.run_checks([{"format", ["--check-formatted"]}],
               run_check: &passing/2,
               snapshot: boom
             )
  end
end
