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

  # Produced by the server rather than hand-written, so this fixture cannot
  # drift into a shape the system can never emit — the previous literal silently
  # elided the structured-subject separator (round 2, finding 2).
  @signature Arbiter.CircuitBreaker.Signature.signature(
               "ws-1",
               :pr_patrol_follow_up,
               ["owner/repo", 4242]
             )

  @open %{
    "signature" => @signature,
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

      # Printed quoted, and the signature itself is printable end to end: the
      # operator copies this line into `arb breaker reset '...'`.
      assert out =~ "'#{@signature}'"
      assert @signature == "ws-1|pr_patrol_follow_up|owner/repo :: 4242"
      assert String.printable?(@signature)
    end

    # `:coordinator_escalation` keys on free-text escalation subject lines, so a
    # signature can carry an apostrophe — which would terminate the `'...'` this
    # command prints for the operator to copy (round 2, observation 2). The CLI
    # ships as an escript and cannot call the server-side `Signature` at
    # runtime, so it carries its own quoter; asserting against the real one here
    # (a test-only umbrella dep) is what keeps the two from drifting.
    test "an apostrophe in a signature is printed as a runnable shell word" do
      signature =
        Arbiter.CircuitBreaker.Signature.signature(
          "ws-1",
          :coordinator_escalation,
          ["bd-x1", "auto-merge didn't land"]
        )

      assert String.contains?(signature, "'"), "fixture must exercise the apostrophe"

      stub_get("/api/breakers", %{
        "breakers" => [%{@open | "signature" => signature}],
        "open_count" => 1,
        "call_sites" => @call_sites
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["list"]) end)

      assert code == 0
      assert out =~ Arbiter.CircuitBreaker.Signature.shell_quote(signature)

      # And the printed word really parses back to the signature under a shell.
      printed =
        out
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.find(&String.starts_with?(&1, "'"))

      {parsed, 0} =
        System.cmd("sh", ["-c", ~s|set -- #{printed}; printf '%s' "$1"|])

      assert parsed == signature
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

  describe "arb breaker list auth holds (bd-21bmdh)" do
    test "prints every open auth hold with its reset command" do
      stub_get("/api/breakers", %{
        "breakers" => [],
        "open_count" => 0,
        "call_sites" => @call_sites,
        "auth_holds" => [
          %{
            "provider" => "claude",
            "open" => true,
            "probation" => false,
            "deaths" => 2,
            "threshold" => 2,
            "opened_at" => "2026-09-22T12:00:00Z"
          }
        ]
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["list"]) end)

      assert code == 0
      assert out =~ "AUTH HOLDS"
      assert out =~ "[OPEN] claude"
      assert out =~ "arb breaker reset --auth-hold claude"
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

    test "--auth-hold <provider> clears that provider's auth hold (bd-21bmdh)" do
      test_pid = self()

      stub_routes([
        {{"post", "/api/breakers/reset"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:body, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"reset" => 1, "auth_hold" => "claude"})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Breaker.run(["reset", "--auth-hold", "claude"]) end)

      assert code == 0
      assert_received {:body, %{"provider" => "claude"}}
      assert out =~ "Cleared the claude auth hold."
    end

    test "refuses to reset with no target rather than guessing" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["reset"]) end)

      assert code != 0
      assert err =~ "needs a signature"
    end

    # A flag's *value* is also a non-`--` token, so the old "first non-flag
    # token" scan read `--workspace ws-1` as a request to reset the signature
    # "ws-1" and reported "no breaker with signature ws-1" — the wrong problem
    # (round 3, finding 3).
    test "a flag value is not mistaken for the signature" do
      for args <- [
            ["reset", "--workspace", "ws-1"],
            ["reset", "--kind", "pr_patrol_follow_up"],
            ["reset", "--kind", "pr_patrol_follow_up", "--workspace", "ws-1"]
          ] do
        {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(args) end)

        assert code != 0, "#{inspect(args)} should have refused, not guessed a signature"
        assert err =~ "needs a signature"
      end
    end

    test "a signature that follows a flag pair is still found" do
      stub_post("/api/breakers/reset", %{"reset" => 1, "signature" => @signature}, 200)

      {out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Breaker.run(["reset", "--workspace", "ws-1", @signature])
        end)

      assert code == 0
      assert out =~ "Closed 1 circuit breaker(s)."
    end

    test "--all still wins over a trailing positional" do
      stub_post("/api/breakers/reset", %{"reset" => 2}, 200)

      {out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Breaker.run(["reset", "--all", "--kind", "pr_patrol_follow_up"])
        end)

      assert code == 0
      assert out =~ "Closed 2 circuit breaker(s)."
    end
  end

  describe "routing through the real `arb` entry point" do
    test "`arb breaker list` reaches this command rather than unknown-command" do
      stub_get("/api/breakers", %{
        "breakers" => [],
        "open_count" => 0,
        "call_sites" => @call_sites
      })

      {out, err, code} = capture(fn -> ArbiterCli.Main.main(["breaker", "list"]) end)

      assert code == 0
      refute err =~ "unknown command"
      assert out =~ "REGISTERED CALL SITES"
    end

    test "`arb breaker` is a known verb, so it is never suggested away" do
      assert {:ok, "breaker"} = ArbiterCli.AliasResolver.resolve("breaker")
    end
  end

  test "an unknown subcommand exits non-zero with a pointer to --help" do
    {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Breaker.run(["frobnicate"]) end)

    assert code == 2
    assert err =~ "unknown breaker subcommand"
  end
end
