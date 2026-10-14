defmodule SpaceTraders.FleetGeneration.ResetReplacementBoot do
  @moduledoc """
  Resumes an interrupted Server Reset replacement once after boot.

  A fence that committed before its replacement did (a crash or deploy
  between them) leaves no request that would rediscover the reset: the
  predecessor's credential has no gameplay authority. Once this runtime holds
  mutation authority, one `FleetGeneration.resume_reset_replacement/0` runs
  under the ordinary establishment authority, so it competes safely with any
  other wakeup. It never retries a failed replacement; that is an Operator
  action.
  """

  use GenServer, restart: :temporary

  alias SpaceTraders.{FleetGeneration, RuntimeAuthority}

  @authority_retry_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :resume)
    {:ok, nil}
  end

  @impl true
  def handle_info(:resume, state) do
    case RuntimeAuthority.execution_allowed?() do
      :ok ->
        _ = FleetGeneration.resume_reset_replacement()
        {:stop, :normal, state}

      {:error, _unavailable} ->
        Process.send_after(self(), :resume, @authority_retry_ms)
        {:noreply, state}
    end
  end
end
