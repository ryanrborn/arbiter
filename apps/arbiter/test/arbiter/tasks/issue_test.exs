defmodule Arbiter.Tasks.IssueTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "test-ws", prefix: "test"})
    {:ok, ws: ws}
  end

  describe "create/2" do
    test "succeeds with minimal valid attrs; id has workspace prefix; defaults applied", %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "first", workspace_id: ws.id})

      assert String.starts_with?(issue.id, "test-")
      assert String.length(issue.id) == 5 + 6, "id should be 'test-' + 6 chars: #{issue.id}"
      assert issue.title == "first"
      assert issue.status == :open
      assert issue.priority == 2
      # bd-5lc99r: the default issue_type is `:feature` (a reviewable type), not
      # `:task`. `:task` is now an opt-in non-reviewable type, so untyped work
      # must default to the reviewable path.
      assert issue.issue_type == :feature
      assert issue.tracker_type == :none
      assert issue.tracker_ref == nil
      assert issue.closed_at == nil
    end

    test "inherits tracker_type from workspace config when not specified", %{ws: ws} do
      {:ok, ws_jira} =
        Ash.update(ws, %{config: %{"tracker" => %{"type" => "jira"}}})

      {:ok, issue} = Ash.create(Issue, %{title: "jira-tracked", workspace_id: ws_jira.id})

      assert issue.tracker_type == :jira
    end

    test "explicit tracker_type overrides workspace inheritance", %{ws: ws} do
      {:ok, ws_jira} = Ash.update(ws, %{config: %{"tracker" => %{"type" => "jira"}}})

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "explicit-none",
          tracker_type: :none,
          workspace_id: ws_jira.id
        })

      assert issue.tracker_type == :none
    end

    test "tracker_ref can be set on create", %{ws: ws} do
      {:ok, issue} =
        Ash.create(Issue, %{
          title: "with-jira-ref",
          tracker_type: :jira,
          tracker_ref: "VR-17585",
          workspace_id: ws.id
        })

      assert issue.tracker_type == :jira
      assert issue.tracker_ref == "VR-17585"
    end

    test "rich-content fields round-trip Markdown", %{ws: ws} do
      desc = "# Heading\n\n- bullet 1\n- bullet 2\n\n```elixir\nIO.puts(\"hi\")\n```"
      acceptance = "1. step one\n2. step two"
      qa = "QA: hit `/api/v2/...` and verify response"

      {:ok, issue} =
        Ash.create(Issue, %{
          title: "rich",
          description: desc,
          acceptance: acceptance,
          qa_notes: qa,
          workspace_id: ws.id
        })

      reloaded = Ash.get!(Issue, issue.id)
      assert reloaded.description == desc
      assert reloaded.acceptance == acceptance
      assert reloaded.qa_notes == qa
    end

    test "fails when title missing", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Issue, %{workspace_id: ws.id})
    end

    test "fails when workspace_id missing" do
      assert {:error, %Ash.Error.Invalid{}} = Ash.create(Issue, %{title: "orphan"})
    end

    test "priority must be 0..4", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Issue, %{title: "p5", priority: 5, workspace_id: ws.id})

      assert {:ok, p0} = Ash.create(Issue, %{title: "p0", priority: 0, workspace_id: ws.id})
      assert p0.priority == 0
    end

    test "difficulty defaults to nil and accepts 0..4", %{ws: ws} do
      {:ok, default} =
        Ash.create(Issue, %{title: "no-difficulty", workspace_id: ws.id})

      assert default.difficulty == nil

      for d <- 0..4 do
        {:ok, set} =
          Ash.create(Issue, %{
            title: "d#{d}",
            difficulty: d,
            workspace_id: ws.id
          })

        assert set.difficulty == d
      end
    end

    test "difficulty rejects out-of-range integers", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Issue, %{title: "d5", difficulty: 5, workspace_id: ws.id})

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Issue, %{title: "dneg", difficulty: -1, workspace_id: ws.id})
    end

    test "difficulty persists across reload and can be updated", %{ws: ws} do
      {:ok, b} = Ash.create(Issue, %{title: "d3", difficulty: 3, workspace_id: ws.id})
      assert Ash.get!(Issue, b.id).difficulty == 3

      {:ok, updated} = Ash.update(b, %{difficulty: 1})
      assert updated.difficulty == 1
      assert Ash.get!(Issue, b.id).difficulty == 1

      # Clearing is allowed (nullable).
      {:ok, cleared} = Ash.update(updated, %{difficulty: nil})
      assert cleared.difficulty == nil
    end

    test "issue_type must be in enum", %{ws: ws} do
      assert {:error, %Ash.Error.Invalid{}} =
               Ash.create(Issue, %{title: "weird", issue_type: :rumor, workspace_id: ws.id})

      assert {:ok, b} = Ash.create(Issue, %{title: "bug", issue_type: :bug, workspace_id: ws.id})
      assert b.issue_type == :bug
    end
  end

  describe "status FSM via :update" do
    setup %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "to-update", workspace_id: ws.id})
      {:ok, issue: issue}
    end

    test "open → in_progress is allowed", %{issue: issue} do
      assert {:ok, updated} = Ash.update(issue, %{status: :in_progress})
      assert updated.status == :in_progress
    end

    test "in_progress → open is allowed", %{issue: issue} do
      {:ok, ip} = Ash.update(issue, %{status: :in_progress})
      assert {:ok, opened} = Ash.update(ip, %{status: :open})
      assert opened.status == :open
    end

    test "open → closed via :update is BLOCKED (must use :close action)", %{issue: issue} do
      assert {:error, %Ash.Error.Invalid{} = err} = Ash.update(issue, %{status: :closed})
      assert err |> Exception.message() |> String.contains?("Use the :close action")
    end
  end

  describe ":close action" do
    setup %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "to-close", workspace_id: ws.id})
      {:ok, issue: issue}
    end

    test "closes an open issue and sets closed_at", %{issue: issue} do
      assert {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert closed.status == :closed
      assert %DateTime{} = closed.closed_at
    end

    test "can close an in_progress issue", %{issue: issue} do
      {:ok, ip} = Ash.update(issue, %{status: :in_progress})
      assert {:ok, closed} = Ash.update(ip, %{}, action: :close)
      assert closed.status == :closed
    end

    test "cannot close an already-closed issue", %{issue: issue} do
      {:ok, closed} = Ash.update(issue, %{}, action: :close)

      assert {:error, %Ash.Error.Invalid{} = err} = Ash.update(closed, %{}, action: :close)
      assert err |> Exception.message() |> String.contains?("already closed")
    end
  end

  describe ":reopen action" do
    setup %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "to-reopen", workspace_id: ws.id})
      {:ok, closed} = Ash.update(issue, %{}, action: :close)
      {:ok, issue: issue, closed: closed}
    end

    test "reopens a closed issue and clears closed_at", %{closed: closed} do
      assert {:ok, reopened} = Ash.update(closed, %{}, action: :reopen)
      assert reopened.status == :open
      assert reopened.closed_at == nil
    end

    test "cannot reopen an open issue", %{issue: issue} do
      # Use the original open issue (before :close was applied)
      assert {:error, %Ash.Error.Invalid{} = err} = Ash.update(issue, %{}, action: :reopen)
      assert err |> Exception.message() |> String.contains?("must be :closed")
    end

    test "clears stale pr_ref and source_pr so a fresh attempt starts clean (bd-38l3px)",
         %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "opened-a-pr", workspace_id: ws.id})
      # A prior run opened a PR (pr_ref) / was a PRPatrol follow-up (source_pr).
      {:ok, issue} =
        Ash.update(issue, %{pr_ref: "owner/repo#123", source_pr: "123"}, action: :update)

      {:ok, closed} = Ash.update(issue, %{}, action: :close)
      assert {:ok, reopened} = Ash.update(closed, %{}, action: :reopen)

      # A reopened bead is a fresh attempt — its prior PR reference must not
      # linger, or MergedPRFinalizer would re-detect that merged PR and re-close
      # the bead every reopen cycle.
      assert reopened.status == :open
      assert reopened.pr_ref == nil
      assert reopened.source_pr == nil
    end

    test "cannot update fields on a closed issue via :update (status guard)", %{closed: closed} do
      # Can update non-status fields? per FSM, only status is guarded — title should be OK
      assert {:ok, _updated} = Ash.update(closed, %{title: "renamed but still closed"})

      # But trying to set status explicitly should error
      assert {:error, %Ash.Error.Invalid{}} = Ash.update(closed, %{status: :open})
    end
  end

  describe "paper_trail audit" do
    setup %{ws: ws} do
      {:ok, issue} = Ash.create(Issue, %{title: "audited", workspace_id: ws.id})
      {:ok, _} = Ash.update(issue, %{title: "audited (v2)"})
      {:ok, _} = Ash.update(issue, %{}, action: :close)

      versions = Ash.read!(Arbiter.Tasks.Issue.Version)
      {:ok, issue: issue, versions: versions}
    end

    test "creates a version row for each write", %{versions: versions} do
      # 1 create + 1 update + 1 close = 3 versions
      assert length(versions) == 3
    end

    test "version rows capture the action name", %{versions: versions} do
      action_names =
        versions
        |> Enum.map(& &1.version_action_name)
        |> Enum.sort()

      assert :close in action_names
      assert :create in action_names
      assert :update in action_names
    end
  end

  describe "enums helpers" do
    test "statuses/0" do
      assert Issue.statuses() == ~w(open in_progress closed)a
    end

    test "issue_types/0" do
      assert Issue.issue_types() == ~w(task bug feature epic chore decision)a
    end

    test "tracker_types/0" do
      assert Issue.tracker_types() == ~w(none jira shortcut linear github gitlab)a
    end
  end

  describe "ready/1 with :workspace_id" do
    test "filters to a single workspace's open issues" do
      {:ok, ws_a} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "wa-#{System.unique_integer([:positive])}",
          prefix: "wa"
        })

      {:ok, ws_b} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "wb-#{System.unique_integer([:positive])}",
          prefix: "wb"
        })

      {:ok, in_a} = Ash.create(Issue, %{title: "a", workspace_id: ws_a.id})
      {:ok, _in_b} = Ash.create(Issue, %{title: "b", workspace_id: ws_b.id})

      ids = Issue.ready(workspace_id: ws_a.id) |> Enum.map(& &1.id)
      assert in_a.id in ids
      refute Enum.any?(ids, &String.starts_with?(&1, "wb-"))
    end

    test "no opts → all workspaces (unchanged from ready/0)" do
      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "wa0-#{System.unique_integer([:positive])}",
          prefix: "wa0"
        })

      {:ok, task} = Ash.create(Issue, %{title: "z", workspace_id: ws.id})

      ids = Issue.ready() |> Enum.map(& &1.id)
      assert task.id in ids
    end
  end
end
