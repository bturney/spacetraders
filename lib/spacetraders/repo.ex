defmodule SpaceTraders.Repo do
  use Ecto.Repo,
    otp_app: :spacetraders,
    adapter: Ecto.Adapters.Postgres
end
