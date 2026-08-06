defmodule SpaceTradersWeb.OperatorLive.Mint do
  @moduledoc """
  Mints a new in-game agent (chosen symbol + faction) via the operator's linked
  AccountToken. The resulting AgentToken is stored encrypted, per-agent.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.Agent
  alias SpaceTraders.API.Model.FactionSymbol

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Mint an agent
            <:subtitle>
              <%= if @account_token_linked? do %>
                Choose a symbol and faction to register a new agent in the game.
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

        <%= if @account_token_linked? do %>
          <.form for={@form} id="mint_form" phx-submit="mint" phx-change="validate">
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

            <.button phx-disable-with="Minting..." class="btn btn-primary w-full">
              Mint agent
            </.button>
          </.form>
        <% else %>
          <div class="alert alert-warning mt-8">
            Link your AccountToken in
            <.link navigate={~p"/operators/settings"} class="underline">Settings</.link>
            to mint agents.
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    operator = socket.assigns.current_scope.operator

    socket =
      socket
      |> assign(:factions, FactionSymbol.values())
      |> assign(:account_token_linked?, not is_nil(operator.account_token))
      |> assign_form(Agent.change_mint())

    {:ok, socket, temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("mint", %{"agent" => mint_params}, socket) do
    operator = socket.assigns.current_scope.operator

    case Agent.mint_agent(operator, mint_params) do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Agent #{agent.symbol} minted.")
         |> redirect(to: ~p"/")}

      {:error, :account_token_not_linked} ->
        {:noreply,
         socket
         |> put_flash(:error, "Link your AccountToken in Settings before minting.")
         |> redirect(to: ~p"/operators/settings")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :insert))}

      {:error, %{message: message}} ->
        {:noreply, socket |> put_flash(:error, message)}
    end
  end

  def handle_event("validate", %{"agent" => mint_params}, socket) do
    changeset = Agent.change_mint(mint_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "agent")
    assign(socket, form: form)
  end
end
