defmodule SpaceTradersWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use SpaceTradersWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :wide, :boolean,
    default: false,
    doc: "use a wider content column (e.g. the fleet card grid dashboard)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-grid">
      <header class="border-b border-base-300/70 bg-base-100/90 backdrop-blur">
        <div class="mx-auto flex min-h-16 max-w-[1440px] items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <.link navigate={~p"/"} class="flex min-w-0 items-center gap-3">
            <span class="brand-mark"><img src={~p"/images/logo.svg"} width="28" height="20" /></span>
            <span class="min-w-0">
              <span class="block truncate text-sm font-bold tracking-[0.18em] text-primary">SPACETRADERS</span>
              <span class="hidden text-[10px] uppercase tracking-[0.24em] opacity-50 sm:block">Operator operations center</span>
            </span>
          </.link>
          <nav class="flex items-center gap-1 sm:gap-2" aria-label="Operator navigation">
            <%= if @current_scope do %>
              <span class="hidden max-w-44 truncate px-2 text-xs opacity-60 md:block">{@current_scope.operator.email}</span>
              <.link navigate={~p"/agents/new"} class="btn btn-sm btn-primary">Mint agent</.link>
              <.link navigate={~p"/operators/settings"} class="btn btn-sm btn-ghost">Settings</.link>
              <.link href={~p"/operators/log-out"} method="delete" class="btn btn-sm btn-ghost">Log out</.link>
            <% else %>
              <.link navigate={~p"/operators/register"} class="btn btn-sm btn-ghost">Register</.link>
              <.link navigate={~p"/operators/log-in"} class="btn btn-sm btn-primary">Log in</.link>
            <% end %>
            <.theme_toggle />
          </nav>
        </div>
      </header>

      <main class="mx-auto w-full max-w-[1440px] px-4 py-8 sm:px-6 sm:py-10 lg:px-8">
        <div class={[@wide && "space-y-6", !@wide && "mx-auto max-w-2xl space-y-6"]}>
          {render_slot(@inner_block)}
        </div>
      </main>
      <footer class="mx-auto max-w-[1440px] px-4 pb-8 text-xs uppercase tracking-[0.18em] opacity-40 sm:px-6 lg:px-8">
        SpaceTraders operations center <span class="mx-2">/</span> keep learning, keep exploring
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="theme-switcher card relative flex flex-row items-center border border-base-300 bg-base-200 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
