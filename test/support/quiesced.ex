defmodule SpaceTraders.Quiesced do
  @moduledoc """
  Test-supervised runtime child that never stops mid-transaction (#398).

  ExUnit stops `start_supervised` children with an exit signal; a GenServer that
  does not trap exits dies at once, even mid-transaction. A process that dies
  holding a sandbox connection makes the ownership proxy disconnect it, and
  Postgrex logs that disconnect as an error. Wrapping the child here stops it
  through `SpaceTraders.Quiesce`, at a moment it holds no connection.

      start_supervised!(Quiesced.child_spec({Reconciler, []}))
      stop_supervised(Reconciler)

  The wrapper keeps the child's id. A child that dies on its own (a test killing
  the runtime) takes the wrapper down with it, without a restart.
  """

  use GenServer

  def child_spec(child) do
    %{id: id, start: start} = Supervisor.child_spec(child, [])
    %{id: id, start: {__MODULE__, :start_link, [start]}, restart: :temporary}
  end

  @doc false
  def start_link(start), do: GenServer.start_link(__MODULE__, start)

  @impl true
  def init({module, function, args}) do
    Process.flag(:trap_exit, true)

    case apply(module, function, args) do
      {:ok, child} -> {:ok, child}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info({:EXIT, child, reason}, child), do: {:stop, {:shutdown, reason}, nil}
  def handle_info(_message, child), do: {:noreply, child}

  @impl true
  def terminate(_reason, nil), do: :ok

  def terminate(_reason, child) do
    SpaceTraders.Quiesce.stop(child, &Process.exit(&1, :shutdown))

    receive do
      {:EXIT, ^child, _} -> :ok
    end
  end
end
