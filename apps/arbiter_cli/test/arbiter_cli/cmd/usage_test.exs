defmodule ArbiterCli.Cmd.UsageTest do
  @moduledoc """
  bd-3j4ch4 AC4: `arb usage --calibration` renders the mis-rating report.
  """

  use ArbiterCli.CliCase, async: false

  @report %{
    "window_days" => 60,
    "re_dispatched_flagged" => 1,
    "tiers" => [
      %{
        "difficulty" => 1,
        "n" => 10,
        "re_dispatched" => 0,
        "n_scored" => 10,
        "p25" => 3.0,
        "median" => 5.0,
        "p75" => 8.0,
        "p90" => 9.0,
        "under_rated" => 0,
        "over_rated" => 0,
        "under_rate" => 0.0,
        "over_rate" => 0.0
      },
      %{
        "difficulty" => 2,
        "n" => 13,
        "re_dispatched" => 1,
        "n_scored" => 12,
        "p25" => 13.0,
        "median" => 16.0,
        "p75" => 19.0,
        "p90" => 25.0,
        "under_rated" => 1,
        "over_rated" => 1,
        "under_rate" => 1 / 12,
        "over_rate" => 1 / 12
      }
    ],
    "flagged" => [
      %{
        "task_id" => "bd-under1",
        "title" => "looks like a D3",
        "difficulty" => 2,
        "issue_type" => "feature",
        "actual_cost_usd" => 25.0,
        "direction" => "under_rated",
        "suggested_difficulty" => 3,
        "re_dispatched" => false
      },
      %{
        "task_id" => "bd-reslung",
        "title" => "re-slung, not mis-rated",
        "difficulty" => 2,
        "issue_type" => "feature",
        "actual_cost_usd" => 26.0,
        "direction" => "under_rated",
        "suggested_difficulty" => 3,
        "re_dispatched" => true
      },
      %{
        "task_id" => "bd-over1",
        "title" => "looks like a D1",
        "difficulty" => 2,
        "issue_type" => "chore",
        "actual_cost_usd" => 5.0,
        "direction" => "over_rated",
        "suggested_difficulty" => 1,
        "re_dispatched" => false
      }
    ]
  }

  describe "arb usage --calibration" do
    test "prints per-tier rates and both mis-rating directions" do
      stub_get("/api/usage/calibration", @report)

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration"]) end)

      assert code == 0
      assert out =~ "Cost calibration"
      assert out =~ "60-day window"

      # Per-tier rates.
      assert out =~ "D2"
      assert out =~ "$13.00"
      assert out =~ "$19.00"
      assert out =~ "8.3%"

      # Both directions are listed, with the suggested tier.
      assert out =~ "under-rated"
      assert out =~ "over-rated"
      assert out =~ "bd-under1"
      assert out =~ "bd-over1"
      assert out =~ "D2 -> D3"
      assert out =~ "D2 -> D1"
    end

    test "footnotes the re-dispatched tasks it kept out of the rates" do
      stub_get("/api/usage/calibration", @report)

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration"]) end)

      assert out =~ "bd-reslung"
      assert out =~ "re-dispatched"
      # The marker on the row itself, so the table is readable without the
      # footnote.
      assert out =~ "*"
    end

    test "--json emits the raw report" do
      stub_get("/api/usage/calibration", @report)

      {out, _err, 0} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration", "--json"]) end)

      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["window_days"] == 60
      assert length(decoded["flagged"]) == 3
    end

    test "an empty report says so rather than printing an empty table" do
      stub_get("/api/usage/calibration", %{
        "window_days" => 60,
        "re_dispatched_flagged" => 0,
        "tiers" => [],
        "flagged" => []
      })

      {out, _err, 0} = capture(fn -> ArbiterCli.Cmd.Usage.run(["--calibration"]) end)

      assert out =~ "no rated closed tasks"
    end
  end

  describe "arb usage (summarize)" do
    test "renders rollup rows in text mode" do
      stub_get("/api/usage", %{
        "by" => "day",
        "data" => [
          %{
            "group" => "2026-06-01",
            "rows" => 2,
            "total_cost_usd" => 1.2345,
            "tokens_in" => 1000,
            "tokens_out" => 500,
            "cache_creation_tokens" => 10,
            "cache_read_tokens" => 20,
            "duration_ms" => 12_500
          }
        ]
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Usage.run([]) end)
      assert code == 0
      assert out =~ "Usage rollup by day"
      assert out =~ "2026-06-01"
      assert out =~ "1.2345"
      assert out =~ "1000"
    end

    test "--json mode emits the raw payload" do
      stub_get("/api/usage", %{"by" => "task", "data" => [%{"group" => "bd-1", "rows" => 1}]})

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["--by", "task", "--json"]) end)

      assert code == 0
      decoded = Jason.decode!(out)
      assert decoded["by"] == "task"
    end

    test "empty results say so" do
      stub_get("/api/usage", %{"by" => "day", "data" => []})
      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Usage.run([]) end)
      assert code == 0
      assert out =~ "(no usage rows for --by day)"
    end
  end

  describe "arb usage --by session" do
    test "renders one row per session" do
      stub_get("/api/usage", %{
        "by" => "session",
        "data" => [
          %{
            "group" => "sess-abc123",
            "rows" => 4,
            "total_cost_usd" => 9.7842,
            "tokens_in" => 42_000,
            "tokens_out" => 18_500,
            "cache_creation_tokens" => 100,
            "cache_read_tokens" => 900,
            "duration_ms" => 3_600_000
          }
        ]
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["--by", "session"]) end)

      assert code == 0
      assert out =~ "Usage rollup by session"
      assert out =~ "sess-abc123"
      assert out =~ "9.7842"
    end
  end

  describe "arb usage --session <id>" do
    test "shows that session's events, drilling into /api/usage/events" do
      stub_get("/api/usage/events", %{
        "data" => [
          %{
            "id" => "x",
            "task_id" => nil,
            "source" => "coordinator_session",
            "session_id" => "sess-abc123",
            "step" => "other",
            "model" => "claude-opus-4-7",
            "cost_usd" => 5.0,
            "tokens_in" => 20_000,
            "tokens_out" => 9_000,
            "duration_ms" => 1_800_000,
            "occurred_at" => "2026-09-10T12:00:00Z"
          }
        ]
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["--session", "sess-abc123"]) end)

      assert code == 0
      assert out =~ "Usage events (1)"
      assert out =~ "session=sess-abc123"
      assert out =~ "source=coordinator_session"
    end

    test "`arb usage events --session <id>` also passes the session filter through" do
      stub_routes([
        {{"get", "/api/usage/events"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           assert conn.query_params["session_id"] == "sess-abc123"
           conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
         end}
      ])

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["events", "--session", "sess-abc123"]) end)

      assert code == 0
      assert out =~ "(no usage events)"
    end
  end

  describe "arb usage events" do
    test "lists one line per event in text mode" do
      stub_get("/api/usage/events", %{
        "data" => [
          %{
            "id" => "x",
            "task_id" => "bd-1",
            "step" => "work",
            "model" => "claude-opus-4-7",
            "cost_usd" => 0.4321,
            "tokens_in" => 1000,
            "tokens_out" => 200,
            "duration_ms" => 30_000,
            "occurred_at" => "2026-06-01T12:00:00Z"
          }
        ]
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Usage.run(["events"]) end)
      assert code == 0
      assert out =~ "Usage events (1)"
      assert out =~ "bd-1"
      assert out =~ "claude-opus-4-7"
      assert out =~ "0.4321"
    end
  end

  describe "source discriminator (bd-adyhvn)" do
    test "--by source renders the whole-bill split" do
      stub_get("/api/usage", %{
        "by" => "source",
        "data" => [
          %{"group" => "task", "rows" => 10, "total_cost_usd" => 12.5},
          %{"group" => "probe", "rows" => 243, "total_cost_usd" => 3.08},
          %{"group" => "preflight", "rows" => 322, "total_cost_usd" => 2.05}
        ]
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["--by", "source"]) end)

      assert code == 0
      assert out =~ "Usage rollup by source"
      assert out =~ "probe"
      assert out =~ "preflight"
      assert out =~ "3.08"
    end

    test "events --source is forwarded to the API as a query param" do
      pid = self()

      stub_routes([
        {{"get", "/api/usage/events"},
         fn conn ->
           send(pid, {:query, conn.query_string})
           conn |> Plug.Conn.put_status(200) |> Req.Test.json(%{"data" => []})
         end}
      ])

      {_out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Usage.run(["events", "--source", "probe"]) end)

      assert code == 0
      assert_receive {:query, query}
      assert query =~ "source=probe"
    end

    test "a task-less event line shows its source and a dash for the task" do
      stub_get("/api/usage/events", %{
        "data" => [
          %{
            "occurred_at" => "2026-09-12T10:00:00Z",
            "source" => "probe",
            "task_id" => nil,
            "step" => "other",
            "model" => "claude-opus-5",
            "cost_usd" => 0.25,
            "tokens_in" => 4,
            "tokens_out" => 7,
            "duration_ms" => 1200
          }
        ]
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Usage.run(["events"]) end)

      assert code == 0
      assert out =~ "source=probe"
      assert out =~ "task=-"
    end
  end
end
