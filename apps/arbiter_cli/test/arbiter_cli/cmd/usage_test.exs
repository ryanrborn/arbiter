defmodule ArbiterCli.Cmd.UsageTest do
  use ArbiterCli.CliCase, async: false

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
