defmodule Mix.Tasks.VerifyTest do
  use ExUnit.Case, async: true

  test "the test alias uses the prepared database without lifecycle tasks" do
    assert Mix.Project.config()[:aliases][:test] == ["test"]
  end

  test "the gate keeps the cheap deterministic invariants and the product suite" do
    assert Mix.Tasks.Verify.required_checks() == [
             {"compile", ["--warnings-as-errors"]},
             {"format", ["--check-formatted"]},
             {"test", ["--raise"]},
             {"space_traders.gen.models", ["--check"]},
             {"space_traders.gen.operations", ["--check"]},
             {"verify.boundary", []},
             {"verify.boot", []}
           ]
  end

  test "every required check runs in order when none of them fails" do
    parent = self()

    result =
      Mix.Tasks.Verify.run_checks(Mix.Tasks.Verify.required_checks(), fn task, args ->
        send(parent, {:ran, task, args})
        :ok
      end)

    ran =
      Stream.repeatedly(fn ->
        receive do
          {:ran, task, args} -> {task, args}
        end
      end)
      |> Enum.take(length(Mix.Tasks.Verify.required_checks()))

    assert result == :ok
    assert ran == Mix.Tasks.Verify.required_checks()
  end

  test "a failing check aborts the gate before any later check runs" do
    assert_raise Mix.Error, "required check failed", fn ->
      Mix.Tasks.Verify.run_checks(
        [{"fixture.first", []}, {"fixture.failing", []}, {"fixture.later", []}],
        fn task, args ->
          send(self(), {:ran, task, args})

          if task == "fixture.failing", do: Mix.raise("required check failed")

          :ok
        end
      )
    end

    assert_received {:ran, "fixture.first", []}
    assert_received {:ran, "fixture.failing", []}
    refute_received {:ran, "fixture.later", []}
  end

  @tag :tmp_dir
  test "an actual ExUnit failure exits nonzero before the next check", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, "lib"))
    File.mkdir_p!(Path.join(tmp_dir, "test"))
    File.cp!("lib/mix/tasks/verify.ex", Path.join(tmp_dir, "lib/verify.ex"))

    File.write!(Path.join(tmp_dir, "mix.exs"), """
    defmodule VerifyFailureFixture.MixProject do
      use Mix.Project
      def project, do: [app: :verify_failure_fixture, version: "0.0.0", aliases: [test: ["test"]]]
    end
    """)

    File.write!(Path.join(tmp_dir, "lib/probe.ex"), """
    defmodule Mix.Tasks.Verify.FailureProbe do
      use Mix.Task
      def run(_) do
        test_check = List.keyfind(Mix.Tasks.Verify.required_checks(), "test", 0)
        Mix.Tasks.Verify.run_checks([test_check, {"verify.later_probe", []}])
      end
    end
    defmodule Mix.Tasks.Verify.LaterProbe do
      use Mix.Task
      def run(_), do: IO.puts("LATER_CHECK_RAN")
    end
    """)

    File.write!(Path.join(tmp_dir, "test/test_helper.exs"), "ExUnit.start()\n")

    File.write!(Path.join(tmp_dir, "test/failure_test.exs"), """
    defmodule ActualFailureTest do
      use ExUnit.Case
      test "deliberate ExUnit failure", do: assert(false)
    end
    """)

    {output, status} =
      System.cmd("mix", ["verify.failure_probe"],
        cd: tmp_dir,
        env: [
          {"MIX_ENV", "test"},
          {"MIX_BUILD_PATH", Path.join(tmp_dir, "_build")},
          {"ERL_FLAGS", "+S 2:2"}
        ],
        stderr_to_stdout: true
      )

    assert status != 0, output
    assert output =~ "1 test, 1 failure"
    refute output =~ "LATER_CHECK_RAN"
    refute output =~ "verify: verify.later_probe"
  end
end
