defmodule SpaceTraders.API.Model.ContractTerms do
  @moduledoc "The terms to fulfill the contract."

  defstruct [
    :deadline,
    :deliver,
    :payment
  ]

  @type t :: %__MODULE__{
          deadline: String.t(),
          deliver: [SpaceTraders.API.Model.ContractDeliverGood.t()] | nil,
          payment: SpaceTraders.API.Model.ContractPayment.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ContractTerms`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      deadline: json["deadline"],
      deliver:
        Enum.map(json["deliver"] || [], &SpaceTraders.API.Model.ContractDeliverGood.from_json/1),
      payment:
        json["payment"] && SpaceTraders.API.Model.ContractPayment.from_json(json["payment"])
    }
  end
end
