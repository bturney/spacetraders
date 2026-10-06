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

  defp exunit(body) do
    "Running ExUnit with seed: 1, max_cases: 8\n\n" <>
      body <> "\nFinished in 1.0 seconds\n3 tests, 0 failures\n"
  end

  defp passing(task, _args) do
    if task == "test",
      do: {"Compiling 2 files (.ex)\n" <> exunit("...\n.\n"), 0},
      else: {"", 0}
  end

  test "the test alias creates and migrates the checkout database quietly before testing" do
    # The leading step seeds deps/ and _build from the main checkout (#619).
    assert [seed, "ecto.create --quiet", "ecto.migrate --quiet", "test"] =
             Mix.Project.config()[:aliases][:test]

    assert is_function(seed, 1)

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
    refute Enum.any?(lines, &(&1 =~ "Compiling"))
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

  describe "stray output" do
    defp gate_with(test_output) do
      runner = fn
        "test", _ -> {test_output, 0}
        task, args -> passing(task, args)
      end

      Verify.run_checks(Verify.required_checks(true), run_check: runner)
    end

    test "a passing test run with a debug dump fails the gate naming the dump" do
      assert_raise Mix.Error, "verify: FAIL at test", fn ->
        gate_with(exunit("..\n507 interruption receipt: %{a: 1}\n.\n"))
      end

      lines = messages()
      assert Enum.any?(lines, &(&1 =~ "stray output" and &1 =~ "507 interruption receipt"))
      assert "verify: rerun with: mix test" in lines
      refute Enum.any?(lines, &(&1 =~ "PASS"))
    end

    test "a dump printed on a line of progress dots is caught" do
      assert_raise Mix.Error, fn -> gate_with(exunit("....hello\n..\n")) end
      assert Enum.any?(messages(), &(&1 =~ "stray output" and &1 =~ "hello"))
    end

    test "a compile warning in a test file is stray output" do
      assert_raise Mix.Error, fn ->
        gate_with(exunit(".\n    warning: unused alias Intent\n.\n"))
      end
    end

    test "formatter output alone passes, including skipped markers and excluded tags" do
      assert :ok = gate_with(exunit("Excluding tags: [:slow]\n\n..*.\n.\n"))
    end

    test "there is no opt-out: the check has no tag to skip it" do
      refute Enum.any?(Verify.required_checks(true), fn {_, args} -> "--exclude" in args end)
    end
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

  describe "preflight" do
    test "reports every problem as cause then fix, runs no check, and exits 2" do
      parent = self()

      problems = fn ->
        [
          {"Postgres unreachable at 127.0.0.1:5432", "docker compose -f compose.dev.yaml up -d"},
          {"dependencies missing: phoenix", "mix setup"}
        ]
      end

      runner = fn task, _ ->
        send(parent, {:ran, task})
        {"", 0}
      end

      assert {:shutdown, 2} =
               catch_exit(
                 Verify.run_checks(Verify.required_checks(true),
                   preflight: problems,
                   run_check: runner
                 )
               )

      refute_received {:ran, _}

      assert messages() == [
               "verify: environment: Postgres unreachable at 127.0.0.1:5432",
               "verify: fix: docker compose -f compose.dev.yaml up -d",
               "verify: environment: dependencies missing: phoenix",
               "verify: fix: mix setup"
             ]
    end

    test "a clean preflight prints nothing and the gate proceeds" do
      assert :ok =
               Verify.run_checks([{"compile", []}],
                 preflight: fn -> [] end,
                 run_check: &passing/2
               )

      assert length(messages()) == 2
    end

    test "a product failure still raises, so it exits 1" do
      assert_raise Mix.Error, fn ->
        Verify.run_checks([{"compile", []}],
          preflight: fn -> [] end,
          run_check: fn _, _ -> {"bad", 1} end
        )
      end
    end

    test "the default preflight finds nothing wrong in a working checkout" do
      assert Verify.preflight() == []
    end

    test "an unreachable Postgres is a problem naming the compose fix" do
      {:ok, l} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(l)
      :gen_tcp.close(l)

      assert [{cause, "docker compose -f compose.dev.yaml up -d"}] =
               Verify.preflight("postgres://u:p@127.0.0.1:#{port}/db", [])

      assert cause =~ "127.0.0.1:#{port}"
    end

    test "missing dependency directories are a problem fixed by mix setup" do
      assert [{cause, "mix setup"}] = Verify.preflight(nil, ["/nonexistent/deps/phoenix"])
      assert cause =~ "phoenix"
    end
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
