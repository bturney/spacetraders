defmodule SpaceTraders.Test.CapacityDispositions do
  @moduledoc """
  Stable Capacity Disposition fixtures for Fleet consumer tests.

  Consumers are asserted against the disposition meaning (proceed, defer,
  unavailable), never against application-wide governor counters.
  """

  alias SpaceTraders.API.CapacityGovernor.Disposition

  def proceed(at \\ DateTime.utc_now()),
    do: %Disposition{status: :proceed, reason: :capacity_available, observed_at: at}

  def defer(at \\ DateTime.utc_now()),
    do: %Disposition{
      status: :defer,
      reason: :contention,
      observed_at: at,
      retry_at: DateTime.add(at, 1, :second)
    }

  def unavailable(at \\ DateTime.utc_now()),
    do: %Disposition{
      status: :unavailable,
      reason: :authority_unavailable,
      observed_at: at,
      retry_at: DateTime.add(at, 1, :second)
    }
end
