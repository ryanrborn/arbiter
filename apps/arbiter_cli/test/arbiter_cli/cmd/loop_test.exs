defmodule ArbiterCli.Cmd.LoopTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Loop

  test "loop analyze prints the markdown report" do
    stub_get("/api/loop/analyze", %{
      "markdown" => "# Loop-analysis report — last 7d\n\nbody",
      "usage_event_id" => "ev-1",
      "summary" => %{"totals" => %{"failed" => 2}}
    })

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--since", "7d"]) end)
    assert exit_code == 0
    assert out =~ "Loop-analysis report"
    refute out =~ "usage_event_id"
  end

  test "loop with no subcommand defaults to analyze" do
    stub_get("/api/loop/analyze", %{
      "markdown" => "# report",
      "usage_event_id" => "e",
      "summary" => %{}
    })

    {out, _err, exit_code} = capture(fn -> Loop.run([]) end)
    assert exit_code == 0
    assert out =~ "report"
  end

  test "loop analyze --json prints the raw envelope" do
    stub_get("/api/loop/analyze", %{
      "markdown" => "# report",
      "usage_event_id" => "ev-9",
      "summary" => %{"totals" => %{"failed" => 1}}
    })

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--json"]) end)
    assert exit_code == 0
    assert out =~ "usage_event_id"
    assert out =~ "ev-9"
  end

  test "loop analyze passes --since through as a query param" do
    stub_routes([
      {{"get", "/api/loop/analyze"},
       fn conn ->
         conn = Plug.Conn.fetch_query_params(conn)
         assert conn.query_params["since"] == "24h"

         Req.Test.json(conn, %{
           "markdown" => "# report",
           "usage_event_id" => "x",
           "summary" => %{}
         })
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--since", "24h"]) end)
    assert exit_code == 0
  end

  # bd-9j2g3x — `--propose` is a different verb on a different route, so the
  # read-only GET can never write.
  test "loop analyze --propose posts to /api/loop/propose and lists what it queued" do
    stub_post(
      "/api/loop/propose",
      %{
        "markdown" => "# report",
        "usage_event_id" => "ev-p",
        "summary" => %{},
        "proposals" => [
          %{
            "id" => "p-1",
            "state" => "hypothesis",
            "kind" => "skill_patch",
            "evidence_count" => 1,
            "distinct_tasks" => 1,
            "gist" => "working-practice guardrail for: inert at runtime"
          }
        ]
      },
      200
    )

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--propose"]) end)

    assert exit_code == 0
    assert out =~ "Queued proposals (1)"
    assert out =~ "hypothesis"
    assert out =~ "1i/1t"
    assert out =~ "arb loop apply"
  end

  describe "the proposal queue" do
    test "loop pending lists the queue" do
      stub_get("/api/loop/pending", %{
        "pending" => [
          %{
            "id" => "p-1",
            "state" => "proposed",
            "kind" => "difficulty_override",
            "evidence_count" => 3,
            "distinct_tasks" => 2,
            "gist" => "raise difficulty on bd-x: D1 → D2"
          }
        ],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      assert out =~ "p-1"
      assert out =~ "proposed"
      assert out =~ "3i/2t"
      assert out =~ "D1 → D2"
    end

    # Amendment D: an approver must see the recurring price next to the
    # evidence, not have to open the row to discover a fleet-wide prompt
    # addition costs tokens on every dispatch from here on.
    test "loop pending prices each proposal's recurring context cost" do
      stub_get("/api/loop/pending", %{
        "pending" => [
          %{
            "id" => "p-1",
            "state" => "proposed",
            "kind" => "skill_patch",
            "evidence_count" => 3,
            "distinct_tasks" => 2,
            "context_cost_tokens" => 120,
            "gist" => "always run mix precommit before pushing"
          },
          %{
            "id" => "p-2",
            "state" => "proposed",
            "kind" => "difficulty_override",
            "evidence_count" => 3,
            "distinct_tasks" => 2,
            "context_cost_tokens" => 0,
            "gist" => "raise difficulty on bd-x: D1 → D2"
          }
        ],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      assert out =~ "+120ctx"
      # Blast radius 1 is genuinely free forever; say so rather than print "0".
      assert out =~ "free"
    end

    # bd-bldypb: a row whose payload can't satisfy its kind's apply
    # preconditions is marked beside the state, so an operator can tell
    # which rows are actionable without pressing apply on each one.
    test "loop pending marks a payload-less row as needing authoring" do
      stub_get("/api/loop/pending", %{
        "pending" => [
          %{
            "id" => "p-1",
            "state" => "proposed",
            "kind" => "skill_patch",
            "evidence_count" => 4,
            "distinct_tasks" => 3,
            "needs_authoring" => true,
            "gist" => "missing test coverage"
          },
          %{
            "id" => "p-2",
            "state" => "proposed",
            "kind" => "difficulty_override",
            "evidence_count" => 1,
            "distinct_tasks" => 1,
            "needs_authoring" => false,
            "gist" => "raise difficulty on bd-x: D1 → D2"
          }
        ],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      lines = String.split(out, "\n", trim: true)
      gapped_line = Enum.find(lines, &String.contains?(&1, "p-1"))
      override_line = Enum.find(lines, &String.contains?(&1, "p-2"))

      assert gapped_line =~ "needs authoring"
      refute override_line =~ "needs authoring"
    end

    test "loop pending names the evidence bar when the queue is empty" do
      stub_get("/api/loop/pending", %{
        "pending" => [],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      assert out =~ "no queued loop proposals"
      assert out =~ "3 incidents"
      assert out =~ "2 distinct tasks"
    end

    test "loop diff prints the unified diff and the evidence behind it" do
      stub_get("/api/loop/pending/p-1", %{
        "pending" => %{
          "id" => "p-1",
          "state" => "proposed",
          "kind" => "difficulty_override",
          "scope" => "task",
          "gist" => "raise difficulty on bd-x",
          "evidence_count" => 3,
          "distinct_tasks" => 2,
          "target_metric" => "rework rate",
          "baseline" => "42.0%",
          "context_cost_tokens" => 0,
          "diff" => "--- a/task\n+++ b/task\n-difficulty: 1\n+difficulty: 2\n"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-1"]) end)

      assert exit_code == 0
      assert out =~ "+difficulty: 2"
      assert out =~ "3 incident(s) across 2 distinct task(s)"
      assert out =~ "rework rate"
      assert out =~ "42.0%"
      # A routing change alters which model runs, not what is in the prompt.
      assert out =~ "context cost: 0 tokens"
    end

    test "loop diff spells out the standing cost of a fleet-wide clause" do
      stub_get("/api/loop/pending/p-3", %{
        "pending" => %{
          "id" => "p-3",
          "state" => "proposed",
          "kind" => "skill_patch",
          "scope" => "fleet",
          "gist" => "always run mix precommit before pushing",
          "evidence_count" => 4,
          "distinct_tasks" => 3,
          "context_cost_tokens" => 120,
          "diff" => "--- a/skill\n+++ b/skill\n+always run mix precommit\n"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-3"]) end)

      assert exit_code == 0
      assert out =~ "context cost: ~120 token(s) added to every dispatch"
    end

    test "loop diff surfaces why a hypothesis is not applicable" do
      stub_get("/api/loop/pending/p-2", %{
        "pending" => %{
          "id" => "p-2",
          "state" => "hypothesis",
          "kind" => "skill_patch",
          "scope" => "fleet",
          "gist" => "guardrail",
          "evidence_count" => 1,
          "distinct_tasks" => 1,
          "diff" => nil,
          "inapplicable_reason" =>
            "1 incident across 1 distinct task — needs 3 incidents across 2 distinct tasks"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-2"]) end)

      assert exit_code == 0
      assert out =~ "not applicable"
      assert out =~ "needs 3 incidents"
      assert out =~ "no diff"
    end

    test "loop diff surfaces why a proposed row needs authoring (bd-bldypb)" do
      stub_get("/api/loop/pending/p-4", %{
        "pending" => %{
          "id" => "p-4",
          "state" => "proposed",
          "kind" => "skill_patch",
          "scope" => "task",
          "gist" => "missing test coverage",
          "evidence_count" => 1,
          "distinct_tasks" => 1,
          "diff" => nil,
          "needs_authoring" => true,
          "authoring_gap" =>
            "this proposal names no target skill: the loop does not yet map a finding " <>
              "category to a skill"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-4"]) end)

      assert exit_code == 0
      assert out =~ "needs authoring"
      assert out =~ "names no target skill"
      assert out =~ "no diff"
    end

    test "loop apply posts to the per-row apply route" do
      stub_post(
        "/api/loop/pending/p-1/apply",
        %{"pending" => %{"id" => "p-1", "gist" => "raise difficulty on bd-x"}, "applied" => true},
        200
      )

      {out, _err, exit_code} = capture(fn -> Loop.run(["apply", "p-1"]) end)

      assert exit_code == 0
      assert out =~ "applied p-1"
    end

    test "loop reject passes the reason through" do
      stub_routes([
        {{"post", "/api/loop/pending/p-1/reject"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["reason"] == "handled by hand"

           Req.Test.json(conn, %{
             "pending" => %{"id" => "p-1", "gist" => "g"},
             "rejected" => true
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn -> Loop.run(["reject", "p-1", "--reason", "handled by hand"]) end)

      assert exit_code == 0
      assert out =~ "rejected p-1"
    end

    test "loop apply all fetches the proposed rows and applies each one" do
      stub_routes([
        {{"get", "/api/loop/pending"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           assert conn.query_params["state"] == "proposed"

           Req.Test.json(conn, %{
             "pending" => [
               %{"id" => "p-1", "gist" => "one"},
               %{"id" => "p-2", "gist" => "two"}
             ],
             "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
           })
         end},
        {{"post", "/api/loop/pending/p-1/apply"},
         fn conn -> Req.Test.json(conn, %{"pending" => %{"id" => "p-1", "gist" => "one"}}) end},
        {{"post", "/api/loop/pending/p-2/apply"},
         fn conn -> Req.Test.json(conn, %{"pending" => %{"id" => "p-2", "gist" => "two"}}) end}
      ])

      {out, _err, exit_code} = capture(fn -> Loop.run(["apply", "all"]) end)

      assert exit_code == 0
      assert out =~ "applied p-1"
      assert out =~ "applied p-2"
    end

    test "loop diff without an id is a usage error" do
      {_out, err, exit_code} = capture(fn -> Loop.run(["diff"]) end)
      assert exit_code == 1
      assert err =~ "usage: arb loop diff"
    end
  end

  test "unknown subcommand errors" do
    {_out, err, exit_code} = capture(fn -> Loop.run(["frobnicate"]) end)
    assert exit_code == 1
    assert err =~ "unknown"
  end

  test "--help prints usage without hitting the API" do
    {out, _err, exit_code} = capture(fn -> Loop.run(["--help"]) end)
    assert exit_code == 0
    assert out =~ "arb loop analyze"
  end
end
