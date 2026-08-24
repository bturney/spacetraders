defmodule SpaceTradersWeb.DashboardPrototype do
  @moduledoc false

  use SpaceTradersWeb, :html

  # PROTOTYPE: Three automated control-panel layouts for issue 177, switchable via
  # ?prototype=a|b|c. Controls drive only the in-memory prototype journey.
  attr :variant, :string, required: true
  attr :stage, :integer, required: true
  attr :path, :string, required: true
  attr :view, :string, required: true

  def render(assigns) do
    ~H"""
    <div phx-window-keydown="prototype_variant" class="space-y-3 pb-28 font-mono">
      <%= case @variant do %>
        <% "a" -> %>
          <%= if @view == "ship" do %>
            <button
              type="button"
              phx-click="prototype_view"
              phx-value-view="fleet"
              class="btn btn-ghost btn-sm"
            >← FLEET</button>
            <.ship_bar stage={@stage} />
            <.console_layout stage={@stage} path={@path} />
          <% else %>
            <.fleet_layout stage={@stage} path={@path} />
          <% end %>
        <% "b" -> %>
          <.ship_bar stage={@stage} />
          <.map_layout stage={@stage} path={@path} />
        <% "c" -> %>
          <.ship_bar stage={@stage} />
          <.sequencer_layout stage={@stage} path={@path} />
      <% end %>
      <.switcher variant={@variant} />
    </div>
    """
  end

  defp fleet_layout(assigns) do
    ~H"""
    <section class="space-y-3">
      <header class="flex flex-wrap items-center justify-between gap-2 rounded border border-base-300 bg-base-300/45 p-2">
        <div class="px-2">
          <p class="text-[0.58rem] font-bold tracking-widest opacity-45">ORBITALIST</p><h1 class="font-black">
            FLEET CONTROL
          </h1>
        </div>
        <div class="flex gap-2">
          <.readout label="SHIPS" value="3" /><.readout label="ACTIVE" value="2" /><.readout
            label="ATTENTION"
            value="1"
          />
        </div>
      </header>

      <div class="grid gap-3 xl:grid-cols-[minmax(0,1fr)_22rem]">
        <main class="order-1 overflow-hidden rounded border border-base-300 bg-base-200">
          <div class="flex items-center gap-2 border-b border-base-300 p-2">
            <button type="button" class="btn btn-primary btn-sm">X1-UX81</button><button
              type="button"
              class="btn btn-ghost btn-sm"
            >SYSTEM</button><button type="button" class="btn btn-ghost btn-sm">INTELLIGENCE</button>
            <span class="ml-auto text-[0.6rem] opacity-45">3 SHIPS · 18 WAYPOINTS</span>
          </div>
          <div class="bg-grid relative min-h-[24rem] sm:min-h-[36rem]">
            <svg
              class="absolute inset-0 size-full"
              viewBox="0 0 800 500"
              aria-label="Fleet System map"
            >
              <path
                d="M120 365 C290 300 350 175 585 125"
                fill="none"
                stroke="currentColor"
                stroke-opacity=".14"
                stroke-width="3"
              />
              <path
                d="M585 125 L790 42"
                fill="none"
                stroke="var(--color-primary)"
                stroke-width="3"
                stroke-dasharray="9 8"
              />
              <circle cx="120" cy="365" r="24" fill="var(--color-secondary)" /><circle
                cx="585"
                cy="125"
                r="29"
                fill="var(--color-primary)"
              /><circle cx="365" cy="340" r="16" fill="var(--color-info)" /><circle
                cx="285"
                cy="170"
                r="12"
                fill="var(--color-info)"
              />
              <path d="M120 365 l10 -28 l10 28 z" fill="var(--color-base-content)" /><circle
                cx="365"
                cy="312"
                r="10"
                fill="var(--color-base-content)"
              /><rect
                x="275"
                y="142"
                width="18"
                height="18"
                fill="var(--color-warning)"
                transform="rotate(45 284 151)"
              />
              <text x="76" y="412" fill="currentColor" font-size="15" font-weight="800">
                ORBITALIST-1
              </text><text x="330" y="380" fill="currentColor" font-size="15" font-weight="800">
                -2
              </text><text x="252" y="125" fill="currentColor" font-size="15" font-weight="800">
                -3
              </text><text x="540" y="176" fill="currentColor" font-size="15" font-weight="800">
                GATE
              </text>
            </svg>
            <div class="absolute left-2 right-2 top-2 rounded border border-primary/40 bg-base-100/95 p-3 shadow-xl sm:left-auto sm:w-80">
              <div class="flex items-start justify-between gap-2">
                <div>
                  <p class="text-[0.52rem] tracking-widest opacity-45">SELECTED WAYPOINT</p><p class="mt-1 text-sm font-black">
                    X1-UX81-GATE
                  </p><p class="mt-1 text-[0.58rem] opacity-50">JUMP GATE · 31u</p>
                </div>
                <button type="button" class="btn btn-ghost btn-xs">×</button>
              </div>
              <div class="mt-3 grid grid-cols-[1fr_auto] gap-2">
                <button type="button" class="btn btn-primary btn-sm">NAVIGATE -1</button><button
                  type="button"
                  class="btn btn-ghost btn-sm"
                >SHIP ▾</button>
              </div>
            </div>
            <div class="absolute bottom-2 left-2 flex gap-3 rounded bg-base-100/90 px-3 py-2 text-[0.58rem] shadow">
              <span>▲ ACTIVE</span><span>● TRANSIT</span><span class="text-warning">◆ BLOCKED</span>
            </div>
          </div>
        </main>

        <aside class="order-2 space-y-2">
          <p class="px-1 text-[0.65rem] font-black tracking-[.18em]">SHIPS</p>
          <.fleet_ship
            symbol="ORBITALIST-1"
            location="X1-UX81-A1 · DOCKED"
            job="EXPANSION"
            action={current_action(@stage, @path)}
            tone="active"
            primary="PAUSE"
            secondary="NAVIGATE"
          />
          <.fleet_ship
            symbol="ORBITALIST-2"
            location="→ X1-UX81-MKT · 00:42"
            job="MARKET TRADING"
            action="NAVIGATE"
            tone="transit"
            primary="TRACK"
            secondary="DETAIL"
          />
          <.fleet_ship
            symbol="ORBITALIST-3"
            location="X1-UX81-AST · ORBIT"
            job="SYSTEM EXPLORATION"
            action="NO ACQUISITION PATH"
            tone="blocked"
            primary="RESOLVE"
            secondary="CONTROL"
          />
          <button type="button" class="btn btn-outline btn-sm w-full">+ ASSIGN JOB</button>
        </aside>
      </div>
    </section>
    """
  end

  attr :symbol, :string, required: true
  attr :location, :string, required: true
  attr :job, :string, required: true
  attr :action, :string, required: true
  attr :tone, :string, required: true
  attr :primary, :string, required: true
  attr :secondary, :string, required: true

  defp fleet_ship(assigns) do
    ~H"""
    <article class={[
      "w-full rounded border bg-base-200 p-3 text-left transition hover:border-primary",
      @tone == "active" && "border-primary/45",
      @tone == "transit" && "border-base-300",
      @tone == "blocked" && "border-warning/55"
    ]}>
      <button type="button" phx-click="prototype_view" phx-value-view="ship" class="w-full text-left">
        <div class="flex items-center justify-between gap-2">
          <b class="text-sm">{@symbol}</b><span class={[
            "size-2 rounded-full",
            @tone == "active" && "animate-pulse bg-primary",
            @tone == "transit" && "bg-info",
            @tone == "blocked" && "bg-warning"
          ]}></span>
        </div>
        <p class="mt-1 text-[0.6rem] opacity-50">{@location}</p>
        <div class="mt-3 border-t border-base-300 pt-2">
          <p class="text-[0.52rem] tracking-widest opacity-40">{@job}</p><p class="mt-1 text-[0.65rem] font-bold">
            {@action}
          </p>
        </div>
      </button>
      <div class="mt-3 grid grid-cols-2 gap-2">
        <button
          type="button"
          class={[
            @tone == "blocked" && "btn btn-warning btn-xs",
            @tone != "blocked" && "btn btn-primary btn-xs"
          ]}
        >{@primary}</button><button
          type="button"
          phx-click="prototype_view"
          phx-value-view="ship"
          class="btn btn-ghost btn-xs"
        >{@secondary}</button>
      </div>
    </article>
    """
  end

  defp ship_bar(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center gap-2 rounded border border-base-300 bg-base-300/45 p-2 sm:gap-3">
      <button type="button" class="btn btn-ghost btn-sm min-w-0 flex-1 justify-start sm:flex-none">
        <span class="truncate font-bold">ORBITALIST-1</span><span class="opacity-45">⌄</span>
      </button>
      <.readout label="NAV" value={nav_value(@stage)} />
      <.readout label="FUEL" value="84 / 100" />
      <.readout label="CARGO" value={cargo_value(@stage)} />
      <div class="ml-auto flex items-center gap-2 rounded border border-primary/40 bg-base-100 px-3 py-2">
        <i class="size-2 animate-pulse rounded-full bg-primary"></i>
        <div>
          <p class="text-[0.58rem] font-bold tracking-widest opacity-50">JOB CONTROL</p><p class="text-xs font-bold">
            {job_state(@stage)}
          </p>
        </div>
      </div>
    </header>
    """
  end

  defp readout(assigns) do
    ~H"""
    <div class="min-w-20 rounded bg-base-100 px-3 py-2 sm:min-w-24">
      <p class="text-[0.55rem] font-bold tracking-widest opacity-45">{@label}</p><p class="text-xs font-bold">
        {@value}
      </p>
    </div>
    """
  end

  defp console_layout(assigns) do
    ~H"""
    <section class="grid gap-3 xl:grid-cols-[minmax(0,1.55fr)_minmax(19rem,.7fr)]">
      <main class="grid gap-3 sm:grid-cols-2">
        <.nav_panel stage={@stage} path={@path} />
        <.ship_panel stage={@stage} path={@path} />
        <.cargo_panel stage={@stage} path={@path} />
        <.intel_panel stage={@stage} />
      </main>
      <aside class="space-y-3">
        <.automation_tape stage={@stage} path={@path} />
        <.transport_controls stage={@stage} path={@path} />
      </aside>
    </section>
    """
  end

  defp map_layout(assigns) do
    ~H"""
    <section class="grid gap-3 xl:grid-cols-[minmax(0,1fr)_18rem]">
      <main class="overflow-hidden rounded border border-base-300 bg-base-200">
        <div class="flex flex-wrap items-center gap-2 border-b border-base-300 p-2">
          <button type="button" class="btn btn-primary btn-sm">X1-UX81</button>
          <button type="button" class="btn btn-ghost btn-sm">Waypoints</button>
          <button type="button" class="btn btn-ghost btn-sm">Markets</button>
          <span class="ml-auto text-xs opacity-50">18 / 21 observed</span>
        </div>
        <div class="bg-grid relative min-h-[27rem] sm:min-h-[35rem]">
          <svg
            class="absolute inset-0 size-full"
            viewBox="0 0 800 500"
            aria-label="System control map"
          >
            <path
              d="M120 365 C290 300 350 175 585 125"
              fill="none"
              stroke="currentColor"
              stroke-opacity=".18"
              stroke-width="3"
            />
            <path
              d="M585 125 L790 42"
              fill="none"
              stroke="var(--color-primary)"
              stroke-width="4"
              stroke-dasharray="9 8"
            />
            <circle cx="120" cy="365" r="23" fill="var(--color-secondary)" />
            <circle cx="585" cy="125" r="30" fill="var(--color-primary)" />
            <circle cx="365" cy="340" r="15" fill="var(--color-info)" />
            <circle cx="285" cy="170" r="12" fill="var(--color-info)" />
            <text x="78" y="410" fill="currentColor" font-size="17" font-weight="800">SHIP</text>
            <text x="538" y="176" fill="currentColor" font-size="17" font-weight="800">GATE</text>
            <text x="680" y="60" fill="currentColor" font-size="14" opacity=".65">X1-DF55</text>
          </svg>
          <div class="absolute bottom-2 left-2 right-2 grid grid-cols-3 gap-2 sm:left-auto sm:w-96">
            <.map_control label="SCAN" active={@stage == 1} />
            <.map_control label="PLOT" active={@stage == 2} />
            <.map_control label={path_button_label(@path)} active={@stage >= 3} />
          </div>
        </div>
      </main>
      <aside class="space-y-3">
        <.route_selector stage={@stage} path={@path} />
        <.automation_tape stage={@stage} path={@path} />
        <.transport_controls stage={@stage} path={@path} />
      </aside>
    </section>
    """
  end

  defp map_control(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "relative min-h-16 rounded border bg-base-100/95 text-xs font-black shadow-lg",
        @active && "border-primary ring-2 ring-primary/30",
        !@active && "border-base-content/15"
      ]}
    >
      <span
        :if={@active}
        class="absolute right-1 top-1 rounded bg-primary px-1 text-[0.5rem] text-primary-content"
      >AUTO</span>{@label}
    </button>
    """
  end

  defp sequencer_layout(assigns) do
    ~H"""
    <section class="grid gap-3 lg:grid-cols-[15rem_minmax(0,1fr)]">
      <aside class="order-2 space-y-3 lg:order-1">
        <.ship_panel stage={@stage} path={@path} />
        <.transport_controls stage={@stage} path={@path} />
      </aside>
      <main class="order-1 space-y-3 lg:order-2">
        <div class="rounded border border-base-300 bg-base-200 p-3 sm:p-4">
          <div class="mb-3 flex items-center justify-between">
            <p class="text-xs font-black tracking-widest">JOB SEQUENCER</p><button
              type="button"
              class="btn btn-warning btn-xs"
            >PAUSE</button>
          </div>
          <div class="grid gap-2 sm:grid-cols-4">
            <.sequence_step number="01" label="SCAN" state={step_state(@stage, 1)} />
            <.sequence_step number="02" label="PLOT" state={step_state(@stage, 2)} />
            <.sequence_step number="03" label={prepare_label(@path)} state={step_state(@stage, 3)} />
            <.sequence_step
              number="04"
              label={path_button_label(@path)}
              state={step_state(@stage, 4)}
            />
          </div>
        </div>
        <div class="grid gap-3 md:grid-cols-2">
          <.route_selector stage={@stage} path={@path} />
          <.automation_tape stage={@stage} path={@path} />
          <.nav_panel stage={@stage} path={@path} />
          <.cargo_panel stage={@stage} path={@path} />
        </div>
      </main>
    </section>
    """
  end

  defp sequence_step(assigns) do
    ~H"""
    <div class={[
      "relative min-h-24 rounded border p-3",
      @state == :active && "border-primary bg-primary/10 ring-2 ring-primary/25",
      @state == :done && "border-success/50 bg-success/5",
      @state == :waiting && "border-base-300 opacity-45"
    ]}>
      <p class="text-[0.6rem] opacity-45">{@number}</p><p class="mt-5 font-black">{@label}</p>
      <span
        :if={@state == :active}
        class="absolute right-2 top-2 rounded bg-primary px-1 text-[0.5rem] text-primary-content"
      >PLAYING</span>
      <span :if={@state == :done} class="absolute right-2 top-2 text-success">✓</span>
    </div>
    """
  end

  defp nav_panel(assigns) do
    ~H"""
    <.instrument title="NAVIGATION" active={@stage in [2, 4]}>
      <div class="grid grid-cols-2 gap-2">
        <.control label="ORBIT" active={false} />
        <.control label="DOCK" active={@stage == 3 && @path == "repair"} />
        <.control label="NAVIGATE" active={@stage == 2} />
        <.control label={path_button_label(@path)} active={@stage == 4} />
      </div>
      <div class="mt-2 flex items-center justify-between rounded bg-base-300/50 px-3 py-2 text-xs">
        <span>X1-UX81-GATE</span><span class="text-primary">SET</span>
      </div>
      <div class="mt-2 grid grid-cols-4 gap-1">
        <button
          :for={destination <- ["HQ", "MARKET", "ASTEROID"]}
          type="button"
          class="btn btn-ghost btn-xs"
        >{destination}</button><button type="button" class="btn btn-ghost btn-xs">MAP…</button>
      </div>
    </.instrument>
    """
  end

  defp ship_panel(assigns) do
    ~H"""
    <.instrument title="SHIP" active={false}>
      <div class="grid grid-cols-2 gap-2 text-xs">
        <.meter label="FUEL" value="84%" width="84%" />
        <.meter label="CONDITION" value="100%" width="100%" />
      </div>
      <div class="mt-3 grid grid-cols-4 gap-1">
        <button
          :for={mode <- ["DRIFT", "STEALTH", "CRUISE", "BURN"]}
          type="button"
          class={[
            "rounded border py-2 text-[0.55rem] font-bold",
            mode == "CRUISE" && "border-primary bg-primary/10",
            mode != "CRUISE" && "border-base-300"
          ]}
        >{mode}</button>
      </div>
    </.instrument>
    """
  end

  defp cargo_panel(assigns) do
    ~H"""
    <.instrument title="CARGO / TRADE" active={@stage == 3 && @path == "repair"}>
      <div class="flex items-end justify-between">
        <div>
          <p class="text-[0.6rem] opacity-45">HOLD</p><p class="text-xl font-black">
            {cargo_value(@stage)}
          </p>
        </div><div class="text-right">
          <p class="text-[0.6rem] opacity-45">CREDITS</p><p class="font-bold">72,840</p>
        </div>
      </div>
      <div class="mt-3 grid grid-cols-3 gap-2">
        <.control label="BUY" active={@stage == 3 && @path == "repair"} />
        <.control label="SELL" active={false} />
        <.control label="DELIVER" active={@stage == 3 && @path == "repair"} />
      </div>
    </.instrument>
    """
  end

  defp intel_panel(assigns) do
    ~H"""
    <.instrument title="SENSORS" active={@stage == 1}>
      <div class="grid grid-cols-3 gap-2">
        <.control label="SCAN" active={@stage == 1} />
        <.control label="CHART" active={false} />
        <.control label="MARKET" active={false} />
      </div>
      <div class="mt-3 flex justify-between text-xs">
        <span>WAYPOINTS 18/18</span><span>LIVE 6/18</span>
      </div>
    </.instrument>
    """
  end

  slot :inner_block, required: true
  attr :title, :string, required: true
  attr :active, :boolean, required: true

  defp instrument(assigns) do
    ~H"""
    <section class={[
      "rounded border bg-base-200 p-3 sm:p-4",
      @active &&
        "border-primary shadow-[inset_0_0_18px_color-mix(in_oklab,var(--color-primary)_8%,transparent)]",
      !@active && "border-base-300"
    ]}>
      <div class="mb-3 flex items-center justify-between">
        <p class="text-[0.65rem] font-black tracking-[.18em]">{@title}</p><span
          :if={@active}
          class="flex items-center gap-1 text-[0.55rem] font-bold text-primary"
        ><i class="size-1.5 animate-pulse rounded-full bg-primary"></i>AUTO</span>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  defp control(assigns) do
    ~H"""
    <button
      type="button"
      class={[
        "relative min-h-12 rounded border text-[0.65rem] font-black",
        @active && "border-primary bg-primary/15 ring-1 ring-primary",
        !@active && "border-base-content/15 bg-base-100"
      ]}
    ><span :if={@active} class="absolute right-1 top-1 text-[0.45rem] text-primary">AUTO</span>{@label}</button>
    """
  end

  defp meter(assigns) do
    ~H"""
    <div>
      <div class="flex justify-between"><span class="opacity-50">{@label}</span><b>{@value}</b></div><div class="mt-1 h-1.5 bg-base-300">
        <div class="h-full bg-primary" style={"width: #{@width}"}></div>
      </div>
    </div>
    """
  end

  defp route_selector(assigns) do
    ~H"""
    <section class="rounded border border-base-300 bg-base-200 p-3">
      <p class="mb-2 text-[0.65rem] font-black tracking-[.18em]">ROUTE</p>
      <div class="grid gap-2">
        <.route_button path="jump" current={@path} title="JUMP" meta="gate ready · instant" />
        <.route_button path="repair" current={@path} title="REPAIR → JUMP" meta="12 circuitry due" />
        <.route_button path="warp" current={@path} title="WARP" meta="62 fuel · 18m" />
      </div>
    </section>
    """
  end

  defp route_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="prototype_journey"
      phx-value-stage="2"
      phx-value-path={@path}
      class={[
        "flex min-h-12 items-center justify-between rounded border px-3 text-left",
        @path == @current && "border-primary bg-primary/10",
        @path != @current && "border-base-content/15"
      ]}
    ><b class="text-xs">{@title}</b><span class="text-[0.6rem] opacity-50">{@meta}</span></button>
    """
  end

  defp automation_tape(assigns) do
    ~H"""
    <section class="rounded border border-primary/45 bg-base-200 p-3">
      <div class="flex items-center justify-between">
        <p class="text-[0.65rem] font-black tracking-[.18em]">JOB TAPE</p><span class="badge badge-primary badge-xs">RUNNING</span>
      </div>
      <div class="mt-3 border-l-2 border-primary/30 pl-3">
        <p class="text-[0.58rem] font-bold text-primary">NOW</p><p class="mt-1 text-sm font-black">
          {current_action(@stage, @path)}
        </p>
        <p class="mt-3 text-[0.58rem] font-bold opacity-40">NEXT</p><p class="mt-1 text-xs opacity-65">
          {next_action(@stage, @path)}
        </p>
      </div>
      <div class="mt-4 grid grid-cols-2 gap-2">
        <button type="button" class="btn btn-warning btn-sm">PAUSE</button><button
          type="button"
          class="btn btn-ghost btn-sm"
        >TAKE CONTROL</button>
      </div>
    </section>
    """
  end

  defp transport_controls(assigns) do
    ~H"""
    <section class="grid grid-cols-3 gap-2 rounded border border-base-300 bg-base-300/35 p-2">
      <button
        type="button"
        phx-click="prototype_journey"
        phx-value-stage={max(@stage - 1, 1)}
        phx-value-path={@path}
        class="btn btn-ghost btn-sm"
      >◀</button>
      <button
        type="button"
        phx-click="prototype_journey"
        phx-value-stage="1"
        phx-value-path={@path}
        class="btn btn-ghost btn-sm"
      >■</button>
      <button
        type="button"
        phx-click="prototype_journey"
        phx-value-stage={min(@stage + 1, 4)}
        phx-value-path={@path}
        class="btn btn-primary btn-sm"
      >▶</button>
    </section>
    """
  end

  defp switcher(assigns) do
    names = %{"a" => "Console", "b" => "Map deck", "c" => "Sequencer"}
    previous = %{"a" => "c", "b" => "a", "c" => "b"}
    next = %{"a" => "b", "b" => "c", "c" => "a"}
    assigns = assign(assigns, names: names, previous: previous, next: next)

    ~H"""
    <nav
      aria-label="Prototype variants"
      class="fixed bottom-4 left-1/2 z-50 flex w-[calc(100%-1rem)] max-w-sm -translate-x-1/2 items-center gap-2 rounded-full border border-base-content/20 bg-base-100 p-2 font-sans shadow-2xl"
    >
      <button
        type="button"
        phx-click="prototype_variant"
        phx-value-variant={@previous[@variant]}
        class="btn btn-circle btn-sm"
      >←</button>
      <span class="min-w-0 flex-1 truncate text-center text-xs font-semibold"><b class="text-primary">{String.upcase(
        @variant
      )}</b>
      · {@names[@variant]}</span>
      <button
        type="button"
        phx-click="prototype_variant"
        phx-value-variant={@next[@variant]}
        class="btn btn-circle btn-sm"
      >→</button>
    </nav>
    """
  end

  defp step_state(stage, step) when stage > step, do: :done
  defp step_state(stage, step) when stage == step, do: :active
  defp step_state(_stage, _step), do: :waiting
  defp nav_value(4), do: "X1-DF55"
  defp nav_value(_stage), do: "X1-UX81"
  defp cargo_value(3), do: "28 / 40"
  defp cargo_value(_stage), do: "0 / 40"
  defp job_state(4), do: "COMPLETE"
  defp job_state(_stage), do: "AUTO · PLAYING"
  defp path_button_label("jump"), do: "JUMP"
  defp path_button_label("repair"), do: "JUMP"
  defp path_button_label("warp"), do: "WARP"
  defp prepare_label("jump"), do: "APPROACH"
  defp prepare_label("repair"), do: "SUPPLY"
  defp prepare_label("warp"), do: "FUEL"
  defp current_action(1, _path), do: "SCAN X1-UX81-GATE"
  defp current_action(2, _path), do: "PLOT X1-DF55"
  defp current_action(3, "jump"), do: "NAVIGATE TO GATE"
  defp current_action(3, "repair"), do: "BUY ADVANCED_CIRCUITRY"
  defp current_action(3, "warp"), do: "REFUEL FOR WARP"
  defp current_action(4, "warp"), do: "WARP · X1-DF55"
  defp current_action(4, _path), do: "JUMP · X1-DF55"
  defp next_action(1, _path), do: "Select viable route"
  defp next_action(2, path), do: prepare_label(path)
  defp next_action(3, path), do: path_button_label(path)
  defp next_action(4, _path), do: "No queued control"
end
