defmodule SpaceTraders.RecordedFamilyInterruptionTest do
  @moduledoc """
  The #507 interruption matrix for every recorded Ship family.

  Each family enters through the live Intent seam (`Intents.execute_action/4`)
  under owned Claim authority; the sender dies at one protocol boundary, a
  separate PostgreSQL session observes what committed, and production boot
  (`Intents.rearm_on_boot/0`) recovers. The controlled game owns transport
  effects. Expected recovery comes from each kind's declared recovery
  description: an unchanged Ship proves absence only where absence is provable.
  """

  # Real commits, a separate observer session, and the shared ShipServer runtime.
  use ExUnit.Case, async: false

  import Ecto.Query
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.Fleet.{Intent, Intents, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents.Recovery
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.{Repo, RuntimeDeath, SafetyFence}

  # {boundary, committed attempt state, game effect applied}
  @phases [
    {:before_preparation, nil, false},
    {:preparation_write, nil, false},
    {:prepared, "prepared", false},
    {:marker_write, "prepared", false},
    {:marker_committed, "sent_or_unknown", false},
    {:transport_authorized, "sent_or_unknown", false},
    {:transport_before_accept, "sent_or_unknown", false},
    {:accepted, "sent_or_unknown", true},
    {:response_delivered, "sent_or_unknown", true},
    {:outcome_write, "sent_or_unknown", true},
    {:outcome_committed, "succeeded", true}
  ]

  @families ~w(dock navigate refuel jump buy sell contract construction transfer scan_waypoints chart extract siphon survey refine install_module remove_module)

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Req.Test.set_req_test_to_shared(SpaceTraders.API)
    restart_capacity_governor()
    observer = start_supervised!({Postgrex, connection_options()})

    on_exit(fn ->
      ShipServer.stop_all()
      restart_capacity_governor()
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()
      :ok = Sandbox.mode(Repo, :manual)
    end)

    {:ok, observer: observer}
  end

  for family <- @families, {phase, committed, accepted} <- @phases do
    @family family
    @phase phase
    @committed committed
    @accepted accepted
    test "#{@family} runtime death at #{@phase} recovers from committed evidence without blind replay",
         %{observer: observer} do
      %{spec: spec, game: game, sender: sender, monitor: monitor} = interrupt(@family, @phase)
      assert_receive {:boundary, ^sender, @phase, sender_backend}, 5_000
      assert observer_backend(observer) != sender_backend
      before = observe(observer, spec)

      if @committed do
        assert [[_id, @committed, sent_at]] = before.attempts
        assert is_nil(sent_at) == (@committed == "prepared")
        assert [[_action, attempt_id]] = before.intent
        assert is_binary(attempt_id)
      else
        assert before.attempts == []
        assert [[nil, nil]] = before.intent
      end

      assert sends(game, spec) == if(@accepted, do: 1, else: 0)

      RuntimeDeath.kill(sender, sender_backend)
      assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}
      assert observe(observer, spec) == before

      restart_runtime()

      # Nothing durable was selected: the restarted runtime selects the same
      # action again through the live seam.
      if is_nil(@committed), do: live_dispatch(spec)

      assert :ok = Intents.rearm_on_boot()
      assert_recovered(spec, game, @committed, @accepted)

      # A later boot over settled or fenced evidence never adds a send.
      restart_runtime()
      assert :ok = Intents.rearm_on_boot()
      assert_recovered(spec, game, @committed, @accepted)
      assert other_posts(game, spec) == []
    end
  end

  for family <- @families,
      {phase, disposition} <- [prepared: "not_sent", marker_committed: "ambiguous"],
      loss <- [:claim, :generation, :emergency_stop] do
    @family family
    @phase phase
    @disposition disposition
    @loss loss
    test "#{@family} #{@loss} lost at #{@phase} suppresses transport and boot never adds a send",
         %{observer: observer} do
      %{spec: spec, game: game, sender: sender, monitor: monitor} = interrupt(@family, @phase)
      assert_receive {:boundary, ^sender, @phase, _backend}, 5_000
      revoke(@loss, spec)
      send(sender, :continue)
      assert_receive {:DOWN, ^monitor, :process, ^sender, :normal}, 5_000

      assert [[id, @disposition, sent_at]] = observe(observer, spec).attempts
      assert is_nil(sent_at) == (@phase == :prepared)
      assert sends(game, spec) == 0

      for _boot <- 1..2 do
        restart_runtime()
        assert :ok = Intents.rearm_on_boot()
      end

      assert sends(game, spec) == 0
      assert Elixir.Agent.get(game, & &1.posts) == []
      retained = MutationAttempts.get!(id)
      refute retained.retry_authorized
      refute Enum.any?(MutationAttempts.list_for_agent(spec.agent), &(&1.retry_of_id == id))
    end
  end

  # -- expectations -----------------------------------------------------------

  defp assert_recovered(spec, game, committed, accepted) do
    attempts =
      MutationAttempts.list_for_agent(spec.agent)
      |> Enum.filter(&(&1.operation_id == spec.operation_id))

    cond do
      committed == "sent_or_unknown" and not accepted and
          Recovery.describe(spec.action).absence == :unprovable ->
        # An unchanged Ship cannot prove this action never happened.
        assert sends(game, spec) == 0
        assert [unknown] = attempts
        assert unknown.state in ["sent_or_unknown", "ambiguous"]
        assert SafetyFence.active?(unknown)
        refute unknown.retry_authorized

      committed == "sent_or_unknown" and not accepted ->
        assert sends(game, spec) == 1
        assert [absent, retry] = attempts
        assert absent.state == "absent"
        refute absent.retry_authorized
        assert retry.retry_of_id == absent.id
        assert retry.state in ["succeeded", "accepted"]

      true ->
        assert sends(game, spec) == 1
        assert [settled] = attempts
        assert settled.state in ["succeeded", "accepted"]
        refute SafetyFence.active?(settled)
    end
  end

  # -- families ---------------------------------------------------------------

  defp family("dock") do
    fixture = claimed_ship()
    ship = fixture.ship

    fixture
    |> owned_intent(type: "navigate", target_waypoint: "X1-UX81-A1")
    |> Map.merge(%{
      action: %{"kind" => "dock", "waypoint" => "X1-UX81-A1"},
      operation_id: "dock-ship",
      post_path: "/v2/my/ships/#{ship.symbol}/dock",
      get: fn path, state ->
        if path == ship_path(ship) do
          ship_body(ship.symbol, %{
            "nav" => nav_body(if(state.applied_at, do: "DOCKED", else: "IN_ORBIT"))
          })
        end
      end,
      response: fn _state -> %{"nav" => nav_body("DOCKED")} end
    })
  end

  defp family("navigate") do
    fixture = claimed_ship() |> owned_intent(type: "navigate", target_waypoint: "X1-UX81-A2")
    ship = fixture.ship
    arrival = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    transit = nav_body("IN_TRANSIT", destination: "X1-UX81-A2", arrival: arrival)

    Map.merge(fixture, %{
      action: %{
        "kind" => "navigate",
        "waypoint" => "X1-UX81-A2",
        "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A2"}
      },
      operation_id: "navigate-ship",
      post_path: ship_path(ship) <> "/navigate",
      get: fn path, state ->
        if path == ship_path(ship) do
          ship_body(ship.symbol, %{
            "nav" => if(state.applied_at, do: transit, else: nav_body("IN_ORBIT")),
            "fuel" => %{"capacity" => 200, "current" => if(state.applied_at, do: 140, else: 150)}
          })
        end
      end,
      response: fn _state ->
        %{"fuel" => %{"capacity" => 200, "current" => 140}, "nav" => transit}
      end
    })
  end

  defp family(kind) when kind in ["refuel", "jump"] do
    destination = if kind == "jump", do: "X1-UX81-A2", else: "X1-UX81-A1"
    fixture = claimed_ship() |> owned_intent(type: "navigate", target_waypoint: destination)
    %{agent: agent, ship: ship} = fixture

    Map.merge(fixture, %{
      action: %{
        "kind" => kind,
        "waypoint" => destination,
        "fuel_before" => 150,
        "credits_before" => 1000
      },
      operation_id: if(kind == "jump", do: "jump-ship", else: "refuel-ship"),
      post_path: ship_path(ship) <> "/" <> kind,
      get: fn
        "/v2/my/agent", state ->
          %{"symbol" => agent.symbol, "credits" => if(state.applied_at, do: 900, else: 1000)}

        path, state ->
          if path == ship_path(ship) do
            sent = not is_nil(state.applied_at)

            ship_body(ship.symbol, %{
              "nav" =>
                nav_body("DOCKED", destination: if(sent, do: destination, else: "X1-UX81-A1")),
              "fuel" => %{"current" => if(sent, do: 200, else: 150), "capacity" => 200}
            })
          end
      end,
      response: fn _state ->
        %{
          "agent" => %{"symbol" => agent.symbol, "credits" => 900},
          "transaction" => %{
            "type" => "PURCHASE",
            "shipSymbol" => ship.symbol,
            "tradeSymbol" => "FUEL",
            "waypointSymbol" => "X1-UX81-A1",
            "units" => 50,
            "pricePerUnit" => 2,
            "totalPrice" => 100
          },
          "cooldown" => %{
            "shipSymbol" => ship.symbol,
            "remainingSeconds" => 0,
            "totalSeconds" => 0
          },
          "nav" => nav_body("DOCKED", destination: destination),
          "fuel" => %{"current" => 200, "capacity" => 200}
        }
      end
    })
  end

  defp family(kind) when kind in ["buy", "sell"] do
    fixture =
      claimed_ship()
      |> owned_intent(
        type: kind,
        target_waypoint: "X1-UX81-A1",
        parameters: %{"trade_symbol" => "IRON_ORE", "units" => 5}
      )

    %{agent: agent, ship: ship} = fixture
    {before_units, after_units} = if kind == "buy", do: {0, 5}, else: {5, 0}
    after_credits = if kind == "buy", do: 950, else: 1050

    Map.merge(fixture, %{
      action: %{
        "kind" => kind,
        "trade_symbol" => "IRON_ORE",
        "units" => 5,
        "listing_price" => 10,
        "cargo_before" => before_units,
        "credits_before" => 1000
      },
      operation_id: if(kind == "buy", do: "purchase-cargo", else: "sell-cargo"),
      post_path: ship_path(ship) <> if(kind == "buy", do: "/purchase", else: "/sell"),
      get: fn
        "/v2/my/agent", state ->
          %{
            "symbol" => agent.symbol,
            "credits" => if(state.applied_at, do: after_credits, else: 1000)
          }

        # A retry re-establishes Market eligibility from fresh evidence.
        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", _state ->
          %{
            "symbol" => "X1-UX81-A1",
            "tradeGoods" => [
              %{
                "symbol" => "IRON_ORE",
                "purchasePrice" => 10,
                "sellPrice" => 10,
                "tradeVolume" => 10,
                "supply" => "HIGH",
                "type" => "EXPORT"
              }
            ]
          }

        path, state ->
          if path == ship_path(ship) do
            units = if state.applied_at, do: after_units, else: before_units
            ship_body(ship.symbol, %{"nav" => nav_body("DOCKED"), "cargo" => iron_cargo(units)})
          end
      end,
      response: fn _state ->
        %{
          "agent" => %{"symbol" => agent.symbol, "credits" => after_credits},
          "cargo" => iron_cargo(after_units),
          "transaction" => %{
            "type" => if(kind == "buy", do: "PURCHASE", else: "SELL"),
            "shipSymbol" => ship.symbol,
            "tradeSymbol" => "IRON_ORE",
            "waypointSymbol" => "X1-UX81-A1",
            "units" => 5,
            "pricePerUnit" => 10,
            "totalPrice" => 50
          }
        }
      end
    })
  end

  defp family(recipient_family) when recipient_family in ["contract", "construction"] do
    recipient =
      if recipient_family == "contract",
        do: %{"type" => "contract", "contract_id" => "ctr-matrix", "waypoint" => "X1-UX81-A1"},
        else: %{"type" => "construction", "system" => "X1-UX81", "waypoint" => "X1-UX81-A1"}

    fixture =
      claimed_ship()
      |> owned_intent(
        type: "deliver",
        target_waypoint: "X1-UX81-A1",
        parameters: %{"trade_symbol" => "IRON_ORE", "units" => 1, "recipient" => recipient}
      )

    ship = fixture.ship
    fulfilled = fn state -> if state.applied_at, do: 5, else: 4 end

    contract = fn state ->
      %{
        "id" => "ctr-matrix",
        "accepted" => true,
        "fulfilled" => false,
        "terms" => %{
          "deadline" => "2099-01-01T00:00:00Z",
          "payment" => %{},
          "deliver" => [
            %{
              "tradeSymbol" => "IRON_ORE",
              "destinationSymbol" => "X1-UX81-A1",
              "unitsRequired" => 6,
              "unitsFulfilled" => fulfilled.(state)
            }
          ]
        }
      }
    end

    construction = fn state ->
      %{
        "symbol" => "X1-UX81-A1",
        "isComplete" => false,
        "materials" => [
          %{"tradeSymbol" => "IRON_ORE", "required" => 6, "fulfilled" => fulfilled.(state)}
        ]
      }
    end

    Map.merge(fixture, %{
      action: %{
        "kind" => "deliver",
        "trade_symbol" => "IRON_ORE",
        "units" => 1,
        "cargo_before" => 12,
        "fulfilled_before" => 4,
        "recipient" => recipient
      },
      operation_id:
        if(recipient_family == "contract", do: "deliver-contract", else: "supply-construction"),
      post_path:
        if(recipient_family == "contract",
          do: "/v2/my/contracts/ctr-matrix/deliver",
          else: "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply"
        ),
      get: fn
        "/v2/my/contracts", state ->
          [contract.(state)]

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction", state ->
          construction.(state)

        path, state ->
          if path == ship_path(ship) do
            units = if state.applied_at, do: 11, else: 12
            ship_body(ship.symbol, %{"nav" => nav_body("DOCKED"), "cargo" => iron_cargo(units)})
          end
      end,
      response: fn state ->
        if recipient_family == "contract",
          do: %{"cargo" => iron_cargo(11), "contract" => contract.(state)},
          else: %{"cargo" => iron_cargo(11), "construction" => construction.(state)}
      end
    })
  end

  defp family("transfer") do
    fixture =
      claimed_ship(
        ships: ["1", "2"],
        reservations: %{},
        candidates: fn revision, [source, target] ->
          [
            %PortfolioCandidate{
              id: "producer",
              strategy_revision_id: revision.id,
              objective_index: 0,
              claims: [source],
              reservations: %{},
              pledges: [
                %{
                  outcome: {:cargo_transfer, source, target, "IRON_ORE"},
                  amount: 4,
                  backing: {:claim, source}
                }
              ],
              dependencies: [],
              expected_value: 1,
              unwind_cost: 0
            },
            %PortfolioCandidate{
              id: "receiver",
              strategy_revision_id: revision.id,
              objective_index: 0,
              claims: [target],
              reservations: %{"cargo_capacity:#{target}" => 4},
              pledges: [
                %{
                  outcome: {:construction, "X1-UX81-A1", "IRON_ORE"},
                  amount: 4,
                  backing: {:dependency, "cargo"}
                }
              ],
              dependencies: [
                %{id: "cargo", kind: :acquisition, candidate_id: "producer", amount: 4}
              ],
              expected_value: 2,
              unwind_cost: 0
            }
          ]
        end,
        selection_reservations: fn [_source, target] -> %{"cargo_capacity:#{target}" => 40} end,
        outcome_remaining: %{{:construction, "X1-UX81-A1", "IRON_ORE"} => 4}
      )

    [source, target] = fixture.ships

    fixture =
      owned_intent(fixture,
        type: "transfer",
        target_waypoint: "X1-UX81-A1",
        parameters: %{"target_ship" => target.symbol, "trade_symbol" => "IRON_ORE", "units" => 4}
      )

    Map.merge(fixture, %{
      action: %{
        "kind" => "transfer",
        "target_ship" => target.symbol,
        "trade_symbol" => "IRON_ORE",
        "units" => 4,
        "source_before" => 12,
        "target_before" => 0
      },
      operation_id: "transfer-cargo",
      post_path: ship_path(source) <> "/transfer",
      get: fn path, state ->
        sent = not is_nil(state.applied_at)

        cond do
          path == ship_path(source) ->
            ship_body(source.symbol, %{"cargo" => iron_cargo(if(sent, do: 8, else: 12))})

          path == ship_path(target) ->
            ship_body(target.symbol, %{"cargo" => iron_cargo(if(sent, do: 4, else: 0))})

          true ->
            nil
        end
      end,
      response: fn _state -> %{"cargo" => iron_cargo(8)} end,
      # Selection carries the exact preflight observations of both Ships.
      complete: fn spec ->
        {:ok, from} = Evidence.get_ship_binding(spec.agent, source.symbol)
        {:ok, to} = Evidence.get_ship_binding(spec.agent, target.symbol)

        update_in(spec.action, fn action ->
          action
          |> Map.put("source_observation_id", from.observation.id)
          |> Map.put("target_observation_id", to.observation.id)
        end)
      end
    })
  end

  defp family(kind) when kind in ["scan_waypoints", "chart"] do
    fixture =
      claimed_ship()
      |> owned_intent(
        type: "acquire_intelligence",
        target_waypoint: "X1-UX81-A1",
        parameters: %{
          "system" => "X1-UX81",
          "subject_type" => "waypoint",
          "required_facts" => [if(kind == "chart", do: "chart", else: "traits")],
          "freshness_seconds" => 300
        }
      )

    %{agent: agent, ship: ship} = fixture

    waypoint = fn state ->
      base = %{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 0,
        "y" => 0,
        "traits" => [],
        "orbitals" => []
      }

      if kind == "chart" and state.applied_at,
        do: Map.put(base, "chart", chart(agent, state)),
        else: base
    end

    cooldown = fn state ->
      %{
        "shipSymbol" => ship.symbol,
        "totalSeconds" => 60,
        "remainingSeconds" => 60,
        "expiration" => state.applied_at |> DateTime.add(60) |> DateTime.to_iso8601()
      }
    end

    Map.merge(fixture, %{
      action: %{"kind" => kind, "waypoint" => "X1-UX81-A1"},
      operation_id: if(kind == "chart", do: "create-chart", else: "create-ship-waypoint-scan"),
      post_path: ship_path(ship) <> if(kind == "chart", do: "/chart", else: "/scan/waypoints"),
      get: fn
        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1", state ->
          waypoint.(state)

        path, state ->
          cond do
            path != ship_path(ship) ->
              nil

            kind == "scan_waypoints" and state.applied_at ->
              ship_body(ship.symbol, %{"cooldown" => cooldown.(state)})

            true ->
              ship_body(ship.symbol)
          end
      end,
      response: fn state ->
        if kind == "chart",
          do: %{"chart" => chart(agent, state), "waypoint" => waypoint.(state)},
          else: %{"cooldown" => cooldown.(state), "waypoints" => [waypoint.(state)]}
      end
    })
  end

  defp family(kind) when kind in ["extract", "siphon", "survey", "refine"] do
    fixture =
      claimed_ship()
      |> owned_intent(
        type: "acquire_resources",
        target_waypoint: "X1-UX81-A1",
        # Survey is selected within an extraction Intent.
        parameters: %{
          "mode" => if(kind == "survey", do: "extract", else: kind),
          "produce" => "IRON"
        }
      )

    ship = fixture.ship
    before = iron_cargo(100, 200)

    effect = fn state ->
      {units, inventory} =
        case kind do
          "refine" -> {10, [%{"symbol" => "IRON", "units" => 10}]}
          "survey" -> {100, [%{"symbol" => "IRON_ORE", "units" => 100}]}
          _ -> {105, [%{"symbol" => "IRON_ORE", "units" => 105}]}
        end

      %{
        "cargo" => %{"capacity" => 200, "units" => units, "inventory" => inventory},
        "cooldown" => %{
          "shipSymbol" => ship.symbol,
          "totalSeconds" => 60,
          "remainingSeconds" => 60,
          "expiration" => state.applied_at |> DateTime.add(60) |> DateTime.to_iso8601()
        }
      }
    end

    Map.merge(fixture, %{
      action: %{
        "kind" => kind,
        "waypoint" => "X1-UX81-A1",
        "cargo_before" => before,
        "produce" => "IRON",
        "trade_symbol" => "IRON_ORE",
        "units" => 5
      },
      operation_id:
        %{
          "extract" => "extract-resources",
          "siphon" => "siphon-resources",
          "survey" => "create-survey",
          "refine" => "ship-refine"
        }[kind],
      post_path: ship_path(ship) <> "/" <> kind,
      get: fn path, state ->
        cond do
          path != ship_path(ship) ->
            nil

          state.applied_at ->
            ship_body(ship.symbol, Map.put(effect.(state), "nav", nav_body("IN_ORBIT")))

          true ->
            ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT"), "cargo" => before})
        end
      end,
      response: fn state ->
        base = effect.(state)

        case kind do
          "survey" ->
            Map.put(base, "surveys", [
              %{
                "symbol" => "X1-UX81-A1",
                "signature" => "MATRIX-SURVEY",
                "expiration" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                "size" => "SMALL",
                "deposits" => [%{"symbol" => "IRON_ORE"}]
              }
            ])

          "refine" ->
            Map.merge(base, %{
              "produced" => [%{"tradeSymbol" => "IRON", "units" => 10}],
              "consumed" => [%{"tradeSymbol" => "IRON_ORE", "units" => 100}]
            })

          _ ->
            Map.put(base, if(kind == "extract", do: "extraction", else: "siphon"), %{
              "shipSymbol" => ship.symbol,
              "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
            })
        end
      end
    })
  end

  defp family(kind) when kind in ["install_module", "remove_module"] do
    module = "MODULE_SURVEY_SUITE_I"

    fixture =
      claimed_ship()
      |> owned_intent(
        type: kind,
        target_waypoint: "X1-UX81-A2",
        parameters: %{"module_symbol" => module}
      )

    %{agent: agent, ship: ship} = fixture
    install = kind == "install_module"

    body = fn fitted ->
      ship_body(ship.symbol, %{
        "nav" => nav_body("DOCKED", destination: "X1-UX81-A2"),
        "modules" => if(fitted, do: [%{"symbol" => module}], else: []),
        "cargo" =>
          if(fitted,
            do: iron_cargo(12),
            else: %{
              "capacity" => 40,
              "units" => 13,
              "inventory" => [
                %{"symbol" => "IRON_ORE", "units" => 12},
                %{"symbol" => module, "units" => 1}
              ]
            }
          )
      })
    end

    Map.merge(fixture, %{
      action: %{
        "kind" => kind,
        "module_symbol" => module,
        "quantity" => 1,
        "installed_before" => if(install, do: 0, else: 1),
        "cargo_before" => if(install, do: 1, else: 0)
      },
      operation_id: if(install, do: "install-ship-module", else: "remove-ship-module"),
      post_path: ship_path(ship) <> if(install, do: "/modules/install", else: "/modules/remove"),
      get: fn
        "/v2/my/agent", _state ->
          %{"symbol" => agent.symbol, "credits" => 18_000}

        path, state ->
          # Installing fits the module from Cargo; removal returns it to Cargo.
          if path == ship_path(ship), do: body.(install == not is_nil(state.applied_at))
      end,
      response: fn _state ->
        fitted = body.(install)

        %{
          "agent" => %{"symbol" => agent.symbol, "credits" => 18_000},
          "modules" => fitted["modules"],
          "cargo" => fitted["cargo"],
          "transaction" => %{
            "waypointSymbol" => "X1-UX81-A2",
            "shipSymbol" => ship.symbol,
            "tradeSymbol" => module,
            "type" => if(install, do: "INSTALL", else: "REMOVE"),
            "units" => 1,
            "perUnit" => 0,
            "totalPrice" => 0,
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        }
      end
    })
  end

  defp chart(agent, state) do
    %{
      "waypointSymbol" => "X1-UX81-A1",
      "submittedBy" => agent.symbol,
      "submittedOn" => DateTime.to_iso8601(state.applied_at)
    }
  end

  defp iron_cargo(units, capacity \\ 40) do
    %{
      "capacity" => capacity,
      "units" => units,
      "inventory" => if(units > 0, do: [%{"symbol" => "IRON_ORE", "units" => units}], else: [])
    }
  end

  defp interrupt(family, phase) do
    spec = family(family)
    barrier = :ets.new(:family_barrier, [:public, :set])
    gate = :atomics.new(1, [])
    :ets.insert(barrier, {:owner, self()})
    game = start_supervised!({Elixir.Agent, fn -> %{applied_at: nil, posts: []} end})
    install_game(spec, game, barrier, gate)
    install_barrier(phase, barrier, gate)
    spec = Map.get(spec, :complete, & &1).(spec)

    sender =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :go -> live_dispatch(spec)
           end
         end}
      )

    :ets.insert(barrier, {:sender, sender})
    monitor = Process.monitor(sender)
    send(sender, :go)
    %{spec: spec, game: game, sender: sender, monitor: monitor}
  end

  defp revoke(:claim, spec) do
    spec.portfolio
    |> Ecto.Changeset.change(superseded_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke(:generation, spec) do
    SpaceTraders.FleetGenerationAdmission.fence(spec.agent.agent_token)

    Repo.get_by!(Generation, agent_id: spec.agent.id)
    |> Ecto.Changeset.change(fenced_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke(:emergency_stop, spec) do
    assert {:ok, _} =
             SpaceTraders.FleetStrategy.engage_emergency_stop(Scope.for_operator(spec.operator))
  end

  # -- live seam and controlled game -------------------------------------------

  defp live_dispatch(spec) do
    {:ok, binding} = Evidence.get_ship_binding(spec.agent, spec.ship.symbol)
    intent = Repo.get!(Intent, spec.intent.id)
    Intents.execute_action(spec.agent, intent, Evidence.bound_ship(binding), spec.action)
  end

  defp install_game(spec, game, barrier, gate) do
    acting_ship = ship_path(spec.ship)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", path} when path == spec.post_path ->
          transport_barrier(:transport_before_accept, barrier, gate)

          state =
            Elixir.Agent.get_and_update(game, fn state ->
              state = %{state | applied_at: DateTime.utc_now(), posts: state.posts ++ [path]}
              {state, state}
            end)

          transport_barrier(:accepted, barrier, gate)
          Req.Test.json(conn, %{"data" => spec.response.(state)})

        {"POST", path} ->
          Elixir.Agent.update(game, &%{&1 | posts: &1.posts ++ [path]})

          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "unexpected #{path}"}})

        {"GET", path} ->
          if path == acting_ship, do: transport_barrier(:before_preparation, barrier, gate)

          case spec.get.(path, Elixir.Agent.get(game, & &1)) do
            nil ->
              conn
              |> Plug.Conn.put_status(404)
              |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "unexpected #{path}"}})

            data ->
              Req.Test.json(conn, %{"data" => data})
          end
      end
    end)
  end

  defp sends(game, spec),
    do: Elixir.Agent.get(game, & &1.posts) |> Enum.count(&(&1 == spec.post_path))

  defp other_posts(game, spec),
    do: Elixir.Agent.get(game, & &1.posts) |> Enum.reject(&(&1 == spec.post_path))

  defp ship_path(ship), do: "/v2/my/ships/#{ship.symbol}"

  # -- interruption boundaries --------------------------------------------------

  defp install_barrier(phase, barrier, gate) do
    id = "family-matrix-#{System.unique_integer([:positive])}"
    :ets.insert(barrier, {:phase, phase})

    :ok =
      :telemetry.attach_many(
        id,
        [
          [:spacetraders, :recorded_dispatch, :prepared],
          [:spacetraders, :recorded_dispatch, :preparation_written],
          [:spacetraders, :recorded_dispatch, :marker_written],
          [:spacetraders, :recorded_dispatch, :marker_committed],
          [:spacetraders, :recorded_dispatch, :transport_authorized],
          [:spacetraders, :mutation_attempts, :outcome_written],
          [:spacetraders, :mutation_attempts, :outcome_committed],
          [:spacetraders, :api, :request]
        ],
        &__MODULE__.boundary/4,
        {self(), barrier, gate}
      )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def boundary([:spacetraders, :api, :request], _, metadata, {owner, barrier, gate}) do
    if metadata.operation_classification == :mutation,
      do: transport_barrier(:response_delivered, barrier, gate, owner)
  end

  def boundary([:spacetraders, _owner, event], _, metadata, {owner, barrier, gate}) do
    phase =
      case event do
        :preparation_written -> :preparation_write
        :marker_written -> :marker_write
        :outcome_written -> :outcome_write
        other -> other
      end

    if Map.get(metadata, :classification, :succeeded) == :succeeded,
      do: transport_barrier(phase, barrier, gate, owner)
  end

  defp transport_barrier(phase, barrier, gate, owner \\ nil) do
    with [{:phase, ^phase}] <- :ets.lookup(barrier, :phase),
         [{:sender, sender}] when sender == self() <- :ets.lookup(barrier, :sender),
         :ok <- :atomics.compare_exchange(gate, 1, 0, 1) do
      [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
      [{:owner, test}] = :ets.lookup(barrier, :owner)
      send(owner || test, {:boundary, self(), phase, backend})

      receive do
        :continue -> :ok
      after
        10_000 -> raise "interrupted sender was not stopped: #{phase}"
      end
    else
      _ -> :ok
    end
  end

  # -- independent observation ----------------------------------------------------

  defp observe(observer, spec) do
    %{
      attempts:
        Postgrex.query!(
          observer,
          "SELECT id::text, state, sent_or_unknown_at FROM mutation_attempts WHERE agent_id = $1 AND operation_id = $2 ORDER BY prepared_at",
          [spec.agent.id, spec.operation_id]
        ).rows,
      intent:
        Postgrex.query!(
          observer,
          "SELECT in_flight_action->>'kind', mutation_attempt_id::text FROM intents WHERE id = $1",
          [spec.intent.id]
        ).rows
    }
  end

  defp observer_backend(observer) do
    %{rows: [[pid]]} = Postgrex.query!(observer, "SELECT pg_backend_pid()", [])
    pid
  end

  defp connection_options do
    Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database, :ssl, :socket_options])
  end

  # -- runtime --------------------------------------------------------------------

  defp restart_runtime do
    ShipServer.stop_all()
    restart_capacity_governor()
  end

  defp restart_capacity_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _pid} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    :ok
  end

  # -- owned authority fixture ------------------------------------------------------

  defp owned_intent(fixture, attrs) do
    intent =
      Repo.insert!(
        struct(
          Intent,
          [
            ship_id: fixture.ship.id,
            caller: "commitment",
            status: "active",
            fleet_commitment_id: fixture.commitment.id,
            fleet_commitment_portfolio_id: fixture.portfolio.id,
            fleet_commitment_portfolio_version: fixture.portfolio.version
          ] ++ attrs
        )
      )

    Map.put(fixture, :intent, intent)
  end

  defp claimed_ship(opts \\ []) do
    unique = System.unique_integer([:positive])
    operator = operator_fixture()
    agent = agent_fixture(operator, %{symbol: "MATRIX#{unique}", agent_token: "TOKEN#{unique}"})
    symbols = Keyword.get(opts, :ships, ["1"]) |> Enum.map(&"#{agent.symbol}-#{&1}")

    ships =
      Enum.map(
        symbols,
        &Repo.insert!(%Ship{agent_id: agent.id, symbol: &1, ship_type: "SHIP_COMMAND_FRIGATE"})
      )

    on_exit(fn ->
      ShipServer.stop_all()

      Sandbox.unboxed_run(Repo, fn ->
        attempt_ids = Repo.all(from a in Attempt, where: a.agent_id == ^agent.id, select: a.id)
        Repo.delete_all(from o in Outcome, where: o.mutation_attempt_id in ^attempt_ids)
        Repo.delete_all(from a in Attempt, where: a.id in ^attempt_ids)

        Repo.delete_all(
          from d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id == ^agent.id
        )

        Repo.delete_all(
          from o in SpaceTraders.Evidence.Observation, where: o.agent_id == ^agent.id
        )

        topics = ["fleet:#{agent.id}", "fleet_allocation:#{operator.id}"]
        Repo.delete_all(from n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics)
        Repo.delete_all(from e in SpaceTraders.Timeline.Event, where: e.owner_id in ^symbols)
        Repo.delete!(operator)
      end)
    end)

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => [%{"objective" => "Grow credits"}], "hard_constraints" => []},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction
      })

    candidates =
      Keyword.get_lazy(opts, :candidates, fn ->
        [
          %PortfolioCandidate{
            id: "family-matrix",
            strategy_revision_id: revision.id,
            objective_index: 0,
            claims: symbols,
            reservations: %{},
            pledges: [],
            dependencies: [],
            expected_value: 1,
            unwind_cost: 0
          }
        ]
      end)

    candidates =
      if is_function(candidates), do: candidates.(revision, symbols), else: candidates

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, candidates, %{
        as_of: DateTime.utc_now(),
        source_version: generation.allocation_version,
        claims: symbols,
        reservations:
          case Keyword.get(opts, :selection_reservations) do
            nil -> %{}
            reservations -> reservations.(symbols)
          end,
        outcome_remaining: Keyword.get(opts, :outcome_remaining, %{})
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "family-matrix"
      })

    [ship | _] = ships
    commitment = Enum.find(portfolio.commitments, &(ship.symbol in &1.claims))

    %{
      agent: agent,
      ship: ship,
      ships: ships,
      portfolio: portfolio,
      commitment: commitment,
      operator: operator
    }
  end
end
