defmodule SpaceTraders.CreditSpending.ModificationFee do
  @moduledoc """
  Quote for one Ship modification (module install or removal): the Shipyard's
  published `modificationsFee` at the Ship's Waypoint (ADR 0013, #579).

  The quote is the latest retained Shipyard observation when it is at most two
  minutes old, otherwise one fresh governed Shipyard read. Admission rechecks
  the same retained observation; a fee no longer fresh is refused, never
  re-quoted in the send window. The module itself is a Market purchase and is
  bounded there.
  """

  alias SpaceTraders.{Clock, Evidence}
  alias SpaceTraders.MutationAttempts.Attempt

  @freshness_seconds 120

  @operations ~w(install-ship-module remove-ship-module)
  @action_kinds ~w(install_module remove_module)

  @doc "Recorded operations whose charge is the Shipyard modification fee."
  def operations, do: @operations

  @doc "Whether a selected Ship action owes a Shipyard modification fee."
  def action?(%{"kind" => kind}), do: kind in @action_kinds
  def action?(_action), do: false

  @doc "Acquires a fresh retained fee quote for the Shipyard at `waypoint`."
  def acquire(agent, waypoint) when is_binary(waypoint) do
    system = system(waypoint)

    with {:ok, quote} <-
           retained_or_read(agent, "shipyard:#{system}:#{waypoint}", fn ->
             Evidence.get_shipyard(agent, system, waypoint, bind: true, owner: "ship_execution")
           end),
         {:ok, fee} <- fee(quote, waypoint) do
      {:ok, %{observation: quote.observation, fee: fee}}
    else
      _ -> {:error, :modification_fee_unavailable}
    end
  end

  def acquire(_agent, _waypoint), do: {:error, :invalid_recorded_action}

  @doc """
  Revalidates a prepared modification bound against its retained quote: the
  same fresh observation, the selected Waypoint, and the recorded fee.
  """
  def validate(agent, %Attempt{} = attempt, spending, bound) when is_map(spending) do
    waypoint = attempt.prepared_evidence["selected_action"]["waypoint"]

    with {:ok, quote} <- Evidence.retained_binding(agent, spending["quote_observation_id"]),
         true <- quote.observation.fleet_generation_id == attempt.fleet_generation_id,
         true <-
           DateTime.to_iso8601(quote.observation.observed_at) == spending["quote_observed_at"],
         true <- spending["waypoint"] == waypoint,
         {:ok, fee} <- fee(quote, waypoint),
         true <- spending["unit_price"] == fee and spending["units"] == 1,
         true <- spending["worst_case_exposure"] == bound.(fee, spending["margin_percent"]) do
      :ok
    else
      _ -> {:error, :modification_fee_stale_or_missing}
    end
  end

  def validate(_agent, _attempt, _spending, _bound),
    do: {:error, :modification_fee_stale_or_missing}

  defp fee(quote, waypoint) do
    with "get-shipyard" <- quote.observation.operation_id,
         true <- Evidence.valid_observation?(quote.observation),
         true <- fresh?(quote.observation.observed_at),
         true <- quote.value.symbol == waypoint,
         fee when is_integer(fee) and fee >= 0 <- quote.value.modifications_fee do
      {:ok, fee}
    else
      _ -> :error
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

  defp fresh?(_time), do: false

  defp system(waypoint), do: waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
end
