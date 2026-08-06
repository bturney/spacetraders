defmodule SpaceTraders.Repo do
  use Ecto.Repo,
    otp_app: :spacetraders,
    adapter: Ecto.Adapters.SQLite3
end
