defmodule SpaceTraders.Repo do
  use Ecto.Repo,
    otp_app: :spacetraders,
    adapter: Application.compile_env(:spacetraders, :repo_adapter)
end
