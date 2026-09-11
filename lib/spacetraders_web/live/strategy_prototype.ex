defmodule SpaceTradersWeb.StrategyPrototype do
  @moduledoc false

  use SpaceTradersWeb, :html

  # PROTOTYPE: Three Fleet Strategy command models, switchable with ?strategy=a|b|c.
  # This is a read-only design artifact for issue #305, not production dashboard code.
  attr :variant, :string, required: true

  def render(assigns) do
    ~H"""
    <div phx-window-keydown="strategy_variant" class="space-y-6 pb-24">
      <%= case @variant do %>
        <% "a" -> %>
          <.briefing_room />
        <% "b" -> %>
          <.outcome_board />
        <% "c" -> %>
          <.guided_strategy />
      <% end %>

      <.switcher variant={@variant} />
    </div>
    """
  end

  defp briefing_room(assigns) do
    ~H"""
    <section class="space-y-6">
      <header class="grid gap-5 border-b border-base-300 pb-6 lg:grid-cols-[1fr_auto] lg:items-end">
        <div>
          <p class="eyebrow">Variant A · briefing room</p>
          <h1 class="mt-2 max-w-4xl text-4xl font-black tracking-tight sm:text-5xl">
            Write the intent. Let the Fleet find the route.
          </h1>
          <p class="mt-3 max-w-2xl text-sm leading-6 opacity-70">
            A compact strategy brief: choose a starting doctrine, order outcomes, then state the lines autonomy may not cross.
          </p>
        </div>
        <span class="badge badge-warning badge-lg">Draft · not active</span>
      </header>

      <div class="grid gap-6 xl:grid-cols-[18rem_minmax(0,1fr)_20rem]">
        <aside class="space-y-3">
          <div>
            <p class="eyebrow">Starting doctrine</p>
            <h2 class="mt-1 text-lg font-bold">Choose a preset</h2>
          </div>
          <button
            class="w-full rounded-lg border-2 border-primary bg-primary/10 p-4 text-left"
            type="button"
          >
            <span class="font-bold">Balanced expansion</span>
            <span class="mt-1 block text-xs leading-5 opacity-70">Grow credits, chart steadily, keep a reserve.</span>
          </button>
          <button class="w-full rounded-lg border border-base-300 p-4 text-left" type="button">
            <span class="font-bold">Chart contender</span>
            <span class="mt-1 block text-xs leading-5 opacity-70">Prioritize submitted charts and Fleet reach.</span>
          </button>
          <button class="w-full rounded-lg border border-base-300 p-4 text-left" type="button">
            <span class="font-bold">Trade engine</span>
            <span class="mt-1 block text-xs leading-5 opacity-70">Compound capital through measured trade.</span>
          </button>
          <p class="rounded-lg bg-base-200 p-3 text-xs leading-5 opacity-70">
            Presets fill the brief. They never silently change an active Fleet Strategy Revision.
          </p>
        </aside>

        <div class="space-y-4">
          <div class="flex items-end justify-between gap-4">
            <div>
              <p class="eyebrow">Protected order</p>
              <h2 class="mt-1 text-2xl font-bold">Strategic Priorities</h2>
            </div>
            <button type="button" class="btn btn-ghost btn-sm">Add outcome</button>
          </div>
          <ol class="space-y-3">
            <li class="grid gap-4 rounded-lg border border-primary/40 bg-base-200 p-5 sm:grid-cols-[3rem_1fr_auto] sm:items-center">
              <span class="grid size-10 place-items-center rounded-full bg-primary font-mono font-black text-primary-content">1</span>
              <div>
                <p class="font-bold">Maintain an operating reserve</p>
                <p class="mt-1 text-sm opacity-65">
                  Keep at least 120,000 credits with a 20,000 credit safety margin.
                </p>
              </div>
              <span class="badge badge-success">Protected first</span>
            </li>
            <li class="grid gap-4 rounded-lg border border-base-300 bg-base-200 p-5 sm:grid-cols-[3rem_1fr_auto] sm:items-center">
              <span class="grid size-10 place-items-center rounded-full border border-base-content/20 font-mono font-black">2</span>
              <div>
                <p class="font-bold">Reach 2,000,000 credits</p>
                <p class="mt-1 text-sm opacity-65">
                  Attain across this Fleet Generation. Prefer reliable compounding.
                </p>
              </div>
              <button type="button" class="btn btn-ghost btn-xs">Edit target</button>
            </li>
            <li class="grid gap-4 rounded-lg border border-base-300 bg-base-200 p-5 sm:grid-cols-[3rem_1fr_auto] sm:items-center">
              <span class="grid size-10 place-items-center rounded-full border border-base-content/20 font-mono font-black">3</span>
              <div>
                <p class="font-bold">Maximize submitted charts</p>
                <p class="mt-1 text-sm opacity-65">
                  Continuous leaderboard objective over each 24-hour horizon.
                </p>
              </div>
              <button type="button" class="btn btn-ghost btn-xs">Move up</button>
            </li>
          </ol>
          <div class="flex flex-wrap justify-end gap-3 border-t border-base-300 pt-5">
            <button type="button" class="btn btn-ghost">Save draft</button>
            <button type="button" class="btn btn-primary">Review and activate</button>
          </div>
        </div>

        <aside class="card h-fit border border-base-300 bg-base-200 p-5">
          <p class="eyebrow">Non-negotiable</p>
          <h2 class="mt-1 text-lg font-bold">Hard Constraints</h2>
          <div class="mt-5 space-y-5 text-sm">
            <label class="flex gap-3">
              <input type="checkbox" class="toggle toggle-primary toggle-sm" checked />
              <span><b>Never miss accepted Contract deadlines</b><small class="mt-1 block opacity-60">Reserve capacity before accepting.</small></span>
            </label>
            <label class="flex gap-3">
              <input type="checkbox" class="toggle toggle-primary toggle-sm" checked />
              <span><b>Maximum loss per uncertain action</b><small class="mt-1 block font-mono opacity-60">25,000 credits</small></span>
            </label>
            <label class="flex gap-3">
              <input type="checkbox" class="toggle toggle-primary toggle-sm" checked />
              <span><b>Auto-mint after Server Reset</b><small class="mt-1 block opacity-60">Use stored AccountToken.</small></span>
            </label>
          </div>
          <button type="button" class="btn btn-ghost btn-sm mt-5 w-full">Show advanced constraints</button>
        </aside>
      </div>
    </section>
    """
  end

  defp outcome_board(assigns) do
    ~H"""
    <section class="space-y-5">
      <header class="flex flex-col gap-5 border-b border-base-300 pb-5 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p class="eyebrow">Variant B · outcome board</p>
          <h1 class="mt-1 text-3xl font-black tracking-tight">Balanced expansion</h1>
          <p class="mt-2 text-sm opacity-65">
            Revision 7 active for 3d 14h · continued through Fleet Generation 2
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <span class="badge badge-success badge-lg">Strategy-capable</span>
          <button type="button" class="btn btn-outline btn-sm">Refine Strategy</button>
        </div>
      </header>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1fr)_22rem]">
        <div class="space-y-5">
          <section class="overflow-hidden rounded-lg border border-base-300">
            <div class="grid gap-px bg-base-300 md:grid-cols-3">
              <article class="bg-base-100 p-6">
                <p class="eyebrow">Priority 1 · maintain</p>
                <p class="mt-5 font-mono text-3xl font-black">184,200</p>
                <p class="mt-1 text-sm">credits reserved · 44,200 margin</p>
                <progress
                  aria-label="Operating reserve progress"
                  class="progress progress-success mt-5 w-full"
                  value="100"
                  max="100"
                ></progress>
                <p class="mt-2 text-xs text-success">Protected for 19 of 19 decisions</p>
              </article>
              <article class="bg-base-100 p-6">
                <p class="eyebrow">Priority 2 · attain</p>
                <p class="mt-5 font-mono text-3xl font-black">41%</p>
                <p class="mt-1 text-sm">823,450 of 2,000,000 credits</p>
                <progress
                  aria-label="Credit target progress"
                  class="progress progress-primary mt-5 w-full"
                  value="41"
                  max="100"
                ></progress>
                <p class="mt-2 text-xs opacity-60">Forecast 5d 8h at current rate</p>
              </article>
              <article class="bg-base-100 p-6">
                <p class="eyebrow">Priority 3 · continuous</p>
                <p class="mt-5 font-mono text-3xl font-black">#146</p>
                <p class="mt-1 text-sm">charts leaderboard · up 31 places</p>
                <progress
                  aria-label="Submitted charts leaderboard progress"
                  class="progress progress-secondary mt-5 w-full"
                  value="63"
                  max="100"
                ></progress>
                <p class="mt-2 text-xs opacity-60">38 charts submitted this generation</p>
              </article>
            </div>
          </section>

          <section class="grid gap-5 lg:grid-cols-[minmax(0,1.3fr)_minmax(18rem,0.7fr)]">
            <article class="card border border-base-300 bg-base-200 p-5">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="eyebrow">What the Fleet is doing</p><h2 class="mt-1 text-xl font-bold">
                    Allocation now
                  </h2>
                </div>
                <span class="badge badge-outline">12 Ships</span>
              </div>
              <div class="mt-5 space-y-4 text-sm">
                <.allocation_row label="Trading and market observation" ships="6 Ships" width="50%" />
                <.allocation_row label="Charting frontier Systems" ships="4 Ships" width="33%" />
                <.allocation_row label="Contract reserve" ships="2 Ships" width="17%" />
              </div>
              <button type="button" class="btn btn-ghost btn-sm mt-5 self-start">Why this allocation?</button>
            </article>

            <article class="card border border-info/40 bg-info/5 p-5">
              <p class="eyebrow text-info">Recommendation</p>
              <h2 class="mt-2 text-xl font-bold">Raise the reserve target?</h2>
              <p class="mt-3 text-sm leading-6 opacity-75">
                Two recent Ship purchases left less margin than intended. A 160,000 credit target would have protected Priority 1 without changing achieved growth.
              </p>
              <div class="mt-5 flex gap-2">
                <button type="button" class="btn btn-primary btn-sm">Review change</button><button
                  type="button"
                  class="btn btn-ghost btn-sm"
                >Dismiss</button>
              </div>
            </article>
          </section>
        </div>

        <aside class="space-y-5">
          <section class="card border border-warning/50 bg-warning/5 p-5">
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="eyebrow text-warning">Operator decision</p><h2 class="mt-1 font-bold">
                  External authority unavailable
                </h2>
              </div><span class="badge badge-warning">1</span>
            </div>
            <p class="mt-3 text-sm leading-6">
              Replacement minting paused: the stored AccountToken was revoked. Unaffected observations continue.
            </p>
            <button type="button" class="btn btn-warning btn-sm mt-4 w-full">Relink AccountToken</button>
          </section>
          <section class="card border border-base-300 bg-base-200 p-5">
            <p class="eyebrow">Limits on growth</p>
            <h2 class="mt-1 font-bold">Last 24 hours</h2>
            <dl class="mt-4 space-y-4 text-sm">
              <div class="flex justify-between gap-3">
                <dt>Idle Cargo capacity</dt><dd class="font-mono font-bold">18%</dd>
              </div>
              <div class="flex justify-between gap-3">
                <dt>API capacity on Strategy</dt><dd class="font-mono font-bold">62%</dd>
              </div>
              <div class="flex justify-between gap-3">
                <dt>Plans constrained by reserve</dt><dd class="font-mono font-bold">7</dd>
              </div>
            </dl>
            <button type="button" class="btn btn-ghost btn-sm mt-5 w-full">Open longitudinal analysis</button>
          </section>
        </aside>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :ships, :string, required: true
  attr :width, :string, required: true

  defp allocation_row(assigns) do
    ~H"""
    <div>
      <div class="mb-2 flex justify-between gap-3"><span>{@label}</span><b>{@ships}</b></div>
      <div class="h-2 overflow-hidden rounded-full bg-base-300">
        <div class="h-full bg-primary" style={"width: #{@width}"}></div>
      </div>
    </div>
    """
  end

  defp guided_strategy(assigns) do
    ~H"""
    <section class="mx-auto max-w-5xl">
      <header class="border-b border-base-300 pb-6 text-center">
        <p class="eyebrow">Variant C · guided strategy</p>
        <h1 class="mx-auto mt-3 max-w-3xl text-4xl font-black tracking-tight">
          What should this Fleet protect first?
        </h1>
        <p class="mx-auto mt-3 max-w-xl text-sm leading-6 opacity-70">
          Build one outcome at a time. The consequences stay visible; implementation details stay out of the way.
        </p>
      </header>

      <div class="mt-8 grid gap-8 lg:grid-cols-[12rem_minmax(0,1fr)]">
        <nav aria-label="Strategy setup progress" class="space-y-1 text-sm">
          <a class="flex items-center gap-3 rounded-lg p-3 opacity-60" href="#"><span class="grid size-7 place-items-center rounded-full bg-success text-success-content">✓</span>Starting point</a>
          <a
            class="flex items-center gap-3 rounded-lg bg-primary/10 p-3 font-bold text-primary"
            href="#"
          ><span class="grid size-7 place-items-center rounded-full bg-primary text-primary-content">2</span>Outcomes</a>
          <a class="flex items-center gap-3 rounded-lg p-3 opacity-60" href="#"><span class="grid size-7 place-items-center rounded-full border">3</span>Boundaries</a>
          <a class="flex items-center gap-3 rounded-lg p-3 opacity-60" href="#"><span class="grid size-7 place-items-center rounded-full border">4</span>Review</a>
        </nav>

        <div>
          <div class="flex items-center justify-between gap-4">
            <div>
              <p class="eyebrow">Priority 1</p><h2 class="mt-1 text-2xl font-bold">
                Protect enough credits to keep operating
              </h2>
            </div><span class="badge badge-primary">Maintain</span>
          </div>
          <p class="mt-3 max-w-2xl text-sm leading-6 opacity-70">
            Higher priorities keep a feasible path before lower priorities receive Ships, credits, or API capacity.
          </p>

          <div class="mt-7 rounded-xl border border-primary/40 bg-base-200 p-6">
            <label class="text-sm font-bold" for="reserve-target">Never plan below</label>
            <div class="mt-3 flex max-w-md items-center gap-3">
              <input
                id="reserve-target"
                class="input input-bordered w-full font-mono text-lg"
                value="120000"
              /><span class="font-bold">credits</span>
            </div>
            <div class="mt-5 rounded-lg border-l-4 border-info bg-info/5 p-4 text-sm leading-6">
              <b>What this means:</b>
              The Fleet may spend freely above this amount. If no safe plan remains, it waits or changes course instead of crossing the line.
            </div>
          </div>

          <section class="mt-8">
            <div class="flex items-center justify-between gap-3">
              <div>
                <p class="eyebrow">Then pursue</p><h2 class="mt-1 text-xl font-bold">
                  Other outcomes, in order
                </h2>
              </div><button type="button" class="btn btn-ghost btn-sm">Add outcome</button>
            </div>
            <div class="mt-4 divide-y divide-base-300 rounded-xl border border-base-300">
              <div class="flex gap-4 p-4">
                <span class="font-mono font-black opacity-40">2</span><div class="flex-1">
                  <b>Build toward 2,000,000 credits</b><p class="mt-1 text-xs opacity-60">
                    Current generation · attain as quickly as safely possible
                  </p>
                </div><button type="button" class="btn btn-ghost btn-xs">Change</button>
              </div>
              <div class="flex gap-4 p-4">
                <span class="font-mono font-black opacity-40">3</span><div class="flex-1">
                  <b>Improve submitted-chart rank</b><p class="mt-1 text-xs opacity-60">
                    Continuous · review every 24 hours
                  </p>
                </div><button type="button" class="btn btn-ghost btn-xs">Change</button>
              </div>
            </div>
          </section>

          <footer class="mt-8 flex flex-col-reverse gap-3 border-t border-base-300 pt-5 sm:flex-row sm:justify-between">
            <button type="button" class="btn btn-ghost">Back</button><button
              type="button"
              class="btn btn-primary"
            >Set the boundaries</button>
          </footer>
        </div>
      </div>

      <aside class="mt-10 rounded-xl border border-warning/50 bg-warning/5 p-5 sm:flex sm:items-center sm:justify-between sm:gap-5">
        <div>
          <p class="eyebrow text-warning">How later changes work</p><p class="mt-2 text-sm leading-6">
            Editing creates a reviewable revision. The active Strategy keeps running until you accept the replacement; Server Resets do not erase it.
          </p>
        </div><button type="button" class="btn btn-outline btn-sm mt-4 shrink-0 sm:mt-0">Compare revisions</button>
      </aside>
    </section>
    """
  end

  defp switcher(assigns) do
    names = %{"a" => "Briefing room", "b" => "Outcome board", "c" => "Guided strategy"}
    previous = %{"a" => "c", "b" => "a", "c" => "b"}
    next = %{"a" => "b", "b" => "c", "c" => "a"}
    assigns = assign(assigns, names: names, previous: previous, next: next)

    ~H"""
    <nav
      aria-label="Fleet Strategy prototype variants"
      class="fixed bottom-5 left-1/2 z-50 flex -translate-x-1/2 items-center gap-2 rounded-full border border-base-content/20 bg-base-100 px-2 py-2 shadow-2xl"
    >
      <button
        type="button"
        phx-click="strategy_variant"
        phx-value-variant={@previous[@variant]}
        class="btn btn-circle btn-sm"
        aria-label="Previous prototype variant"
      >←</button>
      <span class="min-w-44 text-center text-xs font-semibold"><span class="font-mono text-primary">{String.upcase(
        @variant
      )}</span>
      · {@names[@variant]}</span>
      <button
        type="button"
        phx-click="strategy_variant"
        phx-value-variant={@next[@variant]}
        class="btn btn-circle btn-sm"
        aria-label="Next prototype variant"
      >→</button>
    </nav>
    """
  end
end
