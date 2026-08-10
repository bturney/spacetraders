defmodule SpaceTradersWeb.OriginCheckTest do
  use ExUnit.Case, async: true

  alias SpaceTradersWeb.OriginCheck

  test "uses Phoenix's default check for absent or blank configuration" do
    assert OriginCheck.parse(nil) == true
    assert OriginCheck.parse("") == true
    assert OriginCheck.parse("  ") == true
  end

  test "parses and trims configured origins" do
    assert OriginCheck.parse("//project-host:4000, //project-host.taila148e9.ts.net:4000") == [
             "//project-host:4000",
             "//project-host.taila148e9.ts.net:4000"
           ]
  end
end
