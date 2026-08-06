defmodule SpaceTraders.API.Model.ContractPayment do
  @moduledoc "Payments for the contract."

  defstruct [
    :on_accepted,
    :on_fulfilled
  ]

  @type t :: %__MODULE__{
          on_accepted: integer(),
          on_fulfilled: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ContractPayment`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      on_accepted: json["onAccepted"],
      on_fulfilled: json["onFulfilled"]
    }
  end
end
