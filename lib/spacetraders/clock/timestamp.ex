defmodule SpaceTraders.Clock.Timestamp do
  @moduledoc """
  Ecto timestamp generators for gameplay-owned chronology.

  Precision adapts the supported Clock value, never its instant. Infrastructure,
  authentication and physical registration creation order do not use this adapter.
  """

  def now do
    now = SpaceTraders.Clock.utc_now()
    %{now | microsecond: {elem(now.microsecond, 0), 6}}
  end

  def second, do: DateTime.truncate(now(), :second)
end
