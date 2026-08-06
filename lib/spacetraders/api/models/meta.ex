defmodule SpaceTraders.API.Model.Meta do
  @moduledoc "Meta details for pagination."

  defstruct [
    :limit,
    :page,
    :total
  ]

  @type t :: %__MODULE__{
          limit: integer(),
          page: integer(),
          total: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Meta`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      limit: json["limit"],
      page: json["page"],
      total: json["total"]
    }
  end
end
