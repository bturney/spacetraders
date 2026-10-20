defmodule SpaceTraders.FleetGeneration.ResetReplacementBoot do
  @moduledoc """
  Finishes a Server Reset replacement that has not committed.

  A fence that committed before its replacement did (a crash, a deploy, or a
  registration lost while the game was resetting) leaves no request that
  would rediscover the reset: the predecessor's credential has no gameplay
  authority. Once this runtime holds mutation authority,
  `FleetGeneration.resume_reset_replacement/0` runs at boot and then every
  10 minutes under the ordinary establishment authority, so it competes
  safely with any other wakeup. With no fenced Fleet it reads one row and
  does nothing. Nothing needs the Operator (ADR 0017).
  """

  use GenServer

  alias SpaceTraders.{FleetGeneration, RuntimeAuthority}

  @authority_retry_ms 5_000
  @replacement_check_ms 10 * 60_000

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
        Process.send_after(self(), :resume, @replacement_check_ms)
        {:noreply, state}

      {:error, _unavailable} ->
        Process.send_after(self(), :resume, @authority_retry_ms)
        {:noreply, state}
    end
  end
end
