defmodule SpaceTraders.API.GameplayError do
  @moduledoc """
  A typed game-state rejection from the SpaceTraders API.

  The game returns 4xx responses with an `error` envelope carrying a numeric
  `code`. Known codes map to a `type` atom so callers can branch without
  hardcoding numbers:

    * `:in_transit` — ship is travelling, action blocked
    * `:cooldown` — ship is in a forced cooldown
    * `:insufficient_cargo` / `:cargo_full` — cargo limits
    * `:insufficient_credits` — not enough credits for the action
    * `:contract_expired` — contract deadline passed
    * `:other` — any unrecognised 4xx code

  Gameplay errors are returned as values (`{:error, %GameplayError{}}`), never
  raised. Fatal problems surface as `%SpaceTraders.API.Error{}` instead.
  """

  @enforce_keys [:code, :message, :type]
  defstruct [:code, :message, :data, :type]

  @type t :: %__MODULE__{
          code: integer(),
          message: String.t(),
          data: map(),
          type: atom()
        }

  # SpaceTraders error codes → gameplay outcome types. Non-exhaustive on
  # purpose: unknown codes become `:other`.
  @code_types %{
    4000 => :cooldown,
    4200 => :in_transit,
    4214 => :in_transit,
    4216 => :insufficient_credits,
    4217 => :cargo_exceeds_limit,
    4218 => :insufficient_cargo,
    4228 => :cargo_full,
    4236 => :not_in_orbit,
    4244 => :not_docked,
    4248 => :insufficient_credits,
    4503 => :contract_expired,
    4504 => :contract_fulfilled,
    4505 => :contract_not_accepted,
    4600 => :insufficient_credits
  }

  @spec new(integer(), String.t(), map()) :: t()
  def new(code, message, data) do
    %__MODULE__{
      code: code,
      message: message,
      data: data || %{},
      type: Map.get(@code_types, code, :other)
    }
  end
end
