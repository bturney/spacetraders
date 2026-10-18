defmodule SpaceTradersWeb.OperatorLive.Mint do
  @moduledoc """
  Mints the deployment's initial in-game Agent (chosen symbol + faction) via the
  Operator's linked AccountToken. The resulting AgentToken is stored encrypted.
  Once a current Agent exists this page is not an add-another-Agent path.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Agent, FleetGeneration}
  alias SpaceTraders.API.Model.FactionSymbol

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-lg rounded-2xl border border-base-300/70 bg-base-100/80 p-5 shadow-xl sm:p-8">
        <div class="mb-8 text-center">
          <p class="eyebrow">Agent fabrication</p>
          <.header>
            Mint an agent
            <:subtitle>
              <%= if @account_token_linked? do %>
                Choose a symbol and faction to register this deployment's Agent in the game.
              <% else %>
                Link your AccountToken in
                <.link
                  navigate={~p"/operators/settings"}
                  class="font-semibold text-brand hover:underline"
                >
                  Settings
                </.link>
                before minting.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <%= if @current_agent do %>
          <div id="current-fleet-established" class="alert alert-info">
            <span>
              This deployment already has a current Agent, {@current_agent}. A new Agent is
              established only through Fleet replacement, not an ordinary mint.
            </span>
          </div>
          <.link navigate={~p"/mission-control"} class="btn btn-primary mt-4 w-full">
            Open Mission Control
          </.link>
        <% else %>
          <%= if @recovery.status != :clear do %>
            <div id="registration-recovery" class="alert alert-warning">
              <span>{@recovery.summary}</span>
            </div>
            <button
              :if={@recovery.status in [:unresolved, :awaiting_adoption]}
              id="reconcile-registration"
              phx-click="reconcile"
              phx-disable-with="Checking..."
              class="btn btn-primary mt-4 w-full"
            >
              {if @recovery.status == :awaiting_adoption,
                do: "Resume setup of #{@recovery.symbol}",
                else: "Check the game again"}
            </button>
            <.form
              :if={@recovery.status == :unresolved}
              for={@adopt_form}
              id="adopt_registered_form"
              phx-submit="adopt_registered"
              class="mt-6"
            >
              <.input
                field={@adopt_form[:agent_token]}
                type="password"
                label={"AgentToken for #{@recovery.symbol}"}
                autocomplete="off"
                required
              />
              <.input
                field={@adopt_form[:confirmed]}
                type="checkbox"
                label={"I confirm this AgentToken authenticates as #{@recovery.symbol}"}
              />
              <.button phx-disable-with="Adopting..." class="btn min-h-12 w-full">
                Adopt {@recovery.symbol}
              </.button>
            </.form>
          <% else %>
            <%= if @transition_symbol do %>
              <div id="server-reset-transition" class="alert alert-warning">
                <span>
                  A Server Reset fenced {@transition_symbol}. Its replacement is established
                  automatically from the Agent Name Bank, not by an ordinary mint.
                </span>
              </div>
              <.link navigate={~p"/mission-control"} class="btn btn-primary mt-4 w-full">
                Review replacement in Mission Control
              </.link>
            <% end %>
            <%= if !@transition_symbol && @account_token_linked? do %>
              <.form for={@form} id="mint_form" phx-submit="mint" phx-change="validate">
                <div class="mb-5 rounded-xl border border-info/30 bg-info/10 p-4 text-sm leading-6">
                  <strong class="block">A quick start</strong>
                  Choose a unique Agent symbol and a starting Faction. You can begin learning with the starter Ship immediately after minting.
                </div>
                <.input
                  field={@form[:symbol]}
                  type="text"
                  label="Symbol"
                  autocomplete="off"
                  spellcheck="false"
                  required
                  phx-mounted={JS.focus()}
                />
                <.input
                  field={@form[:faction]}
                  type="select"
                  label="Faction"
                  options={@factions}
                  required
                />

                <.button phx-disable-with="Minting..." class="btn btn-primary min-h-12 w-full">
                  Mint Agent
                </.button>
              </.form>
            <% end %>
            <%= if !@transition_symbol && !@account_token_linked? do %>
              <div class="alert alert-warning mt-8">
                Link your AccountToken in
                <.link navigate={~p"/operators/settings"} class="underline">Settings</.link>
                to mint agents.
              </div>
            <% end %>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:factions, FactionSymbol.values())
      |> assign(
        :account_token_linked?,
        Agent.account_token_linked?(socket.assigns.current_scope)
      )
      |> assign_current_agent()
      |> assign_recovery()
      |> assign_form(Agent.change_mint())

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  defp assign_current_agent(socket) do
    {current_agent, transition_symbol} =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent}} -> {agent.symbol, nil}
        {:ok, %{state: :transition, generation: generation}} -> {nil, generation.symbol}
        _ -> {nil, nil}
      end

    socket
    |> assign(:current_agent, current_agent)
    |> assign(:transition_symbol, transition_symbol)
  end

  # Read from the registration's recovery record on every mount and action.
  defp assign_recovery(socket) do
    socket
    |> assign(:recovery, FleetGeneration.registration_recovery(socket.assigns.current_scope))
    |> assign(:adopt_form, to_form(%{"agent_token" => "", "confirmed" => "false"}, as: "adopt"))
  end

  @impl true
  def handle_event("reconcile", _params, socket) do
    case FleetGeneration.reconcile_registration(socket.assigns.current_scope) do
      {:ok, :adopted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent #{socket.assigns.recovery.symbol} adopted.")
         |> redirect(to: ~p"/mission-control")}

      {:ok, :clear} ->
        {:noreply,
         socket
         |> assign_recovery()
         |> put_flash(:info, "The game shows that registration never took effect. You can mint.")}

      {:error, reason} ->
        {:noreply, socket |> assign_recovery() |> put_flash(:error, recovery_error(reason))}
    end
  end

  def handle_event("adopt_registered", %{"adopt" => params}, socket) do
    confirmed = params["confirmed"] == "true"

    case FleetGeneration.adopt_registered_agent(
           socket.assigns.current_scope,
           params["agent_token"] || "",
           confirmed
         ) do
      {:ok, %{agent: agent}} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent #{agent.symbol} adopted.")
         |> redirect(to: ~p"/mission-control")}

      {:error, reason} ->
        {:noreply, socket |> assign_recovery() |> put_flash(:error, recovery_error(reason))}
    end
  end

  def handle_event("mint", %{"agent" => mint_params}, socket) do
    case FleetGeneration.mint(socket.assigns.current_scope, mint_params) do
      {:ok, %{agent: agent, retired_symbols: retired_symbols}} ->
        retired_message =
          case retired_symbols do
            [] -> ""
            nil -> ""
            symbols -> " Retired stale agents: #{Enum.join(symbols, ", ")}."
          end

        {:noreply,
         socket
         |> put_flash(:info, "Agent #{agent.symbol} minted.#{retired_message}")
         |> redirect(to: ~p"/mission-control")}

      {:error, :account_token_not_linked} ->
        {:noreply,
         socket
         |> put_flash(:error, "Link your AccountToken in Settings before minting.")
         |> redirect(to: ~p"/operators/settings")}

      {:error, :runtime_authority_unavailable} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Minting is temporarily unavailable. Please try again shortly."
         )}

      {:error, :registration_unresolved} ->
        socket = assign_recovery(socket)
        {:noreply, put_flash(socket, :error, recovery_error(:registration_unresolved))}

      {:error, :current_fleet_exists} ->
        socket = assign_current_agent(socket)

        {:noreply,
         put_flash(
           socket,
           :error,
           "This deployment already has a current Agent#{current_agent_suffix(socket)}. No Agent was minted."
         )}

      {:error, :fleet_transition_pending} ->
        {:noreply,
         socket
         |> assign_current_agent()
         |> put_flash(
           :error,
           "A Server Reset replacement is pending. No Agent was minted; review it in Mission Control."
         )}

      {:error, %{summary: summary}} ->
        {:noreply, put_flash(socket, :error, summary)}

      {:error, :stale_symbol_owned_elsewhere} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That symbol is retained as a stale Agent by another Operator. Choose a different symbol."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      {:error, %{message: message}} ->
        {:noreply, socket |> put_flash(:error, mint_error_message(message))}
    end
  end

  def handle_event("validate", %{"agent" => mint_params}, socket) do
    changeset = Agent.change_mint(mint_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp recovery_error(:registration_unresolved),
    do: "The registration outcome is still unknown. No additional registration was dispatched."

  defp recovery_error(:registration_identity_mismatch),
    do: "That AgentToken does not authenticate as the registered symbol. Nothing was adopted."

  defp recovery_error(:confirmation_required), do: "Confirm the AgentToken before adopting."
  defp recovery_error(:agent_token_required), do: "Enter the AgentToken to adopt."

  defp recovery_error(:current_fleet_exists),
    do: "This deployment already has a current Agent. Nothing was adopted."

  defp recovery_error(:runtime_authority_unavailable),
    do: "Recovery is temporarily unavailable. Please try again shortly."

  defp recovery_error(_reason), do: "Recovery did not complete. Its state is shown below."

  defp current_agent_suffix(%{assigns: %{current_agent: symbol}}) when is_binary(symbol),
    do: ", #{symbol}"

  defp current_agent_suffix(_socket), do: ""

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "agent")
    assign(socket, form: form)
  end

  defp mint_error_message(message) do
    if String.contains?(message, "Expected \"account-token\" but received agent-token") do
      "Use an AccountToken to mint agents. An AgentToken belongs in the existing-agent import form."
    else
      message
    end
  end
end
