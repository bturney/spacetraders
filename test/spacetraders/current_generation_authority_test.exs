defmodule SpaceTraders.CurrentGenerationAuthorityTest do
  # Adoption takes deployment-wide table locks and admission caches are shared.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.{Agent, Evidence, Fleet, FleetGeneration, Repo}
  alias SpaceTraders.FleetGeneration.Generation

  # A predecessor whose Generation is history keeps its Agent row and a
  # syntactically usable AgentToken; only the published Generation is current.
  defp retained_predecessor_and_current_fleet do
    operator = operator_fixture()
    scope = operator_scope_fixture(operator)

    predecessor =
      agent_fixture(operator, %{symbol: "PARALLAX", agent_token: "PREDECESSOR_SECRET"})

    retired =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: predecessor.id,
        number: 1,
        symbol: "PARALLAX",
        faction: "COSMIC",
        fenced_at: DateTime.add(DateTime.utc_now(), -7200),
        retired_at: DateTime.add(DateTime.utc_now(), -3600)
      })

    current = agent_fixture(operator, %{symbol: "ORBITALIST", agent_token: "CURRENT_SECRET"})

    {:ok, %{state: :current, generation: generation}} = FleetGeneration.adopt_current_fleet()
    true = generation.agent_id == current.id

    %{
      scope: scope,
      operator: operator,
      predecessor: predecessor,
      retired: retired,
      current: current,
      generation: generation
    }
  end

  defp observe_game_requests do
    test = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(
        test,
        {:game_request, conn.method, conn.request_path,
         Plug.Conn.get_req_header(conn, "authorization")}
      )

      Req.Test.json(conn, %{"data" => ship_body(List.last(String.split(conn.request_path, "/")))})
    end)
  end

  describe "new observations and gameplay dispatch" do
    test "use only the current Generation's credential; a cached predecessor reference gains no authority" do
      %{predecessor: predecessor, current: current} = retained_predecessor_and_current_fleet()
      observe_game_requests()

      cached = AgentTokenReference.new(predecessor)

      assert {:error, :generation_not_current} = Evidence.get_ship(cached, "PARALLAX-1")
      assert {:error, :generation_not_current} = Evidence.get_ship(predecessor, "PARALLAX-1")

      assert {:error, :generation_not_current} =
               SpaceTraders.API.accept_contract(cached, "CONTRACT-1")

      refute_received {:game_request, _, _, _}

      assert {:ok, _ship} = Evidence.get_ship(current, "ORBITALIST-1")

      assert_received {:game_request, "GET", "/v2/my/ships/ORBITALIST-1",
                       ["Bearer CURRENT_SECRET"]}

      assert Agent.get_agent(Agent.get_operator!(predecessor.operator_id), predecessor.id).agent_token ==
               "PREDECESSOR_SECRET"
    end

    test "Ship lookup and execution grant a retained predecessor no new authority" do
      %{predecessor: predecessor, current: current} = retained_predecessor_and_current_fleet()
      {:ok, _} = Fleet.record_ship(predecessor, "PARALLAX-1", "SHIP_COMMAND_FRIGATE")
      observe_game_requests()

      # Ship lookup still finds the historical owner; that confers nothing.
      assert {:ok, %{id: predecessor_id}} = Fleet.ship_agent("PARALLAX-1")
      assert predecessor_id == predecessor.id
      assert {:error, :generation_not_current} = Agent.execution_allowed?(predecessor)
      assert {:error, :generation_not_current} = Fleet.list_ships(predecessor)
      refute_received {:game_request, _, _, _}

      assert :ok = Agent.execution_allowed?(current)
    end

    test "a fenced transition dispatches nothing for the fenced Generation" do
      %{current: current, scope: scope} = retained_predecessor_and_current_fleet()

      reset = %SpaceTraders.API.GameplayError{
        code: 4113,
        type: :other,
        message:
          "Failed to parse token. Token reset_date does not match the server. Server resets happen weekly. After a reset, you should re-register your agent. Expected: 2026-10-11, Actual: 2026-10-01"
      }

      assert {:error, :stale_agent} = FleetGeneration.handle_game_result(current, {:error, reset})
      assert {:ok, %{state: :transition}} = FleetGeneration.current_fleet(scope)
      observe_game_requests()

      assert {:error, :stale_agent} = Evidence.get_agent(current)
      assert {:error, :stale_agent} = Evidence.get_ship(current, "ORBITALIST-1")
      refute_received {:game_request, _, _, _}
    end
  end

  describe "late results" do
    test "a predecessor's late observation keeps its Generation and cannot update replacement credits" do
      %{predecessor: predecessor, retired: retired, current: current, generation: generation} =
        retained_predecessor_and_current_fleet()

      scope = operator_scope_fixture(Agent.get_operator!(current.operator_id))
      {:ok, draft} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
      {:ok, revision} = SpaceTraders.FleetStrategy.activate(scope, draft.draft_version)

      generation =
        generation
        |> Ecto.Changeset.change(
          starting_credits: 175_000,
          fleet_strategy_revision_id: revision.id
        )
        |> Repo.update!()

      late = credits_observation(999_999)

      assert {:ok, %{observation: late_evidence}} =
               Evidence.fulfil_demands(predecessor, "agent:PARALLAX", late)

      assert late_evidence.agent_id == predecessor.id
      assert late_evidence.fleet_generation_id == retired.id
      assert Repo.reload!(generation).last_observed_credits == nil
      assert Evidence.latest_observation(current, "agent:PARALLAX") == nil

      assert {:ok, %{observation: current_evidence}} =
               Evidence.fulfil_demands(current, "agent:ORBITALIST", credits_observation(180_000))

      assert current_evidence.fleet_generation_id == generation.id
      assert Repo.reload!(generation).last_observed_credits == 180_000
    end
  end

  defp credits_observation(credits) do
    Evidence.authoritative_observation(
      "get-my-agent",
      ["agent:PARALLAX", "agent:ORBITALIST"],
      %{response: %{"credits" => credits}},
      DateTime.utc_now()
    )
  end
end
