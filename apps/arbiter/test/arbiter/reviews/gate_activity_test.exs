defmodule Arbiter.Reviews.GateActivityTest do
  @moduledoc """
  bd-bq8c8a / #1860 — "is this PR's authoring task currently inside the
  ReviewGate?", the question PRPatrol has to be able to ask before it dispatches
  a fix worker onto a branch the gate is holding.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Reviews.GateActivity
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gate-activity-#{System.unique_integer([:positive])}",
        prefix: "ga"
      })

    %{ws: ws}
  end

  defp authored_task(ws, pr_ref) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "authored-#{System.unique_integer([:positive])}",
        issue_type: :feature,
        tracker_type: :none,
        workspace_id: ws.id
      })

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    {:ok, task} = Ash.update(task, %{pr_ref: pr_ref}, action: :update)
    task
  end

  # A bare worker registration — enough for the registry-backed arms of the
  # check, without a repo, a worktree or a subprocess.
  defp bare_worker(task_id, ws, meta) do
    {:ok, pid} =
      Worker.start(task_id: task_id, repo: "owner/repo", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000) end)
    pid
  end

  describe "engaged/3" do
    test "a PR with no authoring task in the workspace is clear", %{ws: ws} do
      assert GateActivity.engaged(ws.id, 424, "owner/repo") == :clear
    end

    test "an authoring task with no gate activity is clear", %{ws: ws} do
      _task = authored_task(ws, "owner/repo#424")
      assert GateActivity.engaged(ws.id, 424, "owner/repo") == :clear
    end

    test "a task the gate parked is gated", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      {:ok, _, _} = Arbiter.Tasks.ReviewPark.park(task.id, :head_not_pushed)

      assert {:gated, :review_parked, %Issue{id: id}} =
               GateActivity.engaged(ws.id, 424, "owner/repo")

      assert id == task.id
    end

    test "a worker parked at :awaiting_review_gate is gated", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      pid = bare_worker(task.id, ws, %{branch: "feature/x"})
      :sys.replace_state(pid, &%{&1 | status: :awaiting_review_gate})

      assert {:gated, :awaiting_review_gate, %Issue{id: id}} =
               GateActivity.engaged(ws.id, 424, "owner/repo")

      assert id == task.id
    end

    test "a reviewer round running for the task is gated", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      bare_worker(task.id <> "#review", ws, %{role: :reviewer, reviews: task.id})

      assert {:gated, :round_running, %Issue{}} = GateActivity.engaged(ws.id, 424, "owner/repo")
    end

    test "an implementer (fix) round running for the task is gated", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      bare_worker(task.id <> "#review#impl1", ws, %{role: :implementer, revises: task.id})

      assert {:gated, :round_running, %Issue{}} = GateActivity.engaged(ws.id, 424, "owner/repo")
    end

    test "a same-numbered PR in a different repo does not match", %{ws: ws} do
      task = authored_task(ws, "owner/other#424")
      {:ok, _, _} = Arbiter.Tasks.ReviewPark.park(task.id, :head_not_pushed)

      assert GateActivity.engaged(ws.id, 424, "owner/repo") == :clear
    end

    test "a bare (single-repo) pr_ref matches on number alone", %{ws: ws} do
      task = authored_task(ws, "#424")
      {:ok, _, _} = Arbiter.Tasks.ReviewPark.park(task.id, :head_not_pushed)

      assert {:gated, :review_parked, %Issue{}} = GateActivity.engaged(ws.id, 424, "owner/repo")
    end

    test "a closed authoring task is never gated", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      {:ok, _, _} = Arbiter.Tasks.ReviewPark.park(task.id, :head_not_pushed)
      {:ok, _} = Ash.update(Ash.get!(Issue, task.id), %{}, action: :close)

      assert GateActivity.engaged(ws.id, 424, "owner/repo") == :clear
    end

    test "engaged?/3 mirrors engaged/3", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      refute GateActivity.engaged?(ws.id, 424, "owner/repo")
      {:ok, _, _} = Arbiter.Tasks.ReviewPark.park(task.id, :head_not_pushed)
      assert GateActivity.engaged?(ws.id, 424, "owner/repo")
    end

    test "a string PR number is accepted", %{ws: ws} do
      task = authored_task(ws, "owner/repo#424")
      {:ok, _, _} = Arbiter.Tasks.ReviewPark.park(task.id, :head_not_pushed)

      assert {:gated, :review_parked, %Issue{}} = GateActivity.engaged(ws.id, "424", "owner/repo")
    end
  end
end
