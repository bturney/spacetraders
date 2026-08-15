defmodule SpaceTraders.API.PaginationTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.Pagination

  test "stops on an empty first page" do
    assert {:ok, []} = Pagination.collect(fn 1 -> {:ok, []} end, 20)
  end

  test "continues after exact-sized pages and stops on an empty page" do
    pages = %{1 => Enum.map(1..20, &%{symbol: &1}), 2 => []}

    assert {:ok, waypoints} = Pagination.collect(&{:ok, pages[&1]}, 20)
    assert length(waypoints) == 20
  end

  test "stops on the first short page" do
    pages = %{1 => Enum.map(1..20, &%{symbol: &1}), 2 => [%{symbol: 21}]}

    assert {:ok, waypoints} = Pagination.collect(&{:ok, pages[&1]}, 20)
    assert length(waypoints) == 21
  end

  test "returns collected pages with a later-page failure" do
    pages = %{1 => Enum.map(1..20, &%{symbol: &1}), 2 => {:error, :timeout}}

    assert {:error, :timeout, waypoints} =
             Pagination.collect(&page_result(pages, &1), 20)

    assert length(waypoints) == 20
  end

  defp page_result(pages, page) do
    case Map.fetch!(pages, page) do
      {:error, reason} -> {:error, reason}
      items -> {:ok, items}
    end
  end
end
