defmodule ArbiterCli.Cmd.DispatchTest do
  use ArbiterCli.CliCase, async: false

  describe "arb dispatch" do
    test "missing task-id fails with usage hint" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run([]) end)
      assert err =~ "dispatch requires an issue id"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run(["a", "b", "c"]) end)
      assert err =~ "at most two positional"
      assert code != 0
    end

    test "happy path posts to /api/workers/dispatch and renders text" do
      stub_post(
        "/api/workers/dispatch",
        %{
          "task" => %{"id" => "gte-017", "title" => "dispatch cmd", "status" => "in_progress"},
          "worker" => %{"task_id" => "gte-017", "pid" => "#PID<0.123.0>"},
          "machine" => %{"id" => "mc-1", "pid" => "#PID<0.124.0>"}
        }
      )

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017"]) end)
      assert code == 0
      assert out =~ "Dispatch:"
      assert out =~ "gte-017 — dispatch cmd"
      assert out =~ "in_progress"
      assert out =~ "#PID<0.123.0>"
    end

    test "passes repo in body when provided" do
      stub_post("/api/workers/dispatch", %{
        "task" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
        "worker" => %{"task_id" => "gte-017", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "verus_server"]) end)

      assert code == 0
      assert out =~ "Dispatch:"
    end

    test "--json mode emits JSON" do
      stub_post("/api/workers/dispatch", %{
        "task" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
        "worker" => %{"task_id" => "gte-017", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "--json"]) end)
      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["task"]["id"] == "gte-017"
    end

    # Stubs POST /api/workers/dispatch, captures the request body, and forwards
    # any other request as 500/JSON.
    defp stub_dispatch_capture do
      parent = self()
      name = Process.get(:bd2_stub_name)

      Req.Test.stub(name, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/workers/dispatch"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "task" => %{"id" => "gte-017", "title" => "t", "status" => "in_progress"},
              "worker" => %{"task_id" => "gte-017", "pid" => "x"},
              "machine" => %{"id" => "m", "pid" => "y"}
            })

          _ ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
        end
      end)
    end

    test "404 propagates as die" do
      stub_post(
        "/api/workers/dispatch",
        %{"error" => %{"type" => "not_found", "message" => "task not found"}},
        404
      )

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run(["nope-1"]) end)
      assert code != 0
      assert err =~ "not found" || err =~ "404"
    end

    test "--model forwards as `model` in the POST body" do
      stub_dispatch_capture()

      {_out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Dispatch.run(["gte-017", "--with-claude", "--model", "haiku"])
        end)

      assert code == 0
      assert_receive {:body, body}
      assert body["task_id"] == "gte-017"
      assert body["with_claude"] == true
      assert body["model"] == "haiku"
    end

    test "without --model the request body omits the model key" do
      stub_dispatch_capture()

      {_out, _err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017"]) end)

      assert code == 0
      assert_receive {:body, body}
      refute Map.has_key?(body, "model")
    end

    test "--with-gemini sends with_gemini: true in the POST body" do
      stub_dispatch_capture()

      {_out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "--with-gemini"]) end)

      assert code == 0
      assert_receive {:body, body}
      assert body["with_gemini"] == true
      refute Map.has_key?(body, "with_claude")
      refute Map.has_key?(body, "no_agent")
    end

    test "--no-agent sends no_agent: true in the POST body" do
      stub_dispatch_capture()

      {_out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "--no-agent"]) end)

      assert code == 0
      assert_receive {:body, body}
      assert body["no_agent"] == true
      refute Map.has_key?(body, "with_claude")
      refute Map.has_key?(body, "with_gemini")
    end

    test "bare dispatch (no worker flag) sends no worker key — server uses workspace agent.type" do
      stub_dispatch_capture()

      {_out, _err, code} = capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017"]) end)

      assert code == 0
      assert_receive {:body, body}
      refute Map.has_key?(body, "with_claude")
      refute Map.has_key?(body, "with_gemini")
      refute Map.has_key?(body, "no_agent")
      refute Map.has_key?(body, "provider")
    end

    test "--provider gemini sends provider: gemini in the POST body" do
      stub_dispatch_capture()

      {_out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "--provider", "gemini"]) end)

      assert code == 0
      assert_receive {:body, body}
      assert body["provider"] == "gemini"
      refute Map.has_key?(body, "with_claude")
      refute Map.has_key?(body, "with_gemini")
    end

    test "--provider claude sends provider: claude in the POST body" do
      stub_dispatch_capture()

      {_out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "--provider", "claude"]) end)

      assert code == 0
      assert_receive {:body, body}
      assert body["provider"] == "claude"
    end

    test "--provider takes precedence over the deprecated --with-gemini alias" do
      stub_dispatch_capture()

      {_out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Dispatch.run(["gte-017", "--provider", "claude", "--with-gemini"])
        end)

      assert code == 0
      assert_receive {:body, body}
      assert body["provider"] == "claude"
      refute Map.has_key?(body, "with_gemini")
    end

    test "an unknown --provider value dies with a usage hint" do
      {_out, err, code} =
        capture(fn -> ArbiterCli.Cmd.Dispatch.run(["gte-017", "--provider", "llama"]) end)

      assert code != 0
      assert err =~ "--provider must be one of"
    end
  end
end
