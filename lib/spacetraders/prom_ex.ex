defmodule SpaceTraders.PromEx do
  use PromEx, otp_app: :spacetraders

  @impl PromEx
  def plugins do
    [
      {PromEx.Plugins.Phoenix,
       endpoint: SpaceTradersWeb.Endpoint, router: SpaceTradersWeb.Router},
      PromEx.Plugins.PhoenixLiveView,
      PromEx.Plugins.Ecto,
      PromEx.Plugins.Beam,
      SpaceTraders.PromEx.API
    ]
  end

  @impl PromEx
  def dashboards, do: []
end
