defmodule SpaceTraders.Agent.Agent do
  @moduledoc """
  An in-game Agent minted by an Operator.

  This is a local cache of the game's agent record (the server is the source of
  truth); the per-agent `agent_token` authorizes all game actions for this agent
  and is stored encrypted (ADR 0006). A nil `operator_id` marks an agent minted
  out-of-band (e.g. the seeded ORBITALIST) rather than through this deployment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias SpaceTraders.Secret

  @symbol_regex ~r/^[A-Z0-9][A-Z0-9_-]{0,19}$/

  schema "agents" do
    field :symbol, :string
    field :faction, :string
    field :headquarters, :string
    field :agent_token, Secret, source: :agent_token_ciphertext, redact: true
    field :stale_at, :utc_datetime

    belongs_to :operator, SpaceTraders.Agent.Operator
    has_many :ships, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for the attributes chosen at mint time (symbol + faction).

  The symbol rules mirror the game's registration constraints; the API remains
  the source of truth for what is actually accepted.
  """
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:symbol, :faction])
    |> validate_required([:symbol, :faction])
    |> validate_format(:symbol, @symbol_regex,
      message: "must be 1-20 uppercase letters, digits, dashes or underscores"
    )
    |> unique_constraint(:symbol)
  end
end
