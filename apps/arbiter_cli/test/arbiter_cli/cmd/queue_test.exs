defmodule ArbiterCli.Cmd.QueueTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Queue

  describe "retry_auto_resolve" do
    test "posts to the retry_auto_resolve endpoint and prints confirmation" do
      stub_routes([
        {{"post", "/api/queue/bd-1/retry_auto_resolve"},
         {%{"retried" => true, "task_id" => "bd-1"}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Queue.run(["retry_auto_resolve", "bd-1"]) end)

      assert exit_code == 0
      assert out =~ "bd-1"
      assert out =~ "Re-armed"
    end

    test "requires a task id" do
      {_out, err, exit_code} = capture(fn -> Queue.run(["retry_auto_resolve"]) end)

      assert exit_code != 0
      assert err =~ "requires: <task-id>"
    end

    test "reports a friendly error when the task isn't parked on :ci_failed" do
      stub_routes([
        {{"post", "/api/queue/bd-2/retry_auto_resolve"},
         {%{"error" => %{"message" => "nothing to re-arm"}}, 400}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["retry_auto_resolve", "bd-2"]) end)

      assert exit_code != 0
      assert err =~ "not currently parked"
    end

    test "reports a friendly error when no watchdog is running for the task" do
      stub_routes([
        {{"post", "/api/queue/bd-3/retry_auto_resolve"}, {%{"error" => %{"message" => "not found"}}, 404}}
      ])

      {_out, err, exit_code} = capture(fn -> Queue.run(["retry_auto_resolve", "bd-3"]) end)

      assert exit_code != 0
      assert err =~ "no merge watchdog is currently running"
    end
  end
end
