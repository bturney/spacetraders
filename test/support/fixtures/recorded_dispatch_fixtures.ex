defmodule SpaceTraders.RecordedDispatchFixtures do
  @moduledoc """
  Valid durable authority for lower public API adapter tests. These fixtures do
  not claim authenticated Fleet autonomy; higher-level runtime proofs provide
  their own authority fixtures at the seam they exercise.
  """

  import SpaceTraders.AgentFixtures
  import Ecto.Query

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.API.RecordedDispatch
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.{ManualIntervention, Repo, ShipReservation}

  def dispatch_action(ship_symbol, action, token \\ "TOKEN") do
    agent = operator_fixture() |> agent_fixture(%{agent_token: token})
    %{attempt: attempt} = prepare_action(agent, ship_symbol, action)
    SpaceTraders.API.dispatch_recorded(attempt)
  end

  @doc """
  Prepares one recorded action under valid durable authority. Refusals return
  `%{error: reason}` so authority-boundary tests can assert them directly.
  """
  def prepare_action(agent, ship_symbol, action, opts \\ []) do
    agent = ensure_operator(agent)
    {generation, revision} = ensure_generation(agent)

    ship =
      Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) ||
        Repo.insert!(%Ship{
          agent_id: agent.id,
          symbol: ship_symbol,
          ship_type: "SHIP_COMMAND_FRIGATE"
        })

    intent =
      if action["kind"] == "transfer" do
        transfer_intent(agent, ship, generation, revision, action)
      else
        intervention_intent(agent, ship, action, opts[:intent])
      end

    case RecordedDispatch.prepare(agent, intent, action) do
      {:ok, selected} ->
        Map.merge(selected, %{agent: agent, ship: ship})

      {:error, reason} ->
        %{agent: agent, ship: ship, intent: intent, error: {:error, reason}}
    end
  end

  defp ensure_operator(%Agent{operator_id: id} = agent) when is_integer(id), do: agent

  defp ensure_operator(agent) do
    operator = operator_fixture()
    agent |> Ecto.Changeset.change(operator_id: operator.id) |> Repo.update!()
  end

  defp ensure_generation(agent) do
    strategy =
      Repo.one(from s in Strategy, where: s.operator_id == ^agent.operator_id) ||
        Repo.insert!(%Strategy{operator_id: agent.operator_id, revision_number: 1})

    case Repo.one(from g in Generation, where: g.agent_id == ^agent.id and is_nil(g.retired_at)) do
      %Generation{} = generation ->
        {generation,
         generation.fleet_strategy_revision_id &&
           Repo.get!(Revision, generation.fleet_strategy_revision_id)}

      nil ->
        revision = active_revision(strategy) || activated_revision(strategy)

        generation =
          Repo.insert!(%Generation{
            operator_id: agent.operator_id,
            agent_id: agent.id,
            fleet_strategy_revision_id: revision && revision.id,
            number: 1,
            symbol: agent.symbol,
            faction: agent.faction
          })

        {generation, revision}
    end
  end

  defp active_revision(strategy) do
    case strategy.active_revision_id do
      nil ->
        nil

      revision_id ->
        Repo.get!(Revision, revision_id)
    end
  end

  defp activated_revision(strategy) do
    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Grow credits"}],
          "hard_constraints" => []
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))
    revision
  end

  # Lets an authority test present a Fleet with no active Revision.
  def without_active_revision(agent) do
    strategy = Repo.get_by!(Strategy, operator_id: agent.operator_id)
    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: nil))
    :ok
  end

  defp intervention_intent(agent, ship, action, existing) do
    reservation =
      Repo.insert!(%ShipReservation{
        ship_id: ship.id,
        ship_symbol: ship.symbol,
        operator_id: agent.operator_id,
        reason: "Controlled operation adapter proof"
      })

    intent =
      if existing do
        existing
        |> Ecto.Changeset.change(in_flight_action: nil, mutation_attempt_id: nil)
        |> Repo.update!()
      else
        Repo.insert!(%Intent{
          ship_id: ship.id,
          caller: "intervention",
          type: "navigate",
          status: "active",
          target_waypoint: action["waypoint"] || agent.headquarters
        })
      end

    Repo.insert!(%ManualIntervention{
      ship_reservation_id: reservation.id,
      intent_id: intent.id,
      reason: "Controlled operation adapter proof",
      target_waypoint: intent.target_waypoint
    })

    intent
  end

  defp transfer_intent(agent, source, generation, revision, action) do
    target =
      Repo.insert!(%Ship{
        agent_id: agent.id,
        symbol: action["target_ship"],
        ship_type: "SHIP_LIGHT_HAULER"
      })

    capacity = "cargo_capacity:#{target.symbol}"

    candidate = %PortfolioCandidate{
      id: "adapter-transfer",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [source.symbol, target.symbol],
      reservations: %{capacity => action["units"]},
      pledges: [],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: generation.allocation_version,
        claims: candidate.claims,
        reservations: candidate.reservations
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(Repo.get!(Operator, agent.operator_id)),
        generation.id,
        selection,
        %{evidence_references: [], expectations: %{}, calibration_version: "adapter-transfer"}
      )

    [commitment] = portfolio.commitments

    Repo.insert!(%Intent{
      ship_id: source.id,
      caller: "commitment",
      type: "transfer",
      status: "active",
      target_waypoint: agent.headquarters,
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version
    })
  end
end
