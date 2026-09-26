defmodule Arbiter.Workflows.ReviewGateFixRoundDispatcherTest do
  @moduledoc """
  bd-6d3h8m: the fix-rounds-exhausted escalation names the total review
  rounds across every pass, not just the fix-round count.

  On bd-28t80i "1 round" (the fix-round counter) was 6 Opus reviews and 4
  Sonnet implementer passes across 2 passes — a coordinator reading the
  escalation alone had no way to see that.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workflows.ReviewGateFixRoundDispatcher

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "dispatcher-msg-ws-#{System.unique_integer([:positive])}"})

    {:ok, task} =
      Ash.create(Issue, %{title: "exhausted task", workspace_id: ws.id, issue_type: :feature})

    %{ws: ws, task: task}
  end

  defp create_review_round!(task_id, fix_round_attempt, round) do
    {:ok, _} =
      Ash.create(Round, %{
        task_id: task_id,
        round: round,
        fix_round_attempt: fix_round_attempt,
        role: :review,
        verdict: :request_changes,
        findings: "VERDICT: REQUEST_CHANGES",
        converged: false
      })
  end

  defp escalation_for(task_id, ws_id) do
    Message.inbox("admiral", workspace_id: ws_id)
    |> Enum.find(&(&1.task_ref == task_id))
  end

  describe "escalate_exhausted/4 with :budget_exhausted" do
    test "states the total review rounds across both passes, not just the fix-round count",
         %{ws: ws, task: task} do
      # Pass 1 (the original gate): 3 review rounds. Pass 2 (the one automatic
      # fix round): 3 more. 1 fix round ran; 6 reviews total.
      for round <- 1..3, do: create_review_round!(task.id, 0, round)
      for round <- 1..3, do: create_review_round!(task.id, 1, round)

      assert :ok =
               ReviewGateFixRoundDispatcher.escalate_exhausted(
                 task.id,
                 ws.id,
                 1,
                 :budget_exhausted
               )

      msg = escalation_for(task.id, ws.id)
      refute is_nil(msg)

      # The fix-round count alone (bd-a9zb7w's original wording).
      assert msg.subject =~ "exhausted after 1 round(s)"
      # bd-6d3h8m: the total review count and pass count are now also named.
      assert msg.subject =~ "6 reviews"
      assert msg.subject =~ "2 pass"
      assert msg.body =~ "6 reviews"
      assert msg.body =~ "2 review pass"
    end

    test "still sends a sensible message when no Round rows exist (query returns 0, not a crash)",
         %{ws: ws, task: task} do
      assert :ok =
               ReviewGateFixRoundDispatcher.escalate_exhausted(
                 task.id,
                 ws.id,
                 0,
                 :budget_exhausted
               )

      msg = escalation_for(task.id, ws.id)
      refute is_nil(msg)
      assert msg.subject =~ "0 reviews"
    end
  end

  describe "escalate_exhausted/4 with other reasons" do
    test ":not_converging does not claim a review count it wasn't asked to explain",
         %{ws: ws, task: task} do
      assert :ok =
               ReviewGateFixRoundDispatcher.escalate_exhausted(task.id, ws.id, 1, :not_converging)

      msg = escalation_for(task.id, ws.id)
      refute is_nil(msg)
      assert msg.subject =~ "not converging"
      refute msg.subject =~ "reviews"
    end
  end
end
