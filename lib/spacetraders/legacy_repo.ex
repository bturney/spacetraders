defmodule SpaceTraders.LegacyRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :spacetraders,
    adapter: Ecto.Adapters.SQLite3
end
