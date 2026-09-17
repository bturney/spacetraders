defmodule SpaceTraders.API.CapacityGovernor do
  @moduledoc """
  Admission gate for governed API reads.

  The raw rate limiter protects the protocol budget. This module protects the
  application budget by ordering waiting reads by safety, reconciliation, and
  then ordinary demand before handing them to the raw limiter.
  """

  use GenServer

  alias SpaceTraders.API.OperationInventory.Operation

  @lane_rank %{safety: 0, reconciliation: 1, standard: 2}

  defmodule Admission do
    @moduledoc "A production API admission held until the request completes."
    @enforce_keys [:id, :operation_id, :lane, :requested_at]
    defstruct @enforce_keys
  end

  @doc "Starts the governor. `max_in_flight` defaults to one ordered read."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Waits until the demand is admitted, returning its completion identity."
  @spec admit(Operation.t(), map(), GenServer.server()) :: {:ok, Admission.t()}
  def admit(%Operation{} = operation, attrs \\ %{}, name \\ __MODULE__) when is_map(attrs) do
    case Process.whereis(name) do
      nil -> {:ok, nil}
      _pid -> GenServer.call(name, {:admit, operation, attrs}, :infinity)
    end
  end

  @doc "Releases an admission and reports the request outcome to the governor."
  def complete(admission, status, name \\ __MODULE__)

  def complete(nil, _status, _name), do: :ok

  def complete(%Admission{id: id}, status, name) do
    if Process.whereis(name), do: GenServer.cast(name, {:complete, id, status}), else: :ok
  end

  @impl true
  def init(opts) do
    config = Application.get_env(:spacetraders, __MODULE__, [])

    {:ok,
     %{
       max_in_flight: Keyword.get(opts, :max_in_flight, Keyword.get(config, :max_in_flight, 1)),
       in_flight: %{},
       queue: [],
       sequence: 0,
       outage_streak: 0,
       next_probe_at: nil
     }}
  end

  @impl true
  def handle_call({:admit, operation, attrs}, from, state) do
    request = %{
      from: from,
      operation: operation,
      attrs: attrs,
      id: Integer.to_string(state.sequence + 1),
      requested_at: DateTime.utc_now(),
      sequence: state.sequence + 1
    }

    state
    |> Map.update!(:queue, &[request | &1])
    |> Map.put(:sequence, request.sequence)
    |> dispatch()
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_cast({:complete, id, status}, state) do
    state =
      case Map.pop(state.in_flight, id) do
        {nil, _in_flight} -> state
        {_request, in_flight} -> %{state | in_flight: in_flight}
      end

    state = update_outage(state, status)
    {:noreply, dispatch(state)}
  end

  defp dispatch(state) do
    available = state.max_in_flight - map_size(state.in_flight)

    if available > 0 and state.queue != [] do
      {selected, remaining} = take_best(state.queue, available)

      Enum.each(selected, fn request ->
        admission = %Admission{
          id: request.id,
          operation_id: request.operation.id,
          lane: lane(request),
          requested_at: request.requested_at
        }

        GenServer.reply(request.from, {:ok, admission})
      end)

      in_flight =
        Enum.reduce(selected, state.in_flight, fn request, acc ->
          Map.put(acc, request.id, request)
        end)

      %{state | queue: remaining, in_flight: in_flight}
    else
      state
    end
  end

  defp take_best(queue, count) do
    queue = Enum.sort_by(queue, &ordering_key/1)
    Enum.split(queue, count)
  end

  defp ordering_key(request) do
    attrs = request.attrs

    [
      lane_rank(lane(request)),
      datetime_key(Map.get(attrs, :deadline_at)),
      Map.get(attrs, :strategic_priority, :infinity) || :infinity,
      descending_number(Map.get(attrs, :expected_value)),
      not Map.get(attrs, :discovery, false),
      request.sequence
    ]
  end

  defp lane(%{attrs: %{lane: lane}}) when is_atom(lane), do: lane
  defp lane(%{operation: %{owner: :fleet_reconciliation}}), do: :reconciliation
  defp lane(_request), do: :standard

  defp lane_rank(lane), do: Map.fetch!(@lane_rank, lane)

  defp datetime_key(nil), do: :infinity
  defp datetime_key(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)

  defp descending_number(nil), do: :infinity
  defp descending_number(value) when is_number(value), do: -value

  defp update_outage(state, status) when status == :unknown or status in 500..599 do
    %{state | outage_streak: state.outage_streak + 1}
  end

  defp update_outage(state, _status), do: %{state | outage_streak: 0, next_probe_at: nil}
end
