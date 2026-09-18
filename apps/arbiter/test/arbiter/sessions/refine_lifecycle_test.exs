defmodule Arbiter.Sessions.RefineLifecycleTest do
  @moduledoc """
  bd-cvfjms (child 4 of epic bd-cksar2): a refine session ends when its bound
  issue is promoted (`end_reason: "promoted"`) or closed (`"issue_closed"`),
  whichever way that transition happens — and a refinement summary lands on
  the issue either way, written by the agent or as a system fallback.

  Acceptance 1 (promoted, both paths land the same), 2 (closed), 3 (the
  summary fallback), 4 (a child's own promotion never ends the session bound
  to its parent).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Sessions
  alias Arbiter.Sessions.RefineLifecycle
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.SessionEnv
  alias Arbiter.Test.SessionRunnerStub

  setup do
    SessionEnv.sandbox("refine-lifecycle")
    SessionRunnerStub.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{name: "rfl-ws-#{System.unique_integer([:positive])}", prefix: "rfl"})

    {:ok, issue} =
      Ash.create(Issue, %{title: "Make widgets faster", workspace_id: ws.id, issue_type: :task})

    {:ok, ws: ws, issue: issue}
  end

  defp start_subscriber do
    name = :"RefineLifecycle_#{System.unique_integer([:positive])}"

    start_supervised!({RefineLifecycle, enabled?: true, runner: SessionRunnerStub, name: name})

    name
  end

  defp open_refine_session!(issue) do
    {:ok, %{session: session}} =
      Arbiter.Sessions.Refine.open(issue, runner: SessionRunnerStub)

    session
  end

  # Async PubSub delivery: give the subscriber a moment to react and poll for
  # the session row to flip to :ended, rather than sleeping a fixed amount.
  defp await_ended(session_id, tries \\ 50) do
    Enum.reduce_while(1..tries, nil, fn _, _ ->
      case Sessions.get(session_id) do
        {:ok, %{status: :ended} = session} -> {:halt, session}
        _ -> {:cont, Process.sleep(10) && nil}
      end
    end)
  end

  describe "the bound issue is promoted" do
    test "ends the session with reason promoted, via the issue's own promote_to_ready", %{
      issue: issue
    } do
      start_subscriber()
      session = open_refine_session!(issue)

      {:ok, _promoted} = Ash.update(issue, %{}, action: :promote_to_ready)

      ended = await_ended(session.id)
      assert ended
      assert ended.end_reason == "promoted"
      assert ended.status == :ended
      refute is_nil(ended.mcp_token_revoked_at)
    end

    test "ends the session the same way when promoted from outside the session (e.g. the dashboard)",
         %{issue: issue} do
      start_subscriber()
      session = open_refine_session!(issue)

      # No MCP scope, no session context — this is the "Move to Ready" button
      # / `arb update --promote` path, exercised the same way that code path
      # calls the action.
      {:ok, _promoted} = Ash.update(issue, %{}, action: :promote_to_ready)

      ended = await_ended(session.id)
      assert ended.end_reason == "promoted"
    end

    test "ends the session when the session's own task_promote call revokes its in-flight token",
         %{issue: issue} do
      start_subscriber()
      session = open_refine_session!(issue)

      scope = %Arbiter.MCP.Scope{
        tier: :refine,
        workspace_id: issue.workspace_id,
        issue_id: issue.id,
        session_id: session.id
      }

      assert {:ok, _result} =
               Arbiter.MCP.Tools.Task.task_promote(scope, %{"id" => issue.id})

      ended = await_ended(session.id)
      assert ended
      assert ended.end_reason == "promoted"
      refute is_nil(ended.mcp_token_revoked_at)
    end

    test "promoting an already-refined issue again does not re-end an already-ended session",
         %{issue: issue} do
      start_subscriber()
      session = open_refine_session!(issue)

      {:ok, promoted} = Ash.update(issue, %{}, action: :promote_to_ready)
      first_ended = await_ended(session.id)
      assert first_ended.end_reason == "promoted"

      {:ok, _twice} = Ash.update(promoted, %{}, action: :promote_to_ready)
      # Idempotent: the row keeps its original ended_at/end_reason.
      {:ok, still} = Sessions.get(session.id)
      assert still.ended_at == first_ended.ended_at
      assert still.end_reason == "promoted"
    end
  end

  describe "the bound issue is closed" do
    test "ends the session with reason issue_closed", %{issue: issue} do
      start_subscriber()
      session = open_refine_session!(issue)

      {:ok, _closed} = Ash.update(issue, %{reason: "no longer wanted"}, action: :close)

      ended = await_ended(session.id)
      assert ended.end_reason == "issue_closed"
    end
  end

  describe "the refinement summary fallback" do
    test "a blank notes field gets a system fallback note when the session ends", %{
      issue: issue
    } do
      start_subscriber()
      session = open_refine_session!(issue)

      {:ok, _promoted} = Ash.update(issue, %{}, action: :promote_to_ready)
      await_ended(session.id)

      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.notes =~ "Refinement summary unavailable"
    end

    test "an agent-written summary is never overwritten", %{issue: issue} do
      start_subscriber()
      session = open_refine_session!(issue)

      {:ok, issue} =
        Ash.update(issue, %{notes: "Split into two children; both ready."}, action: :update)

      {:ok, _promoted} = Ash.update(issue, %{}, action: :promote_to_ready)
      await_ended(session.id)

      {:ok, reloaded} = Ash.get(Issue, issue.id)
      assert reloaded.notes == "Split into two children; both ready."
    end
  end

  describe "children promoted before the bound issue" do
    test "promoting a child issue does not end the parent's refine session", %{
      issue: issue,
      ws: ws
    } do
      start_subscriber()
      session = open_refine_session!(issue)

      {:ok, child} =
        Ash.create(Issue, %{title: "child", workspace_id: ws.id, issue_type: :task})

      {:ok, _child_promoted} = Ash.update(child, %{}, action: :promote_to_ready)

      # Give the subscriber a beat to (not) react, then assert the parent's
      # session is still live.
      Process.sleep(50)
      {:ok, still_live} = Sessions.get(session.id)
      assert still_live.status != :ended

      # Promoting the bound issue itself still ends it — proves the
      # subscriber was listening the whole time, not just silent.
      {:ok, _promoted} = Ash.update(issue, %{}, action: :promote_to_ready)
      ended = await_ended(session.id)
      assert ended.end_reason == "promoted"
    end
  end
end
