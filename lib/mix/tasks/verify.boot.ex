defmodule Mix.Tasks.Verify.Boot do
  use Mix.Task

  @shortdoc "Boots the app and asserts GET /health returns 200"
  @moduledoc """
  Starts the full OTP application on a real HTTP server and issues an actual
  `GET /health` request against it, asserting a 200 response with
  `{"status": "ok"}`.

  This is the "real app boot" leg of `mix verify`: it proves the whole
  supervision tree (Endpoint, Repo, PubSub) starts and serves traffic, not
  just that the modules compile.

  Run as part of `mix verify`, or directly with `mix verify.boot`.
  """

  @impl Mix.Task
  def run(_args) do
    stop_app_if_started()

    endpoint_config =
      :spacetraders
      |> Application.get_env(SpaceTradersWeb.Endpoint, [])
      |> Keyword.put(:server, true)

    Application.put_env(:spacetraders, SpaceTradersWeb.Endpoint, endpoint_config)

    case Application.ensure_all_started(:spacetraders) do
      {:ok, _started} ->
        check_health(health_url())

      {:error, reason} ->
        Mix.raise("boot verify failed: application did not start: #{inspect(reason)}")
    end
  end

  defp stop_app_if_started do
    if Application.spec(:spacetraders, :vsn) do
      case Application.stop(:spacetraders) do
        :ok ->
          :ok

        {:error, {:not_started, :spacetraders}} ->
          :ok

        {:error, reason} ->
          Mix.raise("boot verify failed: could not stop app: #{inspect(reason)}")
      end
    end
  end

  defp health_url do
    case SpaceTradersWeb.Endpoint.server_info(:http) do
      {:ok, {_ip, port}} ->
        "http://127.0.0.1:#{port}/health"

      {:error, reason} ->
        Mix.raise("boot verify failed: endpoint is not serving HTTP: #{inspect(reason)}")
    end
  end

  defp check_health(url) do
    case Req.get(url, retry: false) do
      {:ok, %Req.Response{status: 200, body: %{"status" => "ok"}}} ->
        Mix.shell().info("boot verify: GET #{url} -> 200 ok")

      {:ok, %Req.Response{status: status}} ->
        Mix.raise("boot verify failed: GET #{url} returned #{status}")

      {:error, reason} ->
        Mix.raise("boot verify failed: request to #{url} errored: #{inspect(reason)}")
    end
  end
end
