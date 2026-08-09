defmodule Arbiter.Loop.PendingWriteTest do
  @moduledoc """
  Stage 2 (bd-9j2g3x): the reviewable-proposal queue and its cross-window
  hypothesis accumulation. These are the correctness-critical semantics —
  fingerprint matching, reinforcement, promotion-exactly-once, and the soft
  rejection that stops a finding being re-proposed from scratch.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}

  require Ash.Query

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "loop-queue-ws", prefix: "lq"})
    %{ws: ws}
  end

  defp candidate(overrides \\ %{}) do
    Map.merge(
      %{
        kind: :skill_patch,
        gist: "teach read discipline: context exhaustion",
        category: "context exhaustion — agent burned its own context window",
        target: nil,
        difficulty: nil,
        repo: nil,
        scope: :fleet,
        target_metric: "context-exhaustion failures per week",
        baseline: "2 this window",
        incident_refs: ["run-a", "run-b"],
        task_refs: ["bd-1"],
        payload: %{},
        origin: "loop.analyze"
      },
      overrides
    )
  end

  defp escalations(ws) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
  end

  describe "fingerprint" do
    test "is deterministic over {kind, target, category, difficulty, repo}" do
      a = Loop.fingerprint(candidate())
      b = Loop.fingerprint(candidate(%{incident_refs: ["run-z"], gist: "different gist"}))

      assert a == b, "fingerprint must ignore fields outside the 5-tuple"

      refute a == Loop.fingerprint(candidate(%{category: "something else"}))
      refute a == Loop.fingerprint(candidate(%{kind: :difficulty_override}))
      refute a == Loop.fingerprint(candidate(%{target: "bd-1"}))
      refute a == Loop.fingerprint(candidate(%{difficulty: 2}))
      refute a == Loop.fingerprint(candidate(%{repo: "arbiter"}))
    end
  end

  describe "record/2 — below the evidence bar" do
    test "a fleet finding with 2 incidents lands :hypothesis and is not applicable", %{ws: ws} do
      {:ok, row} = Loop.record(candidate(%{workspace_id: ws.id}))

      assert row.state == :hypothesis
      assert row.evidence_count == 2
      assert row.distinct_tasks == 1
      assert row.scope == :fleet
      refute Loop.applicable?(row)

      assert {:error, {:not_applicable, msg}} = Loop.apply_pending(row.id)
      assert msg =~ "hypothesis"
      assert msg =~ "2"
      assert msg =~ "3"
    end

    test "no escalation is posted for a hypothesis", %{ws: ws} do
      {:ok, _row} = Loop.record(candidate(%{workspace_id: ws.id}))
      assert escalations(ws) == []
    end
  end

  describe "record/2 — cross-window reinforcement" do
    test "the same fingerprint on a later run reinforces rather than inserting", %{ws: ws} do
      {:ok, first} = Loop.record(candidate(%{workspace_id: ws.id}))

      {:ok, second} =
        Loop.record(candidate(%{workspace_id: ws.id, incident_refs: ["run-b", "run-c"]}))

      assert second.id == first.id
      assert Enum.sort(second.incident_refs) == ["run-a", "run-b", "run-c"]
      assert second.evidence_count == 3
      assert length(Ash.read!(PendingWrite)) == 1
    end

    test "re-running over the identical window is idempotent — no duplicate rows", %{ws: ws} do
      {:ok, a} = Loop.record(candidate(%{workspace_id: ws.id}))
      {:ok, b} = Loop.record(candidate(%{workspace_id: ws.id}))

      assert a.id == b.id
      assert b.evidence_count == 2
      assert length(Ash.read!(PendingWrite)) == 1
    end

    test "crossing the bar promotes to :proposed and escalates exactly once", %{ws: ws} do
      {:ok, row} = Loop.record(candidate(%{workspace_id: ws.id}))
      assert row.state == :hypothesis

      {:ok, promoted} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            incident_refs: ["run-c"],
            task_refs: ["bd-2"]
          })
        )

      assert promoted.id == row.id
      assert promoted.state == :proposed
      assert promoted.evidence_count == 3
      assert promoted.distinct_tasks == 2
      assert Loop.applicable?(promoted)
      assert [%Message{subject: subject}] = escalations(ws)
      assert subject =~ "loop proposal"

      # Reinforcing an already-proposed row must not post a second time.
      {:ok, _again} =
        Loop.record(
          candidate(%{workspace_id: ws.id, incident_refs: ["run-d"], task_refs: ["bd-3"]})
        )

      assert length(escalations(ws)) == 1
    end
  end

  describe "record/2 — escalation for a fleet-wide row with no workspace" do
    # `arb loop analyze --propose` without `--workspace` is the primary path and
    # leaves every candidate's workspace_id nil, so this is the case that
    # actually happens in the field — not the threaded-workspace one above.
    test "falls back to the installation default workspace", %{ws: ws} do
      {:ok, _hyp} = Loop.record(candidate())

      {:ok, promoted} =
        Loop.record(candidate(%{incident_refs: ["run-c"], task_refs: ["bd-2"]}))

      assert promoted.state == :proposed
      assert is_nil(promoted.workspace_id)
      assert promoted.escalated_at, "a posted escalation must stamp the row"
      assert [%Message{subject: subject}] = escalations(ws)
      assert subject =~ "loop proposal"

      # Still exactly once: the stamp guards the second window.
      {:ok, _again} = Loop.record(candidate(%{incident_refs: ["run-d"], task_refs: ["bd-3"]}))
      assert length(escalations(ws)) == 1
    end

    test "leaves escalated_at nil when no workspace can be resolved, so it retries", %{ws: ws} do
      # A second, non-"default" workspace makes the installation default
      # ambiguous, so there is nowhere to post.
      {:ok, other} = Ash.create(Workspace, %{name: "loop-queue-other", prefix: "lo"})

      {:ok, _hyp} = Loop.record(candidate())
      {:ok, promoted} = Loop.record(candidate(%{incident_refs: ["run-c"], task_refs: ["bd-2"]}))

      assert promoted.state == :proposed
      assert escalations(ws) == []
      assert escalations(other) == []

      refute promoted.escalated_at,
             "an unposted escalation must not be stamped — the row would be silently swallowed"

      # Once the ambiguity is gone, the next window posts it rather than having
      # marked it escalated forever.
      {:ok, _} = Ash.update(other, %{name: "default"}, action: :update)

      {:ok, retried} = Loop.record(candidate(%{incident_refs: ["run-d"], task_refs: ["bd-3"]}))

      assert retried.escalated_at
      assert length(escalations(other)) == 1
    end
  end

  describe "record/2 — task scope bypasses the bar" do
    test "a :task-scoped proposal lands :proposed at n=1", %{ws: ws} do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            kind: :difficulty_override,
            scope: :task,
            target: "bd-7rspia",
            incident_refs: ["run-x"],
            task_refs: ["bd-7rspia"],
            payload: %{"task_id" => "bd-7rspia", "difficulty" => 3}
          })
        )

      assert row.state == :proposed
      assert row.evidence_count == 1
      assert Loop.applicable?(row)
    end
  end

  describe "configurable evidence bar" do
    test "workspace config raises the bar", %{ws: ws} do
      {:ok, ws} =
        Ash.update(
          ws,
          %{patch: %{"loop" => %{"evidence_bar" => %{"min_incidents" => 5}}}, unset_paths: []},
          action: :patch_config
        )

      assert Loop.evidence_bar(ws) == %{min_incidents: 5, min_distinct_tasks: 2}

      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            incident_refs: ["r1", "r2", "r3"],
            task_refs: ["bd-1", "bd-2"]
          })
        )

      assert row.state == :hypothesis, "3 incidents is below a min_incidents: 5 bar"
    end

    test "defaults match the documented bar", %{ws: ws} do
      assert Loop.evidence_bar(ws) == %{min_incidents: 3, min_distinct_tasks: 2}
      assert Loop.evidence_bar(nil) == %{min_incidents: 3, min_distinct_tasks: 2}
    end
  end

  describe "context cost (Amendment D)" do
    test "a task-scoped override costs no recurring context", %{ws: ws} do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            kind: :difficulty_override,
            scope: :task,
            target: "bd-7rspia",
            payload: %{"task_id" => "bd-7rspia", "difficulty" => 3}
          })
        )

      assert row.context_cost_tokens == 0,
             "blast-radius-1 is charged once, not on every future dispatch"
    end

    test "a fleet-wide skill patch is charged its recurring per-dispatch price", %{ws: ws} do
      gist = "always read the whole failing test before editing the module under test"

      {:ok, row} = Loop.record(candidate(%{workspace_id: ws.id, gist: gist}))

      assert row.context_cost_tokens > 0,
             "a fleet-wide prompt addition is paid by every dispatch, forever"

      # Tokens, not bytes (Amendment D item 4): the estimate must be in the
      # ballpark of the gist's token count, not its byte count.
      assert row.context_cost_tokens < byte_size(gist)
    end

    test "the estimate scales with the size of the clause being added", %{ws: ws} do
      {:ok, small} = Loop.record(candidate(%{workspace_id: ws.id, gist: "short lesson"}))

      {:ok, big} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            category: "a different category",
            gist: String.duplicate("a much longer lesson body ", 12)
          })
        )

      assert big.context_cost_tokens > small.context_cost_tokens
    end
  end

  describe "apply_pending/2" do
    test "a difficulty_override applies via Issue and paper-trails the proposal id", %{ws: ws} do
      {:ok, issue} =
        Ash.create(Issue, %{title: "green but inert", difficulty: 1, workspace_id: ws.id})

      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            kind: :difficulty_override,
            scope: :task,
            target: issue.id,
            gist: "raise difficulty on #{issue.id} to 2",
            payload: %{"task_id" => issue.id, "difficulty" => 2}
          })
        )

      assert {:ok, applied} = Loop.apply_pending(row.id)
      assert applied.state == :applied
      refute is_nil(applied.applied_at)

      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.difficulty == 2

      versions =
        Arbiter.Tasks.Issue.Version
        |> Ash.Query.filter(version_source_id == ^issue.id)
        |> Ash.read!()

      # Issue has no `actor` column to snapshot, so the attribution rides on the
      # `change_origin` argument, which `store_action_inputs?` records.
      assert Enum.any?(
               versions,
               &(&1.version_action_inputs["change_origin"] == "loop:proposal:#{row.id}")
             ),
             "the apply must attribute a PaperTrail version to the proposal id"
    end

    test "refuses a hypothesis, naming its evidence count and what is still needed",
         %{ws: ws} do
      # 2 incidents across 1 task — one short on each axis of the 3/2 bar.
      {:ok, row} = Loop.record(candidate(%{workspace_id: ws.id}))
      assert row.state == :hypothesis

      assert {:error, {:not_applicable, reason}} = Loop.apply_pending(row.id)

      # The refusal has to be actionable on its own: an operator reading it must
      # learn where the row stands and what would move it, without a second call.
      assert reason =~ "hypothesis"
      assert reason =~ "2 incident(s) across 1 distinct task(s)"
      assert reason =~ "≥ 3 incidents across ≥ 2 distinct tasks"
      assert reason =~ "needs 1 more incident(s) and 1 more distinct task(s)"

      # Refusing must not consume the row.
      {:ok, still} = Loop.get_pending(row.id)
      assert still.state == :hypothesis
    end

    test "refuses an already-applied row without re-applying it", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "once only", difficulty: 1, workspace_id: ws.id})

      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            kind: :difficulty_override,
            scope: :task,
            target: issue.id,
            payload: %{"task_id" => issue.id, "difficulty" => 3}
          })
        )

      assert {:ok, applied} = Loop.apply_pending(row.id)
      assert applied.state == :applied

      assert {:error, {:not_applicable, reason}} = Loop.apply_pending(row.id)
      assert reason =~ "applied"
    end

    test "a proposal survives a restart and is still applicable", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "reload", difficulty: 1, workspace_id: ws.id})

      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            kind: :difficulty_override,
            scope: :task,
            target: issue.id,
            payload: %{"task_id" => issue.id, "difficulty" => 2}
          })
        )

      # Read it back from the database — no in-memory state involved.
      {:ok, reloaded} = Loop.get_pending(row.id)
      assert Loop.applicable?(reloaded)
      assert {:ok, _} = Loop.apply_pending(reloaded.id)
    end

    test "a skill_patch with no attributed skill fails cleanly (Stage 3 gap)", %{ws: ws} do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            scope: :task,
            incident_refs: ["r1"],
            payload: %{}
          })
        )

      assert {:error, {:unmapped, msg}} = Loop.apply_pending(row.id)
      assert msg =~ "skill"
      # The row is untouched, not consumed.
      {:ok, still} = Loop.get_pending(row.id)
      assert still.state == :proposed
    end
  end

  describe "reject_pending/2" do
    test "rejection is soft and stops re-proposal from scratch", %{ws: ws} do
      {:ok, row} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            incident_refs: ["r1", "r2", "r3"],
            task_refs: ["bd-1", "bd-2"]
          })
        )

      assert row.state == :proposed

      assert {:ok, rejected} = Loop.reject_pending(row.id, reason: "already covered by tdd skill")
      assert rejected.state == :rejected
      assert rejected.rejection_reason == "already covered by tdd skill"

      # Row persists (never deleted) and the next window reinforces it in place
      # rather than opening a fresh proposal.
      {:ok, again} = Loop.record(candidate(%{workspace_id: ws.id, incident_refs: ["r4"]}))

      assert again.id == row.id
      assert again.state == :rejected
      assert again.evidence_count == 4
      assert length(Ash.read!(PendingWrite)) == 1
    end
  end

  describe "list_pending/1" do
    test "filters by state", %{ws: ws} do
      {:ok, _h} = Loop.record(candidate(%{workspace_id: ws.id}))

      {:ok, _p} =
        Loop.record(
          candidate(%{
            workspace_id: ws.id,
            category: "missing test coverage",
            incident_refs: ["r1", "r2", "r3"],
            task_refs: ["bd-1", "bd-2"]
          })
        )

      assert length(Loop.list_pending()) == 2
      assert [only] = Loop.list_pending(state: :proposed)
      assert only.state == :proposed
      assert [_] = Loop.list_pending(state: :hypothesis, workspace_id: ws.id)
    end
  end
end
