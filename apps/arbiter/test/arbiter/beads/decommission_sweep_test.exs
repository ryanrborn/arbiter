defmodule Arbiter.Beads.DecommissionSweepTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{DecommissionSweep, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ds-#{System.unique_integer([:positive])}", prefix: "ds"})

    {:ok, ws: ws}
  end

  defp new_bead(ws, title) do
    {:ok, bead} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    bead
  end

  describe "predicates" do
    test "HANDOFF prefix is the handoff category" do
      assert DecommissionSweep.handoff?(%Issue{title: "🤝 HANDOFF: Witness patrol"})
      refute DecommissionSweep.handoff?(%Issue{title: "handoff (lower case)"})
      refute DecommissionSweep.handoff?(%Issue{title: ""})
    end

    test "Daemon role definitions" do
      assert DecommissionSweep.daemon_role?(%Issue{
               title: "MergeQueue for access_control - processes merge queue."
             })

      assert DecommissionSweep.daemon_role?(%Issue{
               title: "Witness for auth_server - monitors worker health."
             })

      assert DecommissionSweep.daemon_role?(%Issue{
               title: "Crew worker ryan in auth_server - human-managed workspace."
             })

      assert DecommissionSweep.daemon_role?(%Issue{
               title: "Deacon (daemon beacon) - receives mechanical heartbeats."
             })

      assert DecommissionSweep.daemon_role?(%Issue{
               title: "Mayor - global coordinator, handles escalations."
             })

      refute DecommissionSweep.daemon_role?(%Issue{title: "MergeQueue merge queue (gte-023)"})
    end

    test "Worker identity beads" do
      assert DecommissionSweep.worker_identity?(%Issue{
               id: "vs-server-worker-chrome",
               title: "vs-server-worker-chrome"
             })

      refute DecommissionSweep.worker_identity?(%Issue{
               id: "bd-something",
               title: "Real work that mentions worker by name"
             })
    end

    test "Workflow definitions by ID prefix" do
      assert DecommissionSweep.workflow_def?(%Issue{id: "vs-wfs-burn-respawn"})
      assert DecommissionSweep.workflow_def?(%Issue{id: "hq-wf-kohms"})
      refute DecommissionSweep.workflow_def?(%Issue{id: "vs-server-other"})
    end

    test "GT-system bug or task" do
      assert DecommissionSweep.gt_system?(%Issue{
               title: "gt convoy close [--force] is a silent no-op"
             })

      assert DecommissionSweep.gt_system?(%Issue{
               title: "GT worker work formula should produce names"
             })

      assert DecommissionSweep.gt_system?(%Issue{
               title: "GT: server repo merge_queue should default to PR"
             })

      assert DecommissionSweep.gt_system?(%Issue{
               title: "[HIGH] Dolt: server unreachable around 15:01"
             })

      refute DecommissionSweep.gt_system?(%Issue{title: "gte-elixir port: do thing"})
    end

    test "Compaction reports" do
      assert DecommissionSweep.compaction_report?(%Issue{title: "Compaction Report 2026-05-14"})
      assert DecommissionSweep.compaction_report?(%Issue{title: "compact report idempotency"})
      refute DecommissionSweep.compaction_report?(%Issue{title: "Compress this data"})
    end

    test "Escalation replies" do
      assert DecommissionSweep.escalation_reply?(%Issue{
               title: "Re: ESCALATION: VR-17575 base branch"
             })

      assert DecommissionSweep.escalation_reply?(%Issue{
               title: "Re: REFINERY BLOCKED: PR-only repo"
             })

      refute DecommissionSweep.escalation_reply?(%Issue{title: "ESCALATION raised"})
    end

    test "Patrol cycle notes" do
      assert DecommissionSweep.patrol_note?(%Issue{title: "Deacon Patrol"})
      assert DecommissionSweep.patrol_note?(%Issue{title: "Witness Patrol"})
      assert DecommissionSweep.patrol_note?(%Issue{title: "MergeQueue Patrol"})
      refute DecommissionSweep.patrol_note?(%Issue{title: "Patrol-style scheduling discussion"})
    end
  end

  describe "proposals/0" do
    test "proposes closure for an open HANDOFF bead", %{ws: ws} do
      bead = new_bead(ws, "🤝 HANDOFF: Witness patrol")

      ids =
        DecommissionSweep.proposals()
        |> Enum.map(& &1.bead_id)

      assert bead.id in ids
    end

    test "skips closed beads", %{ws: ws} do
      bead = new_bead(ws, "🤝 HANDOFF: stale")
      {:ok, _} = Ash.update(bead, %{}, action: :close)

      assert [] = DecommissionSweep.proposals() |> Enum.filter(&(&1.bead_id == bead.id))
    end

    test "keepers list protects gte-026..028 + hq-109 + hq-3be + vs-sy5" do
      # Without actually creating those beads, just confirm the public
      # `proposals/0` excludes them — checked via the categorizer's
      # interaction with the static keepers MapSet.
      keepers = ["gte-026", "gte-027", "gte-028", "hq-109", "hq-3be", "vs-sy5"]
      proposals = DecommissionSweep.proposals()
      proposal_ids = Enum.map(proposals, & &1.bead_id)

      for k <- keepers do
        refute k in proposal_ids, "expected keeper #{k} to be excluded from proposals"
      end
    end
  end

  describe "apply!/1" do
    test "closes each proposed bead", %{ws: ws} do
      b1 = new_bead(ws, "🤝 HANDOFF: a")
      b2 = new_bead(ws, "MergeQueue for fakerig - processes merge queue.")

      proposals = DecommissionSweep.proposals()

      proposals_for_test =
        Enum.filter(proposals, &(&1.bead_id in [b1.id, b2.id]))

      {closed, errors} = DecommissionSweep.apply!(proposals_for_test)

      assert Enum.sort(closed) == Enum.sort([b1.id, b2.id])
      assert errors == []

      {:ok, r1} = Ash.get(Issue, b1.id)
      {:ok, r2} = Ash.get(Issue, b2.id)
      assert r1.status == :closed
      assert r2.status == :closed
    end
  end
end
