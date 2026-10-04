defmodule SpaceTraders.API.RecordedDispatch do
  @moduledoc "Compatibility boundary during capability adoption; root Intents own recorded selection and admission."
  alias SpaceTraders.Fleet.Intents.RecordedAction

  defdelegate prepare(agent, intent, action), to: RecordedAction
  defdelegate prepare_retry(agent, intent, attempt), to: RecordedAction
  defdelegate admit_send(attempt), to: RecordedAction
  defdelegate authorize_transport(attempt), to: RecordedAction
  defdelegate require_commit_boundary(), to: RecordedAction
end
