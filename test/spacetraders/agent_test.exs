defmodule SpaceTraders.AgentTest do
  use SpaceTraders.DataCase

  alias SpaceTraders.Agent

  import SpaceTraders.AgentFixtures
  alias SpaceTraders.Agent.{Operator, OperatorToken, Scope}
  alias SpaceTraders.Fleet.{Ship, ShipServer}
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  describe "get_operator_by_email/1" do
    test "does not return the operator if the email does not exist" do
      refute Agent.get_operator_by_email("unknown@example.com")
    end

    test "returns the operator if the email exists" do
      %{id: id} = operator = operator_fixture()
      assert %Operator{id: ^id} = Agent.get_operator_by_email(operator.email)
    end
  end

  describe "get_operator_by_email_and_password/2" do
    test "does not return the operator if the email does not exist" do
      refute Agent.get_operator_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the operator if the password is not valid" do
      operator = operator_fixture() |> set_password()
      refute Agent.get_operator_by_email_and_password(operator.email, "invalid")
    end

    test "returns the operator if the email and password are valid" do
      %{id: id} = operator = operator_fixture() |> set_password()

      assert %Operator{id: ^id} =
               Agent.get_operator_by_email_and_password(operator.email, valid_operator_password())
    end
  end

  describe "get_operator!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Agent.get_operator!(-1)
      end
    end

    test "returns the operator with the given id" do
      %{id: id} = operator = operator_fixture()
      assert %Operator{id: ^id} = Agent.get_operator!(operator.id)
    end
  end

  describe "register_operator/1" do
    test "requires email to be set" do
      {:error, changeset} = Agent.register_operator(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Agent.register_operator(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Agent.register_operator(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = operator_fixture()
      {:error, changeset} = Agent.register_operator(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Agent.register_operator(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "requires password to be set" do
      {:error, changeset} = Agent.register_operator(%{email: unique_operator_email()})
      assert %{password: ["can't be blank"]} = errors_on(changeset)
    end

    test "registers a confirmed operator with email and password" do
      email = unique_operator_email()
      {:ok, operator} = Agent.register_operator(valid_operator_attributes(email: email))

      assert operator.email == email
      assert operator.confirmed_at
      assert operator.hashed_password
      assert is_nil(operator.password)
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Agent.sudo_mode?(%Operator{authenticated_at: DateTime.utc_now()})
      assert Agent.sudo_mode?(%Operator{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Agent.sudo_mode?(%Operator{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Agent.sudo_mode?(
               %Operator{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Agent.sudo_mode?(%Operator{})
    end
  end

  describe "change_operator_email/3" do
    test "returns a operator changeset" do
      assert %Ecto.Changeset{} = changeset = Agent.change_operator_email(%Operator{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_operator_update_email_instructions/3" do
    setup do
      %{operator: operator_fixture()}
    end

    test "sends token through notification", %{operator: operator} do
      token =
        extract_operator_token(fn url ->
          Agent.deliver_operator_update_email_instructions(operator, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert operator_token = Repo.get_by(OperatorToken, token: :crypto.hash(:sha256, token))
      assert operator_token.operator_id == operator.id
      assert operator_token.sent_to == operator.email
      assert operator_token.context == "change:current@example.com"
    end
  end

  describe "update_operator_email/2" do
    setup do
      operator = unconfirmed_operator_fixture()
      email = unique_operator_email()

      token =
        extract_operator_token(fn url ->
          Agent.deliver_operator_update_email_instructions(
            %{operator | email: email},
            operator.email,
            url
          )
        end)

      %{operator: operator, token: token, email: email}
    end

    test "updates the email with a valid token", %{operator: operator, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Agent.update_operator_email(operator, token)
      changed_operator = Repo.get!(Operator, operator.id)
      assert changed_operator.email != operator.email
      assert changed_operator.email == email
      refute Repo.get_by(OperatorToken, operator_id: operator.id)
    end

    test "does not update email with invalid token", %{operator: operator} do
      assert Agent.update_operator_email(operator, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(Operator, operator.id).email == operator.email
      assert Repo.get_by(OperatorToken, operator_id: operator.id)
    end

    test "does not update email if operator email changed", %{operator: operator, token: token} do
      assert Agent.update_operator_email(%{operator | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Operator, operator.id).email == operator.email
      assert Repo.get_by(OperatorToken, operator_id: operator.id)
    end

    test "does not update email if token expired", %{operator: operator, token: token} do
      {1, nil} = Repo.update_all(OperatorToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Agent.update_operator_email(operator, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(Operator, operator.id).email == operator.email
      assert Repo.get_by(OperatorToken, operator_id: operator.id)
    end
  end

  describe "change_operator_password/3" do
    test "returns a operator changeset" do
      assert %Ecto.Changeset{} = changeset = Agent.change_operator_password(%Operator{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Agent.change_operator_password(
          %Operator{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_operator_password/2" do
    setup do
      %{operator: operator_fixture()}
    end

    test "validates password", %{operator: operator} do
      {:error, changeset} =
        Agent.update_operator_password(operator, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{operator: operator} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Agent.update_operator_password(operator, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{operator: operator} do
      {:ok, {operator, expired_tokens}} =
        Agent.update_operator_password(operator, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(operator.password)
      assert Agent.get_operator_by_email_and_password(operator.email, "new valid password")
    end

    test "deletes all tokens for the given operator", %{operator: operator} do
      _ = Agent.generate_operator_session_token(operator)

      {:ok, {_, _}} =
        Agent.update_operator_password(operator, %{
          password: "new valid password"
        })

      refute Repo.get_by(OperatorToken, operator_id: operator.id)
    end
  end

  describe "generate_operator_session_token/1" do
    setup do
      %{operator: operator_fixture()}
    end

    test "generates a token", %{operator: operator} do
      token = Agent.generate_operator_session_token(operator)
      assert operator_token = Repo.get_by(OperatorToken, token: token)
      assert operator_token.context == "session"
      assert operator_token.authenticated_at != nil

      # Creating the same token for another operator should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%OperatorToken{
          token: operator_token.token,
          operator_id: operator_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given operator in new token", %{operator: operator} do
      operator = %{operator | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Agent.generate_operator_session_token(operator)
      assert operator_token = Repo.get_by(OperatorToken, token: token)
      assert operator_token.authenticated_at == operator.authenticated_at
      assert DateTime.compare(operator_token.inserted_at, operator.authenticated_at) == :gt
    end
  end

  describe "get_operator_by_session_token/1" do
    setup do
      operator = operator_fixture()
      token = Agent.generate_operator_session_token(operator)
      %{operator: operator, token: token}
    end

    test "returns operator by token", %{operator: operator, token: token} do
      assert {session_operator, token_inserted_at} = Agent.get_operator_by_session_token(token)
      assert session_operator.id == operator.id
      assert session_operator.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return operator for invalid token" do
      refute Agent.get_operator_by_session_token("oops")
    end

    test "does not return operator for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(OperatorToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Agent.get_operator_by_session_token(token)
    end
  end

  describe "get_operator_by_magic_link_token/1" do
    setup do
      operator = operator_fixture()
      {encoded_token, _hashed_token} = generate_operator_magic_link_token(operator)
      %{operator: operator, token: encoded_token}
    end

    test "returns operator by token", %{operator: operator, token: token} do
      assert session_operator = Agent.get_operator_by_magic_link_token(token)
      assert session_operator.id == operator.id
    end

    test "does not return operator for invalid token" do
      refute Agent.get_operator_by_magic_link_token("oops")
    end

    test "does not return operator for expired token", %{token: token} do
      {1, nil} = Repo.update_all(OperatorToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Agent.get_operator_by_magic_link_token(token)
    end
  end

  describe "login_operator_by_magic_link/1" do
    test "confirms operator and expires tokens" do
      operator = unconfirmed_operator_fixture()
      refute operator.confirmed_at
      {encoded_token, hashed_token} = generate_operator_magic_link_token(operator)

      assert {:ok, {operator, [%{token: ^hashed_token}]}} =
               Agent.login_operator_by_magic_link(encoded_token)

      assert operator.confirmed_at
    end

    test "returns operator and (deleted) token for confirmed operator" do
      operator = operator_fixture()
      assert operator.confirmed_at
      {encoded_token, _hashed_token} = generate_operator_magic_link_token(operator)
      assert {:ok, {^operator, []}} = Agent.login_operator_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Agent.login_operator_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed operator has password set" do
      operator = unconfirmed_operator_fixture()
      {1, nil} = Repo.update_all(Operator, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_operator_magic_link_token(operator)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Agent.login_operator_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_operator_session_token/1" do
    test "deletes the token" do
      operator = operator_fixture()
      token = Agent.generate_operator_session_token(operator)
      assert Agent.delete_operator_session_token(token) == :ok
      refute Agent.get_operator_by_session_token(token)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{operator: unconfirmed_operator_fixture()}
    end

    test "sends token through notification", %{operator: operator} do
      token =
        extract_operator_token(fn url ->
          Agent.deliver_login_instructions(operator, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert operator_token = Repo.get_by(OperatorToken, token: :crypto.hash(:sha256, token))
      assert operator_token.operator_id == operator.id
      assert operator_token.sent_to == operator.email
      assert operator_token.context == "login"
    end
  end

  describe "inspect/2 for the Operator module" do
    test "does not include password" do
      refute inspect(%Operator{password: "123456"}) =~ "password: \"123456\""
    end
  end

  describe "has_operators?/0" do
    test "is false on an empty database" do
      refute Agent.has_operators?()
    end

    test "is true once an operator exists" do
      operator_fixture()
      assert Agent.has_operators?()
    end
  end

  describe "link_account_token/2" do
    test "stores the token encrypted and reads it back decrypted" do
      operator = operator_fixture()

      assert {:ok, %Operator{account_token: "ACCOUNT_TOKEN"}} =
               Agent.link_account_token(operator, "ACCOUNT_TOKEN")

      reloaded = Repo.get!(Operator, operator.id)
      assert reloaded.account_token == "ACCOUNT_TOKEN"

      # The column never holds the plaintext token.
      from(o in Operator, select: fragment("account_token_ciphertext"))
      |> Repo.one()
      |> then(fn stored ->
        assert is_binary(stored)
        refute stored =~ "ACCOUNT_TOKEN"
        assert {:ok, "ACCOUNT_TOKEN"} = SpaceTraders.Secret.load(stored)
      end)
    end

    test "rejects a blank token" do
      operator = operator_fixture()

      assert {:error, changeset} = Agent.link_account_token(operator, "")
      assert "can't be blank" in errors_on(changeset).account_token
    end
  end

  describe "list_agents/1 and get_agent/2" do
    test "lists only the given operator's agents" do
      operator = operator_fixture()
      other = operator_fixture()

      agent = agent_fixture(operator)
      other_agent = agent_fixture(other)

      assert Agent.list_agents(operator) == [agent]
      assert Agent.list_agents(other) == [other_agent]
    end

    test "get_agent/2 returns nil for another operator's agent" do
      operator = operator_fixture()
      other = operator_fixture()
      agent = agent_fixture(operator)

      refute Agent.get_agent(other, agent.id)
      assert %{id: id} = Agent.get_agent(operator, agent.id)
      assert id == agent.id
    end
  end

  describe "mint_agent/2" do
    setup do
      operator = operator_fixture()
      {:ok, operator} = Agent.link_account_token(operator, "ACCOUNT_TOKEN")
      %{operator: operator}
    end

    test "mints an agent and stores its AgentToken encrypted per-agent", %{operator: operator} do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/register"
        assert conn.body_params == %{"symbol" => "NEWSYM", "faction" => "COSMIC"}

        Req.Test.json(conn, %{
          "data" => %{
            "token" => "AGENT_TOKEN",
            "agent" => %{
              "symbol" => "NEWSYM",
              "credits" => 175_000,
              "headquarters" => "X1-UX81-A2",
              "startingFaction" => "COSMIC"
            },
            "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
            "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
            "ships" => []
          }
        })
      end)

      assert {:ok, agent} = Agent.mint_agent(operator, %{symbol: "NEWSYM", faction: "COSMIC"})

      assert agent.symbol == "NEWSYM"
      assert agent.faction == "COSMIC"
      assert agent.headquarters == "X1-UX81-A2"
      assert agent.operator_id == operator.id

      stored = Repo.get!(SpaceTraders.Agent.Agent, agent.id)
      assert stored.agent_token == "AGENT_TOKEN"

      from(a in SpaceTraders.Agent.Agent, select: fragment("agent_token_ciphertext"))
      |> Repo.one()
      |> then(fn ciphertext ->
        refute ciphertext =~ "AGENT_TOKEN"
        assert {:ok, "AGENT_TOKEN"} = SpaceTraders.Secret.load(ciphertext)
      end)
    end

    test "replaces a stale local agent after a server reset", %{operator: operator} do
      stale_agent = agent_fixture(operator, %{symbol: "RESETME", agent_token: "STALE_TOKEN"})

      ship =
        Repo.insert!(%Ship{
          symbol: "RESETME-1",
          ship_type: "SHIP_COMMAND_FRIGATE",
          agent_id: stale_agent.id
        })

      {:ok, event} =
        Timeline.schedule_event(
          :ship,
          ship.symbol,
          :arrival,
          DateTime.add(DateTime.utc_now(), 1, :hour)
        )

      {:ok, _pid} = ShipServer.ensure_started(stale_agent, ship.symbol)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v2/register"
        assert conn.body_params == %{"symbol" => "RESETME", "faction" => "COSMIC"}

        Req.Test.json(conn, %{
          "data" => %{
            "token" => "FRESH_TOKEN",
            "agent" => %{
              "symbol" => "RESETME",
              "credits" => 175_000,
              "headquarters" => "X1-UX81-A2",
              "startingFaction" => "COSMIC"
            },
            "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
            "faction" => %{"symbol" => "COSMIC", "name" => "Cosmic", "isRecruiting" => true},
            "ships" => []
          }
        })
      end)

      assert {:ok, agent} = Agent.mint_agent(operator, %{symbol: "RESETME", faction: "COSMIC"})
      refute agent.id == stale_agent.id
      assert agent.agent_token == "FRESH_TOKEN"
      refute Repo.get(SpaceTraders.Agent.Agent, stale_agent.id)
      refute Repo.get(Ship, ship.id)
      assert Repo.get(Event, event.id).status == "cancelled"
      assert Registry.lookup(SpaceTraders.Fleet.ShipRegistry, ship.symbol) == []
    end

    test "rejects an invalid symbol before calling the API", %{operator: operator} do
      assert {:error, changeset} =
               Agent.mint_agent(operator, %{symbol: "lower case", faction: "COSMIC"})

      assert "must be 1-20 uppercase letters, digits, dashes or underscores" in errors_on(
               changeset
             ).symbol
    end

    test "requires the operator to have linked an AccountToken" do
      operator = operator_fixture()

      assert Agent.mint_agent(operator, %{symbol: "NEWSYM", faction: "COSMIC"}) ==
               {:error, :account_token_not_linked}
    end

    test "surfaces a game API rejection as a GameplayError", %{operator: operator} do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 400)
        |> Req.Test.json(%{"error" => %{"code" => 4103, "message" => "Symbol is already in use"}})
      end)

      assert {:error,
              %SpaceTraders.API.GameplayError{type: :other, message: "Symbol is already in use"}} =
               Agent.mint_agent(operator, %{symbol: "DUPLICATE", faction: "COSMIC"})
    end

    test "surfaces a fatal API failure as an Error", %{operator: operator} do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        Plug.Conn.send_resp(conn, 500, ~s({"error":"boom"}))
      end)

      assert {:error, %SpaceTraders.API.Error{status: 500}} =
               Agent.mint_agent(operator, %{symbol: "NEWSYM", faction: "COSMIC"})
    end
  end

  describe "import_agent/3" do
    test "validates the AgentToken with the API and stores it encrypted" do
      operator = operator_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/agent"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer AGENT_TOKEN"]

        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "ACCOUNT",
            "symbol" => "ORBITALIST",
            "credits" => 42_000,
            "headquarters" => "X1-UX81-A1",
            "startingFaction" => "COSMIC",
            "shipCount" => 1
          }
        })
      end)

      assert {:ok, imported} =
               Agent.import_agent(Scope.for_operator(operator), "AGENT_TOKEN", true)

      assert imported.symbol == "ORBITALIST"
      assert imported.faction == "COSMIC"
      assert imported.headquarters == "X1-UX81-A1"
      assert imported.operator_id == operator.id

      stored = Repo.get!(SpaceTraders.Agent.Agent, imported.id)
      assert stored.agent_token == "AGENT_TOKEN"

      ciphertext =
        from(a in SpaceTraders.Agent.Agent, select: fragment("agent_token_ciphertext"))
        |> Repo.one()

      refute ciphertext =~ "AGENT_TOKEN"
      assert {:ok, "AGENT_TOKEN"} = SpaceTraders.Secret.load(ciphertext)
    end

    test "requires explicit confirmation" do
      operator = operator_fixture()

      assert Agent.import_agent(Scope.for_operator(operator), "AGENT_TOKEN", false) ==
               {:error, :confirmation_required}

      assert Repo.aggregate(SpaceTraders.Agent.Agent, :count, :id) == 0
    end

    test "does not import a duplicate symbol" do
      operator = operator_fixture()
      agent_fixture(operator, %{symbol: "ORBITALIST"})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "symbol" => "ORBITALIST",
            "credits" => 0,
            "headquarters" => "X1-UX81-A1",
            "startingFaction" => "COSMIC",
            "shipCount" => 1
          }
        })
      end)

      assert Agent.import_agent(Scope.for_operator(operator), "AGENT_TOKEN", true) ==
               {:error, :agent_already_imported}
    end

    test "does not persist an invalid AgentToken" do
      operator = operator_fixture()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{"error" => %{"code" => 4011, "message" => "Invalid token"}})
      end)

      assert {:error, %SpaceTraders.API.GameplayError{message: "Invalid token"}} =
               Agent.import_agent(Scope.for_operator(operator), "AGENT_TOKEN", true)

      assert Repo.aggregate(SpaceTraders.Agent.Agent, :count, :id) == 0
    end
  end

  describe "agent_overview/1" do
    test "pulls the agent's live credits, HQ and faction from the game API" do
      agent = agent_fixture(operator_fixture())

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/agent"

        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "ACCOUNT",
            "symbol" => agent.symbol,
            "headquarters" => "X1-UX81-A1",
            "credits" => 42_000,
            "startingFaction" => "COSMIC",
            "shipCount" => 2
          }
        })
      end)

      assert {:ok, %SpaceTraders.API.Model.Agent{} = overview} = Agent.agent_overview(agent)
      assert overview.symbol == agent.symbol
      assert overview.credits == 42_000
      assert overview.headquarters == "X1-UX81-A1"
      assert overview.starting_faction == "COSMIC"
    end

    test "authorizes the request with the agent's token" do
      import Plug.Conn, only: [get_req_header: 2]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert get_req_header(conn, "authorization") == ["Bearer test-agent-token"]
        Req.Test.json(conn, %{"data" => %{"symbol" => "A", "credits" => 0}})
      end)

      assert {:ok, _} = Agent.agent_overview(agent_fixture(operator_fixture()))
    end

    test "returns an error when the agent has no stored token" do
      agent = %SpaceTraders.Agent.Agent{agent_token: nil}

      assert Agent.agent_overview(agent) == {:error, :agent_token_missing}
    end
  end
end
