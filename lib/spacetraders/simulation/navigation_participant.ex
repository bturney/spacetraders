defmodule SpaceTraders.Simulation.NavigationParticipant do
  @moduledoc """
  Opt-in callback accounting for the closed navigation participant set.

  Synchronous callback bodies include HTTP/DB operations and local PubSub sends.
  The barrier is a supported mailbox protocol, not process-state inspection or
  suspension. Other actors/mechanics are not implicitly covered.
  """

  defmacro __using__(opts) do
    quote do
      @impl true
      def init(opts) do
        if SpaceTraders.Simulation.NavigationClock.enabled?(),
          do: SpaceTraders.Simulation.NavigationClock.register(self(), __MODULE__)

        init_participant(opts)
      end

      @impl true
      def handle_info({:simulation_wake, reference, message}, state) do
        SpaceTraders.Simulation.NavigationClock.work(
          fn -> handle_participant_info(message, state) end,
          reference
        )
      end

      def handle_info(message, state) do
        SpaceTraders.Simulation.NavigationParticipant.work(fn ->
          handle_participant_info(message, state)
        end)
      end

      @impl true
      def handle_call(:simulation_barrier, _from, state) do
        {:reply, SpaceTraders.Simulation.NavigationParticipant.projection(__MODULE__, state),
         state}
      end

      unquote(
        if Keyword.get(opts, :calls, false) do
          quote do
            def handle_call(message, from, state) do
              SpaceTraders.Simulation.NavigationParticipant.work(fn ->
                handle_participant_call(message, from, state)
              end)
            end
          end
        end
      )

      unquote(
        if Keyword.get(opts, :casts, false) do
          quote do
            @impl true
            def handle_cast(message, state) do
              SpaceTraders.Simulation.NavigationParticipant.work(fn ->
                handle_participant_cast(message, state)
              end)
            end
          end
        end
      )
    end
  end

  def work(fun) do
    if SpaceTraders.Simulation.NavigationClock.enabled?(),
      do: SpaceTraders.Simulation.NavigationClock.work(fun),
      else: fun.()
  end

  def projection(SpaceTraders.Evidence.ReadCoordinator, state),
    do: %{unresolved: map_size(state.pending)}

  def projection(_module, _state), do: %{unresolved: 0}
end
