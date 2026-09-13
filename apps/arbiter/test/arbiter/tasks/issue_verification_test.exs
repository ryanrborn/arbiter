defmodule Arbiter.Tasks.IssueVerificationTest do
  @moduledoc """
  bd-9so315 — post-merge verification state.

  A task flagged `verify_after_deploy: true` must not close on merge. It enters
  `:awaiting_verification` and only leaves that state when the coordinator
  records a restart-and-observe result.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Verification
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "verify-ws", prefix: "vfy"})
    {:ok, ws: ws}
  end

  defp task(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id}, attrs))

    issue
  end

  describe "verify_after_deploy flag" do
    test "defaults to false and is settable at create", %{ws: ws} do
      assert task(ws).verify_after_deploy == false
      assert task(ws, %{verify_after_deploy: true}).verify_after_deploy == true
    end

    test "is settable via the :update action", %{ws: ws} do
      issue = task(ws)
      {:ok, updated} = Ash.update(issue, %{verify_after_deploy: true}, action: :update)
      assert updated.verify_after_deploy == true
    end
  end

  describe ":await_verification action" do
    test "moves an open task into :awaiting_verification and stamps the clock", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})

      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      assert awaiting.status == :awaiting_verification
      assert %DateTime{} = awaiting.awaiting_verification_at
      assert awaiting.closed_at == nil
      assert awaiting.verification_outcome == nil
    end

    test "is rejected for an already-closed task", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)

      assert {:error, _} = Ash.update(closed, %{}, action: :await_verification)
    end
  end

  describe "status FSM guards" do
    test ":update cannot move a task into or out of :awaiting_verification", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})

      assert {:error, _} = Ash.update(issue, %{status: :awaiting_verification}, action: :update)

      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)
      assert {:error, _} = Ash.update(awaiting, %{status: :open}, action: :update)
    end

    test ":close is allowed from :awaiting_verification", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, closed} = Ash.update(awaiting, %{close_upstream: false}, action: :close)
      assert closed.status == :closed
    end

    test ":reopen is allowed from :awaiting_verification", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, reopened} = Ash.update(awaiting, %{}, action: :reopen)
      assert reopened.status == :open
    end
  end

  describe "Verification.observed/2" do
    test "closes the task and persists the evidence", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, verified} = Verification.observed(awaiting, "hit /doctor after restart: 3 repos")

      assert verified.status == :closed
      assert verified.verification_outcome == :observed
      assert verified.verification_evidence == "hit /doctor after restart: 3 repos"
      assert %DateTime{} = verified.closed_at
    end

    test "rejects a task that is not awaiting verification", %{ws: ws} do
      issue = task(ws)
      assert {:error, :not_awaiting_verification} = Verification.observed(issue, "x")
    end

    test "requires non-blank evidence", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      assert {:error, :evidence_required} = Verification.observed(awaiting, "   ")
    end
  end

  describe "Verification.failed/2" do
    test "reopens the task and persists the evidence", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})
      {:ok, issue} = Ash.update(issue, %{pr_ref: "1633"}, action: :update)
      {:ok, awaiting} = Ash.update(issue, %{}, action: :await_verification)

      {:ok, failed} = Verification.failed(awaiting, "capture_source still reads headers")

      assert failed.status == :open
      assert failed.verification_outcome == :failed
      assert failed.verification_evidence == "capture_source still reads headers"
      assert failed.closed_at == nil
      # A reopen starts a fresh attempt — the merged PR is no longer its PR.
      assert failed.pr_ref == nil
      # The flag survives, so the retry re-enters verification on its next merge.
      assert failed.verify_after_deploy == true
    end
  end

  describe "Verification.finalize_merged/2" do
    test "an unflagged task closes, exactly as before the flag existed", %{ws: ws} do
      issue = task(ws)

      assert {:ok, :closed, closed} = Verification.finalize_merged(issue, close_upstream: false)
      assert closed.status == :closed
      assert Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id) == []
    end

    test "a flagged task parks and escalates exactly once", %{ws: ws} do
      issue = task(ws, %{verify_after_deploy: true})

      assert {:ok, :awaiting_verification, parked} =
               Verification.finalize_merged(issue, close_upstream: false, mr_ref: "#1633")

      assert parked.status == :awaiting_verification
      assert [escalation] = Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id)
      assert escalation.subject =~ "awaiting verification"
      assert escalation.body =~ "#1633"

      # A second finalize (a re-tick, a second sweep) must not park again or
      # page again — the guard refuses and no escalation is sent.
      assert {:error, _} = Verification.finalize_merged(parked, close_upstream: false)
      assert length(Arbiter.Messages.Message.inbox("coordinator", workspace_id: ws.id)) == 1
    end
  end

  describe "Verification.awaiting/1" do
    test "lists awaiting tasks for a workspace", %{ws: ws} do
      a = task(ws, %{verify_after_deploy: true})
      _b = task(ws, %{verify_after_deploy: true})
      {:ok, _} = Ash.update(a, %{}, action: :await_verification)

      assert [%Issue{id: id}] = Verification.awaiting(workspace_id: ws.id)
      assert id == a.id
    end
  end
end
