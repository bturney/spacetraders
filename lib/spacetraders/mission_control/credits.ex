defmodule SpaceTraders.MissionControl.Credits do
  @moduledoc """
  Glance credits (#770, spec #757): the Agent's balance, its growth over the
  current Generation and Net Earnings over the last 6 h.

  Read from stored facts only (the Generation's retained `get-my-agent`
  observations and its Earnings records): bounded queries, no game request.

    * `balance` - the latest retained observation, else the Generation's last
      observed credits; nil when none exists (never shown as 0);
    * `growth` - balance minus the Generation's starting credits;
    * `series` - at most #{48} points of balance over the Generation, oldest first;
    * `net` - the sum of Earnings records finished in the window, `per_hour` its
      rate (nil while the window is under 10 minutes);
    * `since` - when the Generation is younger than 6 h the window starts there
      and `since` is that time; nil for a full 6 h window.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.Repo

  @window_seconds 6 * 3600
  @points 48
  @min_rate_seconds 600

  @doc "Credits facts of the current Fleet as of `now`; nil without a current Generation."
  def read(%Scope{} = scope, %DateTime{} = now) do
    case FleetGeneration.current_fleet(scope) do
      {:ok, %{state: :current, agent: agent, generation: %{} = generation}} ->
        build(agent, generation, now)

      _ ->
        nil
    end
  end

  @doc "Credits facts of an already-read current Agent and Generation as of `now`."
  def build(agent, generation, now) do
    series = series(agent, generation, now)
    balance = latest(agent, generation) || generation.last_observed_credits

    age = max(DateTime.diff(now, generation.inserted_at), 0)
    window = min(age, @window_seconds)
    net = net(generation, DateTime.add(now, -window))

    %{
      balance: balance,
      growth: balance && generation.starting_credits && balance - generation.starting_credits,
      series: series,
      net: net,
      per_hour: if(window >= @min_rate_seconds, do: round(net * 3600 / window)),
      since: if(age < @window_seconds, do: generation.inserted_at)
    }
  end

  defp observations(agent, generation) do
    from o in Observation,
      where:
        o.agent_id == ^agent.id and o.subject == ^"agent:#{agent.symbol}" and
          o.operation_id == "get-my-agent" and o.fleet_generation_id == ^generation.id
  end

  defmacrop credits_of(o),
    do: quote(do: fragment("(?->'response'->>'credits')::bigint", unquote(o).facts))

  defp latest(agent, generation) do
    Repo.one(
      from o in observations(agent, generation),
        order_by: [desc: o.observed_at],
        limit: 1,
        select: credits_of(o)
    )
  end

  # Last balance of each of at most @points equal time buckets.
  defp series(agent, generation, now) do
    span = max(DateTime.diff(now, generation.inserted_at), 60)
    width = max(div(span, @points) + 1, 1)
    origin = generation.inserted_at

    Repo.all(
      from o in observations(agent, generation),
        distinct:
          fragment("date_bin(make_interval(secs => ?), ?, ?)", ^width, o.observed_at, ^origin),
        order_by: [
          asc:
            fragment("date_bin(make_interval(secs => ?), ?, ?)", ^width, o.observed_at, ^origin),
          desc: o.observed_at
        ],
        select: %{at: o.observed_at, credits: credits_of(o)}
    )
  end

  defp net(generation, since) do
    Repo.one(
      from r in EarningsRecord,
        where: r.fleet_generation_id == ^generation.id and r.finished_at >= ^since,
        select: type(coalesce(sum(r.net_earnings), 0), :integer)
    )
  end
end
