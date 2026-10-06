# Derives the dev/test database from the checkout. Loaded by config/dev.exs and
# config/test.exs (config runs before compilation, so this cannot live in lib/).
unless Code.ensure_loaded?(SpaceTraders.CheckoutDb) do
  defmodule SpaceTraders.CheckoutDb do
    @moduledoc false

    @max_length 63
    @hash_length 6
    @base "postgres://postgres:postgres@127.0.0.1:5432/"

    @doc "Pure: env, checkout path, main-checkout path -> database name."
    def name(env, checkout, main) do
      if Path.expand(checkout) == Path.expand(main) do
        "spacetraders_#{env}"
      else
        hash =
          :crypto.hash(:sha256, Path.expand(checkout))
          |> Base.encode16(case: :lower)
          |> binary_part(0, @hash_length)

        prefix = "spacetraders_#{env}_"

        base =
          checkout
          |> Path.basename()
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9]+/, "_")
          |> String.trim("_")

        room = @max_length - byte_size(prefix) - 1 - @hash_length
        prefix <> binary_part(base, 0, min(room, byte_size(base))) <> "_" <> hash
      end
    end

    @doc "Pure: the connection URL; an explicit `DATABASE_URL` wins."
    def url(_env, _checkout, _main, database_url) when is_binary(database_url),
      do: database_url

    def url(env, checkout, main, nil), do: @base <> name(env, checkout, main)

    @doc "Reads the checkout and main-checkout paths from git."
    def url(env) do
      {checkout, main} = detect()
      url(env, checkout, main, System.get_env("DATABASE_URL"))
    end

    defp detect do
      cwd = File.cwd!()

      with {top, 0} <- git(["rev-parse", "--show-toplevel"]),
           {common, 0} <- git(["rev-parse", "--path-format=absolute", "--git-common-dir"]) do
        {String.trim(top), common |> String.trim() |> Path.dirname()}
      else
        _ -> {cwd, cwd}
      end
    end

    defp git(args) do
      System.cmd("git", args, stderr_to_stdout: true)
    rescue
      _ -> :error
    end
  end
end
