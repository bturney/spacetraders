defmodule SpaceTradersWeb.OperatorLive.Settings do
  use SpaceTradersWeb, :live_view

  on_mount {SpaceTradersWeb.OperatorAuth, :require_sudo_mode}

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mb-8 text-center">
        <p class="eyebrow">Operator profile</p>
        <.header>
          Settings
          <:subtitle>
            Keep your Operator access and AccountToken ready for the next Mission.
          </:subtitle>
        </.header>
      </div>

      <.form
        for={@account_token_form}
        id="account_token_form"
        phx-submit="update_account_token"
        phx-change="validate_account_token"
      >
        <div class="rounded-2xl border border-primary/25 bg-base-100/70 p-4 sm:p-5">
          <p class="eyebrow mb-3">Minting access</p>
          <div class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
            <.input
              field={@account_token_form[:account_token]}
              type="password"
              label="AccountToken"
              autocomplete="off"
              placeholder={@account_token_linked? && "Linked — enter a new token to replace it"}
            />
            <.button variant="primary" class="min-h-11" phx-disable-with="Saving...">
              Link AccountToken
            </.button>
          </div>
          <p :if={@account_token_linked?} class="text-sm text-success">
            An AccountToken is linked. It is used only to mint agents and stored encrypted.
          </p>
          <p :if={!@account_token_linked?} class="text-sm opacity-60">
            Link your my.spacetraders.io AccountToken to mint agents in-app.
          </p>
        </div>
      </.form>

      <div class="divider" />

      <section id="import-agent">
        <p :if={@import_unavailable} class="text-sm opacity-70">{@import_unavailable}</p>
        <.form
          :if={!@import_unavailable}
          for={@import_agent_form}
          id="import_agent_form"
          phx-submit="import_agent"
        >
          <.header>
            Import an existing agent
            <:subtitle>
              For initial setup: an AccountToken can mint an Agent but cannot recover an existing
              AgentToken. Paste the AgentToken from my.spacetraders.io to import that Agent safely.
            </:subtitle>
          </.header>
          <.input
            field={@import_agent_form[:agent_token]}
            type="password"
            label="AgentToken"
            autocomplete="off"
            spellcheck="false"
            required
          />
          <.input
            field={@import_agent_form[:confirmed]}
            type="checkbox"
            label="I confirm this AgentToken belongs to my agent and I want to import it."
          />
          <.button variant="primary" phx-disable-with="Importing...">
            Import agent
          </.button>
          <p class="mt-3 text-sm opacity-70">
            No existing Agent?
            <.link navigate={~p"/agents/new"} class="link link-primary">Mint an Agent</.link>
            instead.
          </p>
        </.form>
      </section>

      <div class="divider" />

      <.form
        for={@name_bank_form}
        id="name_bank_form"
        class="rounded-2xl border border-base-300/70 bg-base-100/70 p-4 sm:p-5"
        phx-submit="save_name_bank"
        phx-change="validate_name_bank"
      >
        <p class="eyebrow mb-3">Agent Name Bank</p>
        <.input
          field={@name_bank_form[:names]}
          type="textarea"
          label="Agent names, one per line, in order of preference"
          rows="6"
          spellcheck="false"
        />
        <p class="mb-3 text-sm opacity-70">
          Used in order when minting or replacing an Agent. Names are uppercased and must be
          3 to 14 characters.
        </p>
        <ul :if={@name_bank_errors != []} id="name_bank_errors" class="mb-3 text-sm text-error">
          <li :for={error <- @name_bank_errors}>{error}</li>
        </ul>
        <.button variant="primary" phx-disable-with="Saving...">Save Name Bank</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@email_form}
        id="email_form"
        class="rounded-2xl border border-base-300/70 bg-base-100/70 p-4 sm:p-5"
        phx-submit="update_email"
        phx-change="validate_email"
      >
        <p class="eyebrow mb-3">Contact channel</p>
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
        class="rounded-2xl border border-base-300/70 bg-base-100/70 p-4 sm:p-5"
        action={~p"/operators/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <p class="eyebrow mb-3">Security</p>
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
      |> assign(:form_drafts, %{})
      |> assign(:account_token_linked?, Agent.account_token_linked?(socket.assigns.current_scope))
      |> assign(:import_agent_form, import_agent_form())
      |> assign_import_availability()
      |> assign_account_token_form()
      |> assign_name_bank()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_name_bank, socket) do
    # Recurring patch: reload stored names only when there is no unsaved draft.
    if Map.has_key?(socket.assigns.form_drafts, :name_bank) do
      {:noreply, socket}
    else
      {:noreply, assign_name_bank(socket)}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

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

    case Agent.link_account_token(socket.assigns.current_scope, operator_params["account_token"]) do
      {:ok, updated_operator} ->
        socket =
          socket
          |> put_flash(:info, "AccountToken linked.")
          |> assign(:current_scope, Scope.for_operator(updated_operator))
          |> assign(:account_token_linked?, true)
          |> assign_account_token_form()

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_account_token_form(socket, changeset)}

      {:error, :not_current_operator} ->
        {:noreply,
         socket
         |> put_flash(:error, "You must log in to change credentials.")
         |> push_navigate(to: ~p"/operators/log-in")}
    end
  end

  def handle_event("validate_name_bank", %{"name_bank" => params}, socket) do
    {:noreply, put_name_bank_draft(socket, params["names"], [])}
  end

  def handle_event("save_name_bank", %{"name_bank" => params}, socket) do
    true = Agent.sudo_mode?(socket.assigns.current_scope.operator)

    case SpaceTraders.AgentNameBank.save(params["names"] || "") do
      {:ok, _names} ->
        {:noreply, socket |> put_flash(:info, "Agent Name Bank saved.") |> assign_name_bank()}

      {:error, errors} ->
        {:noreply, put_name_bank_draft(socket, params["names"], errors)}
    end
  end

  def handle_event("import_agent", %{"import" => params}, socket) do
    confirmed = params["confirmed"] == "true"

    case Agent.import_agent(socket.assigns.current_scope, params["agent_token"], confirmed) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent #{agent.symbol} imported.")
         |> assign(:import_agent_form, import_agent_form())
         |> assign_import_availability()}

      {:error, reason} when reason in [:current_fleet_exists, :fleet_transition_pending] ->
        socket = assign_import_availability(socket)

        {:noreply,
         socket
         |> put_flash(:error, "#{socket.assigns.import_unavailable} No Agent was imported.")
         |> assign(:import_agent_form, import_agent_form())}

      {:error, %{summary: summary}} ->
        {:noreply,
         socket
         |> put_flash(:error, summary)
         |> assign(:import_agent_form, import_agent_form())}

      {:error, :confirmation_required} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Confirm that the AgentToken belongs to your agent before importing."
         )
         |> assign(:import_agent_form, import_agent_form())}

      {:error, :agent_token_required} ->
        {:noreply,
         socket
         |> put_flash(:error, "Enter an AgentToken before importing.")
         |> assign(:import_agent_form, import_agent_form())}

      {:error, :agent_already_imported} ->
        {:noreply,
         socket
         |> put_flash(:error, "That agent is already imported.")
         |> assign(:import_agent_form, import_agent_form())}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> put_flash(:error, "The game returned incomplete agent details.")
         |> assign(:import_agent_form, import_agent_form())}

      {:error, %{message: message}} ->
        {:noreply,
         socket
         |> put_flash(:error, "Agent import failed: #{message}")
         |> assign(:import_agent_form, import_agent_form())}
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

  defp assign_name_bank(socket) do
    names = Enum.join(SpaceTraders.AgentNameBank.list(), "\n")

    socket
    |> update(:form_drafts, &Map.delete(&1, :name_bank))
    |> assign(:name_bank_errors, [])
    |> assign(:name_bank_form, to_form(%{"names" => names}, as: "name_bank"))
  end

  defp put_name_bank_draft(socket, names, errors) do
    names = names || ""

    socket
    |> update(:form_drafts, &Map.put(&1, :name_bank, %{"names" => names}))
    |> assign(:name_bank_errors, errors)
    |> assign(:name_bank_form, to_form(%{"names" => names}, as: "name_bank"))
  end

  defp assign_account_token_form(socket, changeset \\ Agent.change_account_token()) do
    draft = Map.take(changeset.params || %{}, ["account_token"])

    socket
    |> update(:form_drafts, &Map.put(&1, :account_token, draft))
    |> assign(:account_token_form, to_form(changeset, as: "operator"))
  end

  # Import is initial setup only; it is never a mid-game replacement mode.
  defp assign_import_availability(socket) do
    unavailable =
      case SpaceTraders.FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :empty}} ->
          nil

        {:ok, %{state: :current, agent: agent}} ->
          "This deployment already has a current Agent, #{agent.symbol}. Import is only for initial setup."

        {:ok, %{state: :transition}} ->
          "A Fleet transition is in progress. Import is only for initial setup."

        {:error, %{summary: summary}} ->
          summary
      end

    assign(socket, :import_unavailable, unavailable)
  end

  defp import_agent_form do
    to_form(%{"agent_token" => "", "confirmed" => false}, as: "import")
  end
end
