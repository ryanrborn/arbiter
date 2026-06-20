defmodule ArbiterCli.Cmd.WorkerTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Worker

  describe "worker show" do
    test "prints the snapshot and output lines" do
      stub_get("/api/workers/bd-001", %{
        "task_id" => "bd-001",
        "status" => "running",
        "current_step" => "implement",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:00:00Z",
        "output_lines" => ["hello", "world", "arb done"]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-001"]) end)
      assert exit_code == 0
      assert out =~ "bd-001"
      assert out =~ "running"
      assert out =~ "hello"
      assert out =~ "arb done"
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["show"]) end)
      assert exit_code != 0
    end

    test "flags a historical fallback run and shows completion time" do
      stub_get("/api/workers/bd-003", %{
        "source" => "history",
        "task_id" => "bd-003",
        "status" => "failed",
        "current_step" => nil,
        "repo" => "arbiter",
        "started_at" => "2026-05-20T19:00:00Z",
        "completed_at" => "2026-05-20T19:05:00Z",
        "exit_status" => 2,
        "failure_reason" => "claude_crashed",
        "output_lines" => ["boom"]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-003"]) end)
      assert exit_code == 0
      assert out =~ "no live worker"
      assert out =~ "historical run"
      assert out =~ "Completed:  2026-05-20T19:05:00Z"
      assert out =~ "claude_crashed"
      assert out =~ "boom"
    end

    test "uses the plain worker/issue/repo labels" do
      stub_get("/api/workers/bd-004", %{
        "source" => "history",
        "task_id" => "bd-004",
        "status" => "failed",
        "repo" => "arbiter",
        "started_at" => "2026-05-20T19:00:00Z",
        "output_lines" => []
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-004"]) end)
      assert exit_code == 0
      assert out =~ "no live worker"
      assert out =~ "Issue:"
      assert out =~ "Repo:"
    end

    test "--json forwards the full snapshot" do
      stub_get("/api/workers/bd-002", %{
        "task_id" => "bd-002",
        "status" => "completed",
        "output_lines" => ["ok"]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-002", "--json"]) end)
      assert exit_code == 0
      assert {:ok, %{"task_id" => "bd-002"}} = Jason.decode(String.trim(out))
    end
  end

  describe "worker list" do
    test "renders a table of active workers" do
      stub_get("/api/workers", %{
        "data" => [
          %{
            "task_id" => "bd-001",
            "status" => "running",
            "current_step" => "implement",
            "repo" => "test/repo",
            "started_at" => "2026-05-20T19:00:00Z"
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["list"]) end)
      assert exit_code == 0
      assert out =~ "Active workers (1)"
      assert out =~ "bd-001"
      assert out =~ "status=running"
    end

    test "(none) when no active workers" do
      stub_get("/api/workers", %{"data" => []})

      {out, _err, exit_code} = capture(fn -> Worker.run(["list"]) end)
      assert exit_code == 0
      assert out =~ "no active workers"
    end

    test "ls is an alias for list" do
      stub_get("/api/workers", %{"data" => []})

      {out, _err, exit_code} = capture(fn -> Worker.run(["ls"]) end)
      assert exit_code == 0
      assert out =~ "no active workers"
    end
  end

  describe "worker stop" do
    test "POSTs to the stop endpoint" do
      stub_post("/api/workers/bd-003/stop", %{"task_id" => "bd-003", "stopped" => true})

      {out, _err, exit_code} = capture(fn -> Worker.run(["stop", "bd-003"]) end)
      assert exit_code == 0
      assert out =~ "Stopped worker"
      assert out =~ "bd-003"
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["stop"]) end)
      assert exit_code != 0
    end
  end

  describe "worker log" do
    test "prints the run metadata and the full durable transcript, oldest first" do
      stub_get("/api/workers/bd-005/log", %{
        "data" => %{
          "task_id" => "bd-005",
          "run_id" => "run-abc",
          "path" => "/var/arbiter/worker-logs/run-abc.log",
          "exists" => true,
          "line_count" => 3,
          "lines" => ["first", "second", "third"]
        }
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["log", "bd-005"]) end)
      assert exit_code == 0
      assert out =~ "bd-005"
      assert out =~ "run-abc"
      assert out =~ "/var/arbiter/worker-logs/run-abc.log"
      assert out =~ "Full transcript (3 lines"
      assert out =~ "first"
      assert out =~ "third"
    end

    test "reports when no durable transcript exists on disk" do
      stub_get("/api/workers/bd-006/log", %{
        "data" => %{
          "task_id" => "bd-006",
          "run_id" => "run-xyz",
          "path" => "/var/arbiter/worker-logs/run-xyz.log",
          "exists" => false,
          "line_count" => 0,
          "lines" => []
        }
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["log", "bd-006"]) end)
      assert exit_code == 0
      assert out =~ "no durable transcript"
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["log"]) end)
      assert exit_code != 0
    end
  end

  describe "unknown subcommand" do
    test "halts with a useful message" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["wat"]) end)
      assert exit_code != 0
    end

    test "no subcommand at all halts" do
      {_out, _err, exit_code} = capture(fn -> Worker.run([]) end)
      assert exit_code != 0
    end
  end
end
