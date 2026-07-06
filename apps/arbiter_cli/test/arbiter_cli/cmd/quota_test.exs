defmodule ArbiterCli.Cmd.QuotaTest do
  use ArbiterCli.CliCase, async: false

  @snapshot %{
    "utilization_5h" => 0.24,
    "reset_5h_at" => "2026-06-23T23:00:00Z",
    "status_5h" => "allowed",
    "utilization_7d" => 0.08,
    "reset_7d_at" => "2026-06-29T00:00:00Z",
    "status_7d" => "allowed",
    "representative_claim" => "five_hour",
    "overage_status" => "rejected",
    "captured_at" => "2026-06-23T20:20:06Z"
  }

  @codex %{
    "plan" => "plus",
    "limit_reached" => false,
    "session" => %{
      "used" => 42.5,
      "total" => 100,
      "remaining" => 57.5,
      "reset_at" => "2026-06-23T23:00:00Z",
      "unlimited" => false
    },
    "weekly" => %{
      "used" => 8.0,
      "total" => 100,
      "remaining" => 92.0,
      "reset_at" => "2026-06-29T00:00:00Z",
      "unlimited" => false
    },
    "captured_at" => "2026-06-23T20:20:06Z"
  }

  describe "arb quota" do
    test "renders 5h and 7d utilization, status, and reset times in text mode" do
      stub_get("/api/quota", %{"data" => %{"workspace_id" => "ws-1", "claude" => @snapshot}})

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "Anthropic quota (workspace ws-1)"
      assert out =~ "5h:  24.0% used"
      assert out =~ "7d:  8.0% used"
      assert out =~ "status=allowed"
      assert out =~ "2026-06-23T23:00:00Z"
      assert out =~ "representative window: five_hour"
    end

    test "renders codex session + weekly windows in text mode" do
      stub_get("/api/quota", %{
        "data" => %{"workspace_id" => "ws-1", "claude" => @snapshot, "codex" => @codex}
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "Codex quota (workspace ws-1)"
      assert out =~ "plan:"
      assert out =~ "session:  42.5% used"
      assert out =~ "weekly:   8.0% used"
      assert out =~ "2026-06-29T00:00:00Z"
    end

    test "explains the codex empty state with the message" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => nil,
          "codex" => nil,
          "codex_message" => "Codex CLI not authenticated for this workspace"
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "Codex CLI not authenticated for this workspace"
    end

    test "--json mode emits the raw snapshot" do
      stub_get("/api/quota", %{"data" => %{"workspace_id" => "ws-1", "claude" => @snapshot}})

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run(["--json"]) end)
      assert code == 0
      decoded = Jason.decode!(out)
      assert decoded["workspace_id"] == "ws-1"
      assert decoded["claude"]["utilization_5h"] == 0.24
    end

    test "explains the empty state when nothing has been captured" do
      stub_get("/api/quota", %{"data" => %{"workspace_id" => "ws-1", "claude" => nil}})

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "no quota captured yet"
    end
  end
end
