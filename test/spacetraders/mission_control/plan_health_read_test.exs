defmodule SpaceTraders.MissionControl.PlanHealthReadTest do
  @moduledoc """
  Plan Health read from stored facts (#769) on the scenario seeds (#768).
  Seam: `MissionControl.PlanHealth.read/2`.
  """
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.CreditSpendingFixtures
  import SpaceTraders.EvidenceFixtures

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode, as: Episode
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.{Liveness, ScenarioSeeds}
  alias SpaceTraders.MissionControl.PlanHealth

  setup do
    Liveness.reset()
    :ok
  end

  defp read(seeded) do
    operator = Repo.get!(Operator, seeded.generation.operator_id)
    PlanHealth.read(Scope.for_operator(operator), seeded.now)
  end

  for {situation, ships, state} <- [
        {:healthy, 2, :on},
        {:healthy, 120, :on},
        {:busy_not_earning, 2, :setback},
        {:busy_not_earning, 120, :setback},
        {:waiting, 2, :on},
        {:waiting, 120, :on},
        {:stuck, 2, :off},
        {:stuck, 120, :off}
      ] do
    test "#{situation} at #{ships} Ships reads #{state}" do
      health = read(ScenarioSeeds.seed(unquote(situation), unquote(ships)))
      assert health.state == unquote(state), health.reason
    end
  end

  test "a waiting Fleet says when it checks again" do
    health = read(ScenarioSeeds.seed(:waiting, 2))
    assert health.reason =~ "Waiting on purpose for a trade worth making; next check"
  end

  test "old information names the Ships that have not reported" do
    health = read(ScenarioSeeds.seed(:old_information, 120))
    ships = Enum.find(health.checks, &(&1.name == :ships_moving))
    assert ships.detail =~ "30 Ships have not reported since"
  end

  describe "an open trade" do
    setup do
      {agent, [intent], portfolio} = claimed_purchases([0])
      [commitment] = portfolio.commitments
      now = DateTime.utc_now(:second)

      commitment
      |> Ecto.Changeset.change(
        dependencies: [%{"subject" => "market:X1:X1-A2", "evidence_id" => "listing-1"}]
      )
      |> Repo.update!()

      # Estimated at 10 min; taken 20 min ago, so due 5 min ago (150%).
      Repo.get!(Episode, portfolio.strategy_decision_episode_id)
      |> Ecto.Changeset.change(
        expectations: %{
          "selected_trades" => [
            %{"candidate_id" => commitment.candidate_id, "trade_estimate" => %{"seconds" => 600}}
          ]
        }
      )
      |> Repo.update!()

      intent
      |> Ecto.Changeset.change(inserted_at: DateTime.add(now, -20 * 60))
      |> Repo.update!()

      scope = Scope.for_operator(Repo.get!(Operator, agent.operator_id))
      %{agent: agent, commitment: commitment, scope: scope, now: now}
    end

    test "50% past its estimate with no sale, earnings are too old to judge", ctx do
      governed_market_observation(ctx.agent, "X1", "X1-A2", 10, 20, observed_at: ctx.now)
      health = PlanHealth.read(ctx.scope, ctx.now)

      assert health.state == :unknown
      assert health.reason =~ "1 trade is well past its estimate; no sale recorded since"
    end

    test "a recorded trade is no longer expected", ctx do
      governed_market_observation(ctx.agent, "X1", "X1-A2", 10, 20, observed_at: ctx.now)
      record!(ctx)

      assert PlanHealth.read(ctx.scope, ctx.now).state == :on
    end

    test "a Market behind it past the freshness limit is a small setback", ctx do
      governed_market_observation(ctx.agent, "X1", "X1-A2", 10, 20,
        observed_at: DateTime.add(ctx.now, -44 * 60)
      )

      health = PlanHealth.read(ctx.scope, ctx.now)

      assert health.state == :setback
      assert health.reason == "Prices at A2 are 44 min old (trusted up to 30)."
    end
  end

  defp record!(ctx) do
    generation = SpaceTraders.FleetAllocation.active_generation(ctx.agent)

    Repo.insert!(%EarningsRecord{
      source: "trade",
      fleet_generation_id: generation.id,
      fleet_commitment_id: ctx.commitment.id,
      ship_symbol: "BUYER-0",
      ship_type: "SHIP_COMMAND_FRIGATE",
      good: "IRON_ORE",
      units: 10,
      revenue: 200,
      goods_cost: 100,
      fuel_cost: 0,
      other_cost: 0,
      net_earnings: 100,
      expected_value: 100,
      ship_seconds: 600,
      started_at: usec(DateTime.add(ctx.now, -1200)),
      finished_at: usec(DateTime.add(ctx.now, -60))
    })
  end

  defp usec(at), do: %{at | microsecond: {0, 6}}
end
