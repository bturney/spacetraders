defmodule SpaceTraders.AgentNameBank do
  @moduledoc """
  Operator-approved, ordered Agent symbol candidates for minting and
  replacement. Fleet Generation reads `list/0`; automatic conflict fallback
  lives there, not here. Separate from game credentials and Strategy intent.

  Names are validated against the registration contract only: uppercase
  normalization and 3..14 characters. Ship symbols are unrelated.
  """

  import Ecto.Query

  alias SpaceTraders.Repo

  @defaults ~w(ORBITALIST PARALLAX APHELION SIDEREAL LIMINAL)
  @min 3
  @max 14

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    schema "agent_name_bank_entries" do
      field :position, :integer
      field :name, :string
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc "Approved initial candidates, in order."
  def defaults, do: @defaults

  @doc "Ordered, unique candidate symbols (uppercase)."
  @spec list() :: [String.t()]
  def list do
    Repo.all(from e in Entry, order_by: e.position, select: e.name)
  end

  @doc "Seeds the defaults only when the bank has no entries; never overwrites."
  @spec ensure_defaults() :: :ok
  def ensure_defaults do
    Repo.transaction(fn ->
      Repo.query!("LOCK TABLE agent_name_bank_entries IN SHARE ROW EXCLUSIVE MODE")

      if not Repo.exists?(Entry), do: insert_all(@defaults)
    end)

    :ok
  end

  @doc "Parses one-name-per-line (or comma separated) text into candidates."
  @spec parse(String.t()) :: [String.t()]
  def parse(text) when is_binary(text), do: String.split(text, ~r/[\r\n,]+/)

  @doc "Validates and replaces the whole ordered bank atomically."
  @spec save([String.t()] | String.t()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def save(text) when is_binary(text), do: text |> parse() |> save()

  def save(names) when is_list(names) do
    with {:ok, normalized} <- validate(names) do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE agent_name_bank_entries IN SHARE ROW EXCLUSIVE MODE")
          Repo.delete_all(Entry)
          insert_all(normalized)
        end)

      {:ok, normalized}
    end
  end

  @spec validate([String.t()]) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def validate(names) do
    normalized =
      names
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.upcase()))
      |> Enum.reject(&(&1 == ""))

    errors =
      length_errors(normalized) ++ duplicate_errors(normalized) ++ empty_errors(normalized)

    if errors == [], do: {:ok, normalized}, else: {:error, errors}
  end

  defp length_errors(names) do
    for name <- names, String.length(name) < @min or String.length(name) > @max do
      "#{name} must be at least #{@min} and at most #{@max} characters."
    end
  end

  defp duplicate_errors(names) do
    names
    |> Enum.frequencies()
    |> Enum.filter(fn {_, n} -> n > 1 end)
    |> Enum.map(fn {name, _} -> "#{name} may appear only once." end)
  end

  defp empty_errors([]), do: ["Enter at least one name."]
  defp empty_errors(_), do: []

  defp insert_all(names) do
    now = DateTime.utc_now()

    rows =
      names
      |> Enum.with_index(1)
      |> Enum.map(fn {name, position} ->
        %{position: position, name: name, inserted_at: now, updated_at: now}
      end)

    Repo.insert_all(Entry, rows)
  end
end
