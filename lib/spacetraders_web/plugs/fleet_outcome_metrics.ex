defmodule SpaceTradersWeb.FleetOutcomeMetrics do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts) do
    inner = Keyword.get(opts, :inner_plug, PromEx.Plug)
    %{inner: inner, opts: inner.init(Keyword.delete(opts, :inner_plug))}
  end

  @impl true
  def call(%{request_path: path} = conn, %{inner: inner, opts: %{metrics_path: path} = opts}) do
    case SpaceTraders.Outcomes.Fleet.expose(fn -> inner.call(conn, opts) end) do
      :projection_down ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Service Unavailable")
        |> halt()

      conn ->
        conn
    end
  end

  def call(conn, _opts), do: conn
end
