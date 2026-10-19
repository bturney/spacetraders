defmodule SpaceTradersWeb.EntityLive do
  @moduledoc "Deep-linkable, evidence-only pages for known World entities."

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Evidence, FleetGeneration, World}

  @freshness_seconds 300

  @impl true
  def mount(params, _session, socket) do
    # Current entities have no resource selector. Explicit historical Generation
    # links preserve provenance without resurrecting a legacy Agent parameter.
    current =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent, generation: generation}} ->
          %{agent: agent, generation: generation}

        _ ->
          nil
      end

    holder =
      if Map.has_key?(params, "generation"),
        do: historical_holder(socket.assigns.current_scope, params["generation"]),
        else: current

    case holder do
      nil ->
        socket =
          if Map.has_key?(params, "generation"),
            do: put_flash(socket, :error, "Historical Generation evidence is unavailable."),
            else: socket

        {:ok, push_navigate(socket, to: ~p"/world")}

      %{agent: agent, generation: generation} ->
        historical? = Map.has_key?(params, "generation")

        {:ok,
         socket
         |> assign(
           historical?: historical?,
           generation: generation,
           link_generation: if(historical?, do: generation)
         )
         |> assign_entity(agent, params)}
    end
  end

  defp historical_holder(scope, raw_id) when is_binary(raw_id) do
    with {generation_id, ""} <- Integer.parse(raw_id),
         {:ok, holder} <- FleetGeneration.generation_evidence(scope, generation_id) do
      holder
    else
      _ -> nil
    end
  end

  defp historical_holder(_scope, _raw_id), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div class="space-y-6">
        <nav aria-label="Breadcrumb" class="text-sm">
          <.link navigate={~p"/world"} class="link link-primary">World</.link>
          <span class="px-1 opacity-60">/</span>
          <span>Evidence held by {@agent.symbol}</span>
        </nav>

        <p
          :if={@historical?}
          id="historical-evidence"
          class="rounded-lg border border-warning/40 bg-warning/10 p-3 text-sm"
        >
          Historical evidence held by {@agent.symbol}{generation_label(@generation)}.
          This is not the current Fleet; nothing here can be commanded.
        </p>
        <p :if={!@historical?} id="current-fleet-evidence" class="text-sm opacity-70">
          Current Fleet {@agent.symbol}{generation_label(@generation)}
        </p>

        <section :if={@entity == :system} id={"system-#{@system}"} class="space-y-4">
          <header>
            <p class="eyebrow">Known context</p>
            <h1 class="text-3xl font-bold">System {@system}</h1>
            <p class="mt-2 text-sm opacity-70">
              This System is known through its observed Waypoints. Current System-wide intelligence has not been inferred.
            </p>
          </header>

          <section class="rounded-xl border border-base-300 p-5">
            <h2 class="text-xl font-semibold">Known Waypoints</h2>
            <p :if={@waypoints == []} class="mt-2 text-sm opacity-70">
              No Waypoints have been observed in this System.
            </p>
            <ul :if={@waypoints != []} class="mt-3 space-y-2">
              <li :for={waypoint <- @waypoints}>
                <.link
                  navigate={waypoint_path(@link_generation, @system, waypoint.symbol)}
                  class="link link-primary"
                >
                  {waypoint.symbol}
                </.link>
                <span class="ml-2 text-sm opacity-70">Known waypoint</span>
              </li>
            </ul>
          </section>
        </section>

        <section :if={@entity == :waypoint} id={"waypoint-#{@waypoint}"} class="space-y-6">
          <header>
            <p class="eyebrow">Known context</p>
            <h1 class="text-3xl font-bold">Waypoint {@waypoint}</h1>
            <p class="mt-2 text-sm opacity-70">
              <.link navigate={system_path(@link_generation, @system)} class="link link-primary">System {@system}</.link>
              · {existence_label(@intelligence)}
            </p>
          </header>

          <section class="rounded-xl border border-base-300 p-5">
            <h2 class="text-xl font-semibold">Waypoint intelligence</h2>
            <.facts facts={@intelligence.facts} />
          </section>

          <section class="rounded-xl border border-base-300 p-5">
            <h2 class="text-xl font-semibold">Traits</h2>
            <p :if={fact_items(@intelligence.facts["traits"]) == []} class="mt-2 text-sm opacity-70">
              Unknown. No traits have been observed.
            </p>
            <ul :if={fact_items(@intelligence.facts["traits"]) != []} class="mt-3 space-y-2">
              <li :for={trait <- fact_items(@intelligence.facts["traits"])}>
                <span class="font-medium">{item_name(trait)}</span>
                <span :if={item_description(trait)} class="text-sm opacity-70"> · {item_description(
                  trait
                )}</span>
              </li>
            </ul>
          </section>

          <section
            :if={fact_items(@intelligence.facts["modifiers"]) != []}
            id="waypoint-cautions"
            class="rounded-xl border border-warning/40 bg-warning/10 p-5"
          >
            <h2 class="text-xl font-semibold">Waypoint cautions</h2>
            <p class="mt-1 text-sm opacity-70">
              The game supplies these conditions without a severity ranking.
            </p>
            <ul class="mt-3 space-y-2">
              <li :for={modifier <- fact_items(@intelligence.facts["modifiers"])}>
                <span class="font-medium">{item_name(modifier)}</span>
                <span :if={item_description(modifier)} class="text-sm"> · {item_description(modifier)}</span>
              </li>
            </ul>
          </section>

          <nav class="flex flex-wrap gap-3" aria-label="Waypoint contexts">
            <.link
              navigate={entity_path(@link_generation, @system, @waypoint, :market)}
              class="btn btn-outline btn-sm"
            >Market</.link>
            <.link
              navigate={entity_path(@link_generation, @system, @waypoint, :shipyard)}
              class="btn btn-outline btn-sm"
            >Shipyard</.link>
            <.link
              navigate={entity_path(@link_generation, @system, @waypoint, :construction)}
              class="btn btn-outline btn-sm"
            >Construction</.link>
          </nav>
        </section>

        <section
          :if={@entity in [:market, :shipyard, :construction]}
          id={"#{@entity}-#{@waypoint}"}
          class="space-y-6"
        >
          <header>
            <p class="eyebrow">Governed evidence</p>
            <h1 class="text-3xl font-bold">{entity_name(@entity)} {@waypoint}</h1>
            <p class="mt-2 text-sm opacity-70">
              <.link
                navigate={waypoint_path(@link_generation, @system, @waypoint)}
                class="link link-primary"
              >
                Waypoint {@waypoint}
              </.link>
              · {existence_label(@intelligence)}
            </p>
          </header>

          <section class="rounded-xl border border-base-300 p-5">
            <h2 class="text-xl font-semibold">Observed facts</h2>
            <.facts facts={@intelligence.facts} />
          </section>
        </section>

        <section :if={@entity == :contract} id={"contract-#{@contract_id}"} class="space-y-6">
          <header>
            <p class="eyebrow">Owned entity</p>
            <h1 class="text-3xl font-bold">Contract {@contract_id}</h1>
            <p class="mt-2 text-sm opacity-70">
              Contract state is shown only from the latest governed Contract observation.
            </p>
          </header>

          <section class="rounded-xl border border-base-300 p-5">
            <h2 class="text-xl font-semibold">Last observed state</h2>
            <p :if={!@contract} class="mt-2 text-sm opacity-70">
              Unknown. No governed Contract observation is available for this Contract.
            </p>
            <p :if={@contract} class="mt-2 font-medium">{contract_status(@contract)}</p>
            <p :if={@contract_observation} class="mt-1 text-xs opacity-70">
              {observation_context(@contract_observation)}
            </p>
            <ul :if={@contract} class="mt-3 space-y-2">
              <li :for={delivery <- contract_deliveries(@contract)}>
                <.link
                  navigate={contract_waypoint_path(@link_generation, delivery.destination)}
                  class="link link-primary"
                >
                  {delivery.destination}
                </.link>
                · {delivery.trade_symbol} · {delivery.remaining} remaining
              </li>
            </ul>
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :facts, :map, required: true

  defp facts(assigns) do
    ~H"""
    <p :if={@facts == %{}} class="mt-2 text-sm opacity-70">
      Unknown. No governed observation is available for this entity.
    </p>
    <dl :if={@facts != %{}} class="mt-3 grid gap-3 sm:grid-cols-2">
      <div :for={{field, fact} <- Enum.sort(@facts)}>
        <dt class="text-sm opacity-70">{humanize(field)}</dt>
        <dd class="font-medium">{fact_value(fact)}</dd>
        <p class="text-xs opacity-70">{fact_context(fact)}</p>
      </div>
    </dl>
    """
  end

  defp assign_entity(socket, agent, %{"system" => system} = params) do
    case socket.assigns.live_action do
      :system ->
        assign(socket,
          agent: agent,
          entity: :system,
          system: system,
          waypoints: World.waypoints(agent, system, DateTime.utc_now(), @freshness_seconds)
        )

      :waypoint ->
        waypoint = params["waypoint"]

        assign(socket,
          agent: agent,
          entity: :waypoint,
          system: system,
          waypoint: waypoint,
          intelligence:
            World.intelligence(
              agent,
              :waypoint,
              system,
              waypoint,
              DateTime.utc_now(),
              @freshness_seconds
            )
        )

      type when type in [:market, :shipyard, :construction] ->
        waypoint = params["waypoint"]

        assign(socket,
          agent: agent,
          entity: type,
          system: system,
          waypoint: waypoint,
          intelligence:
            World.intelligence(
              agent,
              type,
              system,
              waypoint,
              DateTime.utc_now(),
              @freshness_seconds
            )
        )
    end
  end

  defp assign_entity(socket, agent, %{"contract_id" => contract_id}) do
    contract_observation = Evidence.latest_observation(agent, "contracts:#{agent.symbol}")
    contract = contract_from_observation(contract_observation, contract_id)

    assign(socket,
      agent: agent,
      entity: :contract,
      contract_id: contract_id,
      contract: contract,
      contract_observation: contract_observation
    )
  end

  defp system_path(agent, system), do: path_for_agent(~p"/world/systems/#{system}", agent)

  defp waypoint_path(agent, system, waypoint),
    do: path_for_agent(~p"/world/systems/#{system}/waypoints/#{waypoint}", agent)

  defp entity_path(agent, system, waypoint, :market),
    do: path_for_agent(~p"/world/systems/#{system}/waypoints/#{waypoint}/market", agent)

  defp entity_path(agent, system, waypoint, :shipyard),
    do: path_for_agent(~p"/world/systems/#{system}/waypoints/#{waypoint}/shipyard", agent)

  defp entity_path(agent, system, waypoint, :construction),
    do: path_for_agent(~p"/world/systems/#{system}/waypoints/#{waypoint}/construction", agent)

  defp entity_name(:market), do: "Market"
  defp entity_name(:shipyard), do: "Shipyard"
  defp entity_name(:construction), do: "Construction"

  defp contract_from_observation(nil, _contract_id), do: nil

  defp contract_from_observation(%{facts: %{"response" => contracts}}, contract_id)
       when is_list(contracts),
       do: Enum.find(contracts, &(Map.get(&1, "id") == contract_id))

  defp contract_from_observation(_observation, _contract_id), do: nil

  defp contract_status(%{"fulfilled" => true}), do: "Fulfilled"
  defp contract_status(%{"accepted" => true}), do: "Accepted"
  defp contract_status(_), do: "Pending acceptance"

  defp contract_deliveries(%{"terms" => %{"deliver" => deliveries}}) when is_list(deliveries) do
    Enum.map(deliveries, fn delivery ->
      required = Map.get(delivery, "unitsRequired", 0)
      fulfilled = Map.get(delivery, "unitsFulfilled", 0)

      %{
        destination: Map.get(delivery, "destinationSymbol"),
        trade_symbol: Map.get(delivery, "tradeSymbol", "Unknown good"),
        remaining: max(required - fulfilled, 0)
      }
    end)
  end

  defp contract_deliveries(_), do: []

  defp contract_waypoint_path(agent, waypoint) when is_binary(waypoint) do
    waypoint_path(agent, system_from_waypoint(waypoint), waypoint)
  end

  defp system_from_waypoint(waypoint) do
    SpaceTradersWeb.EntityReference.system_from_waypoint(waypoint)
  end

  defp observation_context(observation) do
    freshness =
      if DateTime.diff(DateTime.utc_now(), observation.observed_at, :second) <=
           @freshness_seconds,
         do: "Fresh",
         else: "Stale"

    "#{freshness} · observed " <>
      Calendar.strftime(observation.observed_at, "%Y-%m-%d %H:%M UTC") <>
      " via #{observation_source(observation.operation_id)}"
  end

  defp observation_source("get-my-ship"), do: "Ship observation"
  defp observation_source("get-contracts"), do: "Contract observation"
  defp observation_source(_operation_id), do: "Governed observation"

  defp path_for_agent(path, nil), do: path
  defp path_for_agent(path, generation), do: "#{path}?generation=#{generation.id}"

  defp generation_label(%{number: number}), do: " · Generation #{number}"
  defp generation_label(_generation), do: ""

  defp existence_label(%{known_existence?: true}), do: "Known waypoint"
  defp existence_label(_), do: "Existence has not been established"

  defp humanize(field), do: field |> String.replace("_", " ") |> String.capitalize()

  defp fact_value(nil), do: "Unknown"
  defp fact_value(%{state: "unknown"}), do: "Unknown"
  defp fact_value(%{state: "known_unavailable"}), do: "Unavailable"
  defp fact_value(%{value: value}), do: format_value(value)

  defp fact_context(nil), do: "Not established"

  defp fact_context(%{freshness: freshness, observed_at: observed_at, source: source}) do
    freshness_label(freshness) <>
      " · observed " <>
      Calendar.strftime(observed_at, "%Y-%m-%d %H:%M UTC") <> " via " <> source
  end

  defp freshness_label(:fresh), do: "Fresh"
  defp freshness_label(:stale), do: "Stale"
  defp freshness_label(_), do: "Not established"

  defp format_value(items) when is_list(items) do
    case items do
      [] ->
        "0 observed"

      _ ->
        names = Enum.map(items, &(Map.get(&1, "symbol") || Map.get(&1, "type")))

        if Enum.all?(names, &is_binary/1),
          do: Enum.join(names, ", "),
          else: "#{length(items)} observed"
    end
  end

  defp format_value(%{}), do: "Observed"
  defp format_value(value), do: to_string(value)

  defp fact_items(%{state: "known", value: items}) when is_list(items), do: items
  defp fact_items(_fact), do: []

  defp item_name(item) do
    Map.get(item, "name") || Map.get(item, "symbol") || Map.get(item, "type") || "Observed"
  end

  defp item_description(item), do: Map.get(item, "description")
end
