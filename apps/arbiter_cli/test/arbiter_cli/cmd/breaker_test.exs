defmodule ArbiterCli.Cmd.BreakerTest do
  @moduledoc """
  `arb breaker list` / `arb breaker reset` (bd-5jr49o) — the operator-facing
  half of acceptance 1 and 5.
  """
  use ArbiterCli.CliCase, async: false

  @call_sites [
    %{
      "kind" => "pr_patrol_follow_up",
      "module" => "Arbiter.Workflows.PRPatrol",
      "description" => "Filing a PRPatrol follow-up task for one PR.",
      "limit" => 6,
      "window_ms" => 21_600_000
    },
    %{
      "kind" => "coordinator_escalation",
      "module" => "Arbiter.Messages.CoordinatorNotifier",
      "description" => "Last line of defence.",
      "limit" => 8,
      "window_ms" => 3_600_000
    }
  ]

  @open %{
    "signature" => "ws-1|pr_patrol_follow_up|owner/repo4242",
    "workspace_id" => "ws-1",
    "kind" => "pr_patrol_follow_up",
    "subject" => "owner/repo 4242",
    "count" => 9,
    "suppressed" => 3,
    "limit" => 6,
    "window_ms" => 21_600_000,
    "open" => true,
    "first_at" => "2026-09-13T01:00:00Z",
    "last_at" => "2026-09-13T02:00:00Z",
    "tripped_at" => "2026-09-13T01:30:00Z"
  }

  describe "arb breaker list" do
    test "prints the call-site registry even when nothing has tripped" do
      stub_get("/api/breakers", %{
        "breakers" => [],
        "open_count" => 0,
        "call_sites" => @call_sites
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["list"]) end)

      assert code == 0
      assert out =~ "No circuit breakers have fired"
      assert out =~ "REGISTERED CALL SITES"
      assert out =~ "pr_patrol_follow_up"
      assert out =~ "K=6"
      assert out =~ "coordinator_escalation"
    end

    test "prints an open breaker with its signature, count and bound" do
      stub_get("/api/breakers", %{
        "breakers" => [@open],
        "open_count" => 1,
        "call_sites" => @call_sites
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["list"]) end)

      assert code == 0
      assert out =~ "[OPEN] pr_patrol_follow_up"
      assert out =~ "9/6 in 360m"
      assert out =~ "3 suppressed"
      assert out =~ "ws-1|pr_patrol_follow_up|owner/repo4242"
    end

    test "--json passes the payload through untouched" do
      stub_get("/api/breakers", %{
        "breakers" => [@open],
        "open_count" => 1,
        "call_sites" => @call_sites
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["list", "--json"]) end)

      assert code == 0
      assert %{"open_count" => 1, "breakers" => [_]} = Jason.decode!(out)
    end
  end

  describe "arb breaker reset" do
    test "closes one breaker by signature" do
      stub_post("/api/breakers/reset", %{"reset" => 1, "signature" => @open["signature"]}, 200)

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Breaker.run(["reset", @open["signature"]]) end)

      assert code == 0
      assert out =~ "Closed 1 circuit breaker(s)."
    end

    test "--all closes a whole scope" do
      stub_post("/api/breakers/reset", %{"reset" => 4}, 200)

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["reset", "--all"]) end)

      assert code == 0
      assert out =~ "Closed 4 circuit breaker(s)."
    end

    test "refuses to reset with no target rather than guessing" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["reset"]) end)

      assert code != 0
      assert err =~ "needs a signature"
    end
  end

  test "an unknown subcommand exits non-zero with a pointer to --help" do
    {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["frobnicate"]) end)

    assert code == 2
    assert err =~ "unknown breaker subcommand"
  end
end
