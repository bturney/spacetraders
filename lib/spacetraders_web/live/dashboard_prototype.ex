defmodule SpaceTradersWeb.DashboardPrototype do
  @moduledoc false

  use SpaceTradersWeb, :html

  # PROTOTYPE: Three Fleet Operations Console layouts, switchable with ?prototype=a|b|c.
  # This is a read-only design artifact for issue #99, not production dashboard code.
  attr :variant, :string, required: true

  def render(assigns) do
    ~H"""
    <div phx-window-keydown="prototype_variant" class="space-y-6 pb-24">
      <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300 pb-5">
        <div>
          <p class="eyebrow">Prototype · fleet operations console</p>
          <h1 class="mt-1 text-3xl font-bold tracking-tight">Mining loop control room</h1>
          <p class="mt-2 max-w-2xl text-sm leading-6 opacity-70">
            Read-only layout study. Select a Ship, inspect the next action, then take the one safe control.
          </p>
        </div>
        <span class="badge badge-warning badge-outline">Not connected to Autopilot</span>
      </div>

      <%= case @variant do %>
        <% "a" -> %>
          <.timeline_layout />
        <% "b" -> %>
          <.map_layout />
        <% "c" -> %>
          <.attention_layout />
      <% end %>

      <.switcher variant={@variant} />
    </div>
    """
  end

  defp timeline_layout(assigns) do
    ~H"""
    <section class="grid gap-5 xl:grid-cols-[15rem_minmax(0,1fr)_18rem]">
      <.fleet_roster />
      <main class="min-w-0 space-y-5">
        <div class="card border border-primary/40 bg-base-200 p-5 shadow-lg shadow-primary/5 sm:p-7">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="eyebrow">Selected ship · extraction loop</p>
              <h2 class="mt-1 font-mono text-2xl font-bold">ORBITALIST-3</h2>
              <p class="mt-2 text-sm opacity-70">At X1-UX81-A1 · Ore asteroid · cargo 28 / 40</p>
            </div>
            <div class="text-right">
              <span class="badge badge-primary badge-lg">AUTOPILOT · ACTIVE</span>
              <p class="mt-2 text-xs opacity-60">Loop 04 · started 14:32 UTC</p>
            </div>
          </div>
          <div class="mt-6 border-y border-base-300 py-5">
            <div class="flex items-center justify-between gap-4">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.18em] opacity-60">Current action</p>
                <p class="mt-1 text-xl font-semibold">Cooldown after extraction</p>
              </div>
              <time class="font-mono text-3xl font-bold text-primary">00:18</time>
            </div>
            <div class="mt-4 h-2 overflow-hidden rounded-full bg-base-300">
              <div class="h-full w-2/3 bg-primary"></div>
            </div>
            <p class="mt-3 text-sm opacity-70">
              Next: extract until cargo reaches 32 units, then navigate to market.
            </p>
          </div>
          <div class="mt-5 flex flex-wrap gap-3">
            <button type="button" class="btn btn-warning">Pause loop</button>
            <button type="button" class="btn btn-ghost">Stop to Manual</button>
            <button type="button" class="btn btn-ghost btn-sm">View configuration</button>
          </div>
        </div>
        <.activity />
      </main>
      <.loop_summary />
    </section>
    """
  end

  defp map_layout(assigns) do
    ~H"""
    <section class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_24rem]">
      <main class="space-y-5">
        <div class="card overflow-hidden border border-base-300 bg-base-200">
          <div class="flex flex-wrap items-center justify-between gap-4 border-b border-base-300 p-5">
            <div>
              <p class="eyebrow">System map · ship workspace</p><h2 class="mt-1 font-mono text-xl font-bold">
                X1-UX81
              </h2>
            </div>
            <div class="flex gap-2">
              <span class="badge badge-outline">3 ships</span><span class="badge badge-primary">ORBITALIST-3 selected</span>
            </div>
          </div>
          <div class="bg-grid relative min-h-96 overflow-hidden p-6">
            <div class="absolute left-[16%] top-[63%] grid size-16 place-items-center rounded-full border-2 border-secondary bg-secondary/15 font-mono text-xs font-bold">
              A1<br />ORE
            </div>
            <div class="absolute right-[16%] top-[27%] grid size-16 place-items-center rounded border-2 border-primary bg-primary/15 font-mono text-xs font-bold">
              A2<br />MARKET
            </div>
            <div class="absolute left-[29%] top-[52%] h-0.5 w-[47%] origin-left -rotate-[28deg] border-t-2 border-dashed border-warning">
            </div>
            <div class="absolute left-[29%] top-[52%] size-5 rounded-full border-4 border-base-100 bg-primary shadow-[0_0_0_6px_color-mix(in_oklab,var(--color-primary)_30%,transparent)]">
            </div>
            <div class="absolute bottom-5 left-5 max-w-xs rounded border border-base-content/15 bg-base-100/95 p-4 shadow-xl">
              <p class="eyebrow">ORBITALIST-3 · active</p><p class="mt-1 font-semibold">
                Cooldown after extraction · 00:18
              </p>
              <p class="mt-2 text-xs opacity-70">
                Route holds at A1 until cargo reaches 32 / 40, then travels to A2.
              </p>
            </div>
          </div>
        </div>
        <div class="card border border-base-300 bg-base-200 p-5"><.activity /></div>
      </main>
      <aside class="space-y-5">
        <.fleet_roster />
        <.loop_summary />
        <div class="card border border-primary/40 bg-base-200 p-5">
          <p class="eyebrow">Control</p><button type="button" class="btn btn-warning mt-3 w-full">Pause loop</button><button
            type="button"
            class="btn btn-ghost mt-2 w-full"
          >Stop to Manual</button>
        </div>
      </aside>
    </section>
    """
  end

  defp attention_layout(assigns) do
    ~H"""
    <section class="grid gap-5 xl:grid-cols-[15rem_minmax(0,1fr)_18rem]">
      <.attention_roster />
      <main class="min-w-0 space-y-5">
        <div class="card border border-warning/50 bg-base-200 p-5 shadow-lg shadow-warning/5 sm:p-7">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <p class="eyebrow text-warning">Selected ship · needs operator attention</p>
              <h2 class="mt-1 font-mono text-2xl font-bold">ORBITALIST-3</h2>
              <p class="mt-2 text-sm opacity-70">
                At X1-UX81-A1 · cargo 32 / 40 · loop paused safely
              </p>
            </div>
            <span class="badge badge-warning badge-lg">BLOCKED</span>
          </div>
          <div class="mt-6 border-y border-warning/30 bg-warning/5 py-5">
            <p class="text-xs font-bold uppercase tracking-[0.18em] text-warning">Recovery needed</p>
            <p class="mt-1 text-xl font-semibold">Market refresh required before navigation</p>
            <p class="mt-3 max-w-2xl text-sm leading-6 opacity-80">
              The Market changed while the Ship was offline. Revalidate its cargo, location, and configured Waypoints before letting the loop continue.
            </p>
            <div class="mt-4 grid gap-3 text-sm sm:grid-cols-3">
              <div>
                <p class="opacity-60">Last attempt</p><p class="mt-1 font-semibold">Navigate to A2</p>
              </div>
              <div>
                <p class="opacity-60">Known cargo</p><p class="mt-1 font-mono font-semibold">
                  32 / 40 IRON_ORE
                </p>
              </div>
              <div>
                <p class="opacity-60">Recorded</p><p class="mt-1 font-mono font-semibold">
                  14:50:12 UTC
                </p>
              </div>
            </div>
          </div>
          <div class="mt-5 flex flex-wrap gap-3">
            <button type="button" class="btn btn-primary">Resume after revalidation</button>
            <button type="button" class="btn btn-ghost">Stop to Manual</button>
          </div>
        </div>
        <.activity />
      </main>
      <.loop_summary />
    </section>
    """
  end

  defp fleet_roster(assigns) do
    ~H"""
    <aside class="card h-fit border border-base-300 bg-base-200 p-4">
      <div class="flex items-center justify-between">
        <div>
          <p class="eyebrow">Fleet</p><h2 class="mt-1 font-semibold">3 ships</h2>
        </div><button type="button" class="btn btn-ghost btn-xs">Map</button>
      </div>
      <div class="mt-4 space-y-2">
        <button type="button" class="w-full rounded border border-primary bg-primary/10 p-3 text-left"><p class="font-mono text-sm font-bold">
          ORBITALIST-3
        </p><p class="mt-1 text-xs text-primary">Autopilot · cooldown 00:18</p></button>
        <button type="button" class="w-full rounded border border-base-300 p-3 text-left"><p class="font-mono text-sm font-bold">
          ORBITALIST-1
        </p><p class="mt-1 text-xs opacity-60">Manual · docked at A2</p></button>
        <button type="button" class="w-full rounded border border-base-300 p-3 text-left"><p class="font-mono text-sm font-bold">
          ORBITALIST-2
        </p><p class="mt-1 text-xs opacity-60">Manual · in transit</p></button>
      </div>
    </aside>
    """
  end

  defp attention_roster(assigns) do
    ~H"""
    <aside class="card h-fit border border-base-300 bg-base-200 p-4">
      <div class="flex items-center justify-between">
        <div>
          <p class="eyebrow">Fleet</p><h2 class="mt-1 font-semibold">3 ships</h2>
        </div>
        <span class="badge badge-warning badge-sm">1 needs attention</span>
      </div>
      <div class="mt-4 space-y-2">
        <button
          type="button"
          class="w-full rounded border-l-4 border-warning bg-warning/10 p-3 text-left ring-1 ring-warning/40"
        >
          <div class="flex items-center justify-between gap-2">
            <p class="font-mono text-sm font-bold">ORBITALIST-3</p><span class="badge badge-warning badge-xs">Blocked</span>
          </div>
          <p class="mt-1 text-xs opacity-70">Market refresh required</p>
        </button>
        <button type="button" class="w-full rounded border border-base-300 p-3 text-left"><p class="font-mono text-sm font-bold">
          ORBITALIST-1
        </p><p class="mt-1 text-xs opacity-60">Manual · docked at A2</p></button>
        <button type="button" class="w-full rounded border border-base-300 p-3 text-left"><p class="font-mono text-sm font-bold">
          ORBITALIST-2
        </p><p class="mt-1 text-xs opacity-60">Manual · in transit</p></button>
      </div>
      <p class="mt-4 text-xs opacity-60">Healthy Autopilot Ships stay quiet.</p>
    </aside>
    """
  end

  defp loop_summary(assigns) do
    ~H"""
    <aside class="card h-fit border border-base-300 bg-base-200 p-5">
      <p class="eyebrow">Loop configuration</p><h2 class="mt-1 font-semibold">Local mining loop</h2><dl class="mt-5 space-y-4 text-sm">
        <div>
          <dt class="opacity-60">Extract at</dt><dd class="mt-1 font-mono font-semibold">
            X1-UX81-A1
          </dd>
        </div><div>
          <dt class="opacity-60">Sell at</dt><dd class="mt-1 font-mono font-semibold">X1-UX81-A2</dd>
        </div><div>
          <dt class="opacity-60">Depart at cargo</dt><dd class="mt-1 font-mono font-semibold">
            32 / 40 units
          </dd>
        </div>
      </dl><button type="button" class="btn btn-ghost btn-sm mt-5 w-full">Edit configuration</button><div class="mt-5 border-t border-base-300 pt-4">
        <p class="text-xs font-bold uppercase tracking-wider opacity-50">Autopilot policy</p><p class="mt-2 text-xs opacity-60">
          Reserved for a later phase. This loop has no route optimization or flight-mode policy.
        </p>
      </div>
    </aside>
    """
  end

  defp activity(assigns) do
    ~H"""
    <section class="min-w-0">
      <div class="flex items-end justify-between gap-3">
        <div>
          <p class="eyebrow">Activity</p><h2 class="mt-1 font-semibold">Latest 10 actions</h2>
        </div><button type="button" class="btn btn-ghost btn-xs">Full audit</button>
      </div><ol class="mt-4 space-y-0 border-l-2 border-base-300 pl-4 text-sm">
        <li class="relative pb-5">
          <i class="absolute -left-[1.43rem] top-1 size-3 rounded-full bg-primary"></i><div class="flex justify-between gap-3">
            <p><b>Extracted 4 IRON_ORE</b> · cargo 28 / 40</p><time class="font-mono text-xs opacity-60">14:45:06</time>
          </div><p class="mt-1 text-xs opacity-60">Cooldown scheduled for 00:30</p>
        </li><li class="relative pb-5">
          <i class="absolute -left-[1.43rem] top-1 size-3 rounded-full bg-success"></i><div class="flex justify-between gap-3">
            <p><b>Cooldown complete</b> · next extraction armed</p><time class="font-mono text-xs opacity-60">14:44:36</time>
          </div>
        </li><li class="relative">
          <i class="absolute -left-[1.43rem] top-1 size-3 rounded-full bg-success"></i><div class="flex justify-between gap-3">
            <p><b>Extracted 3 IRON_ORE</b> · cargo 24 / 40</p><time class="font-mono text-xs opacity-60">14:44:06</time>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  defp switcher(assigns) do
    names = %{"a" => "Timeline command", "b" => "Map-first workspace", "c" => "Inline recovery"}
    previous = %{"a" => "c", "b" => "a", "c" => "b"}
    next = %{"a" => "b", "b" => "c", "c" => "a"}
    assigns = assign(assigns, names: names, previous: previous, next: next)

    ~H"""
    <nav
      aria-label="Prototype variants"
      class="fixed bottom-5 left-1/2 z-50 flex -translate-x-1/2 items-center gap-2 rounded-full border border-base-content/20 bg-base-100 px-2 py-2 shadow-2xl"
    >
      <button
        type="button"
        phx-click="prototype_variant"
        phx-value-variant={@previous[@variant]}
        class="btn btn-circle btn-sm"
        aria-label="Previous prototype variant"
      >←</button>
      <span class="min-w-44 text-center text-xs font-semibold"><span class="font-mono text-primary">{@variant
      |> String.upcase()}</span>
      · {@names[@variant]}</span>
      <button
        type="button"
        phx-click="prototype_variant"
        phx-value-variant={@next[@variant]}
        class="btn btn-circle btn-sm"
        aria-label="Next prototype variant"
      >→</button>
    </nav>
    """
  end
end
