defmodule SpaceTraders.FleetStrategy do
  @moduledoc """
  Owns durable Operator-authored Fleet Strategy drafts and immutable revisions.

  Draft and recommendation changes never change active intent. Only an explicit
  call to `activate/1` snapshots the current draft and advances the active
  Fleet Strategy Revision.
  """

  import Ecto.Query, warn: false

  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Repo

  @presets [
    %{
      id: "steady_growth",
      name: "Steady growth",
      summary: "Grow the Fleet economy while protecting operating capital.",
      objectives: [
        %{
          "objective" => "Grow credits",
          "evaluation" => "Maximize net credit growth over time"
        }
      ],
      hard_constraints: ["Keep at least 50,000 credits available"],
      preferences: ["Prefer lower-risk routes when expected returns are similar"],
      consequences:
        "The Fleet may spend credits and accept bounded trading losses while preserving the credit floor."
    },
    %{
      id: "charted_expansion",
      name: "Charted expansion",
      summary: "Prioritize useful map coverage without exhausting operating capital.",
      objectives: [
        %{
          "objective" => "Chart useful waypoints",
          "evaluation" => "Increase newly charted waypoint coverage"
        },
        %{
          "objective" => "Grow credits",
          "evaluation" => "Maximize net credit growth after charting needs are protected"
        }
      ],
      hard_constraints: ["Keep at least 75,000 credits available"],
      preferences: ["Prefer nearby uncharted systems when expected coverage is similar"],
      consequences:
        "The Fleet may favor exploration over near-term earnings and spend credits above the protected floor."
    }
  ]

  @doc "Returns fully disclosed built-in Fleet Strategy presets."
  def presets, do: @presets

  @doc "Returns the authenticated Operator's current draft and active revision."
  def get(%Scope{operator: %Operator{id: operator_id}}) do
    case Repo.get_by(Strategy, operator_id: operator_id) do
      nil ->
        %{draft: nil, draft_source: nil, active_revision: nil}

      strategy ->
        %{
          draft: strategy.draft_document,
          draft_source: strategy.draft_source,
          active_revision: active_revision(strategy)
        }
    end
  end

  @doc "Persists an Operator-authored draft without changing active intent."
  def save_draft(%Scope{} = scope, document), do: put_draft(scope, document, "operator")

  @doc "Opens a recommendation as a reviewable draft without changing active intent."
  def recommend(%Scope{} = scope, document) do
    case get(scope) do
      %{draft: nil} -> put_draft(scope, document, "recommendation")
      _ -> {:error, :draft_exists}
    end
  end

  @doc "Copies a disclosed preset into a reviewable draft."
  def select_preset(%Scope{} = scope, preset_id) do
    case Enum.find(@presets, &(&1.id == preset_id)) do
      nil -> {:error, :preset_not_found}
      preset -> put_draft(scope, preset_document(preset), "preset:#{preset.id}")
    end
  end

  @doc "Discards the draft without changing active intent."
  def discard_draft(%Scope{operator: %Operator{id: operator_id}} = scope) do
    case Repo.get_by(Strategy, operator_id: operator_id) do
      nil -> {:ok, get(scope)}
      strategy -> update_strategy(strategy, scope, %{draft_document: nil, draft_source: nil})
    end
  end

  @doc "Explicitly activates the current draft as a new immutable revision."
  def activate(%Scope{operator: %Operator{id: operator_id}} = scope) do
    result =
      Repo.transaction(fn ->
        with %Strategy{} = strategy <- Repo.get_by(Strategy, operator_id: operator_id),
             document when is_map(document) <- strategy.draft_document,
             :ok <- validate_document(document) do
          revision =
            %Revision{}
            |> Revision.create_changeset(%{
              fleet_strategy_id: strategy.id,
              number: next_revision_number(strategy.id),
              document: document,
              source: strategy.draft_source || "operator",
              activated_at: DateTime.utc_now(:second)
            })
            |> Repo.insert!()

          strategy
          |> Strategy.changeset(%{
            active_revision_id: revision.id,
            draft_document: nil,
            draft_source: nil
          })
          |> Repo.update!()

          revision
        else
          nil -> Repo.rollback(:draft_not_found)
          :error -> Repo.rollback(:draft_not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    if match?({:ok, %Revision{}}, result), do: broadcast_update(scope)
    result
  end

  defp put_draft(%Scope{operator: %Operator{id: operator_id}} = scope, document, source)
       when is_map(document) do
    strategy =
      Repo.get_by(Strategy, operator_id: operator_id) || %Strategy{operator_id: operator_id}

    update_strategy(strategy, scope, %{draft_document: document, draft_source: source})
  end

  defp put_draft(_scope, _document, _source), do: {:error, :invalid_document}

  defp update_strategy(strategy, scope, attrs) do
    case strategy |> Strategy.changeset(attrs) |> Repo.insert_or_update() do
      {:ok, _strategy} ->
        broadcast_update(scope)
        {:ok, get(scope)}

      error ->
        error
    end
  end

  defp active_revision(%Strategy{active_revision_id: nil}), do: nil
  defp active_revision(%Strategy{active_revision_id: id}), do: Repo.get(Revision, id)

  defp next_revision_number(strategy_id) do
    Repo.one(
      from revision in Revision,
        where: revision.fleet_strategy_id == ^strategy_id,
        select: coalesce(max(revision.number), 0)
    ) + 1
  end

  defp validate_document(%{
         "objectives" => [_ | _],
         "hard_constraints" => constraints,
         "preferences" => preferences
       })
       when is_list(constraints) and is_list(preferences),
       do: :ok

  defp validate_document(_document), do: {:error, :invalid_document}

  defp preset_document(preset) do
    %{
      "objectives" => preset.objectives,
      "hard_constraints" => preset.hard_constraints,
      "preferences" => preset.preferences,
      "consequences" => preset.consequences
    }
  end

  defp broadcast_update(%Scope{operator: %Operator{id: operator_id}}) do
    Phoenix.PubSub.broadcast(
      SpaceTraders.PubSub,
      "fleet_strategy:#{operator_id}",
      {:fleet_strategy_updated, operator_id}
    )
  end
end
