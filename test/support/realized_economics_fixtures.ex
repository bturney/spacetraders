defmodule SpaceTraders.RealizedEconomicsFixtures do
  @moduledoc """
  Root Intents, their recorded MutationAttempts and Credit Calibration
  Realizations, shaped as the recorded-action path writes them, for
  receipt-backed realized economics tests (#689).
  """

  alias SpaceTraders.CreditCalibration
  alias SpaceTraders.CreditCalibration.Realization
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.Repo

  @doc "A completed non-trade root Intent (e.g. coverage) of one Commitment."
  def intent!(portfolio, commitment, type, opts) do
    ship = Repo.get_by!(Ship, symbol: Keyword.fetch!(opts, :ship))

    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      type: type,
      target_waypoint: "X1-A-scout",
      status: Keyword.get(opts, :status, "completed"),
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version,
      last_action_result: %{"kind" => type}
    })
  end

  @doc """
  A refuel (or, with `:operation_id`, another send) issued by `intent`, with
  its Realization of `charge` unless `realized: false`.
  """
  def refuel!(%Intent{} = intent, charge, opts \\ []) do
    ship = Repo.get!(Ship, intent.ship_id)

    provenance =
      Keyword.get(opts, :provenance, %{
        "intent_id" => intent.id,
        "intent_caller" => intent.caller,
        "commitment_id" => intent.fleet_commitment_id,
        "portfolio_id" => intent.fleet_commitment_portfolio_id,
        "ship_symbol" => ship.symbol
      })

    attempt =
      Repo.insert!(%Attempt{
        operation_id: Keyword.get(opts, :operation_id, "refuel-ship"),
        operation_owner: "ship_execution",
        state: Keyword.get(opts, :state, "succeeded"),
        request_fingerprint: Ecto.UUID.generate(),
        prepared_evidence: Keyword.get(opts, :prepared_evidence, %{}),
        provenance: provenance,
        agent_id: ship.agent_id,
        strategy_revision_id: Keyword.get(opts, :strategy_revision_id),
        prepared_at: DateTime.utc_now()
      })

    if Keyword.get(opts, :realized, true) do
      Repo.insert!(%Realization{
        agent_id: ship.agent_id,
        mutation_attempt_id: attempt.id,
        calibration_version_id: CreditCalibration.active().id,
        operation_id: attempt.operation_id,
        unit_price: charge,
        units: 1,
        worst_case_exposure: charge * 2,
        realized_charge: charge,
        credits_after: 10_000,
        within_bound: true
      })
    end

    attempt
  end

  @doc """
  A buy or sell root Intent with its transaction receipt (none when `total` is
  nil) and, unless `attempt: false`, the provenanced send that produced it.
  """
  def trade_intent!(portfolio, commitment, type, total, units, opts \\ []) do
    ship = Repo.get_by!(Ship, symbol: Keyword.get(opts, :ship, "SHIP-1"))

    result =
      if total,
        do: %{
          "transaction" => %{
            "type" => String.upcase(type),
            "trade_symbol" => "IRON_ORE",
            "ship_symbol" => ship.symbol,
            "waypoint_symbol" => "X1-A-#{type}",
            "units" => units,
            "price_per_unit" => div(total, units),
            "total_price" => total
          }
        },
        else: %{"kind" => type}

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        type: type,
        target_waypoint: "X1-A-#{type}",
        status: Keyword.get(opts, :status, "completed"),
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        last_action_result: result
      })

    if total && Keyword.get(opts, :attempt, true) do
      operation = if type == "buy", do: "purchase-cargo", else: "sell-cargo"
      attempt = refuel!(intent, total, operation_id: operation, realized: type == "buy")

      intent |> Ecto.Changeset.change(mutation_attempt_id: attempt.id) |> Repo.update!()
    else
      intent
    end
  end
end
