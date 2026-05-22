defmodule Arbiter.Beads.DoltImport.MapperTest do
  use ExUnit.Case, async: true

  alias Arbiter.Beads.DoltImport.Mapper

  describe "map_status/1" do
    test ~s("open" → :open), do: assert Mapper.map_status("open") == :open
    test ~s("closed" → :closed), do: assert Mapper.map_status("closed") == :closed

    test ~s(anything else → :in_progress) do
      assert Mapper.map_status("hooked") == :in_progress
      assert Mapper.map_status("working") == :in_progress
      assert Mapper.map_status("stalled") == :in_progress
      assert Mapper.map_status("") == :in_progress
      assert Mapper.map_status(nil) == :in_progress
    end
  end

  describe "map_issue_type/1" do
    test "known atoms round-trip" do
      for t <- [:task, :bug, :feature, :epic, :chore, :decision] do
        assert Mapper.map_issue_type(Atom.to_string(t)) == t
      end
    end

    test "unknown types default to :task" do
      assert Mapper.map_issue_type("molecule") == :task
      assert Mapper.map_issue_type("wisp") == :task
      assert Mapper.map_issue_type("") == :task
      assert Mapper.map_issue_type(nil) == :task
    end
  end

  describe "parse_priority/1" do
    test "valid ints in 0..4 pass through" do
      for p <- 0..4, do: assert Mapper.parse_priority(p) == p
    end

    test "above 4 clamps to 4" do
      assert Mapper.parse_priority(5) == 4
      assert Mapper.parse_priority(99) == 4
    end

    test "below 0 clamps to 0" do
      assert Mapper.parse_priority(-1) == 0
    end

    test "nil / non-int defaults to 2" do
      assert Mapper.parse_priority(nil) == 2
      assert Mapper.parse_priority("3") == 2
    end
  end

  describe "parse_external_ref/1" do
    test "jira-VR-17585 → {:jira, \"VR-17585\"}" do
      assert Mapper.parse_external_ref("jira-VR-17585") == {:jira, "VR-17585"}
    end

    test "linear-LIN-42 → {:linear, \"LIN-42\"}" do
      assert Mapper.parse_external_ref("linear-LIN-42") == {:linear, "LIN-42"}
    end

    test "gh-123 → {:github, \"123\"}" do
      assert Mapper.parse_external_ref("gh-123") == {:github, "123"}
    end

    test "github-456 → {:github, \"456\"}" do
      assert Mapper.parse_external_ref("github-456") == {:github, "456"}
    end

    test "nil / empty / unknown → {:none, nil}" do
      assert Mapper.parse_external_ref(nil) == {:none, nil}
      assert Mapper.parse_external_ref("") == {:none, nil}
      assert Mapper.parse_external_ref("randomstuff") == {:none, nil}
    end
  end

  describe "map_dep_type/1" do
    test "underscore form" do
      assert Mapper.map_dep_type("blocks") == :blocks
      assert Mapper.map_dep_type("depends_on") == :depends_on
      assert Mapper.map_dep_type("relates_to") == :relates_to
      assert Mapper.map_dep_type("discovered_from") == :discovered_from
      assert Mapper.map_dep_type("parent_of") == :parent_of
    end

    test "hyphen form normalizes to underscore" do
      assert Mapper.map_dep_type("depends-on") == :depends_on
      assert Mapper.map_dep_type("discovered-from") == :discovered_from
      assert Mapper.map_dep_type("relates-to") == :relates_to
    end

    test "unknown types → nil" do
      assert Mapper.map_dep_type("tracks") == nil
      assert Mapper.map_dep_type("") == nil
      assert Mapper.map_dep_type(nil) == nil
    end
  end

  describe "nonempty/1" do
    test "returns nil for nil and empty string" do
      assert Mapper.nonempty(nil) == nil
      assert Mapper.nonempty("") == nil
    end

    test "passes strings through" do
      assert Mapper.nonempty("hello") == "hello"
    end
  end

  describe "parse_dt/1" do
    test "parses Dolt datetime format" do
      dt = Mapper.parse_dt("2026-05-19 19:21:46.123456")
      assert %DateTime{year: 2026, month: 5, day: 19, hour: 19} = dt
    end

    test "parses datetime without microseconds" do
      dt = Mapper.parse_dt("2026-05-19 19:21:46")
      assert %DateTime{year: 2026, hour: 19} = dt
    end

    test "nil / empty / garbage → nil" do
      assert Mapper.parse_dt(nil) == nil
      assert Mapper.parse_dt("") == nil
      assert Mapper.parse_dt("not a date") == nil
    end
  end

  describe "compose_description/1" do
    test "no design field" do
      assert Mapper.compose_description(%{"description" => "hello"}) == "hello"
    end

    test "design appended as ## Design section when description exists" do
      result =
        Mapper.compose_description(%{
          "description" => "main text",
          "design" => "design notes"
        })

      assert result == "main text\n\n## Design\n\n design notes" |> String.replace(" design", "design")
      assert String.contains?(result, "main text")
      assert String.contains?(result, "## Design")
      assert String.contains?(result, "design notes")
    end

    test "only design (no description)" do
      result = Mapper.compose_description(%{"description" => "", "design" => "design"})
      assert result == "## Design\n\ndesign"
    end

    test "both empty" do
      assert Mapper.compose_description(%{"description" => "", "design" => ""}) == ""
    end

    test "nil handling" do
      assert Mapper.compose_description(%{}) == ""
    end
  end

  describe "derive_prefix/1" do
    test "extracts prefix from first id" do
      assert Mapper.derive_prefix([%{"id" => "hq-3o8"}]) == "hq"
      assert Mapper.derive_prefix([%{"id" => "vs-jwq"}]) == "vs"
      assert Mapper.derive_prefix([%{"id" => "verus-cv-7ipag"}]) == "verus"
    end

    test "lowercases the prefix" do
      assert Mapper.derive_prefix([%{"id" => "HQ-3o8"}]) == "hq"
    end

    test "fallback for empty list" do
      assert Mapper.derive_prefix([]) == "bd"
    end
  end
end
