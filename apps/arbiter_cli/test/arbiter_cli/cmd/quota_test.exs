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

    test "renders per-model Gemini CLI and Antigravity utilization when present" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => nil,
          "gemini" => %{
            "provider" => "gemini-cli",
            "plan" => "Standard",
            "message" => nil,
            "captured_at" => "2026-07-06T20:20:06Z",
            "models" => [
              %{
                "model_id" => "gemini-2.5-pro",
                "used" => 500,
                "total" => 1000,
                "remaining_percentage" => 50.0,
                "reset_at" => "2026-06-23T21:38:04Z",
                "unlimited" => false
              }
            ]
          },
          "antigravity" => %{
            "provider" => "antigravity",
            "plan" => "Pro",
            "message" => nil,
            "captured_at" => "2026-07-06T20:20:06Z",
            "models" => [
              %{
                "model_id" => "gemini-3-flash",
                "display_name" => "Gemini 3 Flash",
                "used" => 750,
                "total" => 1000,
                "remaining_percentage" => 25.0,
                "reset_at" => "2026-06-23T21:38:04Z",
                "unlimited" => false
              }
            ]
          }
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "Gemini CLI"
      assert out =~ "plan: Standard"
      assert out =~ "gemini-2.5-pro"
      assert out =~ "50.0% remaining"
      assert out =~ "Antigravity"
      assert out =~ "Gemini 3 Flash"
      assert out =~ "25.0% remaining"
    end

    test "shows the degraded message for Gemini when the API returned one" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => nil,
          "gemini" => %{
            "provider" => "gemini-cli",
            "plan" => "Free",
            "message" => "Gemini CLI quota auth expired; reconnect the CLI.",
            "captured_at" => "2026-07-06T20:20:06Z",
            "models" => []
          },
          "antigravity" => nil
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "Gemini CLI"
      assert out =~ "auth expired"
    end
  end
end
