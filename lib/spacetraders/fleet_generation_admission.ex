defmodule SpaceTraders.FleetGenerationAdmission do
  @moduledoc false

  use GenServer

  import Ecto.Query, warn: false

  alias SpaceTraders.Agent.Agent
  alias SpaceTraders.Repo

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  def fence(token) when is_binary(token) and token != "" do
    GenServer.call(__MODULE__, {:fence, fingerprint(token)})
  end

  def fence(_token), do: :ok

  def mutation_allowed?(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:mutation_allowed, fingerprint(token)})
  end

  def mutation_allowed?(_token), do: :ok

  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(:ok) do
    fingerprints =
      Repo.all(from agent in Agent, where: not is_nil(agent.stale_at), select: agent.agent_token)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.map(&fingerprint/1)
      |> MapSet.new()

    if Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end

    {:ok, fingerprints}
  end

  @impl true
  def handle_call({:fence, fingerprint}, _from, fingerprints) do
    {:reply, :ok, MapSet.put(fingerprints, fingerprint)}
  end

  def handle_call({:mutation_allowed, fingerprint}, _from, fingerprints) do
    if fingerprint in fingerprints do
      {:reply, {:error, :stale_agent}, fingerprints}
    else
      {:reply, :ok, fingerprints}
    end
  end

  def handle_call(:clear, _from, _fingerprints), do: {:reply, :ok, MapSet.new()}

  defp fingerprint(token), do: :crypto.hash(:sha256, token)
end
