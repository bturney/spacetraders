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

  ## Output contract

  A passing check prints one line (`verify: compile ok 4s`); the ExUnit summary
  line follows the test check; the gate ends with `verify: PASS 7/7 <s>`. A
  failing check stops the gate: its native output is shown, then
  `verify: FAIL at <check>` and the exact rerun command. Tests run with
  `--max-failures 5`.

  Locally the gate runs `mix format` in fix mode and, if files changed, reports
  `verify: reformatted <n> files: commit before push` on pass. When the `CI` env
  var is set it keeps `--check-formatted`.

  ## Preflight and exit codes

  Before any check, preflight collects every environment problem (Postgres
  unreachable, missing deps) and prints two lines each (cause, then fix
  command), then exits 2. A product failure exits 1.

  ## The verdict is the exit status

  Each check runs as its own `mix` command and fails by exiting non-zero.
  `run_checks/2` raises on the first failure, so the gate aborts before any
  later check runs and the process exits non-zero. The gate returns `:ok` only
  when every required check has completed. Output is parsed only for display,
  never to decide the result.
  """

  use Mix.Task

  # The `verify` alias in mix.exs repeats the compile leg ahead of this task so
  # it is the first thing Mix compiles; inside the task it costs nothing.
  @max_failures "5"

  @impl true
  def run(_args), do: run_checks(required_checks(), preflight: &preflight/0)

  @doc """
  The required product checks, in the order the gate runs them.

  Cheap deterministic invariants come first, the whole product suite next, and
  the checks that boot the application last. `ci?` selects `--check-formatted`
  over the local format fix.
  """
  @spec required_checks(boolean) :: [{String.t(), [String.t()]}]
  def required_checks(ci? \\ System.get_env("CI") not in [nil, ""]) do
    [
      {"compile", ["--warnings-as-errors"]},
      {"format", if(ci?, do: ["--check-formatted"], else: [])},
      {"test", ["--raise", "--max-failures", @max_failures]},
      {"space_traders.gen.models", ["--check"]},
      {"space_traders.gen.operations", ["--check"]},
      {"verify.boundary", []},
      {"verify.boot", []}
    ]
  end

  @doc """
  Runs `checks` in order and returns `:ok` once all of them pass.

  Options:

    * `:run_check` - `(task, args -> {output, exit_status})`; defaults to
      running `mix task args` in a subprocess.
    * `:preflight` - `(-> [{cause, fix}])` environment problems found before any
      check; defaults to none. Any problem prints two lines each and exits 2.
    * `:snapshot` - `(-> %{path => hash})` of working-tree files, compared
      around the local `format` check to count reformatted files.

  The first non-zero exit prints that check's output and the failure footer,
  then raises, so no later check runs.
  """
  @spec run_checks([{String.t(), [String.t()]}], keyword) :: :ok
  def run_checks(checks, opts \\ []) do
    run_check = Keyword.get(opts, :run_check, &mix_cmd/2)
    snapshot = Keyword.get(opts, :snapshot, &worktree_snapshot/0)
    total = length(checks)
    started = now()

    problems = Keyword.get(opts, :preflight, fn -> [] end).()
    halt_on_problems(problems)

    reformatted =
      Enum.reduce(checks, 0, fn {task, args} = check, reformatted ->
        fixing_format? = task == "format" and "--check-formatted" not in args
        before = if fixing_format?, do: snapshot.()
        t0 = now()
        {output, status} = run_check.(task, args)

        if status != 0, do: fail(check, output)

        Mix.shell().info("verify: #{task} ok #{elapsed(t0)}")
        if task == "test", do: Enum.each(summary_lines(output), &Mix.shell().info/1)

        if fixing_format?, do: reformatted + changed(before, snapshot.()), else: reformatted
      end)

    if reformatted > 0 do
      Mix.shell().info("verify: reformatted #{reformatted} files: commit before push")
    end

    Mix.shell().info("verify: PASS #{total}/#{total} #{elapsed(started)}")
    :ok
  end

  @doc """
  Environment problems as `{cause, fix}` pairs, all collected. Defaults to the
  configured Repo URL and the project's dependency directories.
  """
  @spec preflight(String.t() | nil, [Path.t()]) :: [{String.t(), String.t()}]
  def preflight(url \\ repo_url(), dep_paths \\ dep_paths()) do
    postgres(url) ++ deps(dep_paths)
  end

  defp repo_url, do: Application.get_env(:spacetraders, SpaceTraders.Repo, [])[:url]

  defp dep_paths, do: Map.values(Mix.Project.deps_paths())

  defp postgres(nil), do: []

  defp postgres(url) do
    %URI{host: host, port: port} = URI.parse(url)
    port = port || 5432

    case :gen_tcp.connect(String.to_charlist(host), port, [], 1_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        []

      {:error, _} ->
        [{"Postgres unreachable at #{host}:#{port}", "docker compose -f compose.dev.yaml up -d"}]
    end
  end

  defp deps(paths) do
    case Enum.reject(paths, &File.dir?/1) do
      [] ->
        []

      missing ->
        [{"dependencies missing: #{Enum.map_join(missing, ", ", &Path.basename/1)}", "mix setup"}]
    end
  end

  defp halt_on_problems([]), do: :ok

  defp halt_on_problems(problems) do
    for {cause, fix} <- problems do
      Mix.shell().info("verify: environment: #{cause}")
      Mix.shell().info("verify: fix: #{fix}")
    end

    exit({:shutdown, 2})
  end

  defp fail({task, args}, output) do
    Mix.shell().info(String.trim_trailing(output))
    Mix.shell().info("verify: FAIL at #{task}")

    if task == "test" and (failure_count(output) || 0) >= String.to_integer(@max_failures) do
      Mix.shell().info("verify: stopped at --max-failures #{@max_failures}; more may exist")
    end

    Mix.shell().info("verify: rerun with: #{rerun(task, args)}")
    Mix.raise("verify: FAIL at #{task}")
  end

  defp rerun("test", _args), do: "mix test --failed"
  defp rerun(task, args), do: Enum.join(["mix", task | args], " ")

  defp summary_lines(output) do
    ~r/^(?:Finished in .*|\d+ (?:doctests?|properties|tests?),.*)$/m
    |> Regex.scan(output)
    |> Enum.map(&hd/1)
  end

  defp failure_count(output) do
    case Regex.run(~r/(\d+) failures?/, output) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp changed(before, after_),
    do: Enum.count(after_, fn {path, hash} -> before[path] != hash end)

  defp worktree_snapshot do
    {files, 0} = System.cmd("git", ["ls-files", "-m", "-o", "--exclude-standard"])

    for path <- String.split(files, "\n", trim: true), File.regular?(path), into: %{} do
      {out, 0} = System.cmd("git", ["hash-object", path])
      {path, out}
    end
  end

  defp mix_cmd(task, args), do: System.cmd("mix", [task | args], stderr_to_stdout: true)

  defp now, do: System.monotonic_time(:millisecond)
  defp elapsed(t0), do: "#{div(now() - t0 + 500, 1000)}s"
end
