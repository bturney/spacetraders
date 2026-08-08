defmodule SpaceTradersWeb.OperatorLive.Registration do
  use SpaceTradersWeb, :live_view

  alias SpaceTraders.Agent

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm rounded-2xl border border-base-300/70 bg-base-100/80 p-5 shadow-xl sm:p-8">
        <div class="mb-8 text-center">
          <p class="eyebrow">Operator onboarding</p>
          <.header>
            Create your operations center
            <:subtitle>
              Already an Operator?
              <.link navigate={~p"/operators/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Confirm password"
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:account_token]}
            type="password"
            label="AccountToken (optional)"
            autocomplete="off"
          />
          <p class="text-xs opacity-60 mt-1">
            Your my.spacetraders.io account token, used only to mint agents.
            You can link it later from Settings.
          </p>

          <.button phx-disable-with="Creating account..." class="btn btn-primary min-h-12 w-full">
            Create Operator account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{operator: operator}}} = socket)
      when not is_nil(operator) do
    {:ok, redirect(socket, to: SpaceTradersWeb.OperatorAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Agent.change_registration(%{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"operator" => operator_params}, socket) do
    case Agent.register_operator(operator_params) do
      {:ok, _operator} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created. Log in to continue.")
         |> push_navigate(to: ~p"/operators/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"operator" => operator_params}, socket) do
    changeset =
      Agent.change_registration(operator_params, validate_unique: false, hash_password: false)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "operator")
    assign(socket, form: form)
  end
end
