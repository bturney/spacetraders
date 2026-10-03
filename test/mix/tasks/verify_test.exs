defmodule Mix.Tasks.VerifyTest do
  use ExUnit.Case, async: true

  test "the test alias uses the prepared database without lifecycle tasks" do
    assert Mix.Project.config()[:aliases][:test] == ["test"]
  end

  test "the gate keeps the cheap deterministic invariants and the product suite" do
    assert Mix.Tasks.Verify.required_checks() == [
             {"compile", ["--warnings-as-errors"]},
             {"format", ["--check-formatted"]},
             {"test", []},
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
end
