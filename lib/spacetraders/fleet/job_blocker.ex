defmodule SpaceTraders.Fleet.JobBlocker do
  @moduledoc """
  A structured explanation of why a Job cannot currently progress.

  Records a stable reason, evidence and observation time, who or what can
  resolve it, the condition for another attempt, and any corrective actions
  (see `CONTEXT.md` → Job Blocker).
  """

  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :reason, :string
    field :evidence, :string
    field :observed_at, :utc_datetime
    field :resolver, :string
    field :retry_condition, :string
    field :corrective_actions, {:array, :string}
  end
end
