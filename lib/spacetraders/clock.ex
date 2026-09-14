defmodule SpaceTraders.Clock do
  @moduledoc "Application clock used by durable waits and runtime processes."

  @callback utc_now() :: DateTime.t()
  @callback send_at(pid(), term(), DateTime.t()) :: reference()

  @spec utc_now() :: DateTime.t()
  def utc_now do
    case Application.get_env(:spacetraders, :clock) do
      nil -> DateTime.utc_now()
      clock -> clock.utc_now()
    end
  end

  @spec send_at(pid(), term(), DateTime.t()) :: reference()
  def send_at(destination, message, %DateTime{} = due_at) when is_pid(destination) do
    case Application.get_env(:spacetraders, :clock) do
      nil ->
        delay = max(DateTime.diff(due_at, DateTime.utc_now(), :millisecond), 0)
        Process.send_after(destination, message, delay)

      clock ->
        clock.send_at(destination, message, due_at)
    end
  end

  @spec send_after(pid(), term(), non_neg_integer()) :: reference()
  def send_after(destination, message, delay_ms) when is_pid(destination) and delay_ms >= 0 do
    send_at(destination, message, DateTime.add(utc_now(), delay_ms, :millisecond))
  end
end
