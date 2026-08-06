defmodule SpaceTradersWeb.OperatorLive.Settings do
  use SpaceTradersWeb, :live_view

  on_mount {SpaceTradersWeb.OperatorAuth, :require_sudo_mode}

  alias SpaceTraders.Agent

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <.form
        for={@account_token_form}
        id="account_token_form"
        phx-submit="update_account_token"
        phx-change="validate_account_token"
      >
        <div class="flex items-center justify-between">
          <.input
            field={@account_token_form[:account_token]}
            type="password"
            label="AccountToken"
            autocomplete="off"
            placeholder={@account_token_linked? && "Linked — enter a new token to replace it"}
          />
          <.button variant="primary" class="mt-6" phx-disable-with="Saving...">
            Link AccountToken
          </.button>
        </div>
        <p :if={@account_token_linked?} class="text-sm text-success">
          An AccountToken is linked. It is used only to mint agents and stored encrypted.
        </p>
        <p :if={!@account_token_linked?} class="text-sm opacity-60">
          Link your my.spacetraders.io AccountToken to mint agents in-app.
        </p>
      </.form>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/operators/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_operator_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Agent.update_operator_email(socket.assigns.current_scope.operator, token) do
        {:ok, _operator} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/operators/settings")}
  end

  def mount(_params, _session, socket) do
    operator = socket.assigns.current_scope.operator
    email_changeset = Agent.change_operator_email(operator, %{}, validate_unique: false)
    password_changeset = Agent.change_operator_password(operator, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, operator.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:account_token_linked?, not is_nil(operator.account_token))
      |> assign_account_token_form()

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_account_token", params, socket) do
    %{"operator" => operator_params} = params

    changeset = Agent.change_account_token(operator_params)

    {:noreply, assign_account_token_form(socket, Map.put(changeset, :action, :validate))}
  end

  def handle_event("update_account_token", params, socket) do
    %{"operator" => operator_params} = params
    operator = socket.assigns.current_scope.operator
    true = Agent.sudo_mode?(operator)

    case Agent.link_account_token(operator, operator_params["account_token"]) do
      {:ok, %{account_token: account_token}} ->
        socket =
          socket
          |> put_flash(:info, "AccountToken linked.")
          |> assign(:account_token_linked?, not is_nil(account_token))
          |> assign_account_token_form()

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_account_token_form(socket, changeset)}
    end
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"operator" => operator_params} = params

    email_form =
      socket.assigns.current_scope.operator
      |> Agent.change_operator_email(operator_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"operator" => operator_params} = params
    operator = socket.assigns.current_scope.operator
    true = Agent.sudo_mode?(operator)

    case Agent.change_operator_email(operator, operator_params) do
      %{valid?: true} = changeset ->
        Agent.deliver_operator_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          operator.email,
          &url(~p"/operators/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"operator" => operator_params} = params

    password_form =
      socket.assigns.current_scope.operator
      |> Agent.change_operator_password(operator_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"operator" => operator_params} = params
    operator = socket.assigns.current_scope.operator
    true = Agent.sudo_mode?(operator)

    case Agent.change_operator_password(operator, operator_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp assign_account_token_form(socket, changeset \\ Agent.change_account_token()) do
    assign(socket, :account_token_form, to_form(changeset, as: "operator"))
  end
end
