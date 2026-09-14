defmodule SpaceTraders.PostgresRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :spacetraders,
    adapter: Ecto.Adapters.Postgres
end
