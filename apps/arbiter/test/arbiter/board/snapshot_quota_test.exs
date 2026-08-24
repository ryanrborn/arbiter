defmodule Arbiter.Board.SnapshotQuotaTest do
  @moduledoc """
  Regression coverage for bd-5j6nmn: Autopilot's quota gate
  (`Snapshot.quota_hold/1`) and the Conductor's quota gate
  (`Arbiter.Workflows.QuotaGate.Default`) must read the same underlying
  data for a given workspace + provider — same provider resolution, same
  over-cap decision, same threshold config.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Tasks.Workspace

  defp codex_workspace do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "board-quota-#{System.unique_integer([:positive])}",
        prefix: "bq#{System.unique_integer([:positive])}",
        config: %{"agent" => %{"type" => "codex"}}
      })

    ws
  end

  defp ready_issue(ws) do
    %{
      id: "bd-ready",
      title: "Task bd-ready",
      status: :open,
      priority: 2,
      difficulty: 2,
      issue_type: :task,
      workspace_id: ws.id,
      refined: true,
      description: nil,
      acceptance: nil,
      notes: nil,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }
  end

  describe "quota_hold/1 — provider resolution" do
    test "holds when the workspace's default provider (codex) is over the ceiling" do
      ws = codex_workspace()

      {:ok, _quota} =
        Ash.create(CodexQuota, %{
          workspace_id: ws.id,
          provider: "codex",
          session_used_percent: 93.0,
          session_reset_at: DateTime.utc_now() |> DateTime.add(3600, :second),
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert {:hold, _reason} = Snapshot.quota_hold(ws.id)
    end

    test "Autopilot holds a promotion end-to-end when the shared quota mechanism reports no headroom" do
      ws = codex_workspace()

      {:ok, _quota} =
        Ash.create(CodexQuota, %{
          workspace_id: ws.id,
          provider: "codex",
          session_used_percent: 93.0,
          session_reset_at: DateTime.utc_now() |> DateTime.add(3600, :second),
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      board =
        Snapshot.load(
          workspace_id: ws.id,
          issues: [ready_issue(ws)],
          workers: [],
          blocked_by: %{}
        )

      assert {:hold, _reason} = board.quota
      assert board.promote == nil
    end
  end
end
