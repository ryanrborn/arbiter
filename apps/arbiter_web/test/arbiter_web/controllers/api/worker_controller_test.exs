defmodule ArbiterWeb.Api.WorkerControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Workers.Run

  setup %{conn: conn} do
    # Clean slate — other tests in the umbrella may have left workers running.
    for snap <- Worker.list_children() do
      Worker.stop(snap.task_id)
    end

    Process.sleep(50)

    {:ok, ws} = Ash.create(Workspace, %{name: "pol-ctrl-ws", prefix: "pc"})
    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  describe "GET /api/workers/:task_id" do
    test "returns the snapshot including output_lines for a running worker",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "show-me", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")

      # Simulate Claude output flowing through the worker.
      :ok = Worker.report(worker_pid, :output_lines, ["hello", "world", "arb done"])

      conn = get(conn, ~p"/api/workers/#{task.id}")
      body = json_response(conn, 200)

      assert body["task_id"] == task.id
      assert body["repo"] == "test/repo"
      assert body["status"] in ["idle", "running", "awaiting", "completed", "failed"]
      assert body["output_lines"] == ["hello", "world", "arb done"]
    end

    test "returns 404 for an unknown task_id", %{conn: conn} do
      conn = get(conn, ~p"/api/workers/no-such-task")
      assert json_response(conn, 404)
    end

    test "falls back to the most recent historical run when no live worker exists",
         %{conn: conn, ws: ws} do
      task_id = "bd-hist-#{System.unique_integer([:positive])}"
      older = DateTime.add(DateTime.utc_now(), -60, :second)
      newer = DateTime.utc_now()

      {:ok, _old} =
        Ash.create(Run, %{
          task_id: task_id,
          repo: "arbiter",
          workspace_id: ws.id,
          status: :completed,
          started_at: older,
          completed_at: older,
          output_lines: ["stale"]
        })

      {:ok, _recent} =
        Ash.create(Run, %{
          task_id: task_id,
          repo: "arbiter",
          workspace_id: ws.id,
          status: :failed,
          started_at: newer,
          completed_at: newer,
          exit_code: 2,
          failure_reason: "claude_crashed",
          output_lines: ["a", "b", "boom"]
        })

      conn = get(conn, ~p"/api/workers/#{task_id}")
      body = json_response(conn, 200)

      assert body["source"] == "history"
      assert body["task_id"] == task_id
      # Most-recent run wins (failed, not the older completed one).
      assert body["status"] == "failed"
      assert body["exit_status"] == 2
      assert body["failure_reason"] == "claude_crashed"
      assert body["output_lines"] == ["a", "b", "boom"]
      assert body["completed_at"]
    end

    test "live snapshot is marked source=live and wins over history",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "live-wins", workspace_id: ws.id})

      {:ok, _run} =
        Ash.create(Run, %{
          task_id: task.id,
          repo: "arbiter",
          workspace_id: ws.id,
          status: :completed,
          started_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "test/repo")
      :ok = Worker.report(worker_pid, :output_lines, ["live-line"])

      conn = get(conn, ~p"/api/workers/#{task.id}")
      body = json_response(conn, 200)

      assert body["source"] == "live"
      assert body["repo"] == "test/repo"
      assert body["output_lines"] == ["live-line"]
    end

    test "returns 404 when neither a live worker nor a historical run exists",
         %{conn: conn} do
      conn = get(conn, ~p"/api/workers/bd-never-ran-#{System.unique_integer([:positive])}")
      assert json_response(conn, 404)
    end

    test "snapshot includes failure_reason when the worker failed",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "failed-pol", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")

      :ok = Worker.fail(worker_pid, {:claude_crashed, "bad token"})

      conn = get(conn, ~p"/api/workers/#{task.id}")
      body = json_response(conn, 200)

      assert body["status"] == "failed"
      assert body["failure_reason"] =~ "claude_crashed"
    end
  end

  describe "POST /api/workers/dispatch" do
    # --no-agent preserves the manual-attach path: the task parks in
    # `:in_progress` with no Driver, so the no-op Work workflow never races
    # to a bogus `:closed`. Regression against the old dry-dispatch footgun.
    test "--no-agent parks the task and does NOT close it",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "dry-dispatch-me", workspace_id: ws.id})

      conn =
        post(conn, ~p"/api/workers/dispatch", %{
          "task_id" => task.id,
          "repo" => "test/repo",
          "no_agent" => true
        })

      body = json_response(conn, 201)

      assert body["task"]["id"] == task.id
      assert body["task"]["status"] == "in_progress"

      # Wait well past the old ~500ms Driver-close race window. Under the old
      # behaviour the task would be `:closed` by now; it must remain parked.
      Process.sleep(900)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
      refute reloaded.status == :closed
    end

    # A `provider` takes the real-work dispatch path (start_claude: true) rather
    # than parking. With an unconfigured repo that path returns a 400 repo error —
    # the signal that the provider was honored as a worker dispatch (a park would
    # 201 with the task in_progress and no agent).
    test "provider routes to a real worker dispatch (repo error rather than park)",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "gem-provider", workspace_id: ws.id})

      conn =
        post(conn, ~p"/api/workers/dispatch", %{
          "task_id" => task.id,
          "provider" => "gemini",
          "repo" => "no-such-repo"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "repo"
    end

    # bd-dcvo3n: `provider: "codex"` must take the real-work dispatch path with
    # the codex agent — not silently fall back to the workspace default. With an
    # unconfigured repo that path returns a 400 repo error, proving the provider
    # was honored (a silent default would still error on repo, so the decisive
    # check is the unknown-provider test below).
    test "provider \"codex\" routes to a real worker dispatch (repo error)",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "codex-provider", workspace_id: ws.id})

      conn =
        post(conn, ~p"/api/workers/dispatch", %{
          "task_id" => task.id,
          "provider" => "codex",
          "repo" => "no-such-repo"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "repo"
    end

    # bd-dcvo3n: an unrecognized `provider` must fail LOUDLY (400) rather than
    # silently falling back to the workspace-default agent. The error must be
    # about the bad provider, NOT the (also-unconfigured) repo — proving we
    # reject before ever reaching the dispatch path.
    test "an unrecognized provider is rejected with a 400 (not a silent default)",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "bad-provider", workspace_id: ws.id})

      conn =
        post(conn, ~p"/api/workers/dispatch", %{
          "task_id" => task.id,
          "provider" => "kodex",
          "repo" => "no-such-repo"
        })

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "provider"
      assert body["error"]["message"] =~ "kodex"
      refute body["error"]["message"] =~ "repo"
    end

    test "returns 404 for an unknown task_id", %{conn: conn} do
      conn = post(conn, ~p"/api/workers/dispatch", %{"task_id" => "no-such-task"})
      assert json_response(conn, 404)
    end

    test "requires a task_id", %{conn: conn} do
      conn = post(conn, ~p"/api/workers/dispatch", %{})
      assert json_response(conn, 400)
    end
  end

  describe "POST /api/workers/:task_id/resume" do
    test "returns 404 for an unknown task_id", %{conn: conn} do
      conn = post(conn, ~p"/api/workers/no-such-task/resume", %{})
      assert json_response(conn, 404)
    end

    test "a task with no prior run nor repo can't be resumed (400)", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "never slung", workspace_id: ws.id})

      conn = post(conn, ~p"/api/workers/#{task.id}/resume", %{})
      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "repo"
    end

    test "a closed task can't be resumed (400)", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "closed", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{}, action: :close)

      conn = post(conn, ~p"/api/workers/#{task.id}/resume", %{"repo" => "test/repo"})
      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "closed"
    end
  end

  describe "POST /api/workers/review" do
    test "dispatches a review-only worker: no worktree, CodeReview workflow attached",
         %{conn: conn, ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "review me",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "42"
        })

      conn =
        post(conn, ~p"/api/workers/review", %{
          "task_id" => task.id,
          # Drop the Claude session — the test only cares about wiring.
          "with_claude" => false,
          "repo" => "no-such-repo"
        })

      body = json_response(conn, 201)

      assert body["task"]["id"] == task.id
      assert body["task"]["status"] == "in_progress"
      assert is_nil(body["worktree_path"])

      # The worker is tagged review_only so completion bypasses the MergeQueue.
      pid = Worker.whereis(task.id)
      assert is_pid(pid)
      snap = Worker.state(pid)
      assert snap.meta[:review_only] == true

      # Cleanup so the next test isn't tripped by a lingering worker.
      Worker.stop(task.id)
    end

    test "returns 404 for an unknown task_id", %{conn: conn} do
      conn = post(conn, ~p"/api/workers/review", %{"task_id" => "no-such-task"})
      assert json_response(conn, 404)
    end

    test "requires a task_id or pr", %{conn: conn} do
      conn = post(conn, ~p"/api/workers/review", %{})
      assert json_response(conn, 400)
    end

    test "external PR review acks against a github-strategy workspace", %{conn: conn} do
      {:ok, gh_ws} =
        Ash.create(Workspace, %{
          name: "ctrl-gh-ws",
          prefix: "cgh",
          config: %{"merge" => %{"strategy" => "github", "config" => %{}}}
        })

      conn =
        post(conn, ~p"/api/workers/review", %{
          "pr" => "https://github.com/leo/verus_sigv4/pull/5",
          "workspace" => gh_ws.name
        })

      body = json_response(conn, 201)
      assert body["data"]["external"] == true
      assert body["data"]["status"] == "dispatched"
      assert body["data"]["mr_ref"] == "leo/verus_sigv4#5"
      assert body["data"]["strategy"] == "github"
    end

    test "external PR review on a direct-strategy workspace is rejected", %{conn: conn, ws: ws} do
      conn =
        post(conn, ~p"/api/workers/review", %{"pr" => "octo/widget#1", "workspace" => ws.name})

      body = json_response(conn, 400)
      assert body["error"]["message"] =~ "not supported"
    end
  end

  describe "POST /api/workers/:task_id/stop" do
    test "terminates a running worker", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "stop-me", workspace_id: ws.id})
      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "r")
      ref = Process.monitor(worker_pid)

      conn = post(conn, ~p"/api/workers/#{task.id}/stop", %{})
      body = json_response(conn, 200)

      assert body["task_id"] == task.id
      assert body["stopped"] == true

      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000
      assert Worker.whereis(task.id) == nil
    end

    test "returns 404 for an unknown task_id", %{conn: conn} do
      conn = post(conn, ~p"/api/workers/no-such-task/stop", %{})
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/workers/:task_id/log" do
    setup do
      root = Path.join(System.tmp_dir!(), "pol-log-ctrl-#{System.unique_integer([:positive])}")
      prev = Application.get_env(:arbiter, :output_log_root)
      Application.put_env(:arbiter, :output_log_root, root)

      on_exit(fn ->
        File.rm_rf(root)

        if prev,
          do: Application.put_env(:arbiter, :output_log_root, prev),
          else: Application.delete_env(:arbiter, :output_log_root)
      end)

      :ok
    end

    test "returns the full, uncapped durable transcript for the most recent run",
         %{conn: conn, ws: ws} do
      task_id = "bd-log-#{System.unique_integer([:positive])}"

      {:ok, run} =
        Ash.create(Run, %{
          task_id: task_id,
          repo: "arbiter",
          workspace_id: ws.id,
          status: :completed,
          started_at: DateTime.utc_now(),
          completed_at: DateTime.utc_now()
        })

      {:ok, handle} = OutputLog.open(run.id)
      Enum.each(1..1500, fn i -> OutputLog.append(handle, "line-#{i}") end)
      OutputLog.close(handle)

      conn = get(conn, ~p"/api/workers/#{task_id}/log")
      data = json_response(conn, 200)["data"]

      assert data["task_id"] == task_id
      assert data["run_id"] == run.id
      assert data["path"] == OutputLog.path_for(run.id)
      assert data["exists"] == true
      # Every line is retained — well past the 1000-line in-memory cap.
      assert data["line_count"] == 1500
      assert List.first(data["lines"]) == "line-1"
      assert List.last(data["lines"]) == "line-1500"
    end

    test "exists=false with empty lines when the run has no transcript on disk",
         %{conn: conn, ws: ws} do
      task_id = "bd-nolog-#{System.unique_integer([:positive])}"

      {:ok, run} =
        Ash.create(Run, %{
          task_id: task_id,
          repo: "arbiter",
          workspace_id: ws.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      conn = get(conn, ~p"/api/workers/#{task_id}/log")
      data = json_response(conn, 200)["data"]

      assert data["run_id"] == run.id
      assert data["exists"] == false
      assert data["lines"] == []
      assert data["line_count"] == 0
    end

    test "returns 404 when no run was ever recorded for the task", %{conn: conn} do
      conn = get(conn, ~p"/api/workers/bd-never-#{System.unique_integer([:positive])}/log")
      assert json_response(conn, 404)
    end
  end
end
