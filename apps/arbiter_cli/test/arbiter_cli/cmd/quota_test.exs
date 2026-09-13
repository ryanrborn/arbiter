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

    # bd-b0zody: two sources now write the same primary columns — the proxy's
    # header capture and the /api/oauth/usage poll — so the row has to say
    # which one produced it, or the overlap window is unreadable.
    test "names the source that produced the row" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => Map.put(@snapshot, "capture_source", "oauth_poll")
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "source:                /api/oauth/usage poll"
    end

    test "names the proxy header capture as the source" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => Map.put(@snapshot, "capture_source", "headers")
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "source:                proxy rate-limit headers"
    end

    # bd-1tuxv8: the 5h and 7d numbers are both printed, but only one window (or
    # neither) is actually gating dispatch — say which, so "7d is at 76%" can't
    # be read as the reason Autopilot is idle.
    test "names the window that is gating dispatch" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" =>
            Map.merge(@snapshot, %{
              "utilization_7d" => 0.91,
              "gating_window" => "7d",
              "gating_reason" => "7d quota 0.91 ≥ 0.90"
            })
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "gating dispatch:       7d — 7d quota 0.91 ≥ 0.90"
    end

    # bd-b7umwj: the STALE label used to read "dispatches may be incorrectly
    # held", which is backwards — staleness makes the gate fail OPEN. It is now
    # per-window, because the two windows behave differently: the 5h window
    # fails open on age (bd-y0yup0's recovery valve), the 7d hold is sticky.
    test "the STALE label says what the gate actually does for each window" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" =>
            Map.merge(@snapshot, %{
              "stale" => true,
              "utilization_7d" => 0.96,
              "status_7d" => "allowed_warning",
              "gating_window" => "7d",
              "gating_reason" => "7d quota 0.96 ≥ 0.90"
            })
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "STALE"
      assert out =~ "5h gate fails open"
      assert out =~ "7d hold stays in force"
      refute out =~ "incorrectly held"
      # And the 7d hold is still reported as gating, stale snapshot or not.
      assert out =~ "gating dispatch:       7d — 7d quota 0.96 ≥ 0.90"
    end

    # bd-4fbpto: STALE alone can't distinguish "the poll is fine, it just
    # didn't land a usable 5h figure this cycle" from "nothing has succeeded
    # in a while" — this asserts the two now read differently.
    test "STALE says the poll is still succeeding when oauth_poll_fresh is true" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" =>
            Map.merge(@snapshot, %{
              "stale" => true,
              "oauth_poll_fresh" => true,
              "oauth_captured_at" => "2026-06-23T20:24:00Z"
            })
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "STALE"
      assert out =~ "/api/oauth/usage last succeeded 2026-06-23T20:24:00Z"
      refute out =~ "no fresh data"
    end

    test "STALE says no fresh data from any source when the poll isn't succeeding either" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" =>
            Map.merge(@snapshot, %{
              "stale" => true,
              "oauth_poll_fresh" => false,
              "capture_source" => "headers"
            })
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "STALE"
      assert out =~ "no fresh data from any source"
      assert out =~ "proxy rate-limit headers"
      refute out =~ "last succeeded"
    end

    test "no STALE label on a fresh snapshot" do
      stub_get("/api/quota", %{
        "data" => %{"workspace_id" => "ws-1", "claude" => Map.put(@snapshot, "stale", false)}
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      refute out =~ "STALE"
    end

    test "says so when no window is gating dispatch" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => Map.merge(@snapshot, %{"gating_window" => nil, "gating_reason" => nil})
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "gating dispatch:       none — dispatch is not quota-held"
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

    test "shows recent per-provider spend from the quotas list (bd-ajh7bd)" do
      stub_get("/api/quota", %{
        "data" => %{
          "workspace_id" => "ws-1",
          "claude" => @snapshot,
          "quotas" => [%{"provider" => "claude", "cost_usd" => 12.5}]
        }
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Quota.run([]) end)
      assert code == 0
      assert out =~ "recent spend (30d): $12.50"
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
