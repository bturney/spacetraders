defmodule SpaceTraders.CreditCalibration do
  @moduledoc """
  Versioned worst-case price margin, realized-versus-quoted evidence, and
  credit shortfalls for credit-bearing spending (ADR 0013).

  The margin is calibration, never Operator intent. It starts at 25%, cannot
  cross the 10% hard lower bound, and every change is a new immutable version
  that retains the evidence and attempt that justified it.

  Only a realized charge attributable to one attempt and above that attempt's
  recorded bound is a pricing-model miss: it widens the margin and raises
  Degraded Attention. Every unreleased shortfall, of any kind, pauses new
  credit-bearing admission for its Agent until a newer authoritative balance
  at or above the active floor releases it. Nothing here sells Cargo or grants
  a recovery-spend exception.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.{Clock, CreditSpending, OperatorConditions, Repo}
  alias SpaceTraders.CreditCalibration.{Realization, Shortfall, Version}
  alias SpaceTraders.FleetStrategy.{Revision, StandingAuthority}
  alias SpaceTraders.MutationAttempts.Attempt

  @widening_step 10
  @unresolved_states ["sent_or_unknown", "ambiguous", "bounded_unknown"]

  @doc "Returns the active calibration version (the newest durable row)."
  def active do
    Repo.one!(from v in Version, order_by: [desc: v.id], limit: 1)
  end

  @doc "Records a newer calibration version; the 10% hard lower bound is enforced."
  def supersede(margin_percent, basis, attrs) when is_integer(margin_percent) do
    if margin_percent < Version.hard_lower_bound() do
      {:error, :below_hard_lower_bound}
    else
      Repo.transaction(fn ->
        # Concurrent supersessions serialize so each chains from the true latest.
        Repo.query!("LOCK TABLE credit_calibration_versions IN SHARE ROW EXCLUSIVE MODE")
        previous = active()

        %Version{}
        |> Version.changeset(
          Map.merge(attrs, %{
            version: "credit-calibration-v#{previous.id + 1}-#{margin_percent}pct",
            margin_percent: margin_percent,
            basis: basis,
            previous_version_id: previous.id
          })
        )
        |> Repo.insert()
        |> case do
          {:ok, version} -> version
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end
  end

  @doc "Returns every recorded shortfall for an Agent, newest first."
  def shortfalls(%Agent{id: agent_id}) do
    Repo.all(
      from s in Shortfall,
        where: s.agent_id == ^agent_id,
        order_by: [desc: s.detected_at, desc: s.id]
    )
  end

  @doc "Returns realized-versus-quoted evidence for one attempt, if attributable."
  def realization(%Attempt{id: id}), do: Repo.get_by(Realization, mutation_attempt_id: id)

  @doc """
  Records the realized charge from a successful credit-bearing response.

  Attribution needs the attempt's retained spending bound plus a response
  transaction for exactly the prepared units and the post-charge Agent credits.
  Anything less records nothing: the shortfall, if any, is found later by a
  credits read and never recalibrates the margin.
  """
  def record_realization(%Attempt{} = attempt, response) do
    with %{} = spending <- attempt.prepared_evidence["spending"],
         {:ok, facts} <- attributable(spending, response) do
      Repo.transaction(fn ->
        CreditSpending.lock_agent(attempt.agent_id)

        if Repo.exists?(from r in Realization, where: r.mutation_attempt_id == ^attempt.id),
          do: Repo.rollback(:already_realized),
          else: realize(attempt, spending, facts)
      end)
      |> case do
        {:ok, %Shortfall{kind: "pricing_model_miss"} = shortfall} ->
          raise_degraded_attention(attempt, shortfall)
          {:ok, shortfall}

        {:ok, result} ->
          {:ok, result}

        {:error, :already_realized} ->
          {:ok, nil}

        error ->
          error
      end
    else
      _ -> {:ok, nil}
    end
  end

  @doc """
  Spending pause check inside the caller's per-Agent admission transaction.

  `credits` is the current authoritative balance binding, or nil when none is
  retained. Releases open shortfalls only from a balance observed after them.
  """
  def spending_pause(%Agent{} = agent, credits, floor, revision) when is_integer(floor) do
    open =
      Repo.all(
        from s in Shortfall,
          where: s.agent_id == ^agent.id and is_nil(s.released_at),
          lock: "FOR UPDATE"
      )

    balance = balance(credits)

    cond do
      open != [] and recovered?(open, balance, floor) ->
        release(agent, open, credits)

      open != [] ->
        {:error, :credit_spending_paused}

      balance && balance.credits < floor ->
        record_shortfall(agent, %{
          kind: classify(agent, revision, balance.credits, floor),
          credits: balance.credits,
          credit_floor: floor,
          strategy_revision_id: revision && revision.id,
          calibration_version_id: active().id,
          evidence: %{"credit_observation_id" => balance.observation_id}
        })

        {:error, :credit_spending_paused}

      true ->
        :ok
    end
  end

  # A Shipyard transaction charges `price` for exactly the offered Ship type.
  defp attributable(%{"kind" => "ship"} = spending, %{
         transaction: %{} = transaction,
         agent: %{} = agent
       }) do
    with bound when is_integer(bound) <- spending["worst_case_exposure"],
         price when is_integer(price) <- spending["unit_price"],
         1 <- spending["units"],
         true <- Map.get(transaction, :ship_type) == spending["ship_type"],
         charge when is_integer(charge) and charge >= 0 <- Map.get(transaction, :price),
         credits when is_integer(credits) <- Map.get(agent, :credits) do
      {:ok, %{bound: bound, unit_price: price, units: 1, charge: charge, credits: credits}}
    else
      _ -> :error
    end
  end

  # A Shipyard modification transaction charges the fee for exactly the module.
  defp attributable(%{"kind" => "modification"} = spending, %{
         transaction: %{} = transaction,
         agent: %{} = agent
       }) do
    with bound when is_integer(bound) <- spending["worst_case_exposure"],
         price when is_integer(price) <- spending["unit_price"],
         1 <- spending["units"],
         true <- Map.get(transaction, :trade_symbol) == spending["module_symbol"],
         charge when is_integer(charge) and charge >= 0 <- Map.get(transaction, :total_price),
         credits when is_integer(credits) <- Map.get(agent, :credits) do
      {:ok, %{bound: bound, unit_price: price, units: 1, charge: charge, credits: credits}}
    else
      _ -> :error
    end
  end

  defp attributable(spending, %{transaction: %{} = transaction, agent: %{} = agent}) do
    with bound when is_integer(bound) <- spending["worst_case_exposure"],
         price when is_integer(price) <- spending["unit_price"],
         units when is_integer(units) <- spending["units"],
         true <- Map.get(transaction, :units) == units,
         true <- Map.get(transaction, :trade_symbol) == spending["trade_symbol"],
         charge when is_integer(charge) and charge >= 0 <- Map.get(transaction, :total_price),
         credits when is_integer(credits) <- Map.get(agent, :credits) do
      {:ok, %{bound: bound, unit_price: price, units: units, charge: charge, credits: credits}}
    else
      _ -> :error
    end
  end

  defp attributable(_spending, _response), do: :error

  defp realize(attempt, spending, facts) do
    version =
      Repo.get_by(Version, version: spending["calibration_version"]) ||
        Repo.rollback(:unknown_calibration_version)

    floor = attempt_floor(attempt)
    within_bound = facts.charge <= facts.bound

    shortfall =
      cond do
        not within_bound ->
          shortfall =
            record_shortfall(attempt.agent_id, %{
              kind: "pricing_model_miss",
              mutation_attempt_id: attempt.id,
              calibration_version_id: version.id,
              strategy_revision_id: attempt.strategy_revision_id,
              credits: facts.credits,
              credit_floor: floor,
              worst_case_exposure: facts.bound,
              realized_charge: facts.charge,
              evidence: %{
                "operation_id" => attempt.operation_id,
                "unit_price" => facts.unit_price,
                "units" => facts.units
              }
            })

          widen(attempt, shortfall, facts)

        facts.credits < floor and not open_shortfall?(attempt.agent_id) ->
          record_shortfall(attempt.agent_id, %{
            kind:
              if(other_unresolved_spend?(attempt.agent_id, attempt.id),
                do: "unattributable_shortfall",
                else: "non_pricing_shortfall"
              ),
            mutation_attempt_id: attempt.id,
            calibration_version_id: version.id,
            strategy_revision_id: attempt.strategy_revision_id,
            credits: facts.credits,
            credit_floor: floor,
            worst_case_exposure: facts.bound,
            realized_charge: facts.charge
          })

        true ->
          nil
      end

    Repo.insert!(%Realization{
      agent_id: attempt.agent_id,
      mutation_attempt_id: attempt.id,
      calibration_version_id: version.id,
      operation_id: attempt.operation_id,
      unit_price: facts.unit_price,
      units: facts.units,
      worst_case_exposure: facts.bound,
      realized_charge: facts.charge,
      credits_after: facts.credits,
      within_bound: within_bound,
      credit_shortfall_id: shortfall && shortfall.id
    })

    shortfall
  end

  # Widen past the observed overshoot by one step, never by less than a step.
  defp widen(attempt, shortfall, facts) do
    quoted = facts.unit_price * facts.units

    overshoot =
      if quoted > 0,
        do: div((facts.charge - quoted) * 100 + quoted - 1, quoted),
        else: 0

    current = active().margin_percent
    margin = max(current, overshoot) + @widening_step

    case supersede(margin, "pricing_model_miss", %{
           mutation_attempt_id: attempt.id,
           evidence: %{
             "credit_shortfall_id" => shortfall.id,
             "quoted_cost" => quoted,
             "worst_case_exposure" => facts.bound,
             "realized_charge" => facts.charge,
             "overshoot_percent" => overshoot
           }
         }) do
      {:ok, version} ->
        shortfall
        |> Ecto.Changeset.change(widened_calibration_version_id: version.id)
        |> Repo.update!()

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp record_shortfall(%Agent{id: agent_id}, attrs), do: record_shortfall(agent_id, attrs)

  defp record_shortfall(agent_id, attrs) when is_integer(agent_id) do
    Repo.insert!(
      struct(Shortfall, Map.merge(attrs, %{agent_id: agent_id, detected_at: Clock.utc_now()}))
    )
  end

  # A revision explains the shortfall when the balance still meets the floor it
  # replaced. Otherwise unresolved concurrent spends make it unattributable.
  defp classify(agent, revision, credits, floor) do
    cond do
      revision_raised_floor?(revision, credits, floor) -> "revision_floor"
      other_unresolved_spend?(agent.id, nil) -> "unattributable_shortfall"
      true -> "non_pricing_shortfall"
    end
  end

  defp revision_raised_floor?(%Revision{number: number} = revision, credits, floor)
       when is_integer(number) and number > 1 do
    previous =
      Repo.one(
        from r in Revision,
          where: r.fleet_strategy_id == ^revision.fleet_strategy_id and r.number == ^(number - 1)
      )

    previous_floor = floor_of(previous)
    previous_floor < floor and credits >= previous_floor
  end

  defp revision_raised_floor?(_revision, _credits, _floor), do: false

  defp other_unresolved_spend?(agent_id, except_id) do
    query =
      from a in Attempt,
        where:
          a.agent_id == ^agent_id and a.state in @unresolved_states and
            a.operation_id in ^CreditSpending.credit_operations()

    query = if except_id, do: where(query, [a], a.id != ^except_id), else: query
    Repo.exists?(query)
  end

  defp open_shortfall?(agent_id),
    do:
      Repo.exists?(from s in Shortfall, where: s.agent_id == ^agent_id and is_nil(s.released_at))

  defp balance(%{value: %{credits: credits}, observation: %{observed_at: at, id: id}})
       when is_integer(credits),
       do: %{credits: credits, observed_at: at, observation_id: id}

  defp balance(_credits), do: nil

  defp recovered?(_open, nil, _floor), do: false

  defp recovered?(open, balance, floor) do
    balance.credits >= floor and
      Enum.all?(open, &(DateTime.compare(balance.observed_at, &1.detected_at) == :gt))
  end

  defp release(agent, open, credits) do
    now = Clock.utc_now()
    ids = Enum.map(open, & &1.id)

    Repo.update_all(from(s in Shortfall, where: s.id in ^ids),
      set: [
        released_at: now,
        release_evidence: %{
          "credit_observation_id" => credits.observation.id,
          "credits" => credits.value.credits
        },
        updated_at: now
      ]
    )

    if Enum.any?(open, &(&1.kind == "pricing_model_miss")) do
      OperatorConditions.resolve(scope(agent.operator_id), attention_key(agent.id),
        notify?: false
      )
    end

    :ok
  end

  defp raise_degraded_attention(attempt, shortfall) do
    agent = Repo.get!(Agent, attempt.agent_id)
    widened = Repo.get!(Version, shortfall.widened_calibration_version_id)

    OperatorConditions.raise(
      scope(agent.operator_id),
      attention_key(agent.id),
      :attention,
      "Degraded Operation: a #{operation_label(attempt.operation_id)} charged " <>
        "#{shortfall.realized_charge} credits, above its calibrated worst-case bound of " <>
        "#{shortfall.worst_case_exposure}. The pricing-model breach is recorded and the " <>
        "margin widened to #{widened.margin_percent}%. New credit-bearing spending stays " <>
        "paused until an authoritative balance at or above the " <>
        "#{shortfall.credit_floor} credit floor is observed; other work continues.",
      fleet_strategy_revision_id: shortfall.strategy_revision_id
    )
  end

  defp operation_label("purchase-cargo"), do: "Market purchase"
  defp operation_label("refuel-ship"), do: "refuel"
  defp operation_label("purchase-ship"), do: "Ship purchase"
  defp operation_label(operation_id), do: operation_id

  defp attention_key(agent_id), do: "credit-pricing-breach:#{agent_id}"

  defp scope(operator_id), do: Scope.for_operator(Repo.get!(Operator, operator_id))

  defp attempt_floor(%Attempt{strategy_revision_id: nil}), do: 0

  defp attempt_floor(%Attempt{strategy_revision_id: id}),
    do: floor_of(Repo.get(Revision, id))

  defp floor_of(nil), do: 0

  defp floor_of(revision) do
    case StandingAuthority.credit_floor(revision) do
      {:ok, floor} -> floor
      _ -> 0
    end
  end
end
