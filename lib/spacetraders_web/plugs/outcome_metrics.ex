defmodule SpaceTradersWeb.OutcomeMetrics do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: PromEx.Plug.init(opts)

  @impl true
  def call(%{request_path: path} = conn, %{metrics_path: path, prom_ex_module: module}) do
    case SpaceTraders.Outcomes.metrics(module) do
      :prom_ex_down ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(503, "Service Unavailable")
        |> halt()

      metrics ->
        PromEx.ETSCronFlusher.defer_ets_flush(module.__ets_cron_flusher_name__())
        conn |> put_resp_content_type("text/plain") |> send_resp(200, metrics) |> halt()
    end
  end

  def call(conn, _opts), do: conn
end
