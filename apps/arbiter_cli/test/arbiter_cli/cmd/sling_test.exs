defmodule ArbiterCli.Cmd.SlingTest do
  use ArbiterCli.CliCase, async: false

  describe "arb sling" do
    test "missing bead-id fails with usage hint" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Sling.run([]) end)
      assert err =~ "sling requires an issue id"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Sling.run(["a", "b", "c"]) end)
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

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Sling.run(["gte-017"]) end)
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
        capture(fn -> ArbiterCli.Cmd.Sling.run(["gte-017", "verus_server"]) end)

      assert code == 0
      assert out =~ "Slung:"
    end

    test "--json mode emits JSON" do
      stub_post("/api/polecats/sling", %{
        "bead" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
        "polecat" => %{"bead_id" => "gte-017", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Sling.run(["gte-017", "--json"]) end)
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

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Sling.run(["nope-1"]) end)
      assert code != 0
      assert err =~ "not found" || err =~ "404"
    end

    test "--model and --review-model are sent in the request body" do
      parent = self()

      stub_routes([
        {{"post", "/api/polecats/sling"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:body, body})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "bead" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
             "polecat" => %{"bead_id" => "gte-017", "pid" => "x"},
             "machine" => %{"id" => "m", "pid" => "y"}
           })
         end}
      ])

      {_out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Sling.run([
            "gte-017",
            "--model",
            "haiku",
            "--review-model",
            "opus"
          ])
        end)

      assert code == 0

      assert_receive {:body, raw}, 1_000
      assert {:ok, body} = Jason.decode(raw)
      assert body["model"] == "haiku"
      assert body["review_model"] == "opus"
    end

    test "model flags absent → body has no model keys (workspace policy applies on server)" do
      parent = self()

      stub_routes([
        {{"post", "/api/polecats/sling"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(parent, {:body, body})

           conn
           |> Plug.Conn.put_status(201)
           |> Req.Test.json(%{
             "bead" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
             "polecat" => %{"bead_id" => "gte-017", "pid" => "x"},
             "machine" => %{"id" => "m", "pid" => "y"}
           })
         end}
      ])

      {_out, _err, code} = capture(fn -> ArbiterCli.Cmd.Sling.run(["gte-017"]) end)
      assert code == 0

      assert_receive {:body, raw}, 1_000
      assert {:ok, body} = Jason.decode(raw)
      refute Map.has_key?(body, "model")
      refute Map.has_key?(body, "review_model")
    end
  end
end
