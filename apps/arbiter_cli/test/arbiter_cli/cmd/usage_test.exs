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
end
