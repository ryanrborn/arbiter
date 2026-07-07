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
    test "formats a multi-minute duration and falls back to the task id as title" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.completed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(125),
                 meta: %{}
               })

      notification = only_notification(ws)
      assert notification.from_ref == task_id
      assert notification.subject == "#{task_id} completed"
      assert notification.body == "#{task_id} completed in 2m 5s"
    end

    test "uses the directive title when the Issue row exists" do
      {:ok, workspace} = Ash.create(Arbiter.Tasks.Workspace, %{name: uniq("ws")})

      {:ok, issue} =
        Ash.create(Arbiter.Tasks.Issue, %{
          title: "Wire the admiral mailbox",
          workspace_id: workspace.id
        })

      assert :ok =
               AdmiralNotifier.completed(%{
                 task_id: issue.id,
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
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.failed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(3661),
                 meta: %{exit_status: 1}
               })

      notification = only_notification(ws)
      assert notification.subject == "#{task_id} failed"
      assert notification.body == "#{task_id} failed after 1h 1m — exit code 1"
    end

    test "omits the exit code when unknown" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.failed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(30),
                 meta: %{}
               })

      assert only_notification(ws).body == "#{task_id} failed after 30s"
    end
  end

  describe "awaiting_review/1" do
    test "names the MR ref when present" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(10),
                 meta: %{mr_ref: "!7"}
               })

      assert only_notification(ws).body == "#{task_id} opened MR !7 — awaiting review"
    end

    test "falls back gracefully when no MR ref is recorded" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(10),
                 meta: %{}
               })

      assert only_notification(ws).body == "#{task_id} — awaiting review"
    end
  end

  describe "awaiting_review_stuck/2 (bd-66ey1o)" do
    test "names the MR ref passed explicitly even when meta has none" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review_stuck(
                 %{task_id: task_id, workspace_id: ws, started_at: started_ago(900), meta: %{}},
                 "#76"
               )

      notification = only_notification(ws)
      assert notification.subject == "#{task_id} stuck awaiting review"

      assert notification.body ==
               "#{task_id} stuck at awaiting_review (MR #76) — escalated (no terminal MR outcome)"
    end

    test "falls back to the meta mr_ref when no override is passed" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.awaiting_review_stuck(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(60),
                 meta: %{mr_ref: "!42"}
               })

      assert only_notification(ws).body ==
               "#{task_id} stuck at awaiting_review (MR !42) — escalated (no terminal MR outcome)"
    end
  end

  describe "guards" do
    test "a worker with no workspace posts nothing" do
      assert :ok =
               AdmiralNotifier.completed(%{
                 task_id: "bd-x",
                 workspace_id: nil,
                 started_at: started_ago(1),
                 meta: %{}
               })

      assert Message.recent_notifications(10) |> Enum.filter(&(&1.from_ref == "bd-x")) == []
    end
  end

  describe "acolyte_stopped/2 (bd-awi4nw)" do
    alias Arbiter.Worker.StopReason

    defp only_escalation(ws) do
      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      escalation
    end

    test "raises an addressed escalation naming the task + cause + remediation" do
      ws = uniq("ws")
      task_id = uniq("bd")
      reason = StopReason.classify(1, ["401 invalid authentication credentials"])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{
                   task_id: task_id,
                   workspace_id: ws,
                   repo: "team/repo",
                   meta: %{activity: %{label: "editing run.ex"}}
                 },
                 reason
               )

      escalation = only_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == task_id
      assert escalation.subject =~ task_id
      assert escalation.subject =~ "credentials expired"
      assert escalation.body =~ "Repo: team/repo"
      assert escalation.body =~ "Last activity: editing run.ex"
      assert escalation.body =~ "Exit code: 1"
      assert escalation.body =~ "Re-authenticate"
    end

    test "offers `arb resume` to continue from the preserved worktree (bd-auma3z)" do
      ws = uniq("ws")
      task_id = uniq("bd")
      reason = StopReason.classify(1, ["boom"])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{task_id: task_id, workspace_id: ws, repo: "r", meta: %{}},
                 reason
               )

      assert only_escalation(ws).body =~ "arb worker resume #{task_id}"
    end

    test "names the kill signal when present" do
      ws = uniq("ws")
      task_id = uniq("bd")
      reason = StopReason.classify(137, [])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{task_id: task_id, workspace_id: ws, repo: "r", meta: %{}},
                 reason
               )

      assert only_escalation(ws).body =~ "signal 9"
    end

    test "a stop with no workspace posts nothing" do
      reason = StopReason.classify(1, ["boom"])

      assert :ok =
               AdmiralNotifier.acolyte_stopped(
                 %{task_id: "bd-noworkspace", workspace_id: nil, repo: "r", meta: %{}},
                 reason
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "merge_blocked/3 (#354)" do
    defp only_merge_escalation(ws) do
      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      escalation
    end

    test "raises an addressed escalation naming the task, reason, and remediation" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.merge_blocked(
                 %{task_id: task_id, workspace_id: ws},
                 "!42",
                 :conflict
               )

      escalation = only_merge_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == task_id
      assert escalation.subject =~ task_id
      assert escalation.subject =~ "merge blocked"
      assert escalation.body =~ "PR/MR: !42"
      assert escalation.body =~ "Reason: conflict"
      assert escalation.body =~ "rebase"
    end

    test "each reason gets its own label + remediation" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.merge_blocked(
                 %{task_id: task_id, workspace_id: ws},
                 "#7",
                 :ci_failed
               )

      body = only_merge_escalation(ws).body
      assert body =~ "CI checks are failing"
      assert body =~ "fix the failing checks"
    end

    test "a non-author-approval block names the human-reviewer remediation (bd-c3lchp)" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.merge_blocked(
                 %{task_id: task_id, workspace_id: ws},
                 "#3609",
                 :needs_nonauthor_approval
               )

      body = only_merge_escalation(ws).body
      assert body =~ "reviewer other than the author"
      assert body =~ "human reviewer"
      assert body =~ "parked"
    end

    test "a block with no workspace posts nothing" do
      assert :ok =
               AdmiralNotifier.merge_blocked(
                 %{task_id: "bd-noworkspace", workspace_id: nil},
                 "!1",
                 :behind_base
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "merge_block_unresolved/4 (#354 Phase 2a)" do
    test "names the reason, attempt count, and remediation after auto-resolve fails" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.merge_block_unresolved(
                 %{task_id: task_id, workspace_id: ws},
                 "!88",
                 :ci_failed,
                 2
               )

      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == task_id
      assert escalation.subject =~ "auto-resolve exhausted (2×)"
      assert escalation.body =~ "after 2 auto-resolve attempt"
      assert escalation.body =~ "Reason: ci_failed"
      assert escalation.body =~ "Auto-resolve attempts: 2"
      assert escalation.body =~ "fix the failing checks"
    end

    test "an unresolved block with no workspace posts nothing" do
      assert :ok =
               AdmiralNotifier.merge_block_unresolved(
                 %{task_id: "bd-noworkspace", workspace_id: nil},
                 "!1",
                 :behind_base,
                 2
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "approved_awaiting_merge/3 (bd-b4pwxa)" do
    defp only_await_escalation(ws) do
      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      escalation
    end

    test "raises an addressed escalation that the approved PR awaits a manual merge" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.approved_awaiting_merge(
                 %{task_id: task_id, workspace_id: ws},
                 "!314",
                 false
               )

      escalation = only_await_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == task_id
      assert escalation.from_ref == task_id
      assert escalation.subject =~ task_id
      assert escalation.subject =~ "awaiting manual merge"
      assert escalation.body =~ "PR/MR: !314"
      assert escalation.body =~ "auto_merge"
      # Actionable: it tells the coordinator to merge or flip the policy.
      assert escalation.body =~ "merge"
    end

    test "names the ReviewGate as the approval source when via_review_gate is true" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               AdmiralNotifier.approved_awaiting_merge(
                 %{task_id: task_id, workspace_id: ws},
                 "!42",
                 true
               )

      assert only_await_escalation(ws).body =~ "ReviewGate"
    end

    test "an approved-awaiting-merge with no workspace posts nothing" do
      assert :ok =
               AdmiralNotifier.approved_awaiting_merge(
                 %{task_id: "bd-noworkspace", workspace_id: nil},
                 "!1",
                 false
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "tracker_sync_failed/3 (bd-1dun7v)" do
    defp only_tracker_escalation(ws) do
      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      escalation
    end

    test "raises an addressed escalation on a validation_failed error" do
      ws = uniq("ws")
      task_id = uniq("bd")

      reason = %Arbiter.Trackers.Jira.Error{
        kind: :validation_failed,
        status: 400,
        message:
          "QA Testing Notes and Deployment Notes must be filled out prior to transitioning to Code Review",
        raw: nil
      }

      assert :ok =
               AdmiralNotifier.tracker_sync_failed(
                 %{task_id: task_id, workspace_id: ws, tracker_type: :jira, tracker_ref: "VR-1"},
                 :code_review,
                 reason
               )

      escalation = only_tracker_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "admiral"
      assert escalation.directive_ref == task_id
      assert escalation.subject =~ "tracker sync failed"
      # The provider's real error must be front-and-center
      assert escalation.body =~
               "QA Testing Notes and Deployment Notes must be filled out prior to transitioning to Code Review"

      # The misleading config-mismatch hint must NOT appear
      refute escalation.body =~ "status_map"
      refute escalation.body =~ "transition_graph"
    end

    test "includes a path-finding hint for no_transition_path (config mismatch)" do
      ws = uniq("ws")
      task_id = uniq("bd")

      reason = %Arbiter.Trackers.Jira.Error{
        kind: :no_transition_path,
        status: nil,
        message: "no transition path to \"Code Review\" in the configured workflow graph",
        raw: nil
      }

      assert :ok =
               AdmiralNotifier.tracker_sync_failed(
                 %{task_id: task_id, workspace_id: ws, tracker_type: :jira, tracker_ref: "VR-2"},
                 :code_review,
                 reason
               )

      body = only_tracker_escalation(ws).body
      # Provider error surfaced
      assert body =~ "no transition path"
      # Config hint is appropriate here
      assert body =~ "transition_graph"
    end

    test "surfaces credentials hint for unauthenticated errors" do
      ws = uniq("ws")
      task_id = uniq("bd")

      reason = %Arbiter.Trackers.Jira.Error{
        kind: :unauthenticated,
        status: 401,
        message: "HTTP 401",
        raw: nil
      }

      assert :ok =
               AdmiralNotifier.tracker_sync_failed(
                 %{task_id: task_id, workspace_id: ws, tracker_type: :jira, tracker_ref: "VR-3"},
                 :in_progress,
                 reason
               )

      body = only_tracker_escalation(ws).body
      assert body =~ "credentials"
      refute body =~ "status_map"
    end

    test "a sync failure with no workspace posts nothing" do
      reason = %Arbiter.Trackers.Jira.Error{
        kind: :validation_failed,
        status: 400,
        message: "some error",
        raw: nil
      }

      assert :ok =
               AdmiralNotifier.tracker_sync_failed(
                 %{task_id: "bd-noworkspace", workspace_id: nil},
                 :in_progress,
                 reason
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "preflight_failed/2 (bd-awi4nw)" do
    alias Arbiter.Worker.StopReason

    test "raises a 'refused to dispatch' escalation" do
      ws = uniq("ws")
      task_id = uniq("bd")
      reason = StopReason.classify(1, ["401 invalid authentication credentials"])

      assert :ok =
               AdmiralNotifier.preflight_failed(
                 %{task_id: task_id, workspace_id: ws, repo: "r", meta: %{}},
                 reason
               )

      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      assert escalation.subject =~ "pre-flight auth failed"
      assert escalation.body =~ "Refused to dispatch"
    end
  end
end
