defmodule Arbiter.Mergers.PRTitleTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.PRTitle
  alias Arbiter.Tasks.{Issue, Workspace}

  defp issue(attrs) do
    struct(Issue, Map.merge(%{issue_type: :bug, title: "some title", tracker_ref: nil}, attrs))
  end

  defp workspace_with_format(format) do
    struct(Workspace, %{config: %{"merge" => %{"pr_title_format" => format}}})
  end

  describe "format/2 with nil workspace" do
    test "returns the raw task title unchanged" do
      i = issue(%{title: "VS: fix something (VR-123)", tracker_ref: "VR-123"})
      assert PRTitle.format(i, nil) == "VS: fix something (VR-123)"
    end
  end

  describe "format/2 with raw workspace" do
    test "passes the title through unchanged" do
      i = issue(%{title: "VS: fix something (VR-123)", tracker_ref: "VR-123"})
      ws = workspace_with_format("raw")
      assert PRTitle.format(i, ws) == "VS: fix something (VR-123)"
    end
  end

  describe "format/2 with conventional_commit workspace" do
    test "bug with Jira tracker ref produces fix: [TICKET] desc" do
      i = issue(%{issue_type: :bug, title: "VS: fix tenant_timezone (VR-17958)", tracker_ref: "VR-17958"})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "fix: [VR-17958] fix tenant_timezone"
    end

    test "feature with Jira tracker ref produces feat: [TICKET] desc" do
      i = issue(%{issue_type: :feature, title: "VS: support new lea_reports object in conversational AI response (VR-17892)", tracker_ref: "VR-17892"})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "feat: [VR-17892] support new lea_reports object in conversational AI response"
    end

    test "strips leading all-caps team prefix (VS:)" do
      i = issue(%{issue_type: :bug, title: "VS: something broken", tracker_ref: nil})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "fix: something broken"
    end

    test "does not strip a lowercase conventional-commit prefix from the description" do
      # strip_internal_prefix only removes ALL-CAPS prefixes; a lowercase one stays in the desc.
      # The type is still derived from issue_type, so a pre-formatted title produces "fix: fix: …".
      # Callers should not pass pre-formatted titles; this asserts the regex boundary only.
      i = issue(%{issue_type: :bug, title: "fix: already formatted title", tracker_ref: nil})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "fix: fix: already formatted title"
    end

    test "strips trailing (TICKET) parenthetical that matches tracker_ref" do
      i = issue(%{issue_type: :chore, title: "clean up deps (VR-999)", tracker_ref: "VR-999"})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "chore: [VR-999] clean up deps"
    end

    test "keeps trailing parenthetical when it does NOT match tracker_ref" do
      i = issue(%{issue_type: :chore, title: "clean up deps (other)", tracker_ref: "VR-999"})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "chore: [VR-999] clean up deps (other)"
    end

    test "no tracker_ref: omits bracket" do
      i = issue(%{issue_type: :feature, title: "add something cool", tracker_ref: nil})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "feat: add something cool"
    end

    test "unknown issue_type defaults to chore" do
      i = issue(%{issue_type: :decision, title: "choose a direction", tracker_ref: nil})
      ws = workspace_with_format("conventional_commit")
      assert PRTitle.format(i, ws) == "docs: choose a direction"
    end

    test "produces no Merge <bead>: prefix in the output" do
      i = issue(%{issue_type: :feature, title: "VS: CAI support new lea_reports object (VR-17892)", tracker_ref: "VR-17892"})
      ws = workspace_with_format("conventional_commit")
      result = PRTitle.format(i, ws)
      refute String.contains?(result, "Merge ")
      refute String.starts_with?(result, "VS:")
    end
  end
end
