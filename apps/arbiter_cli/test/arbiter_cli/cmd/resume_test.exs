defmodule ArbiterCli.Cmd.ResumeTest do
  use ArbiterCli.CliCase, async: false

  # bd-1z7624: `arb worker resume` (and the top-level `arb resume` alias) route
  # through the worker subcommand dispatcher to POST /api/workers/:task_id/resume.
  # These drive the real wired path — ArbiterCli.Cmd.Worker.run(["resume", ...]).
  defp run_resume(args), do: ArbiterCli.Cmd.Worker.run(["resume" | args])

  describe "arb worker resume" do
    test "missing task-id fails with usage hint" do
      {_out, err, code} = capture(fn -> run_resume([]) end)
      assert err =~ "worker resume requires"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> run_resume(["a", "b", "c"]) end)
      assert err =~ "at most"
      assert code != 0
    end

    test "happy path posts to /api/workers/:task_id/resume and renders text" do
      stub_post(
        "/api/workers/bd-1z7624/resume",
        %{
          "task" => %{"id" => "bd-1z7624", "title" => "resume cmd", "status" => "in_progress"},
          "worker" => %{"task_id" => "bd-1z7624", "pid" => "#PID<0.123.0>"},
          "machine" => %{"id" => "mc-1", "pid" => "#PID<0.124.0>"},
          "worktree_path" => "/wt/feature-bd-1z7624",
          "claude_started" => true
        }
      )

      {out, _err, code} = capture(fn -> run_resume(["bd-1z7624"]) end)
      assert code == 0
      assert out =~ "Resume:"
      assert out =~ "bd-1z7624 — resume cmd"
      assert out =~ "(reused)"
      assert out =~ "resumed"
    end

    test "--json mode emits JSON" do
      stub_post("/api/workers/bd-1/resume", %{
        "task" => %{"id" => "bd-1", "title" => "t", "status" => "in_progress"},
        "worker" => %{"task_id" => "bd-1", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} = capture(fn -> run_resume(["bd-1", "--json"]) end)
      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["task"]["id"] == "bd-1"
    end

    test "error response propagates as die" do
      stub_post(
        "/api/workers/bd-x/resume",
        %{
          "error" => %{
            "type" => "invalid_request",
            "message" => "no prior Claude session recorded for this task"
          }
        },
        422
      )

      {_out, err, code} = capture(fn -> run_resume(["bd-x"]) end)
      assert code != 0
      assert err =~ "session" || err =~ "422"
    end

    test "repo and --model forward in the request body" do
      parent = self()
      name = Process.get(:bd2_stub_name)

      Req.Test.stub(name, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/workers/bd-9/resume"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "task" => %{"id" => "bd-9", "title" => "t", "status" => "in_progress"},
              "worker" => %{"task_id" => "bd-9", "pid" => "x"},
              "machine" => %{"id" => "m", "pid" => "y"}
            })

          _ ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
        end
      end)

      {_out, _err, code} =
        capture(fn -> run_resume(["bd-9", "my/repo", "--model", "opus"]) end)

      assert code == 0
      assert_receive {:body, body}
      assert body["repo"] == "my/repo"
      assert body["model"] == "opus"
    end
  end
end
