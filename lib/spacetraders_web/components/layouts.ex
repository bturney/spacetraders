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

  attr :active, :atom,
    default: nil,
    values: [nil, :glance, :ships, :stats],
    doc: "the highlighted main destination"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100">
      <header class="border-b border-line bg-base-100">
        <div class="mx-auto flex min-h-14 max-w-[1360px] items-center justify-between gap-4 px-4 sm:px-6 lg:px-8">
          <.link navigate={~p"/mission-control"} class="flex min-w-0 items-center gap-3">
            <span class="brand-mark"><img src={~p"/images/logo.svg"} width="28" height="20" /></span>
            <span class="truncate text-sm font-bold tracking-[0.18em] text-primary">SPACETRADERS</span>
          </.link>
          <nav class="flex items-center gap-1 sm:gap-2" aria-label="Operator navigation">
            <%= if @current_scope do %>
              <div id="top-bar" class="hidden items-center gap-1 md:flex">
                <.link
                  navigate={~p"/mission-control"}
                  class={["btn btn-sm btn-ghost", @active == :glance && "text-primary"]}
                >Mission Control</.link>
                <.link
                  navigate={~p"/ships"}
                  class={["btn btn-sm btn-ghost", @active == :ships && "text-primary"]}
                >Ships</.link>
              </div>
              <details id="app-menu" class="dropdown dropdown-end">
                <summary class="btn btn-sm btn-ghost">Menu</summary>
                <ul class="menu dropdown-content z-20 w-52 rounded-box border border-line bg-base-200 p-2">
                  <li class="px-3 py-1 text-xs text-dim">{@current_scope.operator.email}</li>
                  <li><.link navigate={~p"/world"}>World</.link></li>
                  <li><.link navigate={~p"/strategy"}>Strategy</.link></li>
                  <li><.link navigate={~p"/generations"}>Generations</.link></li>
                  <li><.link navigate={~p"/operators/settings"}>Settings</.link></li>
                  <li><.link href={~p"/operators/log-out"} method="delete">Log out</.link></li>
                </ul>
              </details>
            <% else %>
              <.link navigate={~p"/operators/log-in"} class="btn btn-sm btn-primary">Log in</.link>
            <% end %>
          </nav>
        </div>
      </header>

      <main class="mx-auto w-full max-w-[1360px] px-4 py-6 pb-24 sm:px-6 sm:py-8 md:pb-10 lg:px-8">
        <div class={[@wide && "space-y-6", !@wide && "mx-auto max-w-2xl space-y-6"]}>
          {render_slot(@inner_block)}
        </div>
      </main>

      <.phone_tabs :if={@current_scope} active={@active} />
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Phone bottom tab bar: Glance | Ships | Stats. Built from Card and Eyebrow.
  Hidden from the `md` breakpoint up, where the top bar takes over.
  """
  attr :active, :atom, default: nil

  def phone_tabs(assigns) do
    assigns =
      assign(assigns, :tabs, [
        {:glance, "Glance", ~p"/mission-control"},
        {:ships, "Ships", ~p"/ships"},
        {:stats, "Stats", "/stats"}
      ])

    ~H"""
    <nav
      id="phone-tabs"
      class="fixed inset-x-0 bottom-0 z-20 md:hidden"
      aria-label="Primary navigation"
    >
      <.card class="grid grid-cols-3 !rounded-none !border-x-0 !border-b-0 !bg-tabbar !p-0">
        <.link
          :for={{key, label, path} <- @tabs}
          navigate={path}
          aria-current={@active == key && "page"}
          class={[
            "flex min-h-12 items-center justify-center",
            @active == key && "bg-base-300"
          ]}
        >
          <.eyebrow class={@active == key && "!text-primary"}>{label}</.eyebrow>
        </.link>
      </.card>
    </nav>
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
end
