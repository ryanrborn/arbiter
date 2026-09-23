defmodule ArbiterCli.Cmd.SchedulerTest do
  @moduledoc """
  bd-9fgg04 / #1903: `arb scheduler status` must tell "paused and still
  draining" from "paused and quiescent", and `arb scheduler wait` blocks until
  the second holds.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Scheduler

  @now DateTime.utc_now() |> DateTime.to_iso8601()

  defp body(state, in_flight \\ []) do
    %{
      "state" => state,
      "paused" => state != "running",
      "safe_to_restart" => state == "quiescent",
      "changed_at" => @now,
      "changed_by" => "cli",
      "in_flight" => in_flight,
      "parked" => [],
      "checked_at" => @now
    }
  end

  defp fix_pass do
    %{
      "kind" => "fix_pass",
      "task_id" => "bd-77j2if",
      "registry_key" => "bd-77j2if:fixpass",
      "status" => "running",
      "agent_live" => true,
      "started_at" => DateTime.utc_now() |> DateTime.add(-300) |> DateTime.to_iso8601(),
      "detail" => nil
    }
  end

  # Answers each GET /api/scheduler/status with the next body in `bodies`,
  # repeating the last one.
  defp stub_status_sequence(bodies) do
    counter = :counters.new(1, [])

    stub_routes([
      {{"get", "/api/scheduler/status"},
       fn conn ->
         :counters.add(counter, 1, 1)
         n = :counters.get(counter, 1)
         Req.Test.json(conn, Enum.at(bodies, n - 1, List.last(bodies)))
       end}
    ])

    counter
  end

  setup do
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    :ok
  end

  describe "status" do
    test "paused and draining names what is still in flight and says it is not safe" do
      stub_get("/api/scheduler/status", body("draining", [fix_pass()]))

      {out, _err, exit_code} = capture(fn -> Scheduler.run(["status"]) end)

      assert exit_code == 0
      assert out =~ "paused, draining"
      assert out =~ "NOT safe to restart"
      assert out =~ "fix_pass"
      assert out =~ "bd-77j2if"
      assert out =~ "5m"
    end

    test "paused and quiescent says safe to restart" do
      stub_get("/api/scheduler/status", body("quiescent"))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "paused, quiescent"
      assert out =~ "safe to restart"
    end

    test "running is not a safe restart point" do
      stub_get("/api/scheduler/status", body("running"))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "running"
      assert out =~ "not a safe restart point"
    end

    test "a server that predates the drain state is reported unknown, never safe" do
      stub_get("/api/scheduler/status", %{
        "paused" => true,
        "changed_at" => nil,
        "changed_by" => nil
      })

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "drain state unknown"
      refute out =~ "safe to restart"
    end

    test "--json passes the server body through" do
      stub_get("/api/scheduler/status", body("draining", [fix_pass()]))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status", "--json"]) end)

      assert %{"state" => "draining", "in_flight" => [%{"kind" => "fix_pass"}]} =
               Jason.decode!(out)
    end
  end

  describe "wait" do
    test "polls through draining and exits 0 once quiescent" do
      counter =
        stub_status_sequence([
          body("draining", [fix_pass()]),
          body("draining", [fix_pass()]),
          body("quiescent")
        ])

      {out, _err, exit_code} = capture(fn -> Scheduler.run(["wait", "--interval", "1"]) end)

      assert exit_code == 0
      assert :counters.get(counter, 1) == 3
      assert out =~ "Waiting: paused, draining"
      assert out =~ "paused, quiescent"
      # The unchanged in-flight list is printed once, not on every poll.
      assert length(String.split(out, "Waiting:")) == 2
    end

    test "gives up with exit 124 when the drain outlasts --timeout" do
      stub_status_sequence([body("draining", [fix_pass()])])

      {out, _err, exit_code} = capture(fn -> Scheduler.run(["wait", "--timeout", "0"]) end)

      assert exit_code == 124
      assert out =~ "Timed out"
      assert out =~ "bd-77j2if"
    end

    test "refuses to wait on a running scheduler — exit 2, pause first" do
      stub_status_sequence([body("running")])

      {_out, err, exit_code} = capture(fn -> Scheduler.run(["wait"]) end)

      assert exit_code == 2
      assert err =~ "arb scheduler pause"
    end

    test "does not treat an older server's bare paused flag as quiescent" do
      stub_status_sequence([%{"paused" => true}])

      {_out, err, exit_code} = capture(fn -> Scheduler.run(["wait"]) end)

      assert exit_code == 1
      assert err =~ "drain state unknown"
    end

    test "--json emits only the final body" do
      stub_status_sequence([body("draining", [fix_pass()]), body("quiescent")])

      {out, _err, 0} = capture(fn -> Scheduler.run(["wait", "--json"]) end)

      assert %{"state" => "quiescent", "safe_to_restart" => true} = Jason.decode!(out)
    end
  end

  describe "pause" do
    test "reports the drain state it lands in" do
      stub_post("/api/scheduler/pause", body("draining", [fix_pass()]), 200)

      {out, _err, 0} = capture(fn -> Scheduler.run(["pause"]) end)

      assert out =~ "Board scheduler paused"
      assert out =~ "paused, draining"
      assert out =~ "fix_pass"
    end
  end
end
