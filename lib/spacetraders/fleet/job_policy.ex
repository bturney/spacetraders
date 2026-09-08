defmodule SpaceTraders.Fleet.JobPolicy do
  @moduledoc "Common decision vocabulary for focused Job Policies."

  @type decision ::
          {:complete, map()}
          | {:wait, atom()}
          | {:block, term()}
          | {:intent, atom() | map()}
end
