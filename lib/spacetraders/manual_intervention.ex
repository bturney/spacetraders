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
  def authorized?(operator_id, ship_symbol, intent_id) when is_integer(intent_id) do
    Repo.exists?(
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
            intent.caller == "intervention" and intent.status in ^Intent.unfinished_states()
    )
  end

  def authorized?(_operator_id, _ship_symbol, _intent_id), do: false
end
