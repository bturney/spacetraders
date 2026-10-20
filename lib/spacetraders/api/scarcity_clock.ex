defmodule SpaceTraders.API.ScarcityClock do
  @moduledoc """
  Clock boundary for opt-in semantic API scarcity, not all gameplay clocks.

  Legacy gameplay TestClock use must not change native transport retries or
  carry governor backoff across unrelated clock lifetimes. NavigationClock
  enables the closed runtime; other bounded harnesses explicitly opt in with
  `:semantic_api_scarcity`. Selection stays fixed while scarcity owners live.
  Socket and DB safety timeouts never use this clock.
  """
  alias SpaceTraders.Clock
  alias SpaceTraders.Simulation.NavigationClock

  def semantic? do
    NavigationClock.enabled?() or
      Application.get_env(:spacetraders, :semantic_api_scarcity, false)
  end

  def utc_now do
    if semantic?(), do: Clock.utc_now(), else: DateTime.utc_now()
  end

  def refill_ms do
    if semantic?(),
      do: DateTime.to_unix(Clock.utc_now(), :millisecond),
      else: System.monotonic_time(:millisecond)
  end

  def send_after(destination, message, delay_ms) do
    if semantic?(),
      do: Clock.send_after(destination, message, delay_ms),
      else: Process.send_after(destination, message, delay_ms)
  end

  def send_at(destination, message, at) do
    if semantic?(),
      do: Clock.send_at(destination, message, at),
      else:
        Process.send_after(
          destination,
          message,
          max(DateTime.diff(at, DateTime.utc_now(), :millisecond), 0)
        )
  end

  def cancel_timer(reference) do
    if semantic?(), do: Clock.cancel_timer(reference), else: Process.cancel_timer(reference)
  end
end
