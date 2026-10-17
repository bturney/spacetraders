defmodule SpaceTraders.RecordedDispatchFixtures do
  @moduledoc """
  Valid durable authority for lower public API adapter tests. These fixtures do
  not claim authenticated Fleet autonomy; higher-level runtime proofs provide
  their own authority fixtures at the seam they exercise.
  """

  import SpaceTraders.AgentFixtures
  import Ecto.Query

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio, PortfolioCandidate}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.SafetyFence.DependencyKey
  alias SpaceTraders.Repo

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
        commitment_intent(agent, ship, generation, revision, action, opts[:intent])
      end

    action =
      if action["kind"] == "transfer",
        do: transfer_evidence(agent, ship_symbol, action),
        else: action

    if action["kind"] in ["buy", "refuel", "jump"] and opts[:live_quote] != true do
      retain_purchase_preflight(agent, intent.target_waypoint, action)
    end

    action =
      if action["kind"] in ["install_module", "remove_module"] and opts[:live_quote] != true do
        action = Map.put_new(action, "waypoint", intent.target_waypoint)
        retain_modification_preflight(agent, action["waypoint"])
        action
      else
        action
      end

    case RecordedAction.prepare(agent, intent, action) do
      {:ok, selected} ->
        Map.merge(selected, %{agent: agent, ship: ship})

      {:error, reason} ->
        %{agent: agent, ship: ship, intent: intent, error: {:error, reason}}
    end
  end

  # Adapter tests provide actual retained Evidence at the public acquisition
  # seam. Production preparation/admission still validate that same source.
  def retain_purchase_preflight(agent, waypoint, action) do
    {waypoint, trade_symbol, volume} = quoted_good(waypoint, action)
    system = waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
    market_subject = "market:#{system}:#{waypoint}"
    agent_subject = DependencyKey.observation_subject("get-my-agent", [], agent.symbol)

    Enum.each(
      [
        {"get-market", market_subject,
         %{
           "symbol" => waypoint,
           "exports" => [],
           "imports" => [],
           "exchange" => [],
           "trade_goods" => [
             %{
               "symbol" => trade_symbol,
               "purchase_price" => action["listing_price"] || 10,
               "trade_volume" => volume
             }
           ]
         }},
        {"get-my-agent", agent_subject,
         %{"symbol" => agent.symbol, "credits" => action["credits_before"] || 1_000_000}}
      ],
      fn {operation, subject, response} ->
        observation =
          SpaceTraders.Evidence.authoritative_observation(
            operation,
            [subject],
            %{response: response},
            SpaceTraders.Clock.utc_now()
          )

        {:ok, _} = SpaceTraders.Evidence.fulfil_demands(agent, subject, observation)
      end
    )
  end

  # A module install or removal is bounded by the docked Shipyard's fee.
  def retain_modification_preflight(agent, waypoint) do
    system = waypoint |> String.split("-") |> Enum.take(2) |> Enum.join("-")
    agent_subject = DependencyKey.observation_subject("get-my-agent", [], agent.symbol)

    Enum.each(
      [
        {"get-shipyard", "shipyard:#{system}:#{waypoint}",
         %{"symbol" => waypoint, "ship_types" => [], "modifications_fee" => 1_000}},
        {"get-my-agent", agent_subject, %{"symbol" => agent.symbol, "credits" => 1_000_000}}
      ],
      fn {operation, subject, response} ->
        observation =
          SpaceTraders.Evidence.authoritative_observation(
            operation,
            [subject],
            %{response: response},
            SpaceTraders.Clock.utc_now()
          )

        {:ok, _} = SpaceTraders.Evidence.fulfil_demands(agent, subject, observation)
      end
    )
  end

  defp quoted_good(waypoint, %{"kind" => "refuel"} = action),
    do: {action["waypoint"] || waypoint, "FUEL", 1_000}

  defp quoted_good(waypoint, %{"kind" => "jump"} = action),
    do: {action["source_waypoint"] || waypoint, "ANTIMATTER", 1_000}

  defp quoted_good(waypoint, action), do: {waypoint, action["trade_symbol"], action["units"]}

  # Lower adapter tests supply controlled retained preflight facts, not network
  # recovery. Runtime/transfer-owner tests acquire their own governed bindings.
  defp transfer_evidence(agent, symbol, action) do
    Enum.reduce(
      [
        {symbol, "source_observation_id", action["units"]},
        {action["target_ship"], "target_observation_id", 0}
      ],
      action,
      fn {ship_symbol, key, units}, selected ->
        cargo = %{
          "capacity" => 40,
          "units" => units,
          "inventory" =>
            if(units > 0, do: [%{"symbol" => action["trade_symbol"], "units" => units}], else: [])
        }

        ship =
          SpaceTraders.ShipBody.ship_body(ship_symbol, %{"cargo" => cargo})
          |> SpaceTraders.API.Model.Ship.from_json()
          |> read_facts()

        subject =
          DependencyKey.observation_subject(
            "get-my-ship",
            [DependencyKey.ship(agent.id, ship_symbol)],
            agent.symbol
          )

        observation =
          SpaceTraders.Evidence.authoritative_observation("get-my-ship", [subject], %{
            response: ship
          })

        {:ok, %{observation: source}} =
          SpaceTraders.Evidence.fulfil_demands(agent, subject, observation)

        Map.put(selected, key, source.id)
      end
    )
  end

  defp read_facts(%_{} = value), do: value |> Map.from_struct() |> read_facts()

  defp read_facts(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), read_facts(nested)} end)

  defp read_facts(value) when is_list(value), do: Enum.map(value, &read_facts/1)
  defp read_facts(value), do: value

  defp ensure_operator(%Agent{operator_id: id} = agent) when is_integer(id), do: agent

  defp ensure_operator(agent) do
    operator = operator_fixture()
    agent |> Ecto.Changeset.change(operator_id: operator.id) |> Repo.update!()
  end

  defp ensure_generation(agent) do
    existing = Repo.one(Strategy)

    strategy =
      existing ||
        Repo.insert!(%Strategy{operator_id: agent.operator_id, revision_number: 1})

    case Repo.one(from g in Generation, where: g.agent_id == ^agent.id and is_nil(g.retired_at)) do
      %Generation{} = generation ->
        generation =
          if existing do
            generation
          else
            revision = activated_revision(strategy)

            generation
            |> Ecto.Changeset.change(fleet_strategy_revision_id: revision.id)
            |> Repo.update!()
          end

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

  @doc "A navigate Intent for `ship` under a one-Ship Fleet Commitment of the Agent's Generation."
  def navigate_intent(agent, ship, waypoint) do
    {generation, revision} = ensure_generation(agent)
    commitment_intent(agent, ship, generation, revision, %{"waypoint" => waypoint}, nil)
  end

  # A navigate Intent under a one-Ship Fleet Commitment: the same durable
  # authority a Strategy-governed Fleet gives every ordinary Ship action.
  defp commitment_intent(agent, ship, generation, revision, action, existing) do
    ownership =
      if revision do
        candidate = %PortfolioCandidate{
          id: "adapter-#{ship.symbol}",
          strategy_revision_id: revision.id,
          objective_index: 0,
          claims: [ship.symbol],
          reservations: %{},
          pledges: [],
          dependencies: [],
          expected_value: 1,
          unwind_cost: 0
        }

        commitment = publish_commitment(agent, generation, revision, candidate)

        [
          caller: "commitment",
          fleet_commitment_id: commitment.id,
          fleet_commitment_portfolio_id: commitment.portfolio.id,
          fleet_commitment_portfolio_version: commitment.portfolio.version
        ]
      else
        # Without an active Revision no Portfolio can be published: the Intent
        # carries no Commitment and admission refuses it.
        [caller: "commitment"]
      end

    if existing do
      existing
      |> Ecto.Changeset.change([in_flight_action: nil, mutation_attempt_id: nil] ++ ownership)
      |> Repo.update!()
    else
      Repo.insert!(
        struct!(
          Intent,
          [
            ship_id: ship.id,
            type: "navigate",
            status: "active",
            target_waypoint: action["waypoint"] || agent.headquarters
          ] ++ ownership
        )
      )
    end
  end

  # One Commitment per Ship. A Ship that already has current authority reuses
  # it; a later Ship joins the Generation's current Portfolio rather than
  # superseding the Commitments earlier Ships act under.
  defp publish_commitment(agent, generation, revision, candidate) do
    [ship_symbol] = candidate.claims

    with {:error, :no_current_ship_claim} <-
           FleetAllocation.current_ship_claim(agent, ship_symbol),
         %Portfolio{} = portfolio <-
           Repo.one(
             from p in Portfolio,
               where: p.fleet_generation_id == ^generation.id and is_nil(p.superseded_at)
           ) do
      commitment =
        Repo.insert!(%Commitment{
          fleet_commitment_portfolio_id: portfolio.id,
          candidate_id: candidate.id,
          objective_index: 0,
          claims: [ship_symbol],
          expected_value: 1.0,
          unwind_cost: 0.0,
          decisive_reason: "adapter"
        })

      Repo.insert_all("fleet_commitment_claims", [
        %{
          fleet_commitment_portfolio_id: portfolio.id,
          fleet_commitment_id: commitment.id,
          resource: ship_symbol
        }
      ])

      %{id: commitment.id, portfolio: portfolio}
    else
      {:ok, claim} ->
        %{id: claim.commitment_id, portfolio: Repo.get!(Portfolio, claim.portfolio_id)}

      nil ->
        publish_first_commitment(agent, generation, revision, candidate)
    end
  end

  defp publish_first_commitment(agent, generation, revision, candidate) do
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
        %{evidence_references: [], expectations: %{}, calibration_version: "adapter"}
      )

    [commitment] = portfolio.commitments
    %{id: commitment.id, portfolio: portfolio}
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
