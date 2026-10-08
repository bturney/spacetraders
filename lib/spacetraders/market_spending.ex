defmodule SpaceTraders.MarketSpending do
  @moduledoc "Quote-backed Market purchase exposure shared by selection and recorded admission."

  import Ecto.Query

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.{Clock, CreditCalibration, Evidence, Repo, World}
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.MutationAttempts.Attempt
  alias SpaceTraders.SafetyFence.DependencyKey

  # Pure planning callers without a calibration read use the initial model;
  # runtime callers pass `CreditCalibration.active/0`'s margin.
  @initial_margin 25
  @minimum_margin 10
  @freshness_seconds 30
  @shipyard_freshness_seconds 300
  @credit_operations ~w(purchase-cargo purchase-ship refuel-ship jump-ship install-ship-module remove-ship-module install-ship-mount remove-ship-mount repair-ship)

  def worst_case_exposure(price, units, margin \\ @initial_margin)
      when is_integer(price) and price >= 0 and is_integer(units) and units >= 0 and
             is_integer(margin) and margin >= @minimum_margin do
    div(price * units * (100 + margin) + 99, 100)
  end

  def affordable_units(credits, price, margin \\ @initial_margin)

  def affordable_units(credits, price, margin) when is_integer(price) and price > 0,
    do: div(max(credits, 0) * 100, price * (100 + margin))

  def affordable_units(_credits, 0, _margin), do: :infinity

  @fuel_per_market_unit 100

  @doc "Market units the game charges for an explicit amount of ship fuel."
  def fuel_market_units(fuel_units) when is_integer(fuel_units) and fuel_units > 0,
    do: div(fuel_units + @fuel_per_market_unit - 1, @fuel_per_market_unit)

  # Reads run before the Intent/Attempt transaction. Reuse preserves original age.
  def acquire(agent, intent, action) do
    case purchase_request(intent, action) do
      {:ok, request} -> acquire_quote(agent, request)
      :none -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  # One selected credit-bearing action names its Market, good and billed units.
  defp purchase_request(intent, %{"kind" => "buy", "units" => units} = action),
    do:
      {:ok,
       %{
         waypoint: intent.target_waypoint,
         symbol: action["trade_symbol"],
         units: units,
         depth_limited?: true,
         extra: %{}
       }}

  defp purchase_request(_intent, %{"kind" => "refuel"} = action) do
    case {action["waypoint"], action["units"]} do
      {waypoint, units} when is_binary(waypoint) and is_integer(units) and units > 0 ->
        {:ok,
         %{
           waypoint: waypoint,
           symbol: "FUEL",
           units: fuel_market_units(units),
           depth_limited?: false,
           extra: %{"fuel_units" => units}
         }}

      _ ->
        {:error, :invalid_recorded_action}
    end
  end

  defp purchase_request(_intent, %{"kind" => "jump"} = action) do
    case action["source_waypoint"] do
      waypoint when is_binary(waypoint) ->
        {:ok,
         %{
           waypoint: waypoint,
           symbol: "ANTIMATTER",
           units: 1,
           depth_limited?: false,
           extra: %{}
         }}

      _ ->
        {:error, :invalid_recorded_action}
    end
  end

  defp purchase_request(_intent, _action), do: :none

  defp acquire_quote(agent, request) do
    %{waypoint: waypoint, symbol: symbol, units: units} = request
    system = waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
    subject = "market:#{system}:#{waypoint}"
    calibration = CreditCalibration.active()

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
           Enum.find(quote.value.trade_goods || [], &(&1.symbol == symbol)),
         true <- is_integer(good.purchase_price) and good.purchase_price >= 0,
         true <-
           is_integer(units) and units > 0 and
             (not request.depth_limited? or
                (is_integer(good.trade_volume) and units <= good.trade_volume)),
         {:ok, credits} <- acquire_credits(agent),
         true <-
           credits.value.symbol == agent.symbol and is_integer(credits.value.credits) and
             credits.value.credits >= 0 do
      {:ok,
       Map.merge(request.extra, %{
         "quote_observation_id" => quote.observation.id,
         "quote_observed_at" => DateTime.to_iso8601(quote.observation.observed_at),
         "credit_observation_id" => credits.observation.id,
         "waypoint" => waypoint,
         "trade_symbol" => symbol,
         "unit_price" => good.purchase_price,
         "units" => units,
         "calibration_version" => calibration.version,
         "margin_percent" => calibration.margin_percent,
         "worst_case_exposure" =>
           worst_case_exposure(good.purchase_price, units, calibration.margin_percent)
       })}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :market_quote_unavailable}
    end
  end

  @spending_operations ~w(purchase-cargo refuel-ship jump-ship)

  @doc """
  Prices one Fleet Ship acquisition from the fresh Shipyard offer evidence the
  candidate was selected on. Missing or stale evidence yields an error rather
  than an invented bound.
  """
  def acquire_ship_purchase(agent, %{source_waypoint: waypoint, ship: %{type: type}}) do
    calibration = CreditCalibration.active()

    with {:ok, price} <- shipyard_price(agent, waypoint, type),
         {:ok, credits} <- acquire_credits(agent),
         true <-
           credits.value.symbol == agent.symbol and is_integer(credits.value.credits) and
             credits.value.credits >= 0 do
      {:ok,
       %{
         "kind" => "ship",
         "credit_observation_id" => credits.observation.id,
         "waypoint" => waypoint,
         "ship_type" => type,
         "unit_price" => price,
         "units" => 1,
         "calibration_version" => calibration.version,
         "margin_percent" => calibration.margin_percent,
         "worst_case_exposure" => worst_case_exposure(price, 1, calibration.margin_percent)
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :authoritative_credit_facts_required}
    end
  end

  defp shipyard_price(agent, waypoint, type) do
    system = waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")

    fact =
      World.intelligence(
        agent,
        :shipyard,
        system,
        waypoint,
        Clock.utc_now(),
        @shipyard_freshness_seconds
      ).facts["ships"]

    with %{state: "known", freshness: :fresh, value: offers} when is_list(offers) <- fact,
         price when is_integer(price) and price >= 0 <-
           offers |> Enum.find(&(offer_field(&1, :type) == type)) |> offer_field(:purchase_price) do
      {:ok, price}
    else
      _ -> {:error, :ship_offer_evidence_unavailable}
    end
  end

  def lock_agent(%Attempt{operation_id: operation, agent_id: id})
      when operation in ["purchase-ship" | @spending_operations],
      do: lock_agent(id)

  def lock_agent(%Attempt{}), do: :ok

  # FOR NO KEY UPDATE serializes spending admissions on the Agent but, unlike
  # FOR UPDATE, never excludes the FOR KEY SHARE a non-spending MutationAttempt
  # insert takes for its agent_id foreign key. Allocation publication holds this
  # lock before the Generation while recorded preparation holds the Generation
  # before referencing the Agent; FOR UPDATE deadlocked the two.
  def lock_agent(id) when is_integer(id),
    do: Repo.one!(from a in Agent, where: a.id == ^id, lock: "FOR NO KEY UPDATE")

  @doc "Credit-bearing operation ids governed by spending admission."
  def credit_operations, do: @credit_operations

  # Every credit-bearing family honours the Agent's spending pause first; a
  # paused Agent never spends through the floor, recovery purposes included.
  def admit(%Attempt{operation_id: operation} = attempt, intent, revision)
      when operation in @credit_operations do
    agent = Repo.get!(Agent, attempt.agent_id)
    # Fleet Ship acquisition has no Intent; its Revision is the attempt's own.
    revision = if is_nil(intent), do: attempt_revision(attempt), else: revision

    credits =
      case current_credits(agent) do
        {:ok, binding} -> binding
        _ -> nil
      end

    with {:ok, floor} <- credit_floor(revision),
         :ok <- CreditCalibration.spending_pause(agent, credits, floor, revision) do
      admit_spend(attempt, agent, intent, revision)
    end
  end

  def admit(_attempt, _intent, _revision), do: :ok

  # Market purchase, refuel and jump/antimatter share one admission rule; the
  # prepared request defines the good and units each one bills.
  defp admit_spend(%Attempt{operation_id: operation} = attempt, agent, intent, revision)
       when operation in @spending_operations do
    spending = attempt.prepared_evidence["spending"]

    with :ok <- current_calibration(spending),
         :ok <- validate_quote(agent, attempt, spending),
         {:ok, credits} <- current_credits(agent),
         {:ok, floor} <- credit_floor(revision),
         {:ok, other_exposure} <-
           other_exposure(agent, intent.fleet_commitment_id, attempt, credits.observation),
         true <- credits.value.credits - other_exposure - spending["worst_case_exposure"] >= floor do
      :ok
    else
      false -> {:error, :insufficient_unreserved_headroom}
      {:error, _} = error -> error
    end
  end

  # Fleet Ship acquisition's own Commitment is named by the attempt's provenance.
  defp admit_spend(%Attempt{operation_id: "purchase-ship"} = attempt, agent, nil, revision) do
    spending = attempt.prepared_evidence["spending"]

    with :ok <- validate_offer(agent, attempt, spending),
         :ok <- current_calibration(spending),
         {:ok, credits} <- current_credits(agent),
         {:ok, floor} <- credit_floor(revision),
         {:ok, other_exposure} <-
           other_exposure(
             agent,
             attempt.provenance["commitment_id"],
             attempt,
             credits.observation
           ),
         true <- credits.value.credits - other_exposure - spending["worst_case_exposure"] >= floor do
      :ok
    else
      false -> {:error, :insufficient_unreserved_headroom}
      {:error, _} = error -> error
    end
  end

  defp admit_spend(_attempt, _agent, _intent, _revision), do: :ok

  defp attempt_revision(%Attempt{strategy_revision_id: nil}), do: nil
  defp attempt_revision(%Attempt{strategy_revision_id: id}), do: Repo.get(Revision, id)

  defp validate_quote(agent, attempt, spending) when is_map(spending) do
    with {:ok, expected} <- expected_purchase(attempt),
         {:ok, quote} <- Evidence.retained_binding(agent, spending["quote_observation_id"]),
         true <- quote.observation.operation_id == "get-market",
         true <- Evidence.valid_observation?(quote.observation),
         true <- quote.observation.fleet_generation_id == attempt.fleet_generation_id,
         true <- quote.value.symbol == spending["waypoint"],
         true <- spending["waypoint"] == expected.waypoint,
         true <-
           DateTime.to_iso8601(quote.observation.observed_at) == spending["quote_observed_at"],
         true <- fresh?(quote.observation.observed_at),
         good when not is_nil(good) <-
           Enum.find(quote.value.trade_goods || [], &(&1.symbol == expected.symbol)),
         true <- is_integer(good.purchase_price) and good.purchase_price >= 0,
         true <-
           spending["trade_symbol"] == expected.symbol and spending["units"] == expected.units,
         true <- spending["unit_price"] == good.purchase_price,
         true <-
           spending["worst_case_exposure"] ==
             worst_case_exposure(good.purchase_price, expected.units, spending["margin_percent"]) do
      :ok
    else
      _ -> {:error, :market_quote_stale_or_missing}
    end
  end

  defp validate_quote(_agent, _attempt, _spending), do: {:error, :market_quote_stale_or_missing}

  # The prepared request, not the spending record, defines what will be billed.
  defp expected_purchase(%Attempt{operation_id: "purchase-cargo"} = attempt) do
    body = attempt.prepared_evidence["request"]["body"]

    {:ok,
     %{
       waypoint: attempt.prepared_evidence["spending"]["waypoint"],
       symbol: body["symbol"],
       units: body["units"]
     }}
  end

  defp expected_purchase(%Attempt{operation_id: "refuel-ship"} = attempt) do
    action = attempt.prepared_evidence["selected_action"]
    fuel_units = attempt.prepared_evidence["request"]["body"]["units"]

    if is_integer(fuel_units) and fuel_units > 0 and action["units"] == fuel_units and
         attempt.prepared_evidence["spending"]["fuel_units"] == fuel_units do
      {:ok, %{waypoint: action["waypoint"], symbol: "FUEL", units: fuel_market_units(fuel_units)}}
    else
      :error
    end
  end

  defp expected_purchase(%Attempt{operation_id: "jump-ship"} = attempt) do
    action = attempt.prepared_evidence["selected_action"]
    {:ok, %{waypoint: action["source_waypoint"], symbol: "ANTIMATTER", units: 1}}
  end

  # A bound prepared under a superseded margin is replanned, never resized.
  defp current_calibration(%{"calibration_version" => version, "margin_percent" => margin}) do
    case CreditCalibration.active() do
      %{version: ^version, margin_percent: ^margin} -> :ok
      _ -> {:error, :credit_calibration_superseded}
    end
  end

  defp current_calibration(_spending), do: {:error, :market_quote_stale_or_missing}

  defp offer_field(nil, _key), do: nil
  defp offer_field(offer, key), do: Map.get(offer, key) || Map.get(offer, Atom.to_string(key))

  defp validate_offer(agent, attempt, %{"waypoint" => waypoint} = spending) do
    body = attempt.prepared_evidence["request"]["body"]

    with true <- body["waypointSymbol"] == waypoint and body["shipType"] == spending["ship_type"],
         {:ok, price} <- shipyard_price(agent, waypoint, spending["ship_type"]),
         true <- spending["unit_price"] == price and spending["units"] == 1,
         true <-
           spending["worst_case_exposure"] ==
             worst_case_exposure(price, 1, spending["margin_percent"]) do
      :ok
    else
      _ -> {:error, :ship_offer_evidence_unavailable}
    end
  end

  defp validate_offer(_agent, _attempt, _spending), do: {:error, :ship_offer_evidence_unavailable}

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
  defp other_exposure(agent, own_commitment_id, attempt, balance_source) do
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
      |> Map.delete(own_commitment_id)

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
