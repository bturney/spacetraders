defmodule SpaceTraders.Outcomes do
  @moduledoc "Fail-soft outcome projections of retained authoritative facts."

  require Logger

  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.API.Model.{Contract, ContractDeliverGood, ContractTerms}
  alias SpaceTraders.Contracts

  @contract_statuses ~w(pending active near_delivery completed expired)

  # Directly decoded facts need no database query or background recompute.
  # Keep the complete tap inside this guard: metrics never govern Evidence.
  def observe(%Observation{} = observation) do
    emit(observation)
    :ok
  rescue
    _error ->
      Logger.error("Outcome metric emission failed; dropping observation",
        operation_id: observation.operation_id
      )

      :ok
  catch
    _kind, _reason ->
      Logger.error("Outcome metric emission failed; dropping observation",
        operation_id: observation.operation_id
      )

      :ok
  end

  defp emit(%Observation{operation_id: "get-my-agent", facts: facts}) do
    %{"credits" => credits} = facts["response"]
    true = is_integer(credits) and credits >= 0
    :telemetry.execute([:spacetraders, :outcome, :agent], %{credits: credits}, %{})
  end

  defp emit(%Observation{operation_id: "get-contracts", facts: facts}) do
    contracts = Map.fetch!(facts, "response")
    counts = Enum.frequencies_by(contracts, &contract_status/1)

    # Include zeros so changed or removed Contracts cannot leave stale series.
    for status <- @contract_statuses do
      :telemetry.execute(
        [:spacetraders, :outcome, :contracts],
        %{count: Map.get(counts, status, 0)},
        %{status: status}
      )
    end
  end

  defp emit(_observation), do: :ok

  defp contract_status(facts) do
    accepted = Map.fetch!(facts, "accepted")
    fulfilled = Map.fetch!(facts, "fulfilled")
    true = is_boolean(accepted) and is_boolean(fulfilled)
    terms = facts["terms"] || %{}

    # Evidence stores the decoded model's snake_case fields. Reuse the domain's
    # deadline and delivery rules rather than inventing a progress threshold.
    contract = %Contract{
      accepted: accepted,
      fulfilled: fulfilled,
      deadline_to_accept: facts["deadline_to_accept"],
      terms: %ContractTerms{
        deadline: terms["deadline"],
        deliver: Enum.map(terms["deliver"] || [], &deliver_good/1)
      }
    }

    case Contracts.status(contract) do
      :fulfilled -> "completed"
      :expired -> "expired"
      :pending -> "pending"
      :accepted -> if Contracts.ready?(contract), do: "near_delivery", else: "active"
    end
  end

  defp deliver_good(facts) do
    required = Map.fetch!(facts, "units_required")
    fulfilled = Map.fetch!(facts, "units_fulfilled")
    true = is_integer(required) and required >= 0 and is_integer(fulfilled) and fulfilled >= 0
    %ContractDeliverGood{units_required: required, units_fulfilled: fulfilled}
  end
end
