defmodule Mix.Tasks.SpaceTraders.Gen.Operations do
  @shortdoc "Generate the classified SpaceTraders operation inventory"

  @moduledoc """
  Generates the executable operation inventory from the bundled OpenAPI spec
  and this task's deliberately maintained governance metadata.

      mix space_traders.gen.operations
      mix space_traders.gen.operations --check

  A new or removed OpenAPI operation makes generation fail until its ownership
  and recovery behavior are deliberately classified here.
  """

  use Mix.Task

  @spec_path "priv/spec/SpaceTraders.json"
  @target_path "lib/spacetraders/api/operation_inventory.ex"

  @read_operations ~w(
    get-status get-systems get-system get-system-waypoints get-waypoint get-market
    get-shipyard get-jump-gate get-construction get-factions get-faction get-my-agent
    get-agents get-agent get-contracts get-contract get-my-ships get-my-ship
    get-my-ship-cargo get-ship-cooldown get-ship-nav get-mounts get-scrap-ship
    get-repair-ship get-supply-chain get-ship-modules
  )

  defp ship_mutation(prerequisites, consequences, evidence, waits \\ :none) do
    {:ship_execution, prerequisites, consequences, evidence, waits}
  end

  defp generate_entry_source(entry) do
    fields = [
      :id,
      :method,
      :path,
      :classification,
      :owner,
      :prerequisites,
      :consequences,
      :success_evidence,
      :waits,
      :ambiguity,
      :visibility,
      :pagination
    ]

    body =
      Enum.map_join(fields, ",\n", fn field ->
        value = inspect(Map.fetch!(entry, field), pretty: true, limit: :infinity, width: 120)
        "#{field}: #{value}"
      end)

    "%Operation{#{body}}"
  end

  defp mutation_metadata do
    %{
      "register" =>
        {:fleet_generation, ["AccountToken authority", "available Agent symbol"],
         ["mints an Agent and its initial Fleet"], ["registration response and AgentToken"],
         :none},
      "supply-construction" =>
        {:ship_execution, ["Ship present with required Cargo", "incomplete Construction"],
         ["removes Cargo and advances Construction"], ["Cargo and Construction response"], :none},
      "accept-contract" =>
        {:fleet_reconciliation, ["available Contract before acceptance deadline"],
         ["accepts Contract and may pay acceptance credits"], ["Agent and Contract response"],
         :none},
      "deliver-contract" =>
        {:ship_execution, ["Ship at delivery Waypoint with required Cargo"],
         ["removes Cargo and advances Contract delivery"], ["Cargo and Contract response"],
         :none},
      "fulfill-contract" =>
        {:fleet_reconciliation, ["accepted Contract with all deliveries complete"],
         ["fulfills Contract and pays completion credits"], ["Agent and Contract response"],
         :none},
      "purchase-ship" =>
        {:fleet_reconciliation, ["Shipyard offer", "sufficient unreserved credits"],
         ["spends credits and adds a Ship"], ["Agent, Ship, and transaction response"], :none},
      "orbit-ship" =>
        ship_mutation(["docked Ship"], ["changes Ship posture to orbit"], ["Ship nav response"]),
      "ship-refine" =>
        ship_mutation(
          ["refinery module", "required Cargo"],
          ["converts Cargo"],
          ["Cargo, Cooldown, and production response"],
          :cooldown
        ),
      "create-chart" =>
        ship_mutation(["uncharted current Waypoint"], ["charts current Waypoint"], [
          "Chart and Waypoint response"
        ]),
      "dock-ship" =>
        ship_mutation(["orbiting Ship"], ["changes Ship posture to docked"], ["Ship nav response"]),
      "create-survey" =>
        ship_mutation(
          ["survey mount", "surveyable Waypoint"],
          ["creates Surveys"],
          ["Surveys and Cooldown response"],
          :cooldown
        ),
      "extract-resources" =>
        ship_mutation(
          ["extraction mount", "extractable Waypoint", "Cargo capacity"],
          ["adds extracted Cargo"],
          ["Extraction, Cargo, and Cooldown response"],
          :cooldown
        ),
      "siphon-resources" =>
        ship_mutation(
          ["siphon mount", "gas Waypoint", "Cargo capacity"],
          ["adds siphoned Cargo"],
          ["Siphon, Cargo, and Cooldown response"],
          :cooldown
        ),
      "extract-resources-with-survey" =>
        ship_mutation(
          ["valid matching Survey", "extraction capability", "Cargo capacity"],
          ["adds extracted Cargo and may exhaust Survey"],
          ["Extraction, Cargo, events, and Cooldown response"],
          :cooldown
        ),
      "jettison" => ship_mutation(["Cargo units aboard"], ["removes Cargo"], ["Cargo response"]),
      "jump-ship" =>
        ship_mutation(
          ["connected Jump Gate", "eligible Ship"],
          ["starts inter-System transit"],
          ["Ship nav, Agent, and Cooldown response"],
          :transit
        ),
      "navigate-ship" =>
        ship_mutation(
          ["reachable destination", "sufficient fuel"],
          ["starts local transit"],
          ["Ship nav and fuel response"],
          :transit
        ),
      "patch-ship-nav" =>
        ship_mutation(["eligible Ship flight mode"], ["changes Flight Mode"], [
          "Ship nav, fuel, and events response"
        ]),
      "warp-ship" =>
        ship_mutation(
          ["warp capability", "reachable destination", "sufficient fuel"],
          ["starts inter-System transit"],
          ["Ship nav and fuel response"],
          :transit
        ),
      "sell-cargo" =>
        ship_mutation(
          ["Ship docked at buying Market", "Cargo units aboard"],
          ["removes Cargo and adds credits"],
          ["Agent, Cargo, and transaction response"]
        ),
      "create-ship-system-scan" =>
        ship_mutation(
          ["sensor mount", "eligible Ship"],
          ["observes nearby Systems"],
          ["scanned Systems and Cooldown response"],
          :cooldown
        ),
      "create-ship-waypoint-scan" =>
        ship_mutation(
          ["sensor mount", "eligible Ship"],
          ["observes nearby Waypoints"],
          ["scanned Waypoints and Cooldown response"],
          :cooldown
        ),
      "create-ship-ship-scan" =>
        ship_mutation(
          ["sensor mount", "eligible Ship"],
          ["observes nearby Ships"],
          ["scanned Ships and Cooldown response"],
          :cooldown
        ),
      "refuel-ship" =>
        ship_mutation(
          ["Ship at refueling Waypoint", "sufficient credits or fuel Cargo"],
          ["adds Ship fuel and may spend credits or Cargo"],
          ["Agent, Cargo, fuel, and transaction response"]
        ),
      "purchase-cargo" =>
        ship_mutation(
          ["Ship docked at selling Market", "Cargo capacity", "sufficient credits"],
          ["adds Cargo and spends credits"],
          ["Agent, Cargo, and transaction response"]
        ),
      "transfer-cargo" =>
        ship_mutation(
          ["co-located Ships", "source Cargo", "target Cargo capacity"],
          ["moves Cargo between Ships"],
          ["source Cargo response"]
        ),
      "negotiateContract" =>
        {:fleet_reconciliation, ["Ship at faction headquarters", "Contract capacity"],
         ["creates an offered Contract"], ["Contract response"], :none},
      "install-mount" =>
        ship_mutation(
          ["Ship at capable Shipyard", "mount in Cargo", "Ship capacity"],
          ["moves mount from Cargo onto Ship and may spend credits"],
          ["mounts, Cargo, Agent, and transaction response"]
        ),
      "remove-mount" =>
        ship_mutation(
          ["Ship at capable Shipyard", "installed mount", "Cargo capacity"],
          ["moves mount from Ship into Cargo and may spend credits"],
          ["mounts, Cargo, Agent, and transaction response"]
        ),
      "scrap-ship" =>
        {:fleet_reconciliation, ["Ship docked at capable Shipyard", "confirmed scrap valuation"],
         ["removes Ship and adds credits"], ["Agent and scrap transaction response"], :none},
      "repair-ship" =>
        ship_mutation(
          ["Ship docked at capable Shipyard", "confirmed repair cost", "sufficient credits"],
          ["restores Ship component condition and spends credits"],
          ["repaired Ship and transaction response"]
        ),
      "install-ship-module" =>
        ship_mutation(
          ["Ship docked at capable Shipyard", "module in Cargo", "Ship capacity"],
          ["moves module from Cargo onto Ship and may spend credits"],
          ["modules, Cargo, Agent, and transaction response"]
        ),
      "remove-ship-module" =>
        ship_mutation(
          ["Ship docked at capable Shipyard", "installed module", "Cargo capacity"],
          ["moves module from Ship into Cargo and may spend credits"],
          ["modules, Cargo, Agent, and transaction response"]
        )
    }
  end

  @impl true
  def run(args) do
    source = generate_source()

    if "--check" in args do
      check_no_drift(source)
    else
      File.write!(@target_path, source)
      Mix.shell().info("Generated operation inventory from the bundled spec")
    end
  end

  @doc false
  def generate_source do
    operations = load_operations()
    assert_complete_classification!(operations)

    entries = Enum.map(operations, &classify/1)

    entries_source =
      entries
      |> Enum.map(&generate_entry_source/1)
      |> Enum.join(",\n")

    ~s'''
    defmodule SpaceTraders.API.OperationInventory.Operation do
      @moduledoc false
      @enforce_keys [
        :id,
        :method,
        :path,
        :classification,
        :owner,
        :prerequisites,
        :consequences,
        :success_evidence,
        :waits,
        :ambiguity,
        :visibility,
        :pagination
      ]
      defstruct @enforce_keys

      @type t() :: %__MODULE__{}
    end

    defmodule SpaceTraders.API.OperationInventory do
      @moduledoc """
      Generated inventory of every operation in the pinned SpaceTraders API.

      Regenerate with `mix space_traders.gen.operations`; edit operation governance
      metadata in that task rather than editing this file directly.
      """

      alias SpaceTraders.API.OperationInventory.Operation

      @operations [#{entries_source}]

      @spec all() :: [Operation.t()]
      def all, do: @operations

      @spec fetch!(String.t()) :: Operation.t()
      def fetch!(operation_id) do
        Enum.find(@operations, &(&1.id == operation_id)) ||
          raise KeyError, key: operation_id, term: __MODULE__
      end
    end
    '''
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> then(&(&1 <> "\n"))
  end

  defp load_operations do
    @spec_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("paths")
    |> Enum.flat_map(fn {path, path_item} ->
      path_item
      |> Map.take(["get", "post", "patch", "put", "delete"])
      |> Enum.map(fn {method, operation} ->
        %{
          id: Map.fetch!(operation, "operationId"),
          method: String.to_atom(method),
          path: path,
          query_parameters:
            operation
            |> Map.get("parameters", [])
            |> Enum.filter(&(&1["in"] == "query"))
        }
      end)
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp assert_complete_classification!(operations) do
    spec_ids = MapSet.new(operations, & &1.id)
    classified_ids = MapSet.new(@read_operations ++ Map.keys(mutation_metadata()))

    if spec_ids != classified_ids do
      missing = MapSet.difference(spec_ids, classified_ids) |> Enum.sort()
      removed = MapSet.difference(classified_ids, spec_ids) |> Enum.sort()

      Mix.raise(
        "Pinned API operation classification drift. " <>
          "Unclassified: #{inspect(missing)}; absent from spec: #{inspect(removed)}"
      )
    end
  end

  defp classify(%{id: id} = operation) when id in @read_operations do
    operation
    |> Map.drop([:query_parameters])
    |> Map.merge(%{
      classification: :read,
      owner: :evidence,
      prerequisites: read_prerequisites(operation),
      consequences: ["records an authoritative observation without changing game state"],
      success_evidence: ["successful response body with observation provenance"],
      waits: [],
      ambiguity: :safe_retry,
      visibility: visibility(operation),
      pagination: pagination(operation)
    })
  end

  defp classify(%{id: id} = operation) do
    {owner, prerequisites, consequences, success_evidence, waits} =
      Map.fetch!(mutation_metadata(), id)

    operation
    |> Map.drop([:query_parameters])
    |> Map.merge(%{
      classification: :mutation,
      owner: owner,
      prerequisites: prerequisites,
      consequences: consequences,
      success_evidence: success_evidence,
      waits: mutation_waits(id, waits),
      ambiguity: {:reconcile_before_retry, reconciliation_evidence(id)},
      visibility: visibility(operation),
      pagination: :none
    })
  end

  defp read_prerequisites(%{id: "get-status"}), do: ["public API availability"]

  defp read_prerequisites(%{path: path}) do
    if String.starts_with?(path, "/my/") do
      ["AgentToken credential reference", "requested entity identifiers"]
    else
      ["requested entity identifiers"]
    end
  end

  defp visibility(%{id: "get-status"}), do: :public
  defp visibility(%{id: id}) when id in ["get-market", "get-shipyard"], do: :location_dependent
  defp visibility(%{path: "/my/ships/" <> _}), do: :ship_local
  defp visibility(%{path: "/my/" <> _}), do: :agent
  defp visibility(_operation), do: :public

  defp pagination(%{query_parameters: []}), do: :none

  defp pagination(%{query_parameters: parameters}) do
    names = MapSet.new(parameters, & &1["name"])
    if MapSet.subset?(MapSet.new(["page", "limit"]), names), do: :page_limit, else: :none
  end

  defp mutation_waits("jump-ship", :transit), do: [:transit, :cooldown]
  defp mutation_waits(_id, :none), do: []
  defp mutation_waits(_id, wait), do: [wait]

  defp reconciliation_evidence("register"), do: ["Agent existence by symbol"]

  defp reconciliation_evidence(id)
       when id in ["accept-contract", "fulfill-contract", "negotiateContract"],
       do: ["Contract state", "Agent credits"]

  defp reconciliation_evidence("deliver-contract"), do: ["Contract delivery", "Ship Cargo"]
  defp reconciliation_evidence("supply-construction"), do: ["Construction state", "Ship Cargo"]
  defp reconciliation_evidence("purchase-ship"), do: ["owned Fleet", "Agent credits"]
  defp reconciliation_evidence("scrap-ship"), do: ["owned Fleet", "Agent credits"]

  defp reconciliation_evidence(id)
       when id in ["purchase-cargo", "sell-cargo", "refuel-ship"],
       do: ["Ship state", "Agent credits"]

  defp reconciliation_evidence(id)
       when id in ["jettison", "transfer-cargo", "install-mount", "remove-mount"],
       do: ["Ship Cargo", "Ship Readiness"]

  defp reconciliation_evidence(id)
       when id in ["install-ship-module", "remove-ship-module", "repair-ship"],
       do: ["Ship state", "Ship Readiness"]

  defp reconciliation_evidence(_id), do: ["Ship state"]

  defp check_no_drift(source) do
    case File.read(@target_path) do
      {:ok, ^source} ->
        Mix.shell().info("Operation inventory is up to date with the bundled spec")

      _ ->
        Mix.raise("#{@target_path} is stale — run `mix space_traders.gen.operations`.")
    end
  end
end
