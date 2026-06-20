defmodule ArbiterCli.Cmd.ReviewTest do
  use ArbiterCli.CliCase, async: false

  describe "arb review" do
    test "missing task-id fails with usage hint" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run([]) end)
      assert err =~ "review requires a task id"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["a", "b"]) end)
      assert err =~ "single positional"
      assert code != 0
    end

    test "happy path posts to /api/workers/review and renders text" do
      stub_post(
        "/api/workers/review",
        %{
          "task" => %{"id" => "bd-rev1", "title" => "review me", "status" => "in_progress"},
          "worker" => %{"task_id" => "bd-rev1", "pid" => "#PID<0.123.0>"},
          "machine" => %{"id" => "mc-1", "pid" => "#PID<0.124.0>"},
          "worktree_path" => nil,
          "claude_started" => true
        }
      )

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["bd-rev1"]) end)
      assert code == 0
      assert out =~ "Review dispatched:"
      assert out =~ "bd-rev1 — review me"
      assert out =~ "in_progress"
      assert out =~ "Claude:   started"
    end

    test "--json mode emits JSON" do
      stub_post("/api/workers/review", %{
        "task" => %{"id" => "bd-rev1", "title" => "t", "status" => "in_progress"},
        "worker" => %{"task_id" => "bd-rev1", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Review.run(["bd-rev1", "--json"]) end)

      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["task"]["id"] == "bd-rev1"
    end

    test "passes --repo and --model in body when provided" do
      parent = self()
      name = Process.get(:bd2_stub_name)

      Req.Test.stub(name, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/workers/review"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "task" => %{"id" => "bd-rev1", "title" => "t", "status" => "in_progress"},
              "worker" => %{"task_id" => "bd-rev1", "pid" => "x"},
              "machine" => %{"id" => "m", "pid" => "y"}
            })

          _ ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
        end
      end)

      {_out, _err, code} =
        capture(fn ->
          ArbiterCli.Cmd.Review.run(["bd-rev1", "--repo", "verus_server", "--model", "haiku"])
        end)

      assert code == 0
      assert_receive {:body, body}
      assert body["task_id"] == "bd-rev1"
      assert body["repo"] == "verus_server"
      assert body["model"] == "haiku"
    end

    test "404 propagates as die" do
      stub_post(
        "/api/workers/review",
        %{"error" => %{"type" => "not_found", "message" => "task not found"}},
        404
      )

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Review.run(["nope-1"]) end)
      assert code != 0
      assert err =~ "not found" || err =~ "404"
    end
  end
end
