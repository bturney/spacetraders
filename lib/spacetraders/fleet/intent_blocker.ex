defmodule SpaceTraders.Fleet.IntentBlocker do
  @moduledoc "A structured explanation of why an Intent cannot currently progress."

  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :reason, :string
    field :summary, :string
    field :evidence, :string
    field :observed_at, :utc_datetime
    field :resolver, :string
    field :retry_condition, :string
    field :corrective_actions, {:array, :string}
  end
end
