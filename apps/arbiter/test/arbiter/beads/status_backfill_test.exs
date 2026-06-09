defmodule Arbiter.Beads.StatusBackfillTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, StatusBackfill, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "sb-#{System.unique_integer([:positive])}", prefix: "sb"})

    {:ok, ws: ws}
  end

  defp new_bead(ws, title) do
    {:ok, bead} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    bead
  end

  describe "proposals/1" do
    test "proposes closure for an open bead with a feat() commit", %{ws: ws} do
      bead = new_bead(ws, "thing")

      [proposal] =
        StatusBackfill.proposals(
          git_log_lines: ["abc1234567890|feat(#{bead.id}): ship the thing"]
        )

      assert proposal.bead_id == bead.id
      assert proposal.current_status == :open
      assert proposal.commit_sha == "abc1234567890"
      assert proposal.commit_subject =~ "ship the thing"
    end

    test "skips beads already :closed", %{ws: ws} do
      bead = new_bead(ws, "done")
      {:ok, _} = Ash.update(bead, %{}, action: :close)

      assert [] =
               StatusBackfill.proposals(git_log_lines: ["abc|feat(#{bead.id}): done"])
    end

    test "skips docs/fix/test commits — only feat() counts as shipped evidence",
         %{ws: ws} do
      bead = new_bead(ws, "x")

      lines = [
        "111|docs(#{bead.id}): document the thing",
        "222|fix(#{bead.id}): patch a bug",
        "333|test(#{bead.id}): add a test"
      ]

      assert [] = StatusBackfill.proposals(git_log_lines: lines)
    end

    test "the most recent (first-in-log) commit is preserved when multiple feats reference the same bead",
         %{ws: ws} do
      bead = new_bead(ws, "evolved")

      lines = [
        "newest|feat(#{bead.id}): final version",
        "older|feat(#{bead.id}): first cut"
      ]

      [proposal] = StatusBackfill.proposals(git_log_lines: lines)
      assert proposal.commit_sha == "newest"
    end

    test "ignores feat() commits for beads that don't exist", %{ws: _ws} do
      assert [] =
               StatusBackfill.proposals(git_log_lines: ["abc|feat(sb-no-such-bead): orphan"])
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

    test "proposes closure for :in_progress beads too, not just :open", %{ws: ws} do
      bead = new_bead(ws, "in-flight")
      {:ok, _} = Ash.update(bead, %{status: :in_progress})

      [proposal] =
        StatusBackfill.proposals(git_log_lines: ["abc|feat(#{bead.id}): finished"])

      assert proposal.current_status == :in_progress
    end
  end

  describe "apply!/1" do
    test "closes each proposed bead and returns the closed ids", %{ws: ws} do
      b1 = new_bead(ws, "a")
      b2 = new_bead(ws, "b")

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
      bead = new_bead(ws, "once")
      lines = ["abc|feat(#{bead.id}): once"]

      ps = StatusBackfill.proposals(git_log_lines: lines)
      {[_], []} = StatusBackfill.apply!(ps)

      # Second pass: proposals/1 filters the now-closed bead out.
      assert [] = StatusBackfill.proposals(git_log_lines: lines)
    end
  end
end
