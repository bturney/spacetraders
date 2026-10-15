defmodule SpaceTraders.ShipAcquisitionCalibration do
  @moduledoc "Versioned Capacity Investment calibration, not Operator-owned Strategy intent."

  @doc """
  The Operator-approved initial model; changes require a new calibration version.
  `no_history_discount` is the fraction removed from the planned rate when
  realized Trade Margin history is absent.
  """
  def current do
    %{
      version: "ship-acquisition-v2",
      horizon_window_seconds: 48 * 60 * 60,
      no_history_discount: 0.5
    }
  end
end
