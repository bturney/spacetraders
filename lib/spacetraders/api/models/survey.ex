defmodule SpaceTraders.API.Model.Survey do
  @moduledoc "A resource survey of a waypoint, detailing a specific extraction location and the types of resources that can be found there."

  defstruct [
    :deposits,
    :expiration,
    :signature,
    :size,
    :symbol
  ]

  @type t :: %__MODULE__{
          deposits: [SpaceTraders.API.Model.SurveyDeposit.t()],
          expiration: String.t(),
          signature: String.t(),
          size: String.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Survey`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      deposits:
        Enum.map(json["deposits"] || [], &SpaceTraders.API.Model.SurveyDeposit.from_json/1),
      expiration: json["expiration"],
      signature: json["signature"],
      size: json["size"],
      symbol: json["symbol"]
    }
  end
end
