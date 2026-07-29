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
    stub_get("/api/loop/analyze", %{"markdown" => "# report", "usage_event_id" => "e", "summary" => %{}})
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
         Req.Test.json(conn, %{"markdown" => "# report", "usage_event_id" => "x", "summary" => %{}})
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--since", "24h"]) end)
    assert exit_code == 0
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
