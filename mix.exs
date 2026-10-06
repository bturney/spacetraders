defmodule SpaceTraders.MixProject do
  use Mix.Project

  def project do
    [
      app: :spacetraders,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {SpaceTraders.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [verify: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:pbkdf2_elixir, "~> 2.0"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:prom_ex, "~> 1.12"},
      {:logger_json, "~> 7.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [&seed_from_main/1, "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind spacetraders", "esbuild spacetraders"],
      "assets.deploy": [
        "tailwind spacetraders --minify",
        "esbuild spacetraders --minify",
        "phx.digest"
      ],
      # The compile leg repeats `Mix.Tasks.Verify`'s first required check so that
      # it runs before Mix compiles the project on its own. See that task.
      verify: ["compile --warnings-as-errors", "verify"]
    ]
  end

  # A fresh worktree has no deps/ or _build/. Mix runs a function alias before it
  # loads or checks deps, so this copy lands first: `mix test <file>` works with
  # no setup, recompiling only app files. Copies only what is absent, and only
  # from a main checkout that has it; the main checkout is never written.
  defp seed_from_main(_args) do
    case System.cmd("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"],
           stderr_to_stdout: true
         ) do
      {common_dir, 0} ->
        main = common_dir |> String.trim() |> Path.dirname()

        if Path.expand(main) != Path.expand(File.cwd!()) do
          for rel <- ["deps", Path.join("_build", to_string(Mix.env()))] do
            seed(Path.join(main, rel), rel)
          end
        end

      _ ->
        :ok
    end
  end

  defp seed(source, dest) do
    if File.dir?(source) and not File.exists?(dest) do
      Mix.shell().info("Seeding #{dest} from #{source}")
      File.mkdir_p!(Path.dirname(dest))
      File.cp_r!(source, dest)
    end
  end
end
