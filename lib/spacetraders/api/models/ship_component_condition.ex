defmodule SpaceTraders.API.Model.ShipComponentCondition do
  @moduledoc "The repairable condition of a component. A value of 0 indicates the component needs significant repairs, while a value of 1 indicates the component is in near perfect condition. As the condition of a component is repaired, the overall integrity of the component decreases."

  @type t :: float()
end
