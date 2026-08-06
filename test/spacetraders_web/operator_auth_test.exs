defmodule SpaceTradersWeb.OperatorAuthTest do
  use SpaceTradersWeb.ConnCase

  alias Phoenix.LiveView
  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTradersWeb.OperatorAuth

  import SpaceTraders.AgentFixtures

  @remember_me_cookie "_space_traders_web_operator_remember_me"
  @remember_me_cookie_max_age 60 * 60 * 24 * 14

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, SpaceTradersWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})

    %{operator: %{operator_fixture() | authenticated_at: DateTime.utc_now(:second)}, conn: conn}
  end

  describe "log_in_operator/3" do
    test "stores the operator token in the session", %{conn: conn, operator: operator} do
      conn = OperatorAuth.log_in_operator(conn, operator)
      assert token = get_session(conn, :operator_token)

      assert get_session(conn, :live_socket_id) ==
               "operators_sessions:#{Base.url_encode64(token)}"

      assert redirected_to(conn) == ~p"/"
      assert Agent.get_operator_by_session_token(token)
    end

    test "clears everything previously stored in the session", %{conn: conn, operator: operator} do
      conn =
        conn |> put_session(:to_be_removed, "value") |> OperatorAuth.log_in_operator(operator)

      refute get_session(conn, :to_be_removed)
    end

    test "keeps session when re-authenticating", %{conn: conn, operator: operator} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_operator(operator))
        |> put_session(:to_be_removed, "value")
        |> OperatorAuth.log_in_operator(operator)

      assert get_session(conn, :to_be_removed)
    end

    test "clears session when operator does not match when re-authenticating", %{
      conn: conn,
      operator: operator
    } do
      other_operator = operator_fixture()

      conn =
        conn
        |> assign(:current_scope, Scope.for_operator(other_operator))
        |> put_session(:to_be_removed, "value")
        |> OperatorAuth.log_in_operator(operator)

      refute get_session(conn, :to_be_removed)
    end

    test "redirects to the configured path", %{conn: conn, operator: operator} do
      conn =
        conn
        |> put_session(:operator_return_to, "/hello")
        |> OperatorAuth.log_in_operator(operator)

      assert redirected_to(conn) == "/hello"
    end

    test "writes a cookie if remember_me is configured", %{conn: conn, operator: operator} do
      conn =
        conn
        |> fetch_cookies()
        |> OperatorAuth.log_in_operator(operator, %{"remember_me" => "true"})

      assert get_session(conn, :operator_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :operator_remember_me) == true

      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :operator_token)
      assert max_age == @remember_me_cookie_max_age
    end

    test "redirects to home when operator is already logged in", %{conn: conn, operator: operator} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_operator(operator))
        |> OperatorAuth.log_in_operator(operator)

      assert redirected_to(conn) == ~p"/"
    end

    test "writes a cookie if remember_me was set in previous session", %{
      conn: conn,
      operator: operator
    } do
      conn =
        conn
        |> fetch_cookies()
        |> OperatorAuth.log_in_operator(operator, %{"remember_me" => "true"})

      assert get_session(conn, :operator_token) == conn.cookies[@remember_me_cookie]
      assert get_session(conn, :operator_remember_me) == true

      conn =
        conn
        |> recycle()
        |> Map.replace!(:secret_key_base, SpaceTradersWeb.Endpoint.config(:secret_key_base))
        |> fetch_cookies()
        |> init_test_session(%{operator_remember_me: true})

      # the conn is already logged in and has the remember_me cookie set,
      # now we log in again and even without explicitly setting remember_me,
      # the cookie should be set again
      conn = conn |> OperatorAuth.log_in_operator(operator, %{})
      assert %{value: signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert signed_token != get_session(conn, :operator_token)
      assert max_age == @remember_me_cookie_max_age
      assert get_session(conn, :operator_remember_me) == true
    end
  end

  describe "logout_operator/1" do
    test "erases session and cookies", %{conn: conn, operator: operator} do
      operator_token = Agent.generate_operator_session_token(operator)

      conn =
        conn
        |> put_session(:operator_token, operator_token)
        |> put_req_cookie(@remember_me_cookie, operator_token)
        |> fetch_cookies()
        |> OperatorAuth.log_out_operator()

      refute get_session(conn, :operator_token)
      refute conn.cookies[@remember_me_cookie]
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
      refute Agent.get_operator_by_session_token(operator_token)
    end

    test "broadcasts to the given live_socket_id", %{conn: conn} do
      live_socket_id = "operators_sessions:abcdef-token"
      SpaceTradersWeb.Endpoint.subscribe(live_socket_id)

      conn
      |> put_session(:live_socket_id, live_socket_id)
      |> OperatorAuth.log_out_operator()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: ^live_socket_id}
    end

    test "works even if operator is already logged out", %{conn: conn} do
      conn = conn |> fetch_cookies() |> OperatorAuth.log_out_operator()
      refute get_session(conn, :operator_token)
      assert %{max_age: 0} = conn.resp_cookies[@remember_me_cookie]
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_scope_for_operator/2" do
    test "authenticates operator from session", %{conn: conn, operator: operator} do
      operator_token = Agent.generate_operator_session_token(operator)

      conn =
        conn
        |> put_session(:operator_token, operator_token)
        |> OperatorAuth.fetch_current_scope_for_operator([])

      assert conn.assigns.current_scope.operator.id == operator.id
      assert conn.assigns.current_scope.operator.authenticated_at == operator.authenticated_at
      assert get_session(conn, :operator_token) == operator_token
    end

    test "authenticates operator from cookies", %{conn: conn, operator: operator} do
      logged_in_conn =
        conn
        |> fetch_cookies()
        |> OperatorAuth.log_in_operator(operator, %{"remember_me" => "true"})

      operator_token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      conn =
        conn
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> OperatorAuth.fetch_current_scope_for_operator([])

      assert conn.assigns.current_scope.operator.id == operator.id
      assert conn.assigns.current_scope.operator.authenticated_at == operator.authenticated_at
      assert get_session(conn, :operator_token) == operator_token
      assert get_session(conn, :operator_remember_me)

      assert get_session(conn, :live_socket_id) ==
               "operators_sessions:#{Base.url_encode64(operator_token)}"
    end

    test "does not authenticate if data is missing", %{conn: conn, operator: operator} do
      _ = Agent.generate_operator_session_token(operator)
      conn = OperatorAuth.fetch_current_scope_for_operator(conn, [])
      refute get_session(conn, :operator_token)
      refute conn.assigns.current_scope
    end

    test "reissues a new token after a few days and refreshes cookie", %{
      conn: conn,
      operator: operator
    } do
      logged_in_conn =
        conn
        |> fetch_cookies()
        |> OperatorAuth.log_in_operator(operator, %{"remember_me" => "true"})

      token = logged_in_conn.cookies[@remember_me_cookie]
      %{value: signed_token} = logged_in_conn.resp_cookies[@remember_me_cookie]

      offset_operator_token(token, -10, :day)
      {operator, _} = Agent.get_operator_by_session_token(token)

      conn =
        conn
        |> put_session(:operator_token, token)
        |> put_session(:operator_remember_me, true)
        |> put_req_cookie(@remember_me_cookie, signed_token)
        |> OperatorAuth.fetch_current_scope_for_operator([])

      assert conn.assigns.current_scope.operator.id == operator.id
      assert conn.assigns.current_scope.operator.authenticated_at == operator.authenticated_at
      assert new_token = get_session(conn, :operator_token)
      assert new_token != token
      assert %{value: new_signed_token, max_age: max_age} = conn.resp_cookies[@remember_me_cookie]
      assert new_signed_token != signed_token
      assert max_age == @remember_me_cookie_max_age
    end
  end

  describe "on_mount :mount_current_scope" do
    setup %{conn: conn} do
      %{conn: OperatorAuth.fetch_current_scope_for_operator(conn, [])}
    end

    test "assigns current_scope based on a valid operator_token", %{
      conn: conn,
      operator: operator
    } do
      operator_token = Agent.generate_operator_session_token(operator)
      session = conn |> put_session(:operator_token, operator_token) |> get_session()

      {:cont, updated_socket} =
        OperatorAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.operator.id == operator.id
    end

    test "assigns nil to current_scope assign if there isn't a valid operator_token", %{
      conn: conn
    } do
      operator_token = "invalid_token"
      session = conn |> put_session(:operator_token, operator_token) |> get_session()

      {:cont, updated_socket} =
        OperatorAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end

    test "assigns nil to current_scope assign if there isn't a operator_token", %{conn: conn} do
      session = conn |> get_session()

      {:cont, updated_socket} =
        OperatorAuth.on_mount(:mount_current_scope, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_authenticated" do
    test "authenticates current_scope based on a valid operator_token", %{
      conn: conn,
      operator: operator
    } do
      operator_token = Agent.generate_operator_session_token(operator)
      session = conn |> put_session(:operator_token, operator_token) |> get_session()

      {:cont, updated_socket} =
        OperatorAuth.on_mount(:require_authenticated, %{}, session, %LiveView.Socket{})

      assert updated_socket.assigns.current_scope.operator.id == operator.id
    end

    test "redirects to login page if there isn't a valid operator_token", %{conn: conn} do
      operator_token = "invalid_token"
      session = conn |> put_session(:operator_token, operator_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: SpaceTradersWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} =
        OperatorAuth.on_mount(:require_authenticated, %{}, session, socket)

      assert updated_socket.assigns.current_scope == nil
    end

    test "redirects to login page if there isn't a operator_token", %{conn: conn} do
      session = conn |> get_session()

      socket = %LiveView.Socket{
        endpoint: SpaceTradersWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      {:halt, updated_socket} =
        OperatorAuth.on_mount(:require_authenticated, %{}, session, socket)

      assert updated_socket.assigns.current_scope == nil
    end
  end

  describe "on_mount :require_sudo_mode" do
    test "allows operators that have authenticated in the last 10 minutes", %{
      conn: conn,
      operator: operator
    } do
      operator_token = Agent.generate_operator_session_token(operator)
      session = conn |> put_session(:operator_token, operator_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: SpaceTradersWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:cont, _updated_socket} =
               OperatorAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end

    test "redirects when authentication is too old", %{conn: conn, operator: operator} do
      eleven_minutes_ago = DateTime.utc_now(:second) |> DateTime.add(-11, :minute)
      operator = %{operator | authenticated_at: eleven_minutes_ago}
      operator_token = Agent.generate_operator_session_token(operator)
      {operator, token_inserted_at} = Agent.get_operator_by_session_token(operator_token)
      assert DateTime.compare(token_inserted_at, operator.authenticated_at) == :gt
      session = conn |> put_session(:operator_token, operator_token) |> get_session()

      socket = %LiveView.Socket{
        endpoint: SpaceTradersWeb.Endpoint,
        assigns: %{__changed__: %{}, flash: %{}}
      }

      assert {:halt, _updated_socket} =
               OperatorAuth.on_mount(:require_sudo_mode, %{}, session, socket)
    end
  end

  describe "require_authenticated_operator/2" do
    setup %{conn: conn} do
      %{conn: OperatorAuth.fetch_current_scope_for_operator(conn, [])}
    end

    test "redirects if operator is not authenticated", %{conn: conn} do
      conn = conn |> fetch_flash() |> OperatorAuth.require_authenticated_operator([])
      assert conn.halted

      assert redirected_to(conn) == ~p"/operators/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "You must log in to access this page."
    end

    test "stores the path to redirect to on GET", %{conn: conn} do
      halted_conn =
        %{conn | path_info: ["foo"], query_string: ""}
        |> fetch_flash()
        |> OperatorAuth.require_authenticated_operator([])

      assert halted_conn.halted
      assert get_session(halted_conn, :operator_return_to) == "/foo"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar=baz"}
        |> fetch_flash()
        |> OperatorAuth.require_authenticated_operator([])

      assert halted_conn.halted
      assert get_session(halted_conn, :operator_return_to) == "/foo?bar=baz"

      halted_conn =
        %{conn | path_info: ["foo"], query_string: "bar", method: "POST"}
        |> fetch_flash()
        |> OperatorAuth.require_authenticated_operator([])

      assert halted_conn.halted
      refute get_session(halted_conn, :operator_return_to)
    end

    test "does not redirect if operator is authenticated", %{conn: conn, operator: operator} do
      conn =
        conn
        |> assign(:current_scope, Scope.for_operator(operator))
        |> OperatorAuth.require_authenticated_operator([])

      refute conn.halted
      refute conn.status
    end
  end

  describe "disconnect_sessions/1" do
    test "broadcasts disconnect messages for each token" do
      tokens = [%{token: "token1"}, %{token: "token2"}]

      for %{token: token} <- tokens do
        SpaceTradersWeb.Endpoint.subscribe("operators_sessions:#{Base.url_encode64(token)}")
      end

      OperatorAuth.disconnect_sessions(tokens)

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "operators_sessions:dG9rZW4x"
      }

      assert_receive %Phoenix.Socket.Broadcast{
        event: "disconnect",
        topic: "operators_sessions:dG9rZW4y"
      }
    end
  end
end
