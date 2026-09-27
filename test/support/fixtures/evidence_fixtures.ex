defmodule SpaceTraders.EvidenceFixtures do
  @moduledoc """
  Records governed authoritative observations for tests.

  Governed reads persist an `Observation` with facts; the Intelligence layer
  additionally persists refreshable facts. Shadow evaluation reads the former
  and Fleet Planning reads the latter, so tests that exercise both record both.
  """

  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Repo

  @doc "Records one governed Market observation carrying trade goods facts."
  def governed_market_observation(agent, system, waypoint, purchase_price, sell_price, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    subject = "market:#{system}:#{waypoint}"

    Repo.insert!(%Observation{
      agent_id: agent.id,
      subject: subject,
      operation_id: "get-market",
      dependency_keys: [subject],
      facts: %{
        "trade_goods" => [
          %{
            "symbol" => "IRON_ORE",
            "purchase_price" => purchase_price,
            "sell_price" => sell_price,
            "trade_volume" => 20,
            "supply" => "MODERATE",
            "activity" => "STATIC"
          }
        ]
      },
      response_fingerprint: "market-#{waypoint}-#{purchase_price}",
      observed_at: observed_at
    })
  end
end
