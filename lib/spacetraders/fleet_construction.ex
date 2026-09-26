defmodule SpaceTraders.FleetConstruction do
  @moduledoc "Construction outcome reconciliation against shared, authoritative project progress."

  import Ecto.Query

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.API.Model.Construction
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Intents}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.FleetStrategy.StandingAuthority
  alias SpaceTraders.Repo
  alias SpaceTraders.ShipReservation

  @doc "Only an authoritative Construction isComplete flag proves completion."
  def completed?(%Construction{is_complete: true}), do: true
  def completed?(%Construction{}), do: false

  @doc "Remaining units of one material from the latest authoritative Construction read."
  def remaining(%Construction{is_complete: true}, _symbol), do: 0

  def remaining(%Construction{materials: materials}, symbol) when is_list(materials) do
    case Enum.find(materials, &(&1.trade_symbol == symbol)) do
      %{required: required, fulfilled: fulfilled}
      when is_integer(required) and is_integer(fulfilled) ->
        max(required - fulfilled, 0)

      _ ->
        :unknown
    end
  end

  def remaining(_, _), do: :unknown

  @doc "Classifies the observed market effect without treating the hypothesis as game truth."
  def market_effect(
        %{part_symbol: part, baseline_price: baseline} = hypothesis,
        %Construction{} = construction,
        listing
      )
      when is_binary(part) and is_integer(baseline) do
    left = remaining(construction, part)

    cond do
      left == :unknown ->
        {:still_evaluating, %{remaining: :unknown}}

      left == 0 ->
        {:superseded, %{remaining: 0}}

      true ->
        case listing do
          %{symbol: ^part, purchase_price: price} when is_integer(price) ->
            classification =
              cond do
                price <= Map.get(hypothesis, :expected_price, baseline - 1) and
                  Map.get(listing, :supply) == Map.get(hypothesis, :expected_supply) and
                    (price < baseline or Map.get(listing, :supply) != hypothesis.baseline_supply) ->
                  :realized

                price < baseline or
                    (Map.get(listing, :supply) == Map.get(hypothesis, :expected_supply) and
                       Map.get(listing, :supply) != hypothesis.baseline_supply) ->
                  :partially_realized

                true ->
                  :superseded
              end

            {classification,
             %{
               remaining: left,
               purchase_price: price,
               supply: Map.get(listing, :supply),
               basis: :observed_listing_change_not_causality
             }}

          _ ->
            {:still_evaluating, %{remaining: left}}
        end
    end
  end

  @doc "Reconciles a completed upstream sale against a new on-site Listing and project read."
  def reconcile_upstream_sale(agent, portfolio, %{
        parameters: %{"market_trade" => %{"construction_upstream" => upstream} = candidate}
      }) do
    with {:ok, construction} <- read_project(agent, upstream["system"], upstream["waypoint"]),
         {:ok, system} <- Fleet.system_from_headquarters(candidate["destination_waypoint"]),
         {:ok, market} <-
           Agent.handle_game_result(
             agent,
             Evidence.get_market(
               AgentTokenReference.new(agent),
               system,
               candidate["destination_waypoint"]
             )
           ),
         listing <- Enum.find(market.trade_goods || [], &(&1.symbol == upstream["part_symbol"])) do
      hypothesis = %{
        part_symbol: upstream["part_symbol"],
        baseline_price: upstream["baseline_price"],
        baseline_supply: upstream["baseline_supply"],
        expected_supply: upstream["expected_supply"],
        expected_price: upstream["expected_price"]
      }

      case market_effect(hypothesis, construction, listing) do
        {:still_evaluating, _actual} ->
          {:error, :part_listing_unavailable}

        {classification, actual} ->
          FleetAllocation.record_portfolio_outcome(portfolio, classification, actual)
      end
    end
  end

  @doc "Projects current Construction Pledges against fresh game progress."
  def current_pledges(
        %Scope{operator: %{id: operator_id}} = scope,
        %AgentRecord{operator_id: operator_id} = agent
      ) do
    case FleetAllocation.current_portfolio(scope, agent) do
      nil ->
        {:ok, []}

      %{commitments: commitments} ->
        commitments
        |> Enum.flat_map(& &1.pledges)
        |> Enum.filter(&match?(%{"outcome" => ["construction" | _]}, &1))
        |> Enum.reduce_while({:ok, [], %{}}, fn pledge, {:ok, projected, projects} ->
          case pledge do
            %{"outcome" => ["construction", waypoint, symbol], "amount" => amount}
            when is_integer(amount) and amount >= 0 ->
              with {:ok, construction} <- cached_project(agent, waypoint, projects) do
                case remaining(construction, symbol) do
                  count when is_integer(count) ->
                    {:cont,
                     {:ok,
                      [
                        %{outcome: pledge["outcome"], amount: amount, remaining: count}
                        | projected
                      ], Map.put(projects, waypoint, construction)}}

                  :unknown ->
                    {:halt, {:error, :construction_progress_unavailable}}
                end
              else
                _ -> {:halt, {:error, :construction_progress_unavailable}}
              end

            _ ->
              {:halt, {:error, :construction_progress_unavailable}}
          end
        end)
        |> case do
          {:ok, projected, _projects} ->
            {:ok, projected |> Enum.reverse() |> FleetAllocation.project_shared_pledges()}

          error ->
            error
        end
    end
  end

  def current_pledges(_, _), do: {:error, :not_authorized}

  defp cached_project(agent, waypoint, projects) do
    case Map.fetch(projects, waypoint) do
      {:ok, construction} ->
        {:ok, construction}

      :error ->
        with {:ok, system} <- Fleet.system_from_headquarters(waypoint),
             do: read_project(agent, system, waypoint)
    end
  end

  @doc "Replans remaining material work; upstream hypotheses may be supplied with their evidence."
  def reconcile(
        %Scope{} = scope,
        %AgentRecord{} = agent,
        %Revision{} = revision,
        upstream_opportunities \\ []
      ) do
    index =
      Enum.find_index(
        revision.document["objectives"] || [],
        &FleetPlanning.construction_objective?/1
      )

    with true <- is_integer(index) || {:error, :strategy},
         :ok <- SpaceTraders.RuntimeAuthority.execution_allowed?(),
         %Generation{fleet_strategy_revision_id: revision_id} = generation <-
           current_generation(agent),
         true <- revision_id == revision.id || {:error, :strategy},
         {:ok, ships} <- Fleet.list_ships(agent),
         {:ok, overview} <- Agent.agent_overview(agent),
         {:ok, constructions, unavailable} <- read_projects(agent, scope) do
      upstream_opportunities =
        Enum.uniq_by(
          upstream_opportunities ++ retained_upstream_opportunities(scope, agent),
          & &1.evidence_id
        )

      case pending_purchase(scope, agent) do
        {commitment, portfolio, buy} ->
          FleetExecution.continue_after_intent(agent, commitment, portfolio, buy)

        nil ->
          case pending_production(scope, agent) do
            {commitment, portfolio, production} ->
              FleetExecution.continue_after_intent(agent, commitment, portfolio, production)

            nil ->
              case pending_transfer(scope, agent) do
                {commitment, portfolio, transfer} ->
                  FleetExecution.continue_after_intent(agent, commitment, portfolio, transfer)

                nil ->
                  with :ok <- settle_upstream_sale(scope, agent) do
                    plan_and_activate(
                      scope,
                      agent,
                      revision,
                      generation,
                      index,
                      constructions,
                      ships,
                      overview.credits,
                      upstream_opportunities,
                      unavailable
                    )
                  end
              end
          end
      end
    else
      nil -> {:error, :generation_unavailable}
      error -> error
    end
  end

  defp construction_commitment?(commitment) do
    Enum.any?(commitment.dependencies, fn dep ->
      String.starts_with?(dep["subject"] || "", "construction:")
    end) or
      Enum.any?(commitment.pledges, &match?(%{"outcome" => ["construction" | _]}, &1))
  end

  defp plan_and_activate(
         scope,
         agent,
         revision,
         generation,
         index,
         constructions,
         ships,
         credits,
         upstream_opportunities,
         unavailable
       ) do
    now = DateTime.utc_now()
    current = FleetAllocation.current_portfolio(scope, agent)

    case FleetAllocation.protected_commitments(
           current,
           Intents.current(agent),
           &construction_commitment?/1
         ) do
      :busy ->
        {:error, :ship_execution_in_progress}

      retained ->
        plan_with_retained(
          scope,
          agent,
          revision,
          generation,
          index,
          constructions,
          ships,
          credits,
          upstream_opportunities,
          unavailable,
          now,
          current,
          retained
        )
    end
  end

  defp plan_with_retained(
         scope,
         agent,
         revision,
         generation,
         index,
         constructions,
         ships,
         credits,
         upstream_opportunities,
         unavailable,
         now,
         current,
         retained
       ) do
    occupied = MapSet.new(Enum.flat_map(retained, & &1.claims))

    available =
      Enum.reject(ships, fn ship ->
        ship.symbol in ShipReservation.reserved_symbols(agent.id) or
          MapSet.member?(occupied, ship.symbol)
      end)

    unreserved_credits =
      credits - Enum.sum_by(retained, &Map.get(&1.reservations, "credits", 0))

    with {:ok, planning} <-
           FleetPlanning.plan_construction(revision, index, %{
             as_of: now,
             constructions: constructions,
             ships: available,
             listings: FleetContracts.sourcing_listings(agent, now),
             credits: max(unreserved_credits, 0),
             upstream_opportunities: upstream_opportunities
           }) do
      failed = FleetAllocation.failed_candidate_ids(generation.id)
      candidates = Enum.reject(planning.candidate_contributions, &MapSet.member?(failed, &1.id))

      if current &&
           Enum.any?(current.commitments, fn commitment ->
             not Enum.any?(retained, &(&1.id == commitment.id)) and
               Enum.any?(commitment.dependencies, &(&1["subject"] in unavailable))
           end) do
        {:error, :construction_progress_unavailable}
      else
        case candidates do
          [] ->
            if current && construction_portfolio?(current) do
              if unavailable == [] and constructions != [] and
                   Enum.all?(constructions, &completed?(&1.construction)) and
                   Enum.all?(current.commitments, &construction_commitment?/1) and
                   Enum.any?(current.commitments, &is_nil(&1.replan_decision_episode_id)) do
                _ =
                  FleetAllocation.record_portfolio_outcome(current, :realized, %{
                    completed_projects: Enum.map(constructions, & &1.construction.symbol),
                    basis: :authoritative_construction
                  })
              end

              if retained != [] do
                affected =
                  current.commitments
                  |> Enum.reject(fn commitment ->
                    Enum.any?(retained, &(&1.id == commitment.id))
                  end)
                  |> Enum.map(& &1.candidate_id)

                if affected == [] do
                  {:ok, %{action: :retained, portfolio: current}}
                else
                  FleetAllocation.replan_subgraph(
                    scope,
                    generation.id,
                    %{
                      revision_id: revision.id,
                      source_version: generation.allocation_version,
                      commitments: [],
                      rejected: []
                    },
                    affected,
                    %{
                      evidence_references: constructions,
                      expectations: %{remaining: 0},
                      calibration_version: "construction-v1"
                    }
                  )
                end
              else
                FleetAllocation.unwind_current_portfolio(scope, generation.id)
              end
            else
              if unavailable != [],
                do: {:error, :construction_progress_unavailable},
                else: {:ok, :no_remaining_construction_work}
            end

          candidates ->
            activate(
              scope,
              agent,
              revision,
              generation,
              available,
              max(unreserved_credits, 0),
              candidates,
              now,
              current,
              retained
            )
        end
      end
    end
  end

  defp activate(
         scope,
         agent,
         revision,
         generation,
         ships,
         credits,
         candidates,
         now,
         current,
         retained
       ) do
    floor =
      case StandingAuthority.credit_floor(revision) do
        {:ok, amount} -> amount
        _ -> 0
      end

    candidates =
      Enum.filter(candidates, &(credits - Map.get(&1.required_resources, :credits, 0) >= floor))

    with {:ok, selection} <-
           FleetAllocation.select_coordinated_portfolio(revision, candidates, %{
             as_of: now,
             claims:
               Enum.map(ships, fn ship ->
                 %{
                   resource: ship.symbol,
                   roles: [:construction_courier, :construction_supplier, :cargo_producer],
                   capabilities: %{
                     cargo_transport: ship.cargo.capacity,
                     resource_ship: ship.symbol,
                     resource_mode:
                       if(FleetPlanning.refinery_capable?(ship), do: [:refine], else: [])
                   }
                 }
               end),
             reservations:
               Enum.reduce(ships, %{credits: credits}, fn ship, capacities ->
                 capacities
                 |> Map.put(
                   "cargo_capacity:#{ship.symbol}",
                   ship.cargo.capacity - ship.cargo.units
                 )
                 |> then(fn capacities ->
                   Enum.reduce(ship.cargo.inventory || [], capacities, fn item, capacities ->
                     Map.put(capacities, "cargo:#{ship.symbol}:#{item.symbol}", item.units)
                   end)
                 end)
               end),
             outcome_remaining:
               for observation <- constructions_from_candidates(candidates), into: %{} do
                 {observation.outcome, observation.remaining}
               end
           }),
         [chosen | _] <- FleetAllocation.coordinated_commitments(selection, candidates),
         candidate <- Enum.find(candidates, &(&1.id == chosen.candidate_id)) do
      if current != nil and
           Enum.all?(
             FleetAllocation.coordinated_commitments(selection, candidates),
             fn proposed ->
               Enum.any?(current.commitments, &(&1.candidate_id == proposed.candidate_id))
             end
           ) and
           Enum.all?(current.commitments, fn commitment ->
             not construction_commitment?(commitment) or
               Enum.all?(commitment.dependencies, fn dep ->
                 case DateTime.from_iso8601(dep["valid_until"] || "") do
                   {:ok, deadline, _} ->
                     DateTime.compare(deadline, now) != :lt

                   _ ->
                     dep["state"] == "satisfied" or
                       (dep["kind"] == "acquisition" and
                          Enum.any?(
                            current.commitments,
                            &(&1.candidate_id == dep["candidate_id"])
                          ))
                 end
               end)
           end) do
        commitment = Enum.find(current.commitments, &(&1.candidate_id == chosen.candidate_id))

        if Repo.exists?(from i in Intent, where: i.fleet_commitment_id == ^commitment.id) do
          {:ok, %{action: :retained, portfolio: current}}
        else
          dispatch_construction_candidate(
            agent,
            revision,
            current,
            commitment,
            candidate,
            candidates
          )
        end
      else
        selected = %{
          selection
          | source_version: generation.allocation_version,
            commitments: FleetAllocation.coordinated_commitments(selection, candidates)
        }

        decision = %{
          evidence_references: candidate.dependencies,
          expectations:
            Map.put(
              candidate.expected_outcomes,
              :upstream_hypothesis,
              candidate.construction[:hypothesis]
            ),
          calibration_version: "construction-v1"
        }

        change =
          if current do
            affected =
              current.commitments
              |> Enum.reject(fn commitment ->
                Enum.any?(retained, &(&1.id == commitment.id))
              end)
              |> Enum.map(& &1.candidate_id)

            FleetAllocation.replan_subgraph(
              scope,
              generation.id,
              selected,
              if(affected == [], do: [chosen.candidate_id], else: affected),
              decision
            )
          else
            FleetAllocation.publish_portfolio(scope, generation.id, selected, decision)
          end

        with {:ok, portfolio} <- change,
             commitment <-
               Enum.find(portfolio.commitments, &(&1.candidate_id == chosen.candidate_id)) do
          dispatch_construction_candidate(
            agent,
            revision,
            portfolio,
            commitment,
            candidate,
            candidates
          )
        end
      end
    else
      [] -> release_failed_construction(scope, generation, revision, current)
      nil -> {:error, :construction_sourcing_unavailable}
      error -> error
    end
  end

  defp dispatch_construction_candidate(
         agent,
         revision,
         portfolio,
         commitment,
         candidate,
         candidates
       ) do
    case commitment.claims do
      [ship_symbol] ->
        if candidate.kind == :cargo_transfer do
          hauler =
            Enum.find(portfolio.commitments, fn item ->
              Enum.any?(item.dependencies, &(&1["candidate_id"] == candidate.id))
            end)

          delivery = Enum.find(candidates, &(&1.id == hauler.candidate_id))

          handoff = %{
            type: "construction",
            system: delivery.construction.system,
            waypoint: delivery.destination_waypoint,
            trade_symbol: delivery.trade_symbol
          }

          result =
            if candidate.resource do
              candidate = %{candidate | transfer: Map.put(candidate.transfer, :delivery, handoff)}

              Intents.request_commitment_resources(
                agent,
                commitment,
                portfolio,
                ship_symbol,
                candidate
              )
            else
              Intents.request_commitment_transfer(agent, commitment, hauler, portfolio, %{
                source_ship: ship_symbol,
                target_ship: hd(hauler.claims),
                trade_symbol: candidate.trade_symbol,
                units: candidate.transfer.units,
                delivery: handoff
              })
            end

          case result do
            {:ok, %{status: "completed", type: "acquire_resources"} = production} ->
              FleetExecution.continue_after_intent(agent, commitment, portfolio, production)

            {:ok, %{status: "completed"} = transfer} ->
              FleetExecution.continue_after_intent(agent, commitment, portfolio, transfer)

            other ->
              other
          end
        else
          dispatch(agent, revision, portfolio, commitment, ship_symbol, candidate)
        end

      _ ->
        {:error, :construction_sourcing_unavailable}
    end
  end

  defp release_failed_construction(scope, generation, revision, current) do
    failed = FleetAllocation.failed_candidate_ids(generation.id)

    affected =
      if current,
        do:
          current.commitments
          |> Enum.filter(&construction_commitment?/1)
          |> Enum.map(& &1.candidate_id)
          |> Enum.filter(&MapSet.member?(failed, &1)),
        else: []

    if affected != [] do
      FleetAllocation.replan_subgraph(
        scope,
        generation.id,
        %{
          revision_id: revision.id,
          source_version: generation.allocation_version,
          commitments: [],
          rejected: []
        },
        affected,
        %{
          evidence_references: [],
          expectations: %{reason: :failed_construction_dependency},
          calibration_version: "construction-v1"
        }
      )
    else
      {:error, :construction_sourcing_unavailable}
    end
  end

  defp constructions_from_candidates(candidates) do
    candidates
    |> Enum.filter(&(&1.kind == :construction_delivery))
    |> Enum.map(fn candidate ->
      %{
        outcome: {:construction, candidate.destination_waypoint, candidate.trade_symbol},
        remaining: candidate.expected_outcomes.units_remaining
      }
    end)
    |> Enum.uniq_by(& &1.outcome)
  end

  defp dispatch(
         agent,
         _revision,
         portfolio,
         commitment,
         ship_symbol,
         %{kind: :construction_delivery, construction: %{source: :cargo}} = candidate
       ) do
    Intents.request_commitment_construction_delivery(
      agent,
      commitment,
      portfolio,
      ship_symbol,
      delivery(candidate)
    )
  end

  defp dispatch(
         agent,
         revision,
         portfolio,
         commitment,
         ship_symbol,
         %{kind: :construction_delivery} = candidate
       ) do
    floor =
      case StandingAuthority.credit_floor(revision) do
        {:ok, amount} -> amount
        _ -> 0
      end

    case Intents.request_commitment_round_trip(agent, commitment, portfolio, ship_symbol, %{
           source_waypoint: candidate.source_waypoint,
           destination_waypoint: candidate.destination_waypoint,
           trade_symbol: candidate.trade_symbol,
           units: candidate.construction.batch_units,
           purchase_price: candidate.construction.max_price,
           reserve_credits: floor + 750,
           construction: %{
             system: candidate.construction.system,
             waypoint: candidate.construction.waypoint
           }
         }) do
      {:ok, %{status: "completed"} = buy} ->
        FleetExecution.continue_after_intent(agent, commitment, portfolio, buy)

      other ->
        other
    end
  end

  defp dispatch(
         agent,
         revision,
         portfolio,
         commitment,
         ship_symbol,
         %{kind: :construction_upstream} = candidate
       ) do
    floor =
      case StandingAuthority.credit_floor(revision) do
        {:ok, amount} -> amount
        _ -> 0
      end

    Intents.request_commitment_round_trip(agent, commitment, portfolio, ship_symbol, %{
      source_waypoint: candidate.source_waypoint,
      destination_waypoint: candidate.destination_waypoint,
      trade_symbol: candidate.trade_symbol,
      units: candidate.construction.batch_units,
      purchase_price: candidate.construction.max_price,
      reserve_credits: floor + 750,
      construction_upstream: %{
        system: candidate.construction.system,
        waypoint: candidate.construction.waypoint,
        part_symbol: candidate.construction.part_symbol,
        baseline_price: candidate.construction.baseline_price,
        baseline_supply: candidate.construction.baseline_supply,
        expected_supply: candidate.expected_outcomes.market_effect.supply,
        expected_price: candidate.expected_outcomes.market_effect.purchase_price
      }
    })
  end

  defp delivery(candidate) do
    %{
      system: candidate.construction.system,
      waypoint: candidate.construction.waypoint,
      trade_symbol: candidate.trade_symbol,
      units: candidate.construction.batch_units
    }
  end

  defp read_projects(agent, scope) do
    known_construction =
      Repo.all(
        from o in Observation,
          where: o.agent_id == ^agent.id and like(o.subject, "construction:%"),
          select: o.subject,
          distinct: true
      )

    under_construction =
      Repo.all(
        from o in Observation,
          where: o.agent_id == ^agent.id and like(o.subject, "waypoint:%"),
          order_by: [desc: o.observed_at, desc: o.id]
      )
      |> Enum.uniq_by(& &1.subject)
      |> Enum.filter(&(&1.facts["is_under_construction"] == true))
      |> Enum.map(&String.replace_prefix(&1.subject, "waypoint:", "construction:"))

    pledged =
      case FleetAllocation.current_portfolio(scope, agent) do
        %{commitments: commitments} ->
          for commitment <- commitments,
              %{"outcome" => ["construction", waypoint, _symbol]} <- commitment.pledges,
              {:ok, system} <- [Fleet.system_from_headquarters(waypoint)],
              do: "construction:#{system}:#{waypoint}"

        _ ->
          []
      end

    (known_construction ++ under_construction ++ pledged)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce({[], []}, fn subject, {projects, unavailable} ->
      case String.split(subject, ":") do
        ["construction", system, waypoint] ->
          case read_project(agent, system, waypoint) do
            {:ok, construction} ->
              observed_at = DateTime.utc_now()

              observation = %{
                system_symbol: system,
                construction: construction,
                observed_at: observed_at,
                evidence_id: Evidence.fingerprint(construction)
              }

              {[observation | projects], unavailable}

            _error ->
              {projects, [subject | unavailable]}
          end

        _ ->
          {projects, unavailable}
      end
    end)
    |> then(fn {projects, unavailable} -> {:ok, Enum.reverse(projects), unavailable} end)
  end

  defp read_project(agent, system, waypoint) do
    case Agent.handle_game_result(
           agent,
           Evidence.get_construction(AgentTokenReference.new(agent), system, waypoint)
         ) do
      {:ok, %Construction{} = construction} = result ->
        Fleet.record_construction_observation(agent, system, construction, "get_construction")
        result

      error ->
        error
    end
  end

  defp pending_purchase(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{commitments: commitments} = portfolio when commitments != [] ->
        Enum.find_value(commitments, fn commitment ->
          intent =
            Repo.one(
              from i in Intent,
                where: i.fleet_commitment_id == ^commitment.id,
                order_by: [desc: i.id],
                limit: 1
            )

          case intent do
            %Intent{
              type: "buy",
              status: "completed",
              last_action_result: %{"units" => units},
              parameters: %{"market_trade" => %{"construction" => _}}
            } = buy
            when is_integer(units) and units > 0 ->
              {commitment, portfolio, buy}

            %Intent{
              type: "buy",
              status: "completed",
              last_action_result: %{"units" => units},
              parameters: %{"market_trade" => %{"construction_upstream" => _}}
            } = buy
            when is_integer(units) and units > 0 ->
              {commitment, portfolio, buy}

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  defp pending_transfer(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{commitments: commitments} = portfolio ->
        Enum.find_value(commitments, fn commitment ->
          case Repo.one(
                 from i in Intent,
                   where: i.fleet_commitment_id == ^commitment.id and i.type == "transfer",
                   order_by: [desc: i.id],
                   limit: 1
               ) do
            %Intent{
              status: "completed",
              parameters: %{"transfer_delivery" => %{"type" => "construction"}}
            } = transfer ->
              hauler =
                Enum.find(commitments, fn other ->
                  Enum.any?(other.dependencies, &(&1["candidate_id"] == commitment.candidate_id))
                end)

              if hauler &&
                   Repo.exists?(
                     from i in Intent,
                       where: i.fleet_commitment_id == ^hauler.id and i.type == "deliver"
                   ),
                 do: nil,
                 else: {commitment, portfolio, transfer}

            _ ->
              nil
          end
        end)

      _ ->
        nil
    end
  end

  defp pending_production(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{commitments: commitments} = portfolio ->
        Enum.find_value(commitments, fn commitment ->
          production =
            Repo.one(
              from i in Intent,
                where: i.fleet_commitment_id == ^commitment.id and i.type == "acquire_resources",
                order_by: [desc: i.id],
                limit: 1
            )

          if match?(
               %Intent{
                 status: "completed",
                 parameters: %{"transfer" => %{"delivery" => %{"type" => "construction"}}}
               },
               production
             ) and
               not Repo.exists?(
                 from i in Intent,
                   where: i.fleet_commitment_id == ^commitment.id and i.type == "transfer"
               ),
             do: {commitment, portfolio, production},
             else: nil
        end)

      _ ->
        nil
    end
  end

  defp settle_upstream_sale(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{strategy_decision_episode: %{classification: :still_evaluating}, commitments: commitments} =
          portfolio ->
        commitments
        |> Enum.find_value(fn commitment ->
          Repo.one(
            from i in Intent,
              where:
                i.fleet_commitment_id == ^commitment.id and
                  i.type == "sell" and i.status == "completed",
              order_by: [desc: i.id],
              limit: 1
          )
        end)
        |> case do
          %Intent{parameters: %{"market_trade" => %{"construction_upstream" => _}}} = sell ->
            case reconcile_upstream_sale(agent, portfolio, sell) do
              {:ok, _} -> :ok
              error -> error
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp retained_upstream_opportunities(scope, agent) do
    case FleetAllocation.current_portfolio(scope, agent) do
      %{
        strategy_decision_episode: %{
          classification: :still_evaluating,
          expectations: %{"upstream_hypothesis" => %{} = stored}
        }
      } ->
        with {:ok, observed_at, _} <- DateTime.from_iso8601(stored["observed_at"] || ""),
             true <- is_binary(stored["evidence_id"]) do
          [
            %{
              part_symbol: stored["part_symbol"],
              raw_symbol: stored["raw_symbol"],
              source_waypoint: stored["source_waypoint"],
              destination_waypoint: stored["destination_waypoint"],
              expected_part_units: stored["expected_part_units"],
              expected_supply: stored["expected_supply"],
              expected_purchase_price: stored["expected_purchase_price"],
              evidence_id: stored["evidence_id"],
              observed_at: observed_at
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp construction_portfolio?(portfolio) do
    Enum.any?(portfolio.commitments, &construction_commitment?/1)
  end

  defp current_generation(agent) do
    Repo.one(
      from g in Generation,
        where:
          g.agent_id == ^agent.id and
            is_nil(g.fenced_at) and is_nil(g.retired_at)
    )
  end
end
