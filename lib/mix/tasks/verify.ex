defmodule Mix.Tasks.Verify do
  @shortdoc "Runs the required product correctness checks and fails fast"

  @moduledoc """
  Runs the required product correctness checks in a fixed order and stops at the
  first failure. Release packaging and deployment-topology checks live in the
  separate `release-deployment-verification` CI contract.

  This is the authoritative product gate behind `scripts/verify` and `mix
  verify`. It only sequences checks: it does not prepare an environment, choose
  a database, allocate a worktree, or retain a transcript. Callers that want
  command output keep it themselves.

  ## The verdict is the exit status

  A required check reports failure by failing, exactly as it would when invoked
  directly. `run_checks/2` lets that failure propagate unchanged, so the gate
  aborts before any later check runs and the process exits non-zero. The gate
  returns `:ok` only when every required check has completed. No check's output
  is inspected to decide the result.
  """

  use Mix.Task

  # Compilation leads the gate. Mix compiles the project itself while loading
  # this task, and `mix format` compiles it again when a formatter plugin is not
  # loaded yet, so by the time any check runs the compile task is already spent.
  # The `verify` alias therefore repeats this leg ahead of the task, where it is
  # the first thing Mix compiles; inside the task it costs nothing.
  @required_checks [
    {"compile", ["--warnings-as-errors"]},
    {"format", ["--check-formatted"]},
    {"test", ["--raise"]},
    {"space_traders.gen.models", ["--check"]},
    {"space_traders.gen.operations", ["--check"]},
    {"verify.boundary", []},
    {"verify.boot", []}
  ]

  @impl true
  def run(_args), do: run_checks(required_checks())

  @doc """
  The required product checks, in the order the gate runs them.

  Cheap deterministic invariants come first, the whole product suite next, and
  the checks that boot the application last.
  """
  @spec required_checks() :: [{String.t(), [String.t()]}]
  def required_checks, do: @required_checks

  @doc """
  Runs `checks` in order and returns `:ok` once all of them pass.

  `run_check` receives the task name and its arguments, and fails by raising.
  It defaults to `Mix.Task.run/2`. Because the failure propagates, no later
  check runs after the first failure.
  """
  @spec run_checks([{String.t(), [String.t()]}], (String.t(), [String.t()] -> term)) :: :ok
  def run_checks(checks, run_check \\ &Mix.Task.run/2) do
    Enum.each(checks, fn {task, args} ->
      Mix.shell().info("verify: #{task}")
      run_check.(task, args)
    end)
  end
end
