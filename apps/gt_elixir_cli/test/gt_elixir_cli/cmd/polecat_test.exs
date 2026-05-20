defmodule GtElixirCli.Cmd.PolecatTest do
  use GtElixirCli.CliCase, async: true

  alias GtElixirCli.Cmd.Polecat

  describe "polecat show" do
    test "prints the snapshot and output lines" do
      stub_get("/api/polecats/bd-001", %{
        "bead_id" => "bd-001",
        "status" => "running",
        "current_step" => "implement",
        "rig" => "test/rig",
        "started_at" => "2026-05-20T19:00:00Z",
        "output_lines" => ["hello", "world", "gt done"]
      })

      {out, _err, exit_code} = capture(fn -> Polecat.run(["show", "bd-001"]) end)
      assert exit_code == 0
      assert out =~ "bd-001"
      assert out =~ "running"
      assert out =~ "hello"
      assert out =~ "gt done"
    end

    test "missing bead_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Polecat.run(["show"]) end)
      assert exit_code != 0
    end

    test "--json forwards the full snapshot" do
      stub_get("/api/polecats/bd-002", %{
        "bead_id" => "bd-002",
        "status" => "completed",
        "output_lines" => ["ok"]
      })

      {out, _err, exit_code} = capture(fn -> Polecat.run(["show", "bd-002", "--json"]) end)
      assert exit_code == 0
      assert {:ok, %{"bead_id" => "bd-002"}} = Jason.decode(String.trim(out))
    end
  end

  describe "polecat stop" do
    test "POSTs to the stop endpoint" do
      stub_post("/api/polecats/bd-003/stop", %{"bead_id" => "bd-003", "stopped" => true})

      {out, _err, exit_code} = capture(fn -> Polecat.run(["stop", "bd-003"]) end)
      assert exit_code == 0
      assert out =~ "Stopped polecat"
      assert out =~ "bd-003"
    end

    test "missing bead_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Polecat.run(["stop"]) end)
      assert exit_code != 0
    end
  end

  describe "unknown subcommand" do
    test "halts with a useful message" do
      {_out, _err, exit_code} = capture(fn -> Polecat.run(["wat"]) end)
      assert exit_code != 0
    end

    test "no subcommand at all halts" do
      {_out, _err, exit_code} = capture(fn -> Polecat.run([]) end)
      assert exit_code != 0
    end
  end
end
