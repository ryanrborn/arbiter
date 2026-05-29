defmodule Arbiter.Messages.AdmiralNotifierTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.AdmiralNotifier
  alias Arbiter.Messages.Message

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp started_ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp only_notification(ws) do
    assert [notification] = Message.recent_notifications(10, workspace_id: ws)
    notification
  end

  describe "completed/1" do
    test "formats a multi-minute duration and falls back to the bead id as title" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.completed(%{
                 bead_id: bead_id,
                 workspace_id: ws,
                 started_at: started_ago(125),
                 meta: %{}
               })

      notification = only_notification(ws)
      assert notification.from_ref == bead_id
      assert notification.subject == "#{bead_id} completed"
      assert notification.body == "#{bead_id} completed in 2m 5s"
    end

    test "uses the directive title when the Issue row exists" do
      {:ok, workspace} = Ash.create(Arbiter.Beads.Workspace, %{name: uniq("ws")})

      {:ok, issue} =
        Ash.create(Arbiter.Beads.Issue, %{
          title: "Wire the admiral mailbox",
          workspace_id: workspace.id
        })

      assert :ok =
               AdmiralNotifier.completed(%{
                 bead_id: issue.id,
                 workspace_id: workspace.id,
                 started_at: started_ago(5),
                 meta: %{}
               })

      assert only_notification(workspace.id).body ==
               "Wire the admiral mailbox completed in 5s"
    end
  end

  describe "failed/1" do
    test "includes the exit code when present" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.failed(%{
                 bead_id: bead_id,
                 workspace_id: ws,
                 started_at: started_ago(3661),
                 meta: %{exit_status: 1}
               })

      notification = only_notification(ws)
      assert notification.subject == "#{bead_id} failed"
      assert notification.body == "#{bead_id} failed after 1h 1m — exit code 1"
    end

    test "omits the exit code when unknown" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.failed(%{
                 bead_id: bead_id,
                 workspace_id: ws,
                 started_at: started_ago(30),
                 meta: %{}
               })

      assert only_notification(ws).body == "#{bead_id} failed after 30s"
    end
  end

  describe "awaiting_review/1" do
    test "names the MR ref when present" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review(%{
                 bead_id: bead_id,
                 workspace_id: ws,
                 started_at: started_ago(10),
                 meta: %{mr_ref: "!7"}
               })

      assert only_notification(ws).body == "#{bead_id} opened MR !7 — awaiting review"
    end

    test "falls back gracefully when no MR ref is recorded" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review(%{
                 bead_id: bead_id,
                 workspace_id: ws,
                 started_at: started_ago(10),
                 meta: %{}
               })

      assert only_notification(ws).body == "#{bead_id} — awaiting review"
    end
  end

  describe "guards" do
    test "a polecat with no workspace posts nothing" do
      assert :ok =
               AdmiralNotifier.completed(%{
                 bead_id: "bd-x",
                 workspace_id: nil,
                 started_at: started_ago(1),
                 meta: %{}
               })

      assert Message.recent_notifications(10) |> Enum.filter(&(&1.from_ref == "bd-x")) == []
    end
  end
end
