defmodule SpaceTraders.ManualIntervention do
  @moduledoc "Durable record of an exceptional, Operator-authorized Ship outcome."

  use Ecto.Schema
  import Ecto.Query

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.Repo
  alias SpaceTraders.ShipReservation

  schema "manual_interventions" do
    belongs_to :ship_reservation, ShipReservation
    belongs_to :intent, Intent
    field :reason, :string
    field :target_waypoint, :string
    field :final_status, :string
    timestamps(type: :utc_datetime_usec)
  end

  def list(%Scope{operator: %{id: operator_id}}) do
    Repo.all(
      from intervention in __MODULE__,
        join: reservation in ShipReservation,
        on: reservation.id == intervention.ship_reservation_id,
        where: reservation.operator_id == ^operator_id,
        preload: [:intent, :ship_reservation],
        order_by: [desc: intervention.inserted_at]
    )
  end

  @doc "Checks that the pending or active Intent still owns its reserved Ship."
  def authorized?(operator_id, ship_symbol, intent_id),
    do: match?({:ok, _}, authorization(operator_id, ship_symbol, intent_id))

  @doc "Returns current authenticated Intervention provenance, optionally under admission locks."
  def authorization(operator_id, ship_symbol, intent_id, opts \\ [])

  def authorization(operator_id, ship_symbol, intent_id, opts) when is_integer(intent_id) do
    query =
      from intervention in __MODULE__,
        join: reservation in ShipReservation,
        on: reservation.id == intervention.ship_reservation_id,
        join: ship in Ship,
        on: ship.id == reservation.ship_id,
        join: intent in Intent,
        on: intent.id == intervention.intent_id,
        where:
          reservation.operator_id == ^operator_id and is_nil(reservation.released_at) and
            ship.symbol == ^ship_symbol and
            intent.id == ^intent_id and intent.ship_id == ship.id and
            intent.caller == "intervention" and intent.status in ^Intent.unfinished_states(),
        select: %{intervention_id: intervention.id, ship_reservation_id: reservation.id}

    query = if Keyword.get(opts, :lock, false), do: lock(query, "FOR SHARE"), else: query

    case Repo.one(query) do
      nil -> {:error, :intervention_not_authorized}
      authority -> {:ok, authority}
    end
  end

  def authorization(_operator_id, _ship_symbol, _intent_id, _opts),
    do: {:error, :intervention_not_authorized}
end
