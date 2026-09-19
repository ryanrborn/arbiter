defmodule ArbiterWeb.NavTest do
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  alias ArbiterWeb.Nav

  describe "groups/1" do
    test "returns the 5 groups in exact order with expected labels" do
      groups = Nav.groups(3)

      assert length(groups) == 5

      labels = Enum.map(groups, & &1.label)
      assert labels == [nil, "Work", "Fleet", "Analysis", "Config"]
    end

    test "item order within each group matches specification" do
      groups = Nav.groups(5)

      [ungrouped, work, fleet, analysis, config] = groups

      assert Enum.map(ungrouped.items, &{&1.label, &1.href}) == [
               {"Board", "/"}
             ]

      assert Enum.map(work.items, &{&1.label, &1.href}) == [
               {"Issues", "/tasks"},
               {"Epics", "/epics"},
               {"Merge queues", "/merge_queue"}
             ]

      assert Enum.map(fleet.items, &{&1.label, &1.href}) == [
               {"Workers", "/workers"},
               {"Run history", "/workers/history"},
               {"Sessions", "/sessions"}
             ]

      assert Enum.map(analysis.items, &{&1.label, &1.href}) == [
               {"Usage", "/usage"},
               {"Reviews", "/reviews"},
               {"Audit", "/audit"}
             ]

      assert Enum.map(config.items, &{&1.label, &1.href}) == [
               {"Workspaces", "/workspaces"},
               {"Skills", "/skills"},
               {"Loop", "/loop"}
             ]
    end

    test "the Epics badge equals the passed count while every other badge is nil" do
      count = 42
      groups = Nav.groups(count)
      all_items = Nav.flat_items(groups)

      assert length(all_items) == 13

      epics_item = Enum.find(all_items, &(&1.href == "/epics"))
      assert epics_item.badge == count

      other_items = Enum.reject(all_items, &(&1.href == "/epics"))
      assert Enum.all?(other_items, &is_nil(&1.badge))
    end

    test "every item's :icon is a heroicon name that Core.icon/1 renders without raising" do
      groups = Nav.groups(0)
      all_items = Nav.flat_items(groups)

      for item <- all_items do
        assert is_binary(item.icon)
        assert String.starts_with?(item.icon, "hero-")

        # Rendering with Core.icon/1 must not raise
        html =
          render_component(&ArbiterWeb.CoreComponents.Core.icon/1, %{name: item.icon})

        assert html =~ item.icon
      end
    end
  end

  describe "flat_items/1" do
    test "returns every item across every group in group order" do
      groups = Nav.groups(10)
      flat = Nav.flat_items(groups)

      assert length(flat) == 13

      expected_hrefs = [
        "/",
        "/tasks",
        "/epics",
        "/merge_queue",
        "/workers",
        "/workers/history",
        "/sessions",
        "/usage",
        "/reviews",
        "/audit",
        "/workspaces",
        "/skills",
        "/loop"
      ]

      assert Enum.map(flat, & &1.href) == expected_hrefs

      for item <- flat do
        assert Map.has_key?(item, :label)
        assert Map.has_key?(item, :href)
        assert Map.has_key?(item, :badge)
      end
    end
  end

  describe "active?/2" do
    test "root path exact match" do
      assert Nav.active?("/", "/") == true
      assert Nav.active?("/tasks", "/") == false
      assert Nav.active?("/anything", "/") == false
    end

    test "prefix match" do
      assert Nav.active?("/tasks", "/tasks") == true
      assert Nav.active?("/tasks/42", "/tasks") == true
      assert Nav.active?("/workers/history", "/workers/history") == true
      assert Nav.active?("/workers/history/abc123", "/workers/history") == true
    end

    test "sibling sharing prefix string does not match" do
      assert Nav.active?("/tasksomething", "/tasks") == false
      assert Nav.active?("/workers-backup", "/workers") == false
    end

    test "nil current path returns false" do
      assert Nav.active?(nil, "/") == false
      assert Nav.active?(nil, "/tasks") == false
      assert Nav.active?(nil, "/workers/history") == false
    end
  end

  describe "active_href/2" do
    test "returns the longest matching item href, resolving run-detail to /workers/history" do
      groups = Nav.groups(0)

      assert Nav.active_href(groups, "/workers/history/abc123") == "/workers/history"
      assert Nav.active_href(groups, "/workers/history") == "/workers/history"
      assert Nav.active_href(groups, "/workers/42") == "/workers"
      assert Nav.active_href(groups, "/workers") == "/workers"
      assert Nav.active_href(groups, "/") == "/"
    end

    test "returns nil when no item matches" do
      groups = Nav.groups(0)

      assert Nav.active_href(groups, nil) == nil
      assert Nav.active_href(groups, "/other/unknown") == nil
    end
  end
end
