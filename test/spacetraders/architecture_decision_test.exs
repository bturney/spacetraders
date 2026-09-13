defmodule SpaceTraders.ArchitectureDecisionTest do
  use ExUnit.Case, async: true

  @adr_dir Path.expand("../../docs/adr", __DIR__)
  @governing_adr Path.join(@adr_dir, "0010-autonomous-runtime.md")
  @relationships [
    {"0002-sqlite-local-state.md", "ADR 0002 is superseded",
     "Superseded for the autonomous runtime by [ADR 0010](0010-autonomous-runtime.md)."},
    {"0004-liveview-as-control-surface-no-cli.md", "ADR 0004 is superseded",
     "The per-Ship manual-control framing is superseded for the autonomous runtime by [ADR 0010](0010-autonomous-runtime.md)."},
    {"0005-async-time-per-entity-timers.md", "ADR 0005 is superseded",
     "The timer ownership, SQLite persistence, and per-entity scheduling decisions are superseded for the autonomous runtime by [ADR 0010](0010-autonomous-runtime.md)."},
    {"0007-game-truth-and-quality-of-life-guardrails.md", "ADR 0007 is reaffirmed",
     "Reaffirmed as the gameplay authority boundary by [ADR 0010](0010-autonomous-runtime.md)."}
  ]

  test "the governing decision is accepted and records each authority relationship" do
    decision = File.read!(@governing_adr)

    assert decision =~ "Status: Accepted"
    assert decision =~ "SpaceTraders is authoritative"

    for {_filename, relationship, _backlink} <- @relationships do
      assert decision =~ relationship
    end
  end

  test "earlier decisions point maintainers to the governing decision" do
    for {filename, _relationship, backlink} <- @relationships do
      earlier_decision = @adr_dir |> Path.join(filename) |> File.read!() |> normalize_whitespace()

      assert earlier_decision =~ backlink
    end
  end

  defp normalize_whitespace(contents), do: String.replace(contents, ~r/\s+/, " ")
end
