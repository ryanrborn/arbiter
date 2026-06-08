defmodule ArbiterCli.Cmd.WorkerTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Worker

  test "list routes to the polecats index" do
    stub_get("/api/polecats", %{"data" => []})
    {out, _err, code} = capture(fn -> Worker.run(["list", "--json"]) end)
    assert code == 0
    assert out =~ "data"
  end

  test "show routes to the polecat snapshot" do
    stub_get("/api/polecats/bd-1", %{"bead_id" => "bd-1", "status" => "running"})
    {out, _err, code} = capture(fn -> Worker.run(["show", "bd-1", "--json"]) end)
    assert code == 0
    assert out =~ "bd-1"
  end

  test "stop routes to the polecat stop endpoint" do
    stub_post("/api/polecats/bd-1/stop", %{"bead_id" => "bd-1"})
    {out, _err, code} = capture(fn -> Worker.run(["stop", "bd-1", "--json"]) end)
    assert code == 0
    assert out =~ "bd-1"
  end

  test "resume routes to the resume endpoint" do
    stub_post("/api/polecats/bd-1/resume", %{"bead_id" => "bd-1"})
    {_out, _err, code} = capture(fn -> Worker.run(["resume", "bd-1", "--json"]) end)
    assert code == 0
  end

  test "unknown subcommand errors" do
    {_out, err, code} = capture(fn -> Worker.run(["frobnicate"]) end)
    assert code == 1
    assert err =~ "unknown worker subcommand"
  end
end
