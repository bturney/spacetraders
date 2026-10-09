defmodule SpaceTraders.Outcomes.Fleet do
  @moduledoc """
  Event-driven, fail-soft projections of the registered current Fleet.

  Every projection publishes its entire bounded vector, including zeroes. The
  independent dimensions share `ships_total`; unused dimension labels are empty.
  Sum only one dimension (for example `claim!=""`) to count Ships once.

  The scope is all registered Ships of non-stale Agents, without identity labels.
  Claim counts use current, unfenced, unreleased Fleet Commitment authority;
  Intent counts use each Ship's latest root lifecycle, including terminal states
  and `none`. Nav counts use the newest retained whole-Ship/Fleet read or
  successful recorded mutation nav fact; missing or unsupported facts are
  `unknown`. A complete vector always clears previously nonzero state counts.

  Boot reconstructs all three vectors. Successful durable lifecycle writes
  enqueue bounded family names only after their outer transaction commits.
  Events within the default 50 ms window share one aggregate SQL query per dirty
  family. Errors log and drop; the next real change or worker boot can reconstruct
  again. There is no periodic recompute and no game API access. Fleet freshness
  is the epoch of the latest successful recompute, and remains fixed during idle.
  """
  use GenServer
  require Logger

  alias SpaceTraders.Repo
  alias SpaceTraders.Fleet.Intent

  @families [:claim, :intent_state, :nav_status]
  @states %{
    claim: ~w(claimed free),
    intent_state: ["none", "unknown"] ++ Intent.unfinished_states() ++ Intent.terminal_states(),
    nav_status: ~w(DOCKED IN_ORBIT IN_TRANSIT unknown)
  }
  @ships """
  SELECT s.id, s.symbol, s.agent_id FROM ships s
  JOIN agents a ON a.id = s.agent_id WHERE a.stale_at IS NULL
  """
  @handler {__MODULE__, :durable_changes}
  @pending {__MODULE__, :pending}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc false
  # Retain just the bounded authoritative nav fact in the existing mutation
  # ledger. Its recorded_at supplies ordering against subsequent owned reads.
  def nav_evidence(%{nav: %{status: status}}) when status in ~w(DOCKED IN_ORBIT IN_TRANSIT),
    do: %{nav_status: status}

  def nav_evidence(_), do: %{}

  @doc false
  # Exposition shares the publisher mailbox; a scrape sees a complete vector.
  # Gameplay only sends notifications and never enters this synchronous seam.
  def expose(fun) when is_function(fun, 0) do
    case Process.whereis(__MODULE__) do
      nil -> fun.()
      pid -> GenServer.call(pid, {:expose, fun})
    end
  catch
    :exit, _ -> :projection_down
  end

  @impl true
  def handle_call({:expose, fun}, _from, state), do: {:reply, fun.(), state}

  @impl true
  def init(opts) do
    # Ecto emits query telemetry in the writer process, including transaction
    # management. Buffer only bounded family names there; send after COMMIT so
    # an independent worker never races uncommitted facts. No extra writer SQL.
    :telemetry.detach(@handler)

    :ok =
      :telemetry.attach(
        @handler,
        Repo.config()[:telemetry_prefix] ++ [:query],
        &__MODULE__.durable_change/4,
        self()
      )

    Process.send_after(self(), :recompute, Keyword.get(opts, :coalesce_ms, 50))

    {:ok,
     %{
       dirty: MapSet.new(@families),
       coalesce_ms: Keyword.get(opts, :coalesce_ms, 50),
       repo: Keyword.get(opts, :repo, Repo)
     }}
  end

  @doc false
  def durable_change(_event, _measurements, metadata, worker) do
    case metadata do
      %{query: "begin", result: {:ok, _}} ->
        Process.put(@pending, MapSet.new())

      %{query: "commit", result: {:ok, _}} ->
        notify(worker, Process.delete(@pending) || MapSet.new())

      %{query: "rollback"} ->
        Process.delete(@pending)

      %{result: {:ok, %{command: command, num_rows: rows}}}
      when command in [:insert, :update, :delete] and rows > 0 ->
        families = changed_families(metadata, command)

        case Process.get(@pending) do
          nil -> notify(worker, MapSet.new(families))
          pending -> Process.put(@pending, Enum.reduce(families, pending, &MapSet.put(&2, &1)))
        end

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> Logger.error("Fleet outcome notification failed; dropping change")
  catch
    _, _ -> Logger.error("Fleet outcome notification failed; dropping change")
  end

  defp changed_families(%{source: "ships"}, _), do: @families

  defp changed_families(%{source: source}, command)
       when source in ["agents", "fleet_generations"] and command in [:insert, :delete],
       do: @families

  defp changed_families(%{source: source, query: query}, :update)
       when source in ["agents", "fleet_generations"] do
    if String.contains?(query, ["\"stale_at\"", "\"fenced_at\"", "\"retired_at\"", "\"agent_id\""]),
       do: @families,
       else: []
  end

  defp changed_families(%{source: source}, _)
       when source in [
              "fleet_commitment_claims",
              "fleet_commitments",
              "fleet_commitment_portfolios"
            ],
       do: [:claim]

  defp changed_families(%{source: "intents"}, _), do: [:intent_state]

  defp changed_families(%{source: source}, :delete)
       when source in ["authoritative_observations", "mutation_attempt_outcomes"],
       do: [:nav_status]

  defp changed_families(%{source: "authoritative_observations"} = metadata, _) do
    if Enum.any?(
         metadata.cast_params || metadata.params,
         &(&1 in ["get-my-ship", "get-my-ships"])
       ),
       do: [:nav_status],
       else: []
  end

  defp changed_families(%{source: "mutation_attempt_outcomes"} = metadata, _) do
    if Enum.any?(metadata.cast_params || metadata.params, fn
         %{"nav_status" => status} -> status in ~w(DOCKED IN_ORBIT IN_TRANSIT)
         _ -> false
       end),
       do: [:nav_status],
       else: []
  end

  defp changed_families(_, _), do: []

  defp notify(worker, families) do
    if MapSet.size(families) > 0, do: send(worker, {:dirty, families})
  end

  @impl true
  def handle_info({:dirty, families}, state) do
    if MapSet.size(state.dirty) == 0,
      do: Process.send_after(self(), :recompute, state.coalesce_ms)

    {:noreply, %{state | dirty: MapSet.union(state.dirty, families)}}
  end

  @impl true
  def handle_info(:recompute, state) do
    Enum.each(state.dirty, &project(&1, state.repo))
    {:noreply, %{state | dirty: MapSet.new()}}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler)

  defp project(family, repo) do
    counts = Map.new(@states[family], &{&1, 0})

    counts =
      repo.query!(query(family)).rows
      |> Enum.reduce(counts, fn [label, count], counts ->
        label = if label in @states[family], do: label, else: "unknown"
        Map.update!(counts, label, &(&1 + count))
      end)

    Enum.each(counts, fn {label, count} ->
      metadata = %{claim: "", intent_state: "", nav_status: ""} |> Map.put(family, label)
      :telemetry.execute([:spacetraders, :outcome, :fleet, :ships], %{count: count}, metadata)
    end)

    :telemetry.execute(
      [:spacetraders, :outcome, :observed],
      %{
        observed_at_seconds:
          DateTime.to_unix(SpaceTraders.Clock.utc_now(), :microsecond) / 1_000_000
      },
      %{family: "fleet"}
    )

    :telemetry.execute(
      [:spacetraders, :outcome, :fleet, :projection],
      %{counts: counts, recomputes: 1},
      %{family: family}
    )
  rescue
    _ -> drop(family)
  catch
    _, _ -> drop(family)
  end

  defp drop(family) do
    Logger.error("Fleet outcome projection failed; dropping recompute", family: family)

    :telemetry.execute([:spacetraders, :outcome, :fleet, :projection_failed], %{count: 1}, %{
      family: family
    })
  end

  defp query(:claim) do
    """
    WITH ships AS (#{@ships})
    SELECT CASE WHEN EXISTS (
      SELECT 1 FROM fleet_commitment_claims c
      JOIN fleet_commitments k ON k.id = c.fleet_commitment_id
      JOIN fleet_commitment_portfolios p ON p.id = c.fleet_commitment_portfolio_id
      JOIN fleet_generations g ON g.id = p.fleet_generation_id
      WHERE c.resource = s.symbol AND g.agent_id = s.agent_id
        AND p.superseded_at IS NULL AND g.fenced_at IS NULL AND g.retired_at IS NULL
        AND k.unwind_state = 'not_required'
    ) THEN 'claimed' ELSE 'free' END, count(*)
    FROM ships s GROUP BY 1
    """
  end

  defp query(:intent_state) do
    """
    WITH ships AS (#{@ships}), latest AS (
      SELECT DISTINCT ON (i.ship_id) i.ship_id, i.status
      FROM intents i JOIN ships s ON s.id = i.ship_id
      ORDER BY i.ship_id, i.inserted_at DESC, i.id DESC
    )
    SELECT COALESCE(i.status, 'none'), count(*)
    FROM ships s LEFT JOIN latest i ON i.ship_id = s.id GROUP BY 1
    """
  end

  defp query(:nav_status) do
    """
    WITH ships AS (#{@ships}), latest_reads AS (
      SELECT DISTINCT ON (o.agent_id, o.subject)
        o.agent_id, o.subject, o.operation_id, o.facts, o.observed_at, o.id
      FROM authoritative_observations o
      WHERE o.operation_id IN ('get-my-ship', 'get-my-ships')
        AND o.agent_id IN (SELECT agent_id FROM ships)
      ORDER BY o.agent_id, o.subject, o.observed_at DESC, o.id DESC
    ), reads AS (
      SELECT s.id AS ship_id, o.facts #>> '{response,nav,status}' AS status,
        o.observed_at AS at, o.id::text AS tie
      FROM latest_reads o JOIN ships s ON s.agent_id = o.agent_id
        AND o.subject = 'ship:' || s.symbol AND o.operation_id = 'get-my-ship'
      UNION ALL
      SELECT s.id, item #>> '{nav,status}', o.observed_at, o.id::text
      FROM latest_reads o
      CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(o.facts->'response') = 'array' THEN o.facts->'response' ELSE '[]'::jsonb END
      ) item
      JOIN ships s ON s.agent_id = o.agent_id AND s.symbol = item->>'symbol'
      WHERE o.operation_id = 'get-my-ships'
    ), mutations AS (
      SELECT DISTINCT ON (s.id) s.id AS ship_id, o.evidence->>'nav_status' AS status,
        o.recorded_at AS at, o.id::text AS tie
      FROM mutation_attempt_outcomes o
      JOIN mutation_attempts m ON m.id = o.mutation_attempt_id
      JOIN ships s ON s.agent_id = m.agent_id AND s.symbol = m.provenance->>'ship_symbol'
      WHERE o.classification = 'succeeded' AND o.evidence->>'nav_status' IS NOT NULL
      ORDER BY s.id, o.recorded_at DESC, o.id DESC
    ), latest AS (
      SELECT DISTINCT ON (ship_id) ship_id, status
      FROM (SELECT * FROM reads UNION ALL SELECT * FROM mutations) facts
      ORDER BY ship_id, at DESC, tie DESC
    )
    SELECT COALESCE(n.status, 'unknown'), count(*)
    FROM ships s LEFT JOIN latest n ON n.ship_id = s.id GROUP BY 1
    """
  end
end
