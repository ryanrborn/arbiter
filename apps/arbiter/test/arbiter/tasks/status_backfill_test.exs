defmodule Arbiter.Tasks.StatusBackfillTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, StatusBackfill, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "sb-#{System.unique_integer([:positive])}", prefix: "sb"})

    {:ok, ws: ws}
  end

  defp new_task(ws, title) do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    task
  end

  describe "proposals/1" do
    test "proposes closure for an open task with a feat() commit", %{ws: ws} do
      task = new_task(ws, "thing")

      [proposal] =
        StatusBackfill.proposals(
          git_log_lines: ["abc1234567890|feat(#{task.id}): ship the thing"]
        )

      assert proposal.task_id == task.id
      assert proposal.current_status == :open
      assert proposal.commit_sha == "abc1234567890"
      assert proposal.commit_subject =~ "ship the thing"
    end

    test "skips tasks already :closed", %{ws: ws} do
      task = new_task(ws, "done")
      {:ok, _} = Ash.update(task, %{}, action: :close)

      assert [] =
               StatusBackfill.proposals(git_log_lines: ["abc|feat(#{task.id}): done"])
    end

    test "skips docs/fix/test commits — only feat() counts as shipped evidence",
         %{ws: ws} do
      task = new_task(ws, "x")

      lines = [
        "111|docs(#{task.id}): document the thing",
        "222|fix(#{task.id}): patch a bug",
        "333|test(#{task.id}): add a test"
      ]

      assert [] = StatusBackfill.proposals(git_log_lines: lines)
    end

    test "the most recent (first-in-log) commit is preserved when multiple feats reference the same task",
         %{ws: ws} do
      task = new_task(ws, "evolved")

      lines = [
        "newest|feat(#{task.id}): final version",
        "older|feat(#{task.id}): first cut"
      ]

      [proposal] = StatusBackfill.proposals(git_log_lines: lines)
      assert proposal.commit_sha == "newest"
    end

    test "ignores feat() commits for tasks that don't exist", %{ws: _ws} do
      assert [] =
               StatusBackfill.proposals(git_log_lines: ["abc|feat(sb-no-such-task): orphan"])
    end

    test "handles malformed log lines gracefully" do
      lines = [
        "",
        "no-pipe-separator",
        "abc|some prose with no prefix",
        "abc|feat(): empty parens",
        "abc|chore: bare chore"
      ]

      assert [] = StatusBackfill.proposals(git_log_lines: lines)
    end

    test "proposes closure for :in_progress tasks too, not just :open", %{ws: ws} do
      task = new_task(ws, "in-flight")
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      [proposal] =
        StatusBackfill.proposals(git_log_lines: ["abc|feat(#{task.id}): finished"])

      assert proposal.current_status == :in_progress
    end
  end

  describe "apply!/1" do
    test "closes each proposed task and returns the closed ids", %{ws: ws} do
      b1 = new_task(ws, "a")
      b2 = new_task(ws, "b")

      proposals =
        StatusBackfill.proposals(
          git_log_lines: [
            "111|feat(#{b1.id}): a",
            "222|feat(#{b2.id}): b"
          ]
        )

      {closed, errors} = StatusBackfill.apply!(proposals)

      assert Enum.sort(closed) == Enum.sort([b1.id, b2.id])
      assert errors == []

      {:ok, r1} = Ash.get(Issue, b1.id)
      {:ok, r2} = Ash.get(Issue, b2.id)
      assert r1.status == :closed
      assert r2.status == :closed
    end

    test "is idempotent — re-running apply! after closures is a no-op via proposals", %{ws: ws} do
      task = new_task(ws, "once")
      lines = ["abc|feat(#{task.id}): once"]

      ps = StatusBackfill.proposals(git_log_lines: lines)
      {[_], []} = StatusBackfill.apply!(ps)

      # Second pass: proposals/1 filters the now-closed task out.
      assert [] = StatusBackfill.proposals(git_log_lines: lines)
    end
  end
end
