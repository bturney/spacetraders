defmodule SpaceTraders.GameplayMutationTest do
  # Runtime mutation cases share Req.Test and restart the application Reconciler.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.SafetyFence

  test "a successful gameplay mutation retains its successful outcome" do
    {agent, revision, ship, game} = negotiating_fleet(:success)

    assert {:ok, %{id: "negotiated-contract"}} =
             FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert [%{state: "succeeded", outcomes: [%{classification: "succeeded"}]} = attempt] =
             negotiation_attempts(agent)

    refute SafetyFence.active?(attempt)
    assert Elixir.Agent.get(game, & &1.negotiations) == 1
  end

  test "a rejected gameplay mutation is definitive and permits a fresh attempt" do
    {agent, revision, ship, game} = negotiating_fleet(:rejected)

    assert {:error, %API.GameplayError{code: 4000}} =
             FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert [%{state: "rejected", outcomes: [%{classification: "rejected"}]} = rejected] =
             negotiation_attempts(agent)

    refute SafetyFence.active?(rejected)

    Elixir.Agent.update(game, &%{&1 | outcome: :success})

    assert {:ok, %{id: "negotiated-contract"}} =
             FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert [retained, %{state: "succeeded"}] = negotiation_attempts(agent)
    assert retained == rejected
    assert Elixir.Agent.get(game, & &1.negotiations) == 2
  end

  test "an API outage fences negotiate-contract instead of replaying it" do
    {agent, revision, ship, game} = negotiating_fleet(:outage)

    assert {:error, _reason} = FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert [%{state: "ambiguous", outcomes: [%{classification: "ambiguous"}]} = attempt] =
             negotiation_attempts(agent)

    assert SafetyFence.active?(attempt)
    attempt_id = attempt.id

    assert {:error, %{reason: {:safety_fenced, [^attempt_id]}}} =
             FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert Elixir.Agent.get(game, & &1.negotiations) == 1
    assert [^attempt] = negotiation_attempts(agent)
  end

  test "a lost negotiate-contract response remains fenced after the reconciler restarts" do
    Req.Test.set_req_test_to_shared(SpaceTraders.API)
    previous_reconciler = start_supervised!(Reconciler)
    # Drain boot reconstruction before creating this test's Fleet Generation.
    :sys.get_state(previous_reconciler)

    {agent, revision, ship, game} = negotiating_fleet(:lost_response)

    assert {:error, _reason} = FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert [%{state: "ambiguous", outcomes: [%{classification: "ambiguous"}]} = attempt] =
             negotiation_attempts(agent)

    assert SafetyFence.active?(attempt)
    assert Elixir.Agent.get(game, & &1.applied)
    attempt_id = attempt.id

    stop_supervised!(Reconciler)
    replacement = start_supervised!(Reconciler)
    assert replacement != previous_reconciler
    # Boot queues a Fleet wakeup; drain it as well as the initial boot message.
    :sys.get_state(replacement)
    :sys.get_state(replacement)

    assert {:error, %{reason: {:safety_fenced, [^attempt_id]}}} =
             FleetContracts.negotiate_if_available(agent, revision, ship.symbol)

    assert [^attempt] = negotiation_attempts(agent)
    assert SafetyFence.active?(MutationAttempts.get!(attempt.id))

    assert Elixir.Agent.get(game, & &1.negotiations) == 1
  end

  defp negotiating_fleet(outcome) do
    {agent, revision, ship} = fleet_fixture()

    game =
      start_supervised!(
        {Elixir.Agent,
         fn -> %{offered: false, applied: false, negotiations: 0, outcome: outcome} end}
      )

    ship_path = "/v2/my/ships/#{ship.symbol}"
    negotiate_path = ship_path <> "/negotiate/contract"

    Req.Test.stub(API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/contracts"} ->
          contracts = if Elixir.Agent.get(game, & &1.offered), do: [offered_contract()], else: []
          Req.Test.json(conn, %{"data" => contracts})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("DOCKED", destination: agent.headquarters)
              })
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body(ship.symbol, %{
                "nav" => nav_body("DOCKED", destination: agent.headquarters)
              })
            ]
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1_000,
              "headquarters" => agent.headquarters,
              "startingFaction" => agent.faction
            }
          })

        {"POST", ^negotiate_path} ->
          outcome =
            Elixir.Agent.get_and_update(game, fn state ->
              offered = state.outcome == :success
              applied = state.outcome in [:success, :lost_response]

              {state.outcome,
               %{state | offered: offered, applied: applied, negotiations: state.negotiations + 1}}
            end)

          case outcome do
            :success ->
              Req.Test.json(conn, %{"data" => %{"contract" => offered_contract()}})

            :rejected ->
              conn
              |> Plug.Conn.put_status(400)
              |> Req.Test.json(%{"error" => %{"code" => 4000, "message" => "Rejected"}})

            :lost_response ->
              Req.Test.transport_error(conn, :timeout)

            :outage ->
              Req.Test.transport_error(conn, :econnrefused)
          end

        request ->
          flunk("unexpected gameplay request: #{inspect(request)}")
      end
    end)

    {agent, revision, ship, game}
  end

  defp fleet_fixture do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    ship = Repo.insert!(%Ship{symbol: "NEGOTIATOR", ship_type: "SHIP_PROBE", agent_id: agent.id})
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Fulfil contracts"}],
          "hard_constraints" => []
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    Repo.insert!(%Generation{
      operator_id: operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction,
      replacement_symbols: %{},
      objective_progress: %{}
    })

    {agent, revision, ship}
  end

  defp offered_contract do
    now = DateTime.utc_now()

    %{
      "id" => "negotiated-contract",
      "accepted" => false,
      "fulfilled" => false,
      "deadlineToAccept" => DateTime.add(now, 3600) |> DateTime.to_iso8601(),
      "terms" => %{
        "deadline" => DateTime.add(now, 86_400) |> DateTime.to_iso8601(),
        "deliver" => [],
        "payment" => %{"onAccepted" => 0, "onFulfilled" => 100}
      }
    }
  end

  defp negotiation_attempts(agent) do
    agent
    |> MutationAttempts.list_for_agent()
    |> Enum.filter(&(&1.operation_id == "negotiateContract"))
  end
end
