defmodule SpaceTraders.ShipReservation do
  @moduledoc "Explicit Operator reservation excluding a Ship from Fleet allocation."

  use Ecto.Schema
  import Ecto.Query

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.{FleetAllocation, FleetGeneration}
  alias SpaceTraders.FleetGeneration.Identity
  alias SpaceTraders.Repo

  schema "ship_reservations" do
    belongs_to :ship, Ship
    field :ship_symbol, :string
    field :operator_id, :id
    field :reason, :string
    field :released_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def reserved_ship_ids(agent_id) do
    Repo.all(
      from reservation in __MODULE__,
        join: ship in Ship,
        on: ship.id == reservation.ship_id,
        where: ship.agent_id == ^agent_id and is_nil(reservation.released_at),
        select: ship.id
    )
  end

  @doc "Releases reset-scoped Ship authority before a Stale Agent is retired."
  def release_for_agent!(agent_id) do
    Repo.update_all(
      from(reservation in __MODULE__,
        join: ship in Ship,
        on: ship.id == reservation.ship_id,
        where: ship.agent_id == ^agent_id and is_nil(reservation.released_at)
      ),
      set: [released_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )

    :ok
  end

  @doc """
  Active reservations for the deployment Operator. A Generation's reservations
  are released when it retires, so active ones belong to live Ships; the
  reserving Operator is attribution, not a tenant filter.
  """
  def list(%Scope{operator: %{id: operator_id}}) do
    if Identity.operator?(operator_id) do
      Repo.all(
        from reservation in __MODULE__,
          where: is_nil(reservation.released_at),
          preload: [:ship],
          order_by: [desc: reservation.inserted_at]
      )
    else
      []
    end
  end

  def reserved_symbols(agent_id) do
    Repo.all(
      from reservation in __MODULE__,
        join: ship in Ship,
        on: ship.id == reservation.ship_id,
        where: ship.agent_id == ^agent_id and is_nil(reservation.released_at),
        select: ship.symbol
    )
  end

  def reserve(%Scope{operator: %{id: operator_id}}, ship_id, reason)
      when is_integer(ship_id) and is_binary(reason) do
    reason = String.trim(reason)

    if reason == "" do
      {:error, :reason_required}
    else
      Repo.transaction(fn ->
        unless Identity.operator?(operator_id), do: Repo.rollback(:not_deployment_operator)

        ship = Repo.one(from ship in Ship, where: ship.id == ^ship_id, lock: "FOR UPDATE")

        cond do
          is_nil(ship) ->
            Repo.rollback(:ship_not_found)

          # Only the current Generation's Ships can be taken out of allocation;
          # a retained predecessor's Ship stays history.
          (authority = FleetGeneration.gameplay_authority(ship.agent_id)) != :ok ->
            {:error, reason} = authority
            Repo.rollback(reason)

          Repo.exists?(
            from i in Intent,
              where: i.ship_id == ^ship_id and i.status in ^Intent.unfinished_states()
          ) ->
            Repo.rollback(:ship_busy)

          match?(
            {:ok, _},
            FleetAllocation.current_ship_claim(
              %SpaceTraders.Agent.Agent{id: ship.agent_id, operator_id: operator_id},
              ship.symbol
            )
          ) ->
            Repo.rollback(:ship_claimed)

          true ->
            if Repo.exists?(
                 from reservation in __MODULE__,
                   where: reservation.ship_id == ^ship.id and is_nil(reservation.released_at)
               ) do
              Repo.rollback(:already_reserved)
            end

            Repo.insert!(%__MODULE__{
              ship_id: ship.id,
              ship_symbol: ship.symbol,
              operator_id: operator_id,
              reason: reason
            })
        end
      end)
    end
  end

  def reserve(_scope, _ship_id, _reason), do: {:error, :invalid_reservation}

  def release(%Scope{operator: %{id: operator_id}}, ship_id) when is_integer(ship_id) do
    Repo.transaction(fn ->
      unless Identity.operator?(operator_id), do: Repo.rollback(:not_deployment_operator)

      reservation =
        Repo.one(
          from reservation in __MODULE__,
            where: reservation.ship_id == ^ship_id and is_nil(reservation.released_at),
            lock: "FOR UPDATE"
        )

      if is_nil(reservation), do: Repo.rollback(:reservation_not_found)

      if Repo.exists?(
           from intervention in SpaceTraders.ManualIntervention,
             join: intent in Intent,
             on: intent.id == intervention.intent_id,
             where:
               intervention.ship_reservation_id == ^reservation.id and
                 intent.status in ^Intent.unfinished_states()
         ) do
        Repo.rollback(:intervention_in_progress)
      end

      Repo.update!(Ecto.Changeset.change(reservation, released_at: DateTime.utc_now()))
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, cause} -> {:error, cause}
    end
  end

  def release(_scope, _ship_id), do: {:error, :invalid_reservation}
end
