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
          <%= if @account_token_linked? do %>
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
          <% else %>
            <div class="alert alert-warning mt-8">
              Link your AccountToken in
              <.link navigate={~p"/operators/settings"} class="underline">Settings</.link>
              to mint agents.
            </div>
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
      |> assign_form(Agent.change_mint())

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  defp assign_current_agent(socket) do
    current_agent =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent}} -> agent.symbol
        _ -> nil
      end

    assign(socket, :current_agent, current_agent)
  end

  @impl true
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

      {:error, :current_fleet_exists} ->
        socket = assign_current_agent(socket)

        {:noreply,
         put_flash(
           socket,
           :error,
           "This deployment already has a current Agent#{current_agent_suffix(socket)}. No Agent was minted."
         )}

      {:error, :emergency_stopped} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Emergency Stop is engaged. Minting is suppressed until it is resumed."
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
