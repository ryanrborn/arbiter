defmodule ArbiterWeb.PagingTest do
  use ExUnit.Case, async: true

  alias ArbiterWeb.Paging

  describe "parse_page/1" do
    test "defaults to 1 when absent or unparseable" do
      assert Paging.parse_page(%{}) == 1
      assert Paging.parse_page(%{"page" => "nope"}) == 1
      assert Paging.parse_page(%{"page" => "0"}) == 1
      assert Paging.parse_page(%{"page" => "-3"}) == 1
    end

    test "parses a valid 1-based page" do
      assert Paging.parse_page(%{"page" => "4"}) == 4
      assert Paging.parse_page(%{"page" => "12"}) == 12
    end
  end

  describe "paginate_list/3" do
    test "slices the requested page and reports metadata" do
      list = Enum.to_list(1..55)

      p1 = Paging.paginate_list(list, 1, 25)
      assert p1.entries == Enum.to_list(1..25)
      assert p1.page == 1
      assert p1.total_count == 55
      assert p1.total_pages == 3

      p3 = Paging.paginate_list(list, 3, 25)
      assert p3.entries == Enum.to_list(51..55)
      assert p3.page == 3
    end

    test "clamps an out-of-range page to the last page" do
      list = Enum.to_list(1..10)
      result = Paging.paginate_list(list, 99, 25)
      assert result.page == 1
      assert result.total_pages == 1
      assert result.entries == list
    end

    test "an empty list still reports one page" do
      result = Paging.paginate_list([], 1, 25)
      assert result.entries == []
      assert result.total_count == 0
      assert result.total_pages == 1
    end
  end
end
