# Opt-in #837 matched comparison of two arm summaries written by
# shipyard_productive_investment.exs (unchanged control B, repair V), one
# preset at a time. Reports N_B(T), N_V(T), Delta(T) and the P1 class.
#
#   MIX_ENV=test mix run --no-start test/diagnostics/shipyard_productive_compare.exs \
#     B/837-steady_growth-summary.json V/837-steady_growth-summary.json
defmodule SpaceTraders.ShipyardProductiveCompare do
  import ExUnit.Assertions

  def run([b_path, v_path]) do
    [b, v] = Enum.map([b_path, v_path], &load/1)

    # Identical frozen inputs and fixture sources; independent arms.
    assert b.preset == v.preset
    assert b.manifest == v.manifest
    assert b.comparison_sources == v.comparison_sources
    assert b.as_of == v.as_of and b.as_of == "2026-10-24T00:00:00Z"
    assert b.code_revision == "accae0cced7a6d3e866724b0117ddaaaf66d6afc"
    refute v.code_revision == b.code_revision

    SpaceTraders.ShipyardPayback.classify(b, v)
    |> Map.merge(%{
      preset: v.preset,
      b: Map.take(b, ~w(code_revision cycles_by_ship acquisitions contradictions account)a),
      v:
        Map.take(
          v,
          ~w(code_revision cycles_by_ship acquisitions new_ship_cycles valuation payback account unknown_effects unsettled_attempts unfinished_intents closure_tail_effects)a
        ),
      limits: [
        "Fixture forecast, not realized repayment or live qualification.",
        "No 10k/5% superiority gate; a negative acquisition-loaded Delta is reported as observed.",
        "Delta attribution is inconclusive while B records send-clock contradictions."
      ]
    })
    |> Jason.encode!(pretty: true)
    |> IO.puts()
  end

  defp load(path) do
    arm = path |> File.read!() |> Jason.decode!(keys: :atoms)
    classes = Map.new(~w(supported inconclusive not_applicable)a, &{Atom.to_string(&1), &1})
    update_in(arm.payback.classification, &Map.fetch!(classes, &1))
  end
end

SpaceTraders.ShipyardProductiveCompare.run(System.argv())
