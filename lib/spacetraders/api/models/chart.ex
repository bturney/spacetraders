defmodule SpaceTraders.API.Model.Chart do
  @moduledoc "The chart of a system or waypoint, which makes the location visible to other agents."

  defstruct [
    :submitted_by,
    :submitted_on,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          submitted_by: String.t() | nil,
          submitted_on: String.t() | nil,
          waypoint_symbol: String.t() | nil
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Chart`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      submitted_by: json["submittedBy"],
      submitted_on: json["submittedOn"],
      waypoint_symbol: json["waypointSymbol"]
    }
  end
end
