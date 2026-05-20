defmodule GtElixirCli.Cmd.SlingTest do
  use GtElixirCli.CliCase, async: false

  describe "bd2 sling" do
    test "missing bead-id fails with usage hint" do
      {_out, err, code} = capture(fn -> GtElixirCli.Cmd.Sling.run([]) end)
      assert err =~ "sling requires an issue id"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> GtElixirCli.Cmd.Sling.run(["a", "b", "c"]) end)
      assert err =~ "at most two positional"
      assert code != 0
    end

    test "happy path posts to /api/polecats/sling and renders text" do
      stub_post(
        "/api/polecats/sling",
        %{
          "bead" => %{"id" => "gte-017", "title" => "sling cmd", "status" => "in_progress"},
          "polecat" => %{"bead_id" => "gte-017", "pid" => "#PID<0.123.0>"},
          "machine" => %{"id" => "mc-1", "pid" => "#PID<0.124.0>"}
        }
      )

      {out, _err, code} = capture(fn -> GtElixirCli.Cmd.Sling.run(["gte-017"]) end)
      assert code == 0
      assert out =~ "Slung:"
      assert out =~ "gte-017 — sling cmd"
      assert out =~ "in_progress"
      assert out =~ "#PID<0.123.0>"
    end

    test "passes rig in body when provided" do
      stub_post("/api/polecats/sling", %{
        "bead" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
        "polecat" => %{"bead_id" => "gte-017", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} =
        capture(fn -> GtElixirCli.Cmd.Sling.run(["gte-017", "verus_server"]) end)

      assert code == 0
      assert out =~ "Slung:"
    end

    test "--json mode emits JSON" do
      stub_post("/api/polecats/sling", %{
        "bead" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
        "polecat" => %{"bead_id" => "gte-017", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} = capture(fn -> GtElixirCli.Cmd.Sling.run(["gte-017", "--json"]) end)
      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["bead"]["id"] == "gte-017"
    end

    test "404 propagates as die" do
      stub_post(
        "/api/polecats/sling",
        %{"error" => %{"type" => "not_found", "message" => "bead not found"}},
        404
      )

      {_out, err, code} = capture(fn -> GtElixirCli.Cmd.Sling.run(["nope-1"]) end)
      assert code != 0
      assert err =~ "not found" || err =~ "404"
    end
  end
end
