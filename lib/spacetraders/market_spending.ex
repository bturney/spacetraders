defmodule SpaceTraders.MarketSpending do
  @moduledoc "Quote-backed Market purchase exposure shared by selection and recorded admission."

  import Ecto.Query

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.{Clock, Evidence, Repo}
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.StandingAuthority
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.SafetyFence.DependencyKey

  @version "market-purchase-v1-25pct"
  @margin 25
  @minimum_margin 10
  @freshness_seconds 30
  @credit_operations ~w(purchase-cargo purchase-ship refuel-ship jump-ship install-ship-module remove-ship-module install-ship-mount remove-ship-mount repair-ship)

  def worst_case_exposure(price, units, margin \\ @margin)
      when is_integer(price) and price >= 0 and is_integer(units) and units >= 0 and
             is_integer(margin) and margin >= @minimum_margin do
    div(price * units * (100 + margin) + 99, 100)
  end

  def affordable_units(credits, price) when is_integer(price) and price > 0,
    do: div(max(credits, 0) * 100, price * (100 + @margin))

  def affordable_units(_credits, 0), do: :infinity

  # Reads run before the Intent/Attempt transaction. Reuse preserves original age.
  def acquire(agent, intent, %{"kind" => "buy", "units" => units} = action) do
    waypoint = intent.target_waypoint
    system = waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
    subject = "market:#{system}:#{waypoint}"

    with {:ok, quote} <-
           retained_or_read(agent, subject, fn ->
             Evidence.get_market(agent, system, waypoint,
               bind: true,
               required_facts: ["symbol", "trade_goods"],
               owner: "ship_execution"
             )
           end),
         true <- quote.value.symbol == waypoint and fresh?(quote.observation.observed_at),
         true <- Evidence.valid_observation?(quote.observation),
         good when not is_nil(good) <-
           Enum.find(quote.value.trade_goods || [], &(&1.symbol == action["trade_symbol"])),
         true <- is_integer(good.purchase_price) and good.purchase_price >= 0,
         true <-
           is_integer(units) and units > 0 and is_integer(good.trade_volume) and
             units <= good.trade_volume,
         {:ok, credits} <- acquire_credits(agent),
         true <-
           credits.value.symbol == agent.symbol and is_integer(credits.value.credits) and
             credits.value.credits >= 0 do
      {:ok,
       %{
         "quote_observation_id" => quote.observation.id,
         "quote_observed_at" => DateTime.to_iso8601(quote.observation.observed_at),
         "credit_observation_id" => credits.observation.id,
         "waypoint" => waypoint,
         "trade_symbol" => action["trade_symbol"],
         "unit_price" => good.purchase_price,
         "units" => units,
         "calibration_version" => @version,
         "margin_percent" => @margin,
         "worst_case_exposure" => worst_case_exposure(good.purchase_price, units)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :market_quote_unavailable}
    end
  end

  def acquire(_agent, _intent, _action), do: {:ok, nil}

  def lock_agent(%Attempt{operation_id: "purchase-cargo", agent_id: id}), do: lock_agent(id)
  def lock_agent(%Attempt{}), do: :ok

  def lock_agent(id) when is_integer(id),
    do: Repo.one!(from a in Agent, where: a.id == ^id, lock: "FOR UPDATE")

  def admit(%Attempt{operation_id: "purchase-cargo"} = attempt, intent, revision) do
    agent = Repo.get!(Agent, attempt.agent_id)
    spending = attempt.prepared_evidence["spending"]

    with :ok <- validate_quote(agent, attempt, spending),
         {:ok, credits} <- current_credits(agent),
         {:ok, floor} <- credit_floor(revision),
         {:ok, other_exposure} <- other_exposure(agent, intent, attempt, credits.observation),
         true <- credits.value.credits - other_exposure - spending["worst_case_exposure"] >= floor do
      :ok
    else
      false -> {:error, :insufficient_unreserved_headroom}
      {:error, _} = error -> error
    end
  end

  def admit(_attempt, _intent, _revision), do: :ok

  defp validate_quote(agent, attempt, spending) when is_map(spending) do
    body = attempt.prepared_evidence["request"]["body"]

    with {:ok, quote} <- Evidence.retained_binding(agent, spending["quote_observation_id"]),
         true <- quote.observation.operation_id == "get-market",
         true <- Evidence.valid_observation?(quote.observation),
         true <- quote.observation.fleet_generation_id == attempt.fleet_generation_id,
         true <- quote.value.symbol == spending["waypoint"],
         true <-
           DateTime.to_iso8601(quote.observation.observed_at) == spending["quote_observed_at"],
         true <- fresh?(quote.observation.observed_at),
         good when not is_nil(good) <-
           Enum.find(quote.value.trade_goods || [], &(&1.symbol == body["symbol"])),
         true <- is_integer(good.purchase_price) and good.purchase_price >= 0,
         true <-
           spending["trade_symbol"] == body["symbol"] and spending["units"] == body["units"],
         true <- spending["unit_price"] == good.purchase_price,
         true <-
           spending["calibration_version"] == @version and spending["margin_percent"] == @margin,
         true <-
           spending["worst_case_exposure"] ==
             worst_case_exposure(good.purchase_price, body["units"]) do
      :ok
    else
      _ -> {:error, :market_quote_stale_or_missing}
    end
  end

  defp validate_quote(_agent, _attempt, _spending), do: {:error, :market_quote_stale_or_missing}

  defp acquire_credits(agent) do
    case current_credits(agent) do
      {:ok, binding} ->
        if Repo.exists?(
             from a in Attempt,
               where:
                 a.agent_id == ^agent.id and a.operation_id in ^@credit_operations and
                   a.state in ["succeeded", "accepted"] and
                   a.updated_at >= ^binding.observation.observed_at
           ),
           do: Evidence.get_agent_binding(agent, owner: "ship_execution"),
           else: {:ok, binding}

      _ ->
        Evidence.get_agent_binding(agent, owner: "ship_execution")
    end
  end

  defp current_credits(agent) do
    subject = DependencyKey.observation_subject("get-my-agent", [], agent.symbol)

    with %{id: id} <- Evidence.latest_observation(agent, subject),
         {:ok, binding} <- Evidence.retained_binding(agent, id),
         true <- Evidence.valid_observation?(binding.observation),
         true <- fresh?(binding.observation.observed_at),
         true <-
           binding.value.symbol == agent.symbol and is_integer(binding.value.credits) and
             binding.value.credits >= 0 do
      {:ok, binding}
    else
      _ -> {:error, :authoritative_credit_facts_required}
    end
  end

  defp retained_or_read(agent, subject, read) do
    with %{id: id, observed_at: time} <- Evidence.latest_observation(agent, subject),
         true <- fresh?(time),
         {:ok, binding} <- Evidence.retained_binding(agent, id) do
      {:ok, binding}
    else
      _ -> read.()
    end
  end

  defp fresh?(%DateTime{} = time),
    do: DateTime.diff(Clock.utc_now(), time, :millisecond) in 0..(@freshness_seconds * 1000)

  defp fresh?(_), do: false

  defp credit_floor(nil), do: {:ok, 0}

  defp credit_floor(revision) do
    case StandingAuthority.credit_floor(revision) do
      {:error, :no_credit_floor} -> {:ok, 0}
      result -> result
    end
  end

  # A Reservation and its admitted attempts protect the same work. Charge the
  # larger protection, never both. The current action consumes its own share.
  defp other_exposure(agent, intent, attempt, balance_source) do
    reservations =
      Repo.all(
        from c in Commitment,
          join: p in Portfolio,
          on: p.id == c.fleet_commitment_portfolio_id,
          join: g in Generation,
          on: g.id == p.fleet_generation_id,
          where:
            g.agent_id == ^agent.id and is_nil(g.retired_at) and is_nil(p.superseded_at) and
              c.unwind_state == :not_required,
          select: {c.id, c.reservations}
      )
      |> Map.new(fn {id, resources} -> {id, Map.get(resources, "credits", 0)} end)
      |> Map.delete(intent.fleet_commitment_id)

    attempts =
      Repo.all(
        from a in Attempt,
          where:
            a.agent_id == ^agent.id and a.id != ^attempt.id and
              a.operation_id in ^@credit_operations and
              (a.state in ["sent_or_unknown", "ambiguous", "bounded_unknown"] or
                 (a.state in ["succeeded", "accepted"] and
                    a.updated_at >= ^balance_source.observed_at))
      )

    Enum.reduce_while(attempts, {:ok, %{}}, fn a, {:ok, exposures} ->
      case get_in(a.prepared_evidence, ["spending", "worst_case_exposure"]) do
        bound when is_integer(bound) and bound >= 0 ->
          key = a.provenance["commitment_id"] || a.id
          {:cont, {:ok, Map.update(exposures, key, bound, &(&1 + bound))}}

        _ ->
          {:halt, {:error, :unbounded_purchase_exposure}}
      end
    end)
    |> case do
      {:ok, exposures} ->
        {:ok,
         Map.merge(reservations, exposures, fn _id, reserve, bound -> max(reserve, bound) end)
         |> Map.values()
         |> Enum.sum()}

      error ->
        error
    end
  end
end
