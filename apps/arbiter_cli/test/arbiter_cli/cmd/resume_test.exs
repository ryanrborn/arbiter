defmodule ArbiterCli.Cmd.ResumeTest do
  use ArbiterCli.CliCase, async: false

  describe "arb resume" do
    test "missing bead-id fails with usage hint" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Resume.run([]) end)
      assert err =~ "resume requires a bead id"
      assert code != 0
    end

    test "too many positional args fails" do
      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Resume.run(["a", "b", "c"]) end)
      assert err =~ "at most two positional"
      assert code != 0
    end

    test "happy path posts to /api/polecats/:bead_id/resume and renders text" do
      stub_post(
        "/api/polecats/bd-auma3z/resume",
        %{
          "bead" => %{"id" => "bd-auma3z", "title" => "resume cmd", "status" => "in_progress"},
          "polecat" => %{"bead_id" => "bd-auma3z", "pid" => "#PID<0.123.0>"},
          "machine" => %{"id" => "mc-1", "pid" => "#PID<0.124.0>"},
          "worktree_path" => "/wt/feature-bd-auma3z",
          "claude_started" => true
        }
      )

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Resume.run(["bd-auma3z"]) end)
      assert code == 0
      assert out =~ "Resume:"
      assert out =~ "bd-auma3z — resume cmd"
      assert out =~ "(reused)"
      assert out =~ "resumed"
    end

    test "--json mode emits JSON" do
      stub_post("/api/polecats/bd-1/resume", %{
        "bead" => %{"id" => "bd-1", "title" => "t", "status" => "in_progress"},
        "polecat" => %{"bead_id" => "bd-1", "pid" => "x"},
        "machine" => %{"id" => "m", "pid" => "y"}
      })

      {out, _err, code} = capture(fn -> ArbiterCli.Cmd.Resume.run(["bd-1", "--json"]) end)
      assert code == 0
      assert {:ok, decoded} = Jason.decode(out)
      assert decoded["bead"]["id"] == "bd-1"
    end

    test "error response propagates as die" do
      stub_post(
        "/api/polecats/bd-x/resume",
        %{
          "error" => %{
            "type" => "invalid_request",
            "message" => "no preserved worktree for this bead"
          }
        },
        422
      )

      {_out, err, code} = capture(fn -> ArbiterCli.Cmd.Resume.run(["bd-x"]) end)
      assert code != 0
      assert err =~ "worktree" || err =~ "422"
    end

    test "rig and --model forward in the request body" do
      parent = self()
      name = Process.get(:bd2_stub_name)

      Req.Test.stub(name, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/polecats/bd-9/resume"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(body)})

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "bead" => %{"id" => "bd-9", "title" => "t", "status" => "in_progress"},
              "polecat" => %{"bead_id" => "bd-9", "pid" => "x"},
              "machine" => %{"id" => "m", "pid" => "y"}
            })

          _ ->
            conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{error: "unmatched"})
        end
      end)

      {_out, _err, code} =
        capture(fn -> ArbiterCli.Cmd.Resume.run(["bd-9", "my/rig", "--model", "opus"]) end)

      assert code == 0
      assert_receive {:body, body}
      assert body["rig"] == "my/rig"
      assert body["model"] == "opus"
    end
  end
end
