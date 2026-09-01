defmodule ArbiterCli.Cmd.QueueTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Queue

  describe "retry-auto-resolve" do
    test "posts to the retry_auto_resolve endpoint and prints confirmation" do
      stub_routes([
        {{"post", "/api/queue/bd-1/retry_auto_resolve"},
         {%{"retried" => true, "task_id" => "bd-1"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["retry-auto-resolve", "bd-1"]) end)

      assert exit_code == 0
      assert out =~ "bd-1"
      assert out =~ "Re-armed"
    end

    test "requires a task id" do
      {_out, err, exit_code} = capture(fn -> Queue.run(["retry-auto-resolve"]) end)

      assert exit_code != 0
      assert err =~ "requires: <task-id>"
    end

    test "reports a friendly error when the task isn't parked on :ci_failed" do
      stub_routes([
        {{"post", "/api/queue/bd-2/retry_auto_resolve"},
         {%{"error" => %{"message" => "nothing to re-arm"}}, 400}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["retry-auto-resolve", "bd-2"]) end)

      assert exit_code != 0
      assert err =~ "not currently parked"
    end

    test "reports a friendly error when no watchdog is running for the task" do
      stub_routes([
        {{"post", "/api/queue/bd-3/retry_auto_resolve"},
         {%{"error" => %{"message" => "not found"}}, 404}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["retry-auto-resolve", "bd-3"]) end)

      assert exit_code != 0
      assert err =~ "no merge watchdog is currently running"
    end

    test "reports a friendly error when the watchdog is busy (mid-poll)" do
      stub_routes([
        {{"post", "/api/queue/bd-5/retry_auto_resolve"},
         {%{"error" => %{"message" => "busy"}}, 503}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["retry-auto-resolve", "bd-5"]) end)

      assert exit_code != 0
      assert err =~ "busy polling"
    end

    # bd-8jixav: this is the exact dead end the incident hit — the watchdog had
    # died, so re-arming 404s. The message must name the command that recovers.
    test "the no-watchdog error points at restart-watchdog" do
      stub_routes([
        {{"post", "/api/queue/bd-9/retry_auto_resolve"},
         {%{"error" => %{"message" => "not found"}}, 404}}
      ])

      {_out, err, _exit_code} = capture(fn -> Queue.run(["retry-auto-resolve", "bd-9"]) end)

      assert err =~ "arb queue restart-watchdog bd-9"
    end

    test "retry_auto_resolve (underscored) is still accepted as an alias" do
      stub_routes([
        {{"post", "/api/queue/bd-4/retry_auto_resolve"},
         {%{"retried" => true, "task_id" => "bd-4"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["retry_auto_resolve", "bd-4"]) end)

      assert exit_code == 0
      assert out =~ "Re-armed"
    end
  end

  describe "restart-watchdog (bd-8jixav)" do
    test "posts to the restart_watchdog endpoint and prints confirmation" do
      stub_routes([
        {{"post", "/api/queue/bd-1/restart_watchdog"},
         {%{"restarted" => true, "task_id" => "bd-1"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["restart-watchdog", "bd-1"]) end)

      assert exit_code == 0
      assert out =~ "bd-1"
      assert out =~ "Restarted"
    end

    test "emits the raw body in --json mode" do
      stub_routes([
        {{"post", "/api/queue/bd-1/restart_watchdog"},
         {%{"restarted" => true, "task_id" => "bd-1"}, 200}}
      ])

      {out, _err, exit_code} =
        capture(fn -> Queue.run(["restart-watchdog", "bd-1", "--json"]) end)

      assert exit_code == 0
      assert Jason.decode!(out) == %{"restarted" => true, "task_id" => "bd-1"}
    end

    test "requires a task id" do
      {_out, err, exit_code} = capture(fn -> Queue.run(["restart-watchdog"]) end)

      assert exit_code != 0
      assert err =~ "requires: <task-id>"
    end

    test "reports a friendly error when no worker is registered" do
      stub_routes([
        {{"post", "/api/queue/bd-2/restart_watchdog"},
         {%{"error" => %{"message" => "no worker"}}, 404}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["restart-watchdog", "bd-2"]) end)

      assert exit_code != 0
      assert err =~ "no worker is running"
      # The fallback it names has to be a command that exists: `arb resume` /
      # `arb worker resume`, never `arb task resume` (there is no task resource).
      assert err =~ "arb worker resume bd-2"
      refute err =~ "arb task resume"
    end

    # Refusing is the point: two watchdogs on one MR race the merge.
    test "reports a friendly error when a watchdog is already running" do
      stub_routes([
        {{"post", "/api/queue/bd-3/restart_watchdog"},
         {%{"error" => %{"message" => "already running"}}, 409}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["restart-watchdog", "bd-3"]) end)

      assert exit_code != 0
      assert err =~ "already running"
      assert err =~ "Nothing to restart"
    end

    test "surfaces the server message when the worker is not parked" do
      stub_routes([
        {{"post", "/api/queue/bd-4/restart_watchdog"},
         {%{"error" => %{"message" => "task bd-4's worker is running, not awaiting_review"}}, 400}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["restart-watchdog", "bd-4"]) end)

      assert exit_code != 0
      assert err =~ "not awaiting_review"
    end

    test "reports a friendly error when the worker is busy" do
      stub_routes([
        {{"post", "/api/queue/bd-5/restart_watchdog"},
         {%{"error" => %{"message" => "busy"}}, 503}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["restart-watchdog", "bd-5"]) end)

      assert exit_code != 0
      assert err =~ "did not answer in time"
    end

    test "restart_watchdog (underscored) is accepted as an alias" do
      stub_routes([
        {{"post", "/api/queue/bd-6/restart_watchdog"},
         {%{"restarted" => true, "task_id" => "bd-6"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["restart_watchdog", "bd-6"]) end)

      assert exit_code == 0
      assert out =~ "Restarted"
    end

    test "--help documents the subcommand" do
      {out, _err, exit_code} = capture(fn -> Queue.run(["--help"]) end)

      assert exit_code == 0
      assert out =~ "restart-watchdog"
    end
  end

  describe "rerun-ci (bd-5mzzww / #1448)" do
    test "posts to the rerun_ci endpoint and reports the granularity actually used" do
      stub_routes([
        {{"post", "/api/queue/bd-r1/rerun_ci"},
         {%{
            "rerun" => true,
            "task_id" => "bd-r1",
            "mode" => "all_jobs",
            "run_id" => 42,
            "workflow" => "CI",
            "rationale" => "2 completed upstream job(s) would be reused"
          }, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["rerun-ci", "bd-r1"]) end)

      assert exit_code == 0
      assert out =~ "bd-r1"
      assert out =~ "all_jobs"
      # The operator must be able to see WHY, or they will reach for the
      # failed-jobs button again next time.
      assert out =~ "reused"
    end

    test "passes an explicit --mode through" do
      stub_routes([
        {{"post", "/api/queue/bd-r2/rerun_ci"},
         {%{"rerun" => true, "task_id" => "bd-r2", "mode" => "workflow"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["rerun-ci", "bd-r2", "--mode", "workflow"]) end)

      assert exit_code == 0
      assert out =~ "workflow"
    end

    test "requires a task id" do
      {_out, err, exit_code} = capture(fn -> Queue.run(["rerun-ci"]) end)

      assert exit_code != 0
      assert err =~ "requires: <task-id>"
    end

    test "reports a friendly error when no watchdog is running" do
      stub_routes([
        {{"post", "/api/queue/bd-r3/rerun_ci"}, {%{"errors" => %{"detail" => "Not Found"}}, 404}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["rerun-ci", "bd-r3"]) end)

      assert exit_code != 0
      assert err =~ "no merge watchdog"
      assert err =~ "restart-watchdog"
    end

    test "emits the raw body in --json mode" do
      stub_routes([
        {{"post", "/api/queue/bd-r4/rerun_ci"},
         {%{"rerun" => true, "task_id" => "bd-r4", "mode" => "failed_jobs"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["rerun-ci", "bd-r4", "--json"]) end)

      assert exit_code == 0
      assert {:ok, %{"mode" => "failed_jobs"}} = Jason.decode(String.trim(out))
    end

    test "--help documents the subcommand and the granularity trap" do
      {out, _err, exit_code} = capture(fn -> Queue.run(["--help"]) end)

      assert exit_code == 0
      assert out =~ "rerun-ci"
      assert out =~ "all_jobs"
    end
  end

  describe "mark-ci-external (bd-5mzzww / #1448)" do
    test "posts the note and confirms the reclassification" do
      stub_routes([
        {{"post", "/api/queue/bd-x1/mark_ci_external"},
         {%{"marked" => true, "task_id" => "bd-x1", "park_reason" => "ci_failed_external"}, 200}}
      ])

      {out, _err, exit_code} =
        capture(fn -> Queue.run(["mark-ci-external", "bd-x1", "shared runner outage"]) end)

      assert exit_code == 0
      assert out =~ "bd-x1"
      assert out =~ "ci_failed_external"
    end

    test "requires a task id and a note" do
      {_out, err, code} = capture(fn -> Queue.run(["mark-ci-external"]) end)
      assert code != 0
      assert err =~ "requires: <task-id> <note>"

      {_out, err2, code2} = capture(fn -> Queue.run(["mark-ci-external", "bd-x2"]) end)
      assert code2 != 0
      assert err2 =~ "requires: <task-id> <note>"
    end

    test "reports a friendly error when the task is not parked on :ci_failed" do
      stub_routes([
        {{"post", "/api/queue/bd-x3/mark_ci_external"},
         {%{"error" => %{"message" => "nothing to reclassify"}}, 400}}
      ])

      {_out, err, exit_code} =
        capture(fn -> Queue.run(["mark-ci-external", "bd-x3", "infra down"]) end)

      assert exit_code != 0
      assert err =~ "nothing to reclassify"
    end
  end
end
