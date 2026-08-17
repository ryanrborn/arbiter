defmodule Arbiter.Messages.CoordinatorNotifierTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.CoordinatorNotifier
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
               CoordinatorNotifier.completed(%{
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
          title: "Wire the coordinator mailbox",
          workspace_id: workspace.id
        })

      assert :ok =
               CoordinatorNotifier.completed(%{
                 task_id: issue.id,
                 workspace_id: workspace.id,
                 started_at: started_ago(5),
                 meta: %{}
               })

      assert only_notification(workspace.id).body ==
               "Wire the coordinator mailbox completed in 5s"
    end
  end

  describe "failed/1" do
    test "includes the exit code when present" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.failed(%{
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
               CoordinatorNotifier.failed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(30),
                 meta: %{}
               })

      assert only_notification(ws).body == "#{task_id} failed after 30s"
    end

    # bd-3wgdie: a ReviewGate non-convergence is not a crash — the worker
    # completed its work and exited 0, it just lost a review argument. The
    # generic "failed ... exit code 0" wording reads as a dead worker and
    # sent a real 66h-old escalation undiscovered. Distinguish the two.
    test "reads as an escalation, not a crash, when ReviewGate did not converge" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.failed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(518),
                 meta: %{
                   exit_status: 0,
                   failure_reason: :review_gate_rejected,
                   review_gate_rounds: 2
                 }
               })

      notification = only_notification(ws)
      refute notification.body =~ "exit code"
      refute notification.subject =~ "failed"
      assert notification.subject =~ "escalated"
      assert notification.body =~ "escalated"
      assert notification.body =~ "ReviewGate did not converge"
      assert notification.body =~ "2 round"
    end

    test "reads as an escalation when ReviewGate could not produce a verdict" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.failed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(30),
                 meta: %{exit_status: 0, failure_reason: :review_gate_inconclusive}
               })

      notification = only_notification(ws)
      refute notification.body =~ "exit code"
      assert notification.subject =~ "escalated"
      assert notification.body =~ "ReviewGate"
      assert notification.body =~ "no parseable verdict" or notification.body =~ "inconclusive"
    end

    test "an unrelated crash keeps the plain failed wording even with exit code 0" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.failed(%{
                 task_id: task_id,
                 workspace_id: ws,
                 started_at: started_ago(30),
                 meta: %{exit_status: 0, failure_reason: :timeout}
               })

      assert only_notification(ws).body == "#{task_id} failed after 30s — exit code 0"
    end
  end

  describe "awaiting_review/1" do
    test "names the MR ref when present" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.awaiting_review(%{
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
               CoordinatorNotifier.awaiting_review(%{
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
               CoordinatorNotifier.awaiting_review_stuck(
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
               CoordinatorNotifier.awaiting_review_stuck(%{
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
               CoordinatorNotifier.completed(%{
                 task_id: "bd-x",
                 workspace_id: nil,
                 started_at: started_ago(1),
                 meta: %{}
               })

      assert Message.recent_notifications(10) |> Enum.filter(&(&1.from_ref == "bd-x")) == []
    end
  end

  describe "worker_stopped/2 (bd-awi4nw)" do
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
               CoordinatorNotifier.worker_stopped(
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
      assert escalation.to_ref == "coordinator"
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
               CoordinatorNotifier.worker_stopped(
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
               CoordinatorNotifier.worker_stopped(
                 %{task_id: task_id, workspace_id: ws, repo: "r", meta: %{}},
                 reason
               )

      assert only_escalation(ws).body =~ "signal 9"
    end

    test "a stop with no workspace posts nothing" do
      reason = StopReason.classify(1, ["boom"])

      assert :ok =
               CoordinatorNotifier.worker_stopped(
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
               CoordinatorNotifier.merge_blocked(
                 %{task_id: task_id, workspace_id: ws},
                 "!42",
                 :conflict
               )

      escalation = only_merge_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "coordinator"
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
               CoordinatorNotifier.merge_blocked(
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
               CoordinatorNotifier.merge_blocked(
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
               CoordinatorNotifier.merge_blocked(
                 %{task_id: "bd-noworkspace", workspace_id: nil},
                 "!1",
                 :behind_base
               )

      assert Message.inbox("admiral") |> Enum.filter(&(&1.from_ref == "bd-noworkspace")) == []
    end
  end

  describe "merge_blocked/3 dedupe + backoff (bd-brwx7w)" do
    defp merge_escalations(ws), do: Message.inbox("admiral", workspace_id: ws)

    test "a repeated block for the same reason escalates once, not once per poll" do
      ws = uniq("ws")
      task_id = uniq("bd")
      snapshot = %{task_id: task_id, workspace_id: ws}

      for _ <- 1..5 do
        assert :ok =
                 CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      end

      assert [_only_one] = merge_escalations(ws)
    end

    test "the two approval-block reasons share a dedupe key (two pollers, one page)" do
      ws = uniq("ws")
      task_id = uniq("bd")
      snapshot = %{task_id: task_id, workspace_id: ws}

      # The Watchdog's non-author path and the generic block path report the same
      # real-world condition under two different atoms; alternating between them
      # must not defeat the latch.
      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_approval)
      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_approval)

      assert [only_one] = merge_escalations(ws)
      assert only_one.body =~ "Reason: needs_approval"
    end

    test "a genuinely different block reason still escalates" do
      ws = uniq("ws")
      task_id = uniq("bd")
      snapshot = %{task_id: task_id, workspace_id: ws}

      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :ci_failed)

      assert [_approval, _ci] = merge_escalations(ws)
    end

    test "an outstanding (read-but-uncleared) escalation still dedupes" do
      ws = uniq("ws")
      task_id = uniq("bd")
      snapshot = %{task_id: task_id, workspace_id: ws}

      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      assert [msg] = merge_escalations(ws)
      Message.mark_read(msg.id)

      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)

      assert [_still_one] = Message.outstanding("admiral", workspace_id: ws)
      assert merge_escalations(ws) == []
    end

    test "a different task with the same reason is not suppressed" do
      ws = uniq("ws")

      assert :ok =
               CoordinatorNotifier.merge_blocked(
                 %{task_id: uniq("bd"), workspace_id: ws},
                 "#1",
                 :needs_nonauthor_approval
               )

      assert :ok =
               CoordinatorNotifier.merge_blocked(
                 %{task_id: uniq("bd"), workspace_id: ws},
                 "#2",
                 :needs_nonauthor_approval
               )

      assert [_a, _b] = merge_escalations(ws)
    end

    test "a cleared *resolvable* block re-escalates immediately when it comes back" do
      # The cooldown exists to damp a block the fleet cannot resolve. A CI
      # failure that was addressed and then reappears is genuine new news, and
      # must not be swallowed by it.
      ws = uniq("ws")
      task_id = uniq("bd")
      snapshot = %{task_id: task_id, workspace_id: ws}

      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :ci_failed)
      assert [msg] = merge_escalations(ws)
      Message.mark_cleared(msg.id)

      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :ci_failed)
      assert [_fresh] = merge_escalations(ws)
    end

    test "once cleared, the block re-escalates only after the cooldown elapses" do
      ws = uniq("ws")
      task_id = uniq("bd")
      snapshot = %{task_id: task_id, workspace_id: ws}

      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      assert [msg] = merge_escalations(ws)
      Message.mark_cleared(msg.id)

      # Cleared but still inside the cooldown window: silence.
      assert :ok = CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      assert merge_escalations(ws) == []

      with_cooldown(0, fn ->
        assert :ok =
                 CoordinatorNotifier.merge_blocked(snapshot, "#1226", :needs_nonauthor_approval)
      end)

      assert [_fresh] = merge_escalations(ws)
    end

    defp with_cooldown(ms, fun) do
      prev = Application.get_env(:arbiter, :merge_block_escalation_cooldown_ms)
      Application.put_env(:arbiter, :merge_block_escalation_cooldown_ms, ms)

      try do
        fun.()
      after
        case prev do
          nil -> Application.delete_env(:arbiter, :merge_block_escalation_cooldown_ms)
          val -> Application.put_env(:arbiter, :merge_block_escalation_cooldown_ms, val)
        end
      end
    end
  end

  describe "merge_blocked/3 remediation respects merge.auto_merge (bd-brwx7w)" do
    defp workspace_with(config) do
      {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: uniq("ws"), config: config})
      ws
    end

    test "auto_merge on promises the auto-merge" do
      ws = workspace_with(%{"merge" => %{"auto_merge" => true}})

      assert :ok =
               CoordinatorNotifier.merge_blocked(
                 %{task_id: uniq("bd"), workspace_id: ws.id},
                 "#1226",
                 :needs_nonauthor_approval
               )

      assert [msg] = Message.inbox("admiral", workspace_id: ws.id)
      assert msg.body =~ "will auto-merge once approved"
    end

    test "auto_merge off says the fleet will not merge it and a human must" do
      ws = workspace_with(%{"merge" => %{"auto_merge" => false}})

      assert :ok =
               CoordinatorNotifier.merge_blocked(
                 %{task_id: uniq("bd"), workspace_id: ws.id},
                 "#1226",
                 :needs_nonauthor_approval
               )

      assert [msg] = Message.inbox("admiral", workspace_id: ws.id)
      refute msg.body =~ "will auto-merge once approved"
      assert msg.body =~ "`merge.auto_merge` disabled"
      assert msg.body =~ "will not merge it automatically"
    end
  end

  describe "merge_block_unresolved/4 (#354 Phase 2a)" do
    test "names the reason, attempt count, and remediation after auto-resolve fails" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.merge_block_unresolved(
                 %{task_id: task_id, workspace_id: ws},
                 "!88",
                 :ci_failed,
                 2
               )

      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "coordinator"
      assert escalation.directive_ref == task_id
      assert escalation.subject =~ "auto-resolve exhausted (2×)"
      assert escalation.body =~ "after 2 auto-resolve attempt"
      assert escalation.body =~ "Reason: ci_failed"
      assert escalation.body =~ "Auto-resolve attempts: 2"
      assert escalation.body =~ "fix the failing checks"
    end

    test "an unresolved block with no workspace posts nothing" do
      assert :ok =
               CoordinatorNotifier.merge_block_unresolved(
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
               CoordinatorNotifier.approved_awaiting_merge(
                 %{task_id: task_id, workspace_id: ws},
                 "!314",
                 false
               )

      escalation = only_await_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "coordinator"
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
               CoordinatorNotifier.approved_awaiting_merge(
                 %{task_id: task_id, workspace_id: ws},
                 "!42",
                 true
               )

      assert only_await_escalation(ws).body =~ "ReviewGate"
    end

    test "an approved-awaiting-merge with no workspace posts nothing" do
      assert :ok =
               CoordinatorNotifier.approved_awaiting_merge(
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
               CoordinatorNotifier.tracker_sync_failed(
                 %{task_id: task_id, workspace_id: ws, tracker_type: :jira, tracker_ref: "VR-1"},
                 :code_review,
                 reason
               )

      escalation = only_tracker_escalation(ws)
      assert escalation.kind == :escalation
      assert escalation.to_ref == "coordinator"
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
               CoordinatorNotifier.tracker_sync_failed(
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
               CoordinatorNotifier.tracker_sync_failed(
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
               CoordinatorNotifier.tracker_sync_failed(
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
               CoordinatorNotifier.preflight_failed(
                 %{task_id: task_id, workspace_id: ws, repo: "r", meta: %{}},
                 reason
               )

      assert [escalation] = Message.inbox("admiral", workspace_id: ws)
      assert escalation.subject =~ "pre-flight auth failed"
      assert escalation.body =~ "Refused to dispatch"
    end
  end
end
