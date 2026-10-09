defmodule SpaceTraders.EvidenceFixtures do
  @moduledoc """
  Records governed authoritative observations for tests.

  A governed Market read persists one Evidence `Observation`; Operational
  Intelligence then retains its Listing facts linked to that exact source.
  Market planning, shadow evaluation and coverage read the linked
  Intelligence facts, so Market fixtures record both stores, linked.
  """

  import Ecto.Query

  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo

  @doc "Records one governed IRON_ORE Market Listing, linked in both stores."
  def governed_market_observation(agent, system, waypoint, purchase_price, sell_price, opts \\ []) do
    goods = [
      %{
        symbol: "IRON_ORE",
        purchase_price: purchase_price,
        sell_price: sell_price,
        trade_volume: Keyword.get(opts, :trade_volume, 20),
        supply: "MODERATE",
        activity: "STATIC"
      }
    ]

    {source, _retained} = retained_market_listing(agent, system, waypoint, goods, opts)
    source
  end

  @doc """
  Records one governed Market Listing: the Evidence observation and the
  Intelligence facts linked to it.

  Options: `:observed_at` (original acquisition time), `:fleet_generation_id`
  (defaults to the Agent's current Generation, as governed retention does),
  `:observing_ship_symbol`.
  """
  def retained_market_listing(agent, system, waypoint, goods, opts \\ []) do
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())
    subject = "market:#{system}:#{waypoint}"

    facts = %{
      "symbol" => waypoint,
      "trade_goods" => Enum.map(goods, &stringify/1)
    }

    source =
      Repo.insert!(%Observation{
        agent_id: agent.id,
        subject: subject,
        operation_id: "get-market",
        dependency_keys: [subject],
        facts: facts,
        response_fingerprint: SpaceTraders.Evidence.fingerprint(facts),
        observed_at: DateTime.add(observed_at, 0, :microsecond),
        fleet_generation_id:
          Keyword.get_lazy(opts, :fleet_generation_id, fn -> current_generation(agent) end)
      })

    {:ok, retained} =
      Intelligence.observe_market(
        agent,
        system,
        %{symbol: waypoint, exports: [], imports: [], exchange: [], trade_goods: goods},
        source: "get_market",
        observing_ship_symbol: Keyword.get(opts, :observing_ship_symbol, "#{agent.symbol}-1"),
        evidence: source
      )

    {source, retained}
  end

  defp current_generation(agent) do
    Repo.one(
      from generation in Generation,
        where: generation.agent_id == ^agent.id and is_nil(generation.retired_at),
        select: generation.id
    )
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
