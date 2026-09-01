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
end
