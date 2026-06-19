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

  describe "awaiting_review_stuck/2 (bd-66ey1o)" do
    test "names the MR ref passed explicitly even when meta has none" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review_stuck(
                 %{bead_id: bead_id, workspace_id: ws, started_at: started_ago(900), meta: %{}},
                 "#76"
               )

      notification = only_notification(ws)
      assert notification.subject == "#{bead_id} stuck awaiting review"

      assert notification.body ==
               "#{bead_id} stuck at awaiting_review (MR #76) — escalated (no terminal MR outcome)"
    end

    test "falls back to the meta mr_ref when no override is passed" do
      ws = uniq("ws")
      bead_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review_stuck(%{
                 bead_id: bead_id,
                 workspace_id: ws,
                 started_at: started_ago(60),
                 meta: %{mr_ref: "!42"}
               })

      assert only_notification(ws).body ==
               "#{bead_id} stuck at awaiting_review (MR !42) — escalated (no terminal MR outcome)"
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

  describe "acolyte_stopped/2 (bd-awi4nw)" do
    alias Arbiter.Polecat.StopReason

    defp only_escalation(ws) do
      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      escalation
    end

    test "raises an addressed escalation naming the bead + cause + remediation" do
      ws = uniq("ws")
      bead_id = uniq("bd")
      reason = StopReason.classify(1, ["401 invalid authentication credentials"])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{
                   bead_id: bead_id,
                   workspace_id: ws,
                   rig: "team/repo",
                   meta: %{activity: %{label: "editing run.ex"}}
                 },
                 reason
               )

      escalation = only_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == bead_id
      assert escalation.subject =~ bead_id
      assert escalation.subject =~ "credentials expired"
      assert escalation.body =~ "Rig: team/repo"
      assert escalation.body =~ "Last activity: editing run.ex"
      assert escalation.body =~ "Exit code: 1"
      assert escalation.body =~ "Re-authenticate"
    end

    test "offers `arb resume` to continue from the preserved worktree (bd-auma3z)" do
      ws = uniq("ws")
      bead_id = uniq("bd")
      reason = StopReason.classify(1, ["boom"])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{bead_id: bead_id, workspace_id: ws, rig: "r", meta: %{}},
                 reason
               )

      assert only_escalation(ws).body =~ "arb worker resume #{bead_id}"
    end

    test "names the kill signal when present" do
      ws = uniq("ws")
      bead_id = uniq("bd")
      reason = StopReason.classify(137, [])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{bead_id: bead_id, workspace_id: ws, rig: "r", meta: %{}},
                 reason
               )

      assert only_escalation(ws).body =~ "signal 9"
    end

    test "a stop with no workspace posts nothing" do
      reason = StopReason.classify(1, ["boom"])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{bead_id: "bd-noworkspace", workspace_id: nil, rig: "r", meta: %{}},
                 reason
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "preflight_failed/2 (bd-awi4nw)" do
    alias Arbiter.Polecat.StopReason

    test "raises a 'refused to dispatch' escalation" do
      ws = uniq("ws")
      bead_id = uniq("bd")
      reason = StopReason.classify(1, ["401 invalid authentication credentials"])

      assert :ok =
               AdmiralNotifier.preflight_failed(
                 %{bead_id: bead_id, workspace_id: ws, rig: "r", meta: %{}},
                 reason
               )

      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      assert escalation.subject =~ "pre-flight auth failed"
      assert escalation.body =~ "Refused to dispatch"
    end
  end
end
