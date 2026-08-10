defmodule SpaceTradersWeb.OriginCheck do
  @moduledoc false

  def parse(nil), do: true

  def parse(origins) do
    case origins |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> true
      allowed_origins -> allowed_origins
    end
  end
end
