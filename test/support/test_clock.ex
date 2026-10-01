defmodule SpaceTraders.TestClock do
  @moduledoc false

  use Agent

  def start_link(now) do
    Agent.start_link(fn -> %{now: now, timers: []} end, name: __MODULE__)
  end

  def utc_now do
    Agent.get(__MODULE__, & &1.now)
  end

  @doc "The next scheduled wake of a live process, for runtime scenario time control."
  def next_due_at do
    Agent.get(__MODULE__, fn state ->
      state.timers
      |> Enum.filter(fn {_due_at, destination, _message} ->
        is_pid(destination) and Process.alive?(destination)
      end)
      |> Enum.map(fn {due_at, _destination, _message} -> due_at end)
      |> Enum.min(DateTime, fn -> nil end)
    end)
  end

  def send_at(destination, message, due_at) do
    reference = make_ref()

    Agent.update(__MODULE__, fn state ->
      if DateTime.compare(due_at, state.now) == :gt do
        %{state | timers: [{due_at, destination, message} | state.timers]}
      else
        send(destination, message)
        state
      end
    end)

    reference
  end

  def advance(amount, unit \\ :second) do
    Agent.get_and_update(__MODULE__, fn state ->
      advanced = DateTime.add(state.now, amount, unit)

      {due, pending} =
        Enum.split_with(state.timers, fn {due_at, _destination, _message} ->
          DateTime.compare(due_at, advanced) != :gt
        end)

      Enum.each(due, fn {_due_at, destination, message} -> send(destination, message) end)

      {advanced, %{state | now: advanced, timers: pending}}
    end)
  end
end
