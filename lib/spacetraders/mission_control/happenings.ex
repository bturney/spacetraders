defmodule SpaceTraders.MissionControl.Happenings do
  @moduledoc """
  Glance's "Just happened" feed (#771): the last 8 consequential events of the
  current Fleet Generation, newest first, read from stored facts. It never
  calls the game and runs a fixed number of queries.

  Five kinds:

    * `:sale` - an Earnings record landed, with its Net Earnings;
    * `:skipped_buy` - a buy step ended infeasible, with its reason;
    * `:joined` - a Ship joined after the opening Fleet (more than a minute
      after the first one);
    * `:stuck` / `:recovered` - a step became blocked, or got going again;
    * `:best` - an Earnings record beat every earlier trade (the Stats best).

  Chart and construction slots stay reserved until a Strategy does that work.
  """

  import Ecto.Query

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.Outcomes.EarningsRecord
  alias SpaceTraders.Repo

  @limit 8
  @opening_fleet_seconds 60

  @doc "Number of events the feed holds."
  def limit, do: @limit

  @doc "The feed of the Agent's current Generation, newest first."
  def read(%AgentRecord{} = agent) do
    case FleetAllocation.active_generation(agent) do
      nil ->
        []

      generation ->
        [
          sales(generation.id),
          bests(generation.id),
          skipped_buys(agent.id),
          stuck(agent.id),
          recovered(agent.id),
          joined(agent.id)
        ]
        |> List.flatten()
        |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.id}, :desc)
        |> Enum.take(@limit)
    end
  end

  defp sales(generation_id) do
    from(r in EarningsRecord,
      where: r.fleet_generation_id == ^generation_id,
      order_by: [desc: r.finished_at, desc: r.id],
      limit: @limit
    )
    |> Repo.all()
    |> Enum.map(fn r ->
      %{
        id: "sale-#{r.id}",
        record_id: r.id,
        detail: "#{r.units} #{good(r.good)}#{route(r)}",
        kind: :sale,
        at: r.finished_at,
        ship: r.ship_symbol,
        amount: r.net_earnings,
        text: "#{r.ship_symbol} sold #{r.units} #{good(r.good)}#{route(r)}"
      }
    end)
  end

  # A record that beat the best of every earlier record (the first is no "new" best).
  defp bests(generation_id) do
    ranked =
      from(r in EarningsRecord,
        where: r.fleet_generation_id == ^generation_id,
        select: %{
          id: r.id,
          best_before:
            over(max(r.net_earnings),
              order_by: [asc: r.finished_at, asc: r.id],
              frame: fragment("ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING")
            )
        }
      )

    from(r in EarningsRecord,
      join: k in subquery(ranked),
      on: k.id == r.id,
      where: not is_nil(k.best_before) and r.net_earnings > k.best_before,
      order_by: [desc: r.finished_at, desc: r.id],
      limit: @limit
    )
    |> Repo.all()
    |> Enum.map(fn r ->
      %{
        id: "best-#{r.id}",
        kind: :best,
        at: r.finished_at,
        ship: r.ship_symbol,
        amount: r.net_earnings,
        text: "New best trade: #{good(r.good)} by #{r.ship_symbol}"
      }
    end)
  end

  defp skipped_buys(agent_id) do
    from(i in Intent,
      join: s in Ship,
      on: s.id == i.ship_id,
      where:
        s.agent_id == ^agent_id and is_nil(s.retired_at) and i.type == "buy" and
          i.status == "infeasible" and not is_nil(i.finished_at),
      order_by: [desc: i.finished_at, desc: i.id],
      limit: @limit,
      select: {i, s.symbol}
    )
    |> Repo.all()
    |> Enum.map(fn {i, symbol} ->
      %{
        id: "skip-#{i.id}",
        kind: :skipped_buy,
        at: i.finished_at,
        ship: symbol,
        amount: nil,
        text: "#{symbol} skipped buying #{good(i.parameters["trade_symbol"])}: #{skip_reason(i)}"
      }
    end)
  end

  defp stuck(agent_id) do
    transitions(agent_id, :blocked_at)
    |> Enum.map(fn {i, symbol} ->
      %{
        id: "stuck-#{i.id}-#{DateTime.to_unix(i.blocked_at)}",
        kind: :stuck,
        at: i.blocked_at,
        ship: symbol,
        amount: nil,
        text: "#{symbol} got stuck: #{blocked_reason(i)}"
      }
    end)
  end

  defp recovered(agent_id) do
    transitions(agent_id, :recovered_at)
    |> Enum.map(fn {i, symbol} ->
      %{
        id: "recovered-#{i.id}-#{DateTime.to_unix(i.recovered_at)}",
        kind: :recovered,
        at: i.recovered_at,
        ship: symbol,
        amount: nil,
        text: "#{symbol} recovered and is moving again"
      }
    end)
  end

  defp transitions(agent_id, field) do
    from(i in Intent,
      join: s in Ship,
      on: s.id == i.ship_id,
      where: s.agent_id == ^agent_id and is_nil(s.retired_at) and not is_nil(field(i, ^field)),
      order_by: [desc: field(i, ^field), desc: i.id],
      limit: @limit,
      select: {i, s.symbol}
    )
    |> Repo.all()
  end

  defp joined(agent_id) do
    ships = from(s in Ship, where: s.agent_id == ^agent_id and is_nil(s.retired_at))

    case Repo.one(from s in ships, select: min(s.inserted_at)) do
      nil ->
        []

      first ->
        after_opening = DateTime.add(first, @opening_fleet_seconds)

        from(s in ships,
          where: s.inserted_at > ^after_opening,
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: @limit
        )
        |> Repo.all()
        |> Enum.map(fn s ->
          %{
            id: "joined-#{s.id}",
            kind: :joined,
            at: s.inserted_at,
            ship: s.symbol,
            amount: nil,
            text: "#{s.symbol} joined the Fleet"
          }
        end)
    end
  end

  defp route(%{source_waypoint: from, destination_waypoint: to})
       when is_binary(from) and is_binary(to),
       do: ", #{short(from)} to #{short(to)}"

  defp route(_record), do: ""

  defp skip_reason(%Intent{last_action_result: %{"evidence" => %{"reason" => reason}}})
       when is_binary(reason),
       do: humanize(reason)

  defp skip_reason(_intent), do: "it could not go ahead"

  defp blocked_reason(%{blocked_reason: reason}) when is_binary(reason) and reason != "",
    do: reason

  defp blocked_reason(_intent), do: "the step cannot progress"

  defp humanize(text), do: text |> String.replace("_", " ") |> String.downcase()
  defp good(nil), do: "goods"
  defp good(symbol), do: symbol |> String.replace("_", " ") |> String.capitalize()
  defp short(symbol), do: symbol |> String.split("-") |> List.last()
end
