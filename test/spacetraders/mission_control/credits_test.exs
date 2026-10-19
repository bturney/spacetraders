defmodule SpaceTraders.MissionControl.CreditsTest do
  @moduledoc """
  Glance credits (#770, spec #757): the balance, its growth over the
  Generation and Net Earnings over the last 6 h, all from stored data.
  Seam: `MissionControl.Credits.read/2`.
  """
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.MissionControl.Credits
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.ScenarioSeeds

  defp read(seeded) do
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    Credits.read(Scope.for_operator(operator), seeded.now)
  end

  defp record(seeded, net, finished_at) do
    Repo.insert!(%EarningsRecord{
      source: "trade",
      fleet_generation_id: seeded.generation.id,
      ship_symbol: "SEEDED-1",
      ship_type: "SHIP_LIGHT_HAULER",
      good: "IRON_ORE",
      units: 1,
      revenue: net,
      goods_cost: 0,
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: net,
      ship_seconds: 60,
      finished_at: finished_at,
      started_at: DateTime.add(finished_at, -60)
    })
  end

  defp observe(seeded, credits, at) do
    Repo.insert!(%Observation{
      agent_id: seeded.agent.id,
      subject: "agent:#{seeded.agent.symbol}",
      operation_id: "get-my-agent",
      dependency_keys: [],
      facts: %{"response" => %{"credits" => credits}},
      response_fingerprint: "fp-#{credits}",
      observed_at: DateTime.add(at, 0, :microsecond),
      fleet_generation_id: seeded.generation.id
    })
  end

  defp update_generation(seeded, set),
    do: Repo.update_all(from(g in Generation, where: g.id == ^seeded.generation.id), set: set)

  defp backdate(seeded, hours) do
    inserted = seeded.now |> DateTime.add(-hours * 3600) |> DateTime.truncate(:second)
    update_generation(seeded, inserted_at: inserted)
    inserted
  end

  test "no current Fleet reads nil" do
    operator = SpaceTraders.AgentFixtures.operator_fixture()
    assert Credits.read(Scope.for_operator(operator), DateTime.utc_now()) == nil
  end

  describe "with a Fleet" do
    setup do
      seeded = ScenarioSeeds.seed(:healthy, 2)
      Repo.delete_all(EarningsRecord)
      Repo.delete_all(from o in Observation, where: o.operation_id == "get-my-agent")
      update_generation(seeded, starting_credits: 100_000, last_observed_credits: nil)
      %{seeded: seeded}
    end

    test "balance is the latest stored observation; growth is its change since the start", %{
      seeded: seeded
    } do
      start = backdate(seeded, 10)
      observe(seeded, 100_000, DateTime.add(start, 10))
      observe(seeded, 130_000, DateTime.add(seeded.now, -3600))
      observe(seeded, 150_000, DateTime.add(seeded.now, -5))

      credits = read(seeded)
      assert credits.balance == 150_000
      assert credits.growth == 50_000
      assert hd(credits.series).credits == 100_000
      assert List.last(credits.series).credits == 150_000
    end

    test "without any observation the balance is unknown, never zero", %{seeded: seeded} do
      credits = read(seeded)
      assert credits.balance == nil
      assert credits.growth == nil
      assert credits.series == []
    end

    test "rate is the sum of Earnings records in the last 6 h, labelled with the window", %{
      seeded: seeded
    } do
      backdate(seeded, 10)
      record(seeded, 1_000, DateTime.add(seeded.now, -3600))
      record(seeded, 2_500, DateTime.add(seeded.now, -5 * 3600))
      record(seeded, 9_999, DateTime.add(seeded.now, -7 * 3600))

      credits = read(seeded)
      assert credits.net == 3_500
      assert credits.since == nil
      assert credits.per_hour == 583
    end

    test "a young Generation reads since HH:MM", %{seeded: seeded} do
      inserted = backdate(seeded, 2)
      record(seeded, 1_200, DateTime.add(seeded.now, -1800))

      credits = read(seeded)
      assert credits.net == 1_200
      assert credits.since == inserted
    end
  end
end
