defmodule Mix.Tasks.Spacetraders.Seed do
  @shortdoc "Seeds a synthetic scenario (healthy, busy_not_earning, waiting, stuck, old_information)"

  @moduledoc """
  Seeds one of the five situations into the dev database (#768).

      mix spacetraders.seed <situation> [--ships 2|120]
      mix spacetraders.seed --clear

  Situations: healthy, busy_not_earning, waiting, stuck, old_information.
  Ships default to 2. Run on a database without a real Fleet (`mix ecto.reset`
  first); seeding again replaces the previous seed. Log in at
  /operators/log-in as `seed@scenario.test` with the password
  `scenario seed 12345`, then open /ships. The seeded Agent has a fake token:
  do not point a running app at the real game.
  """

  use Mix.Task

  require Logger

  alias SpaceTraders.ScenarioSeeds

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [ships: :integer, clear: :boolean])
    Mix.Task.run("app.config")
    Logger.configure(level: :warning)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = SpaceTraders.Repo.start_link(pool_size: 2)

    cond do
      opts[:clear] ->
        ScenarioSeeds.clear!()
        Mix.shell().info("Seed cleared")

      match?([_], rest) ->
        seed(hd(rest), Keyword.get(opts, :ships, 2))

      true ->
        names = Enum.join(ScenarioSeeds.situations(), "|")
        Mix.raise("usage: mix spacetraders.seed <#{names}> [--ships 2|120]")
    end
  end

  defp seed(name, ships) do
    situation = Enum.find(ScenarioSeeds.situations(), &(Atom.to_string(&1) == name))
    situation || Mix.raise("unknown situation #{name}")
    ships in ScenarioSeeds.sizes() || Mix.raise("--ships must be 2 or 120")

    seeded = ScenarioSeeds.seed(situation, ships)
    credentials = ScenarioSeeds.credentials()

    Mix.shell().info(
      "Seeded #{situation} with #{ships} Ships (#{length(seeded.affected)} affected). " <>
        "Log in as #{credentials.email} / #{credentials.password}, open /ships."
    )
  end
end
