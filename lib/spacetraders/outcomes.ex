defmodule SpaceTraders.Outcomes do
  @moduledoc "Fail-soft outcome projections of retained authoritative facts."

  use GenServer

  require Logger

  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.API.Model.{Contract, ContractDeliverGood, ContractTerms}
  alias SpaceTraders.Contracts

  @contract_statuses ~w(pending active near_delivery completed expired)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The read only enqueues already-retained facts. No database access, polling,
  # or wait on the exporter is introduced into gameplay.
  def observe(%Observation{} = observation) do
    if Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:observe, observation}),
      else: log_failure(observation)

    :ok
  end

  @doc false
  def metrics(prom_ex_module) do
    GenServer.call(__MODULE__, {:metrics, prom_ex_module})
  catch
    :exit, _reason -> :prom_ex_down
  end

  @impl true
  def init(_opts) do
    # PromEx can outlive this process. Invalidate any retained previous pair
    # on restart; a timestamp of zero is unknown, never an observation.
    credit_pair(nil)

    {:ok,
     %{credit: nil, previous: nil, contracts_at: nil, started_at: SpaceTraders.Clock.utc_now()}}
  end

  @impl true
  def handle_call({:metrics, prom_ex_module}, _from, state) do
    # Exposition and credit publication share this mailbox: the four values
    # cannot be scraped halfway through updating an authoritative pair.
    {:reply, PromEx.get_metrics(prom_ex_module), state}
  end

  @impl true
  def handle_cast({:observe, observation}, state) do
    # Historical replay after restart is not a newly acquired observation.
    # This process deliberately waits for two post-start acquisitions.
    if DateTime.compare(observation.observed_at, state.started_at) == :lt,
      do: {:noreply, state},
      else: {:noreply, emit(observation, state)}
  rescue
    _error ->
      log_failure(observation)
      {:noreply, state}
  catch
    _kind, _reason ->
      log_failure(observation)
      {:noreply, state}
  end

  defp log_failure(observation) do
    Logger.error("Outcome metric emission failed; dropping observation",
      operation_id: observation.operation_id
    )
  end

  defp emit(%Observation{operation_id: "get-my-agent", facts: facts} = observation, state) do
    %{"credits" => credits} = facts["response"]
    true = is_integer(credits) and credits >= 0
    identity = {observation.agent_id, observation.fleet_generation_id}

    current = %{
      id: observation.id,
      identity: identity,
      credits: credits,
      fingerprint: observation.response_fingerprint,
      observed_at: observation.observed_at
    }

    last = state.credit

    cond do
      last &&
          (current.id == last.id || DateTime.compare(current.observed_at, last.observed_at) == :lt) ->
        state

      last && current.identity == last.identity &&
        current.fingerprint == last.fingerprint &&
          DateTime.compare(current.observed_at, last.observed_at) == :eq ->
        state

      true ->
        previous =
          cond do
            is_nil(last) || current.identity != last.identity -> nil
            DateTime.compare(current.observed_at, last.observed_at) == :eq -> state.previous
            true -> last
          end

        credit_pair(previous)
        :telemetry.execute([:spacetraders, :outcome, :agent], %{credits: credits}, %{})
        observed("credits", observation)
        %{state | credit: current, previous: previous}
    end
  end

  defp emit(%Observation{operation_id: "get-contracts", facts: facts} = observation, state) do
    contracts = Map.fetch!(facts, "response")
    counts = Enum.frequencies_by(contracts, &contract_status/1)

    # Include zeros so changed or removed Contracts cannot leave stale series.
    if is_nil(state.contracts_at) ||
         DateTime.compare(observation.observed_at, state.contracts_at) != :lt do
      for status <- @contract_statuses do
        :telemetry.execute(
          [:spacetraders, :outcome, :contracts],
          %{count: Map.get(counts, status, 0)},
          %{status: status}
        )
      end

      observed("contracts", observation)
      %{state | contracts_at: observation.observed_at}
    else
      state
    end
  end

  defp emit(_observation, state), do: state

  defp credit_pair(previous) do
    :telemetry.execute(
      [:spacetraders, :outcome, :credit_pair],
      %{
        previous_credits: previous && previous.credits,
        previous_observed_at_seconds: if(previous, do: epoch(previous.observed_at), else: 0)
      },
      %{}
    )
  end

  defp observed(family, observation) do
    :telemetry.execute(
      [:spacetraders, :outcome, :observed],
      %{observed_at_seconds: epoch(observation.observed_at)},
      %{family: family}
    )
  end

  defp epoch(observed_at), do: DateTime.to_unix(observed_at, :microsecond) / 1_000_000

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
