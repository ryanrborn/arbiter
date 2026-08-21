defmodule Arbiter.Workflows.MergeQueue.AutoResumeDispatcherTest do
  # DataCase: escalate_exhausted/4 writes a real :escalation mailbox message.
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue.AutoResumeDispatcher

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "auto-resume-ws", prefix: "ar"})
    {:ok, ws: ws}
  end

  defp escalations(ws) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
  end

  describe "escalate_exhausted/5" do
    test "pages the coordinator with the spent attempt count", %{ws: ws} do
      assert :ok =
               AutoResumeDispatcher.escalate_exhausted(
                 "bd-abc123",
                 ws.id,
                 "!274",
                 3,
                 :budget_exhausted
               )

      assert [msg] = escalations(ws)
      assert msg.kind == :escalation
      assert msg.to_ref == Message.coordinator_ref()
      assert msg.from_ref == "bd-abc123"
      assert msg.task_ref == "bd-abc123"

      # Acceptance criterion: the page must SAY the budget is spent, so a
      # coordinator can tell it from a fresh failure without a worker_show.
      assert msg.subject =~ "auto-resume exhausted after 3 attempts"
      assert msg.subject =~ "bd-abc123"
      assert msg.body =~ "auto-resume is exhausted after 3 attempt(s)"
      assert msg.body =~ "NOT a fresh failure"
      assert msg.body =~ "!274"
    end

    test "says auto-resume never ran when the budget is configured to 0", %{ws: ws} do
      assert :ok =
               AutoResumeDispatcher.escalate_exhausted(
                 "bd-zero",
                 ws.id,
                 "!1",
                 0,
                 :budget_exhausted
               )

      assert [msg] = escalations(ws)
      assert msg.subject =~ "auto-resume exhausted after 0 attempts"
      assert msg.body =~ "auto-resume budget is 0"
      refute msg.body =~ "NOT a fresh failure"
    end

    test "a resume that could not run reads differently from a spent budget", %{ws: ws} do
      assert :ok =
               AutoResumeDispatcher.escalate_exhausted(
                 "bd-gone",
                 ws.id,
                 "!9",
                 0,
                 {:resume_failed, :no_outpost}
               )

      assert [msg] = escalations(ws)
      assert msg.subject =~ "auto-resume FAILED after 0 attempts"
      refute msg.subject =~ "exhausted"
      assert msg.body =~ ":no_outpost"
      assert msg.body =~ "a fresh dispatch is needed rather than a resume"
    end

    test "reports (rather than swallows) a missing workspace_id" do
      assert {:error, :no_workspace_id} =
               AutoResumeDispatcher.escalate_exhausted("bd-nows", nil, "!1", 3, :budget_exhausted)
    end

    test "tolerates a nil mr_ref", %{ws: ws} do
      assert :ok =
               AutoResumeDispatcher.escalate_exhausted(
                 "bd-nomr",
                 ws.id,
                 nil,
                 2,
                 :budget_exhausted
               )

      assert [msg] = escalations(ws)
      assert msg.body =~ "(unknown)"
    end
  end

  describe "resume/1" do
    test "surfaces a dispatch failure as {:error, _} rather than raising" do
      # No such task -> Dispatch.resume returns an error tuple. The Watchdog
      # relies on that to fall back to escalating instead of assuming the task
      # is healing.
      assert {:error, _} =
               AutoResumeDispatcher.resume(%{task_id: "bd-does-not-exist", attempt: 1})
    end
  end
end
