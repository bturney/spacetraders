defmodule SpaceTraders.API.Error do
  @moduledoc """
  A fatal, non-gameplay API failure: 5xx server errors, transport errors, or a
  response that could not be decoded into a model struct.

  Distinguishable from `SpaceTraders.API.GameplayError` by struct type — gameplay
  outcomes are typed results, everything else is `%SpaceTraders.API.Error{}`.
  """

  @enforce_keys [:message]
  defstruct [:status, :message, :reason]

  @type t :: %__MODULE__{
          status: integer() | nil,
          message: String.t(),
          reason: term()
        }

  @spec new(integer(), String.t()) :: t()
  def new(status, message), do: %__MODULE__{status: status, message: message}

  @spec transport(term()) :: t()
  def transport(reason),
    do: %__MODULE__{message: "transport error: #{inspect(reason)}", reason: reason}
end
