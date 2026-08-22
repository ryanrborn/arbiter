defmodule Arbiter.Board.FileScopeTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.FileScope

  describe "declared_paths/1" do
    test "extracts repo-relative file paths from an issue's text" do
      issue = %{
        title: "Board screen",
        description: "Replaces `lib/arbiter_web/live/dashboard_live.ex` entirely.",
        acceptance: nil,
        notes: nil
      }

      assert FileScope.declared_paths(issue) ==
               MapSet.new(["lib/arbiter_web/live/dashboard_live.ex"])
    end

    test "extracts directory scopes as trailing-slash entries" do
      issue = %{title: "x", description: "Touches `apps/arbiter/lib/arbiter/board/` broadly."}

      assert FileScope.declared_paths(issue) ==
               MapSet.new(["apps/arbiter/lib/arbiter/board/"])
    end

    test "ignores prose, bare words and non-path tokens" do
      issue = %{
        title: "Fix the thing",
        description: "It is 3.5x faster. See README and `mix test`. Version 1.2.3 shipped."
      }

      assert FileScope.declared_paths(issue) == MapSet.new()
    end

    test "de-duplicates and normalises leading ./" do
      issue = %{title: "t", description: "`./lib/a.ex` and lib/a.ex and `lib/a.ex`"}

      assert FileScope.declared_paths(issue) == MapSet.new(["lib/a.ex"])
    end

    test "tolerates nil and missing fields" do
      assert FileScope.declared_paths(%{}) == MapSet.new()
      assert FileScope.declared_paths(%{title: nil, description: nil}) == MapSet.new()
    end
  end

  describe "overlap/2" do
    test "is empty when the two scopes share nothing" do
      assert FileScope.overlap(MapSet.new(["lib/a.ex"]), MapSet.new(["lib/b.ex"])) == []
    end

    test "reports the shared path when both name the same file" do
      assert FileScope.overlap(
               MapSet.new(["lib/a.ex", "lib/c.ex"]),
               MapSet.new(["lib/b.ex", "lib/a.ex"])
             ) == ["lib/a.ex"]
    end

    test "a declared directory contains files beneath it" do
      assert FileScope.overlap(
               MapSet.new(["lib/board/"]),
               MapSet.new(["lib/board/scheduler.ex"])
             ) == ["lib/board/scheduler.ex"]
    end

    test "a directory on the other side matches too, and is reported as the file" do
      assert FileScope.overlap(
               MapSet.new(["lib/board/scheduler.ex"]),
               MapSet.new(["lib/board/"])
             ) == ["lib/board/scheduler.ex"]
    end

    test "a directory prefix must land on a segment boundary" do
      assert FileScope.overlap(
               MapSet.new(["lib/board/"]),
               MapSet.new(["lib/boardroom/x.ex"])
             ) == []
    end

    test "results are sorted and de-duplicated" do
      assert FileScope.overlap(
               MapSet.new(["lib/b.ex", "lib/a.ex", "lib/"]),
               MapSet.new(["lib/a.ex", "lib/b.ex"])
             ) == ["lib/a.ex", "lib/b.ex"]
    end
  end

  describe "overlap?/2" do
    test "mirrors overlap/2 emptiness" do
      refute FileScope.overlap?(MapSet.new(["lib/a.ex"]), MapSet.new(["lib/b.ex"]))
      assert FileScope.overlap?(MapSet.new(["lib/a.ex"]), MapSet.new(["lib/a.ex"]))
    end
  end
end
