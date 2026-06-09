defmodule Arbiter.Beads.Issue.Changes.InheritTrackerTypeTest do
  @moduledoc """
  Tests for tracker_type inheritance from workspace config during issue creation.

  Verifies that:

    * tracker_type is inferred from workspace.config["tracker"]["type"]
    * when tracker_type is explicitly passed, it's not overridden,
    * tracker types including "shortcut" are properly recognized, and
    * :none is the fallback when the workspace has no tracker configured.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.Issue
  alias Arbiter.Beads.Workspace

  defp workspace_with_tracker(tracker_type) when is_binary(tracker_type) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-#{tracker_type}-#{System.unique_integer([:positive])}",
        prefix: String.slice(tracker_type, 0..2),
        config: %{"tracker" => %{"type" => tracker_type}}
      })

    ws
  end

  defp workspace_without_tracker do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-none-#{System.unique_integer([:positive])}",
        prefix: "wn"
      })

    ws
  end

  describe "inheritance from workspace.config" do
    test "inherits github tracker_type" do
      ws = workspace_with_tracker("github")

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "github tracked",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :github
    end

    test "inherits jira tracker_type" do
      ws = workspace_with_tracker("jira")

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "jira tracked",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :jira
    end

    test "inherits linear tracker_type" do
      ws = workspace_with_tracker("linear")

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "linear tracked",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :linear
    end

    test "inherits shortcut tracker_type" do
      ws = workspace_with_tracker("shortcut")

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "shortcut tracked",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :shortcut
    end

    test "defaults to :none when workspace has no tracker config" do
      ws = workspace_without_tracker()

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "no tracker",
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :none
    end
  end

  describe "explicit override" do
    test "explicit tracker_type is not overridden by workspace config" do
      ws = workspace_with_tracker("github")

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "override tracker",
                 tracker_type: :jira,
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :jira
    end

    test "explicit :none overrides workspace tracker config" do
      ws = workspace_with_tracker("shortcut")

      assert {:ok, issue} =
               Ash.create(Issue, %{
                 title: "force local only",
                 tracker_type: :none,
                 workspace_id: ws.id
               })

      assert issue.tracker_type == :none
    end
  end
end
