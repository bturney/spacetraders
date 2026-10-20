defmodule SpaceTraders.Clock do
  @moduledoc """
  Application clock for gameplay-semantic time and durable waits.

  The default uses UTC and process timers. An application-wide `:clock` module
  may implement this contract for controlled semantic time. Infrastructure
  liveness and transport/DB timeouts must continue to use wall time directly.

  Timer references are ephemeral, not durable work: consumers reconstruct waits
  from persisted state on restart. Cancellation cannot retract a message already
  sent, so consumers must also reject superseded wake messages.
  """

  @callback utc_now() :: DateTime.t()
  @callback send_at(pid(), term(), DateTime.t()) :: reference()
  @callback cancel_timer(reference()) :: non_neg_integer() | false

  @spec utc_now() :: DateTime.t()
  def utc_now do
    case Application.get_env(:spacetraders, :clock) do
      nil -> DateTime.utc_now()
      clock -> clock.utc_now()
    end
  end

  @spec send_at(pid(), term(), DateTime.t()) :: reference()
  def send_at(destination, message, %DateTime{} = due_at) when is_pid(destination) do
    case Application.get_env(:spacetraders, :clock) do
      nil ->
        delay = max(DateTime.diff(due_at, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(destination, message, delay)

      clock ->
        clock.send_at(destination, message, due_at)
    end
  end

  @spec send_after(pid(), term(), non_neg_integer()) :: reference()
  def send_after(destination, message, delay_ms) when is_pid(destination) and delay_ms >= 0 do
    send_at(destination, message, DateTime.add(utc_now(), delay_ms, :millisecond))
  end

  @doc """
  Withdraws a scheduled wake, returning remaining semantic milliseconds or
  `false` if it already fired, was cancelled, or is unknown. Does not flush
  messages already delivered. Clock selection must stay fixed while timers live.
  """
  @spec cancel_timer(reference()) :: non_neg_integer() | false
  def cancel_timer(reference) when is_reference(reference) do
    case Application.get_env(:spacetraders, :clock) do
      nil -> Process.cancel_timer(reference)
      clock -> clock.cancel_timer(reference)
    end
  end
end
