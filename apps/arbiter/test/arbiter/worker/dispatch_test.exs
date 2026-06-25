defmodule Arbiter.Worker.DispatchTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run
  require Ash.Query

  # The most recent worker_run for a task — used by the resume tests to assert
  # run lineage (resumed_from_run_id) and terminal status.
  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "dispatch-test-ws", prefix: "st"})
    {:ok, ws: ws}
  end

  describe "dispatch/2 happy path" do
    test "spawns a worker and starts a workflow machine", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "hello world", workspace_id: ws.id})

      assert {:ok, result} = Dispatch.dispatch(task.id, repo: "test/repo", start_driver: false)
      assert result.task.status == :in_progress
      assert is_pid(result.worker_pid)
      assert is_pid(result.machine_pid)
      assert is_binary(result.machine_id)
      assert result.driver_pid == nil

      # worker is registered
      assert Worker.whereis(task.id) == result.worker_pid
    end

    test "idempotent for already-in_progress tasks", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _first} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)

      # Second dispatch: task is already :in_progress; worker already exists.
      # Should NOT crash; should return the existing worker pid.
      assert {:ok, second} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      assert second.task.status == :in_progress
      assert Worker.whereis(task.id) == second.worker_pid
    end

    # bd-d70whv: redispatch a failed worker must start a fresh worker rather than
    # reusing the stale :failed one. Previously, start_worker/3 returned the
    # existing pid on {:already_started, pid} regardless of status, and the
    # :failed status caused the "arb done" FSM guard to silently no-op.
    test "redispatch a :failed worker starts a fresh :idle worker (bd-d70whv)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "redispatch failed", workspace_id: ws.id})

      {:ok, first} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      first_pid = first.worker_pid

      :ok = Worker.fail(first_pid, :credentials_expired)
      assert Worker.state(first_pid).status == :failed

      # Re-dispatch: must evict the stale worker and start a new one.
      {:ok, second} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)

      assert second.worker_pid != first_pid
      refute Process.alive?(first_pid)
      assert Worker.state(second.worker_pid).status == :idle
    end

    test "redispatch a :completed worker also starts fresh (bd-d70whv)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "redispatch completed", workspace_id: ws.id})

      {:ok, first} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)
      first_pid = first.worker_pid

      :ok = Worker.advance(first_pid, :work)
      :ok = Worker.complete(first_pid, :done)
      assert Worker.state(first_pid).status == :completed

      {:ok, second} = Dispatch.dispatch(task.id, repo: "r", start_driver: false)

      assert second.worker_pid != first_pid
      refute Process.alive?(first_pid)
      assert Worker.state(second.worker_pid).status == :idle
    end

    test "starts a Driver by default and drives task to :closed", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "drive me", workspace_id: ws.id})

      assert {:ok, result} = Dispatch.dispatch(task.id, repo: "test/repo", interval_ms: 5)
      assert is_pid(result.driver_pid)
      assert Process.alive?(result.driver_pid)

      # Wait for the driver to walk Workflows.Work to completion. The work
      # workflow has 5 no-op steps; at 5ms intervals it should finish well
      # under 500ms.
      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end
  end

  describe "dispatch/2 error cases" do
    test "non-existent task returns {:error, {:task_not_found, _}}" do
      assert {:error, {:task_not_found, "no-such-task-123"}} =
               Dispatch.dispatch("no-such-task-123")
    end

    test "closed tasks cannot be slung", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(task, %{}, action: :close)

      assert {:error, {:task_closed, _}} = Dispatch.dispatch(task.id)
    end

    test "tasks already awaiting review cannot be re-slung (bd-appwsh)", %{ws: ws} do
      alias Arbiter.Test.StubMerger

      StubMerger.reset()
      {:ok, task} = Ash.create(Issue, %{title: "awaiting-review guard", workspace_id: ws.id})

      # Boot a worker and park it at :awaiting_review via open_mr/5 with a
      # stub merger. Use a far-future Watchdog interval so the auto-started Watchdog
      # does not poll or transition the worker during the assertion window.
      {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
      :ok = Worker.advance(pid, :implement)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

      StubMerger.next_open_ref("!test")

      open_opts = %{
        adapter: StubMerger,
        workspace: nil,
        interval_ms: 1_000_000,
        initial_delay_ms: 1_000_000
      }

      assert {:ok, "!test"} = Worker.open_mr(pid, "feature/guard", "Guard", "", open_opts)
      assert Worker.state(pid).status == :awaiting_review

      assert {:error, {:task_awaiting_review, _}} =
               Dispatch.dispatch(task.id, start_driver: false)
    end
  end

  describe "pre-flight auth check (bd-awi4nw)" do
    alias Arbiter.Messages.Message

    # bd-1ziw04: real-work dispatchs now require the repo to be in :repo_paths.
    # Configure a minimal entry so repo validation passes and the preflight check
    # actually fires. No real git repo is needed — the probe aborts before the
    # worktree provisioning step.
    setup do
      prior = Application.get_env(:arbiter, :repo_paths)
      Application.put_env(:arbiter, :repo_paths, %{"test/repo" => "/tmp"})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :repo_paths, prior),
          else: Application.delete_env(:arbiter, :repo_paths)
      end)
    end

    test "a failing auth probe REFUSES to dispatch and leaves the task untouched", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "auth gate", workspace_id: ws.id})

      assert {:error, {:auth_check_failed, reason}} =
               Dispatch.dispatch(task.id,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 probe_command: [
                   "sh",
                   "-c",
                   "echo '401 invalid authentication credentials'; exit 1"
                 ],
                 probe_env: []
               )

      assert reason.category == :auth_expired

      # Refused BEFORE any state mutation: task is still :open, no worker spawned.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil
    end

    test "a failed pre-flight escalates to the Admiral with a re-auth message", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "auth escalate", workspace_id: ws.id})

      {:error, {:auth_check_failed, _}} =
        Dispatch.dispatch(task.id,
          repo: "test/repo",
          start_driver: false,
          start_claude: true,
          probe_command: ["sh", "-c", "echo '401 invalid authentication credentials'; exit 1"],
          probe_env: []
        )

      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.directive_ref == task.id))

      assert escalation.subject =~ "pre-flight auth failed"
      assert escalation.body =~ "Re-authenticate"
    end

    test "pre-flight is skipped when start_claude is false (default path unaffected)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no preflight", workspace_id: ws.id})

      # Even with a probe_command that would 401, no start_claude means no probe.
      # provision_worktree: false so we don't try to git-fetch /tmp.
      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 repo: "test/repo",
                 start_driver: false,
                 provision_worktree: false,
                 probe_command: ["sh", "-c", "exit 1"]
               )

      assert result.task.status == :in_progress
    end

    test "preflight: false bypasses the probe even with start_claude", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "bypass", workspace_id: ws.id})

      # start_claude + preflight: false + provision_worktree: false errors at the
      # claude-start step (:missing_worktree) — proving we got PAST the (disabled)
      # preflight rather than being refused by it. The repo must be valid so the
      # repo-resolution guard (bd-1ziw04) passes before reaching the preflight gate.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false,
                 probe_command: ["sh", "-c", "echo 401; exit 1"]
               )
    end
  end

  describe "dispatch/2 result shape" do
    test "returns a map with the standard keys", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "shape", workspace_id: ws.id})
      {:ok, result} = Dispatch.dispatch(task.id, repo: "test/repo", start_driver: false)

      for key <- [:task, :worker_pid, :machine_id, :machine_pid, :driver_pid, :worktree_path] do
        assert Map.has_key?(result, key), "missing #{key}"
      end
    end
  end

  describe "Claude session (start_claude opt)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-claude-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{tmp: tmp}
    end

    # Build a `claude`-named shim on PATH that writes its argv (one per line) to
    # `argv_file` and exits 0. Used to verify the spawn argv assembled by the
    # adapter path (Agents.Claude.default_argv) — `--model <name>` is the bit
    # Phase A specifically wires up.
    defp stub_claude_on_path(tmp, argv_file), do: stub_named_on_path(tmp, "claude", argv_file)

    # Build a `<name>`-named shim on PATH that writes its argv (one per line) to
    # `argv_file` and exits 0. Generalizes `stub_claude_on_path` so a forced
    # provider (e.g. `agy`/`gemini`) can be intercepted the same way — its stub
    # dir is prepended to PATH so it wins over any real binary installed there.
    defp stub_named_on_path(tmp, name, argv_file) do
      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, name)

      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> #{argv_file}; done
      exit 0
      """)

      File.chmod!(stub, 0o755)

      old_path = System.get_env("PATH") || ""

      # Only prepend the stub dir once even if several shims share it.
      unless String.starts_with?(old_path, "#{stub_dir}:") do
        System.put_env("PATH", "#{stub_dir}:#{old_path}")
        on_exit(fn -> System.put_env("PATH", old_path) end)
      end

      :ok
    end

    # Flip the per-spawn `.mcp.json` injection on (config/test.exs disables it by
    # default) and restore the prior config when the test ends. The signing
    # secret falls back to the Phoenix endpoint's :secret_key_base, so no secret
    # needs to be injected here.
    defp enable_mcp_injection! do
      prior = Application.get_env(:arbiter, Arbiter.MCP)
      Application.put_env(:arbiter, Arbiter.MCP, Keyword.put(prior || [], :inject_config, true))
      on_exit(fn -> Application.put_env(:arbiter, Arbiter.MCP, prior) end)
      :ok
    end

    defp seed_repo!(tmp, sub) do
      repo = Path.join(tmp, sub)
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      # Bare origin: Worktree.create fetches from origin and branches from
      # origin/<base>; provide an upstream the provisioner can consult.
      remote = Path.join(tmp, sub <> "-remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      repo
    end

    test "defaults to start_claude: false → claude_port is nil", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no claude", workspace_id: ws.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "test/repo", start_driver: false)
      assert result.claude_port == nil
    end

    test "start_claude: true with claude_command spawns a subprocess in the worktree",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

      # Use the tmp dir as a stand-in worktree by passing it through manually.
      # Dispatch.maybe_provision_worktree returns nil when repo is unmapped, but
      # we need a worktree_path for ClaudeSession; so we point a tmp repo at
      # a real git repo and let Dispatch provision the worktree itself.
      repo = seed_repo!(tmp, "repo")

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      Application.put_env(:arbiter, :repo_paths, %{"claude/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "claude/repo",
          start_driver: false,
          start_claude: true,
          # Stand-in for a running `claude --print` session — stays alive (so it
          # isn't caught by bd-awi4nw stop-detection as a died-early worker),
          # but proves ClaudeSession.start was wired into Dispatch.
          claude_command: ["sleep", "2"]
        )

      assert is_port(result.claude_port)
      assert is_binary(result.worktree_path)
    end

    # bd-dlv3no: a review dispatch has no per-task worktree, so its Claude cwd
    # falls back to the repo's shared checkout. The per-spawn MCP config carries a
    # bearer scope token; writing `.mcp.json` into that canonical checkout leaks
    # the token into the working tree the live server + operator share (the
    # "worker leaks into the main worktree" class). The spawn must NOT touch the
    # repo's working tree.
    test "review dispatch does not write .mcp.json into the shared repo checkout",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "reviewrig")

      Application.put_env(:arbiter, :repo_paths, %{"rv/repo" => repo})
      enable_mcp_injection!()

      on_exit(fn -> Application.delete_env(:arbiter, :repo_paths) end)

      {:ok, task} = Ash.create(Issue, %{title: "review me", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "rv/repo",
          review: true,
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "2"]
        )

      # Review runs in the repo (no worktree) ...
      assert result.worktree_path == nil
      assert is_port(result.claude_port)
      # ... and the token-bearing config never lands in that shared checkout.
      refute File.exists?(Path.join(repo, ".mcp.json"))
    end

    # Counterpart: a normal work dispatch DOES get the MCP config — but only ever
    # inside its own isolated worktree, never the repo.
    test "work dispatch writes .mcp.json into its isolated worktree (not the repo)",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "workrig")

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "work-wt"))
      Application.put_env(:arbiter, :repo_paths, %{"work/repo" => repo})
      enable_mcp_injection!()

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, task} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "work/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      assert is_binary(result.worktree_path)
      assert File.exists?(Path.join(result.worktree_path, ".mcp.json"))
      refute File.exists?(Path.join(repo, ".mcp.json"))
    end

    test ".mcp.json is not tracked after being untracked from git",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "gitignore-check")

      # Set up the repo to simulate the original issue: .mcp.json is listed in
      # .gitignore, but we also add it to git (committing it before the ignore
      # took effect). This mirrors the production state before the fix.
      gitignore_path = Path.join(repo, ".gitignore")
      File.write!(gitignore_path, ".mcp.json\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", ".gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "add gitignore"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Now add and commit .mcp.json (simulating the original bug state).
      # In the real repo, this happened because .mcp.json was committed before
      # the .gitignore entry existed. Use -f to force-add since it's in gitignore.
      mcp_path = Path.join(repo, ".mcp.json")
      File.write!(mcp_path, "{\"old\": \"token\"}\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "-f", ".mcp.json"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "commit mcp config"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Verify the buggy state: .mcp.json is tracked despite being in .gitignore
      {tracked_before, 0} = System.cmd("git", ["-C", repo, "ls-files"])

      assert String.contains?(tracked_before, ".mcp.json"),
             "Setup: .mcp.json should be tracked in the test repo"

      # Now apply the fix: untrack .mcp.json with git rm --cached
      # This removes .mcp.json from git's index but leaves the file in the working tree
      {_, 0} = System.cmd("git", ["-C", repo, "rm", "--cached", ".mcp.json"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "untrack .mcp.json"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      # Clean up: remove the file from the working tree so it won't show as untracked
      # (In production, the worktree gets the gitignore and starts clean; here we simulate that)
      File.rm!(mcp_path)

      # Verify the fix: .mcp.json is no longer tracked and not in the working tree
      {tracked_after, 0} = System.cmd("git", ["-C", repo, "ls-files"])

      refute String.contains?(tracked_after, ".mcp.json"),
             "After fix: .mcp.json should be untracked"

      refute File.exists?(mcp_path),
             "After fix: .mcp.json file should be removed from working tree"

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "gic-wt"))
      Application.put_env(:arbiter, :repo_paths, %{"gic/repo" => repo})
      enable_mcp_injection!()

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, task} = Ash.create(Issue, %{title: "check ignore", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "gic/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      wt = result.worktree_path
      assert is_binary(wt)

      # .mcp.json was written into the worktree by the spawn
      assert File.exists?(Path.join(wt, ".mcp.json"))

      # Critical assertion: after the fix, .mcp.json must NOT be in git ls-files.
      {wt_tracked, 0} = System.cmd("git", ["-C", wt, "ls-files"])

      refute String.contains?(wt_tracked, ".mcp.json"),
             "REGRESSION: .mcp.json is tracked in worktree. After the fix, it should be untracked and ignored."

      # The worktree status must be clean. The injected .mcp.json is ignored,
      # so it should not appear in git status.
      {status_output, _status_code} = System.cmd("git", ["-C", wt, "status", "--porcelain"])

      refute String.contains?(status_output, ".mcp.json"),
             "REGRESSION: .mcp.json shows in git status. After the fix, the injected file must be ignored and clean."
    end

    test "start_claude: true with an unresolvable repo returns {:error, {:repo_not_found, repo}}",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no wt", workspace_id: ws.id})

      assert {:error, {:repo_not_found, "no-such-repo"}} =
               Dispatch.dispatch(task.id,
                 repo: "no-such-repo",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["echo", "x"]
               )
    end

    test "start_claude: true implies claude_driven Driver mode (no workflow ticking)",
         %{ws: ws, tmp: tmp} do
      {:ok, task} = Ash.create(Issue, %{title: "drvr-mode", workspace_id: ws.id})

      repo = seed_repo!(tmp, "drvrepo")

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "drv-wt"))
      Application.put_env(:arbiter, :repo_paths, %{"drvr/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "drvr/repo",
          start_claude: true,
          # A stand-in for a *running* Claude session: it must stay alive for the
          # duration of this test. A command that exits immediately would (since
          # bd-awi4nw) trip stop-detection and fail the worker — exactly the
          # "worker died without `arb done`" path we now catch.
          claude_command: ["sleep", "2"],
          # Speed up the worker-status polling for the assertion below.
          interval_ms: 5,
          max_ticks: 50
        )

      assert is_pid(result.driver_pid)

      # Dispatch must have nudged the worker out of :idle so the UI/CLI
      # report a meaningful status while Claude works. In claude_driven
      # mode the Driver never ticks the Machine, so without this nudge
      # the worker would stay :idle until "arb done" fires.
      snap = Worker.state(result.worker_pid)
      assert snap.status == :running
      assert snap.current_step == :claude

      # If the Driver were in workflow mode, the no-op steps would close
      # the task in ~500ms. Wait that long and verify the task is still
      # :in_progress — the Driver is waiting on the worker instead.
      Process.sleep(150)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress

      # Now simulate Claude completion and let the Driver react.
      :ok = Worker.complete(result.worker_pid, :claude_done)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :closed
    end

    test "passes the workspace `agent.config.model` as `--model` to claude",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "model-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "mwt"))
      Application.put_env(:arbiter, :repo_paths, %{"m/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "model task", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          repo: "m/repo",
          start_driver: false,
          start_claude: true,
          # This test asserts the WORK-spawn argv; disable the bd-awi4nw auth
          # pre-flight so its probe (which invokes the same `claude` stub) doesn't
          # write to the shared argv file and race the work spawn's capture.
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "sonnet" in args
    end

    test "per-dispatch :model opt overrides the workspace's routed model",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "override-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "owt"))
      Application.put_env(:arbiter, :repo_paths, %{"o/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "override", workspace_id: ws.id})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          repo: "o/repo",
          start_driver: false,
          start_claude: true,
          model: "opus",
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw).
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "opus" in args
      refute "sonnet" in args
    end

    test "agent_type: :gemini dispatches the Gemini adapter, not Claude",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      gemini_file = Path.join(tmp, "gemini-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "agy", gemini_file)

      repo = seed_repo!(tmp, "gem-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "gwt"))
      Application.put_env(:arbiter, :repo_paths, %{"g/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      # Workspace defaults to Claude — the forced provider must win over it.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => "claude"}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "gemini task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "g/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :gemini,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw)
          # so its probe doesn't also write to the stub argv files.
          preflight: false
        )

      gemini_args = wait_for_argv!(gemini_file)
      assert "-p" in gemini_args
      # The Gemini adapter ran — and Claude did not.
      refute File.exists?(claude_file)

      # The worker's routing config records the gemini provider + a model id.
      snap = Worker.state(result.worker_pid)
      routing = snap.meta[:routing_config]
      assert routing.provider == "gemini"
      assert routing.model =~ "gemini"
    end

    test "ByPriority routing picks --model from `routing.rules[Pn]`",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "prio-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "pwt"))
      Application.put_env(:arbiter, :repo_paths, %{"p/repo" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :repo_paths)
      end)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
            "routing" => %{
              "policy" => "by_priority",
              "rules" => %{"P4" => %{"model" => "haiku"}}
            }
          }
        })

      # priority 4 → routing rule fires → haiku.
      {:ok, task} =
        Ash.create(Issue, %{title: "trivial", workspace_id: ws.id, priority: 4})

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          repo: "p/repo",
          start_driver: false,
          start_claude: true,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw).
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "haiku" in args
    end
  end

  # Read a stub's captured argv once it has settled. The argv-recording shim
  # appends one line per arg, so a bare `File.exists?` check can race a partial
  # write and return only the first token. Wait until the file's contents stop
  # changing across two polls, then split into the arg list.
  defp wait_for_argv!(file) do
    wait_until(fn -> File.exists?(file) end)
    settle_argv(file, File.read!(file))
  end

  defp settle_argv(file, prev) do
    Process.sleep(20)

    case File.read!(file) do
      ^prev -> String.split(prev, "\n", trim: true)
      next -> settle_argv(file, next)
    end
  end

  # Spin until `fun.()` returns truthy or the deadline expires.
  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  describe "worktree provisioning" do
    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-wt-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      # Bare origin: Worktree.create fetches from `origin` and branches from
      # `origin/<base>`. Tests set it up explicitly so the repo has an upstream
      # the provisioning path can consult.
      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"st/repo" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, remote: remote, worktree_root: worktree_root, tmp: tmp}
    end

    test "creates a worktree on a derived branch when repo is configured",
         %{ws: ws, worktree_root: root} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "implement the thing",
          workspace_id: ws.id,
          issue_type: :feature
        })

      {:ok, result} =
        Dispatch.dispatch(task.id, repo: "st/repo", start_driver: false)

      assert is_binary(result.worktree_path)
      assert String.starts_with?(result.worktree_path, root)
      assert File.dir?(result.worktree_path)

      # Branch matches BranchNamer's derivation.
      branch = Arbiter.Worker.BranchNamer.derive(task)
      assert {:ok, ^branch} = Arbiter.Worker.Worktree.current_branch(result.worktree_path)
    end

    test "skips worktree when repo is not in repo_paths", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "unmapped", workspace_id: ws.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "no-such-repo", start_driver: false)
      assert result.worktree_path == nil
    end

    test "skips worktree for a task issue_type even with a configured repo (bd-5lc99r)",
         %{ws: ws} do
      # A `task` is non-reviewable ops/research work with no code deliverable, so
      # dispatch must not provision a worktree by default — even though `st/repo`
      # is configured and a feature/bug/chore would get one here.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "research spike",
          workspace_id: ws.id,
          issue_type: :task
        })

      {:ok, result} = Dispatch.dispatch(task.id, repo: "st/repo", start_driver: false)
      assert result.worktree_path == nil
    end

    test "provision_worktree: true forces a worktree even for a task type (bd-5lc99r)",
         %{ws: ws} do
      # The rare task that genuinely needs a repo checkout to inspect can opt back
      # in with an explicit flag.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "task needing a checkout",
          workspace_id: ws.id,
          issue_type: :task
        })

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "st/repo",
          start_driver: false,
          provision_worktree: true
        )

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "per-workspace rig_paths overrides the Application env", %{repo: repo} do
      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "per-ws-#{System.unique_integer([:positive])}",
          prefix: "pw",
          config: %{"repo_paths" => %{"per-ws/repo" => repo}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "per-ws", workspace_id: ws_local.id})

      # `per-ws/repo` is NOT in Application env — only in this workspace's
      # config. Dispatch must still find it.
      {:ok, result} = Dispatch.dispatch(task.id, repo: "per-ws/repo", start_driver: false)
      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "cuts the worktree from (and targets) the workspace's configured base branch",
         %{repo: repo} do
      # The source repo's default branch is `main`. Create a `develop` branch
      # that diverges from it (pushed to origin so the fetch-from-origin
      # provisioner can see it), then configure a workspace whose merge config
      # points the integration branch at `develop`.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "develop"])
      File.write!(Path.join(repo, "DEVELOP_ONLY.md"), "only on develop\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DEVELOP_ONLY.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "develop-only file"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "develop"])
      # Leave the repo's HEAD on `main` so a hardcoded "main" base would NOT
      # see the develop-only file — the assertion below proves we cut from
      # `develop`, not from whatever HEAD happens to be.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "base-branch-ws-#{System.unique_integer([:positive])}",
          prefix: "bb",
          config: %{
            "repo_paths" => %{"bb/repo" => repo},
            "merge" => %{"base" => "develop"}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "non-main base", workspace_id: ws_local.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "bb/repo", start_driver: false)

      # Worktree was cut from `develop`: the develop-only file is present.
      assert is_binary(result.worktree_path)
      assert File.exists?(Path.join(result.worktree_path, "DEVELOP_ONLY.md"))

      # Merge target_branch threaded into the worker's meta matches the base,
      # so the completed branch merges back into `develop`, not `main`.
      assert %{target_branch: "develop"} = Worker.state(result.worker_pid).meta
    end

    test "skips worktree when provision_worktree: false", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "opt-out", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "st/repo",
          start_driver: false,
          provision_worktree: false
        )

      assert result.worktree_path == nil
    end

    test "attaches to existing branch when re-dispatching a reopened task", %{repo: repo, ws: ws} do
      # Reproduces bd-4tta5n: task is slung once (branch created), the worktree
      # is cleaned up but the branch remains, then the task is reopened and
      # re-slung. Worktree.create fails with "already exists"; dispatch must fall
      # back to Worktree.attach and succeed.
      {:ok, task} =
        Ash.create(Issue, %{title: "re-dispatch after review", workspace_id: ws.id})

      # First dispatch — provisions the worktree, creating the branch locally.
      {:ok, first} = Dispatch.dispatch(task.id, repo: "st/repo", start_driver: false)
      assert is_binary(first.worktree_path)
      branch = Arbiter.Worker.BranchNamer.derive(task)

      # Simulate Driver cleanup: remove the worktree directory but leave the
      # branch (Worktree.cleanup removes the worktree, not the branch).
      Arbiter.Worker.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      # Confirm the branch still exists in the repo.
      {branches, 0} = System.cmd("git", ["-C", repo, "branch", "--list", branch])
      assert String.contains?(branches, branch)

      # Reopen task so it can be re-slung.
      {:ok, task} = Ash.update(task, %{status: :open})

      # Second dispatch — branch already exists; must attach instead of creating.
      assert {:ok, second} = Dispatch.dispatch(task.id, repo: "st/repo", start_driver: false)
      assert is_binary(second.worktree_path)
      assert File.dir?(second.worktree_path)
      assert {:ok, ^branch} = Arbiter.Worker.Worktree.current_branch(second.worktree_path)
    end

    test "worktree starts from upstream tip even when the repo's local base is stale",
         %{repo: repo, remote: remote, tmp: tmp, ws: ws} do
      # Reproduces the 2026-06-04 incident: a second clone advances origin/main;
      # the repo's local `main` stays put. Dispatch must still produce a worktree
      # at the upstream tip.
      clone = Path.join(tmp, "advance")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, "UPSTREAM.md"), "added on origin\n")
      {_, 0} = System.cmd("git", ["-C", clone, "add", "UPSTREAM.md"])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])

      refute File.exists?(Path.join(repo, "UPSTREAM.md"))

      {:ok, task} = Ash.create(Issue, %{title: "stale local base", workspace_id: ws.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "st/repo", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "UPSTREAM.md"))
    end

    test "fetch failure aborts the dispatch with a clear error", %{ws: ws, tmp: tmp} do
      # Rig with a broken `origin` (points at a nonexistent path): the fetch
      # must fail and the dispatch abort with a structured error rather than
      # silently falling back to the stale local base.
      broken = Path.join(tmp, "broken-origin")
      File.mkdir_p!(broken)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", broken])
      {_, 0} = System.cmd("git", ["-C", broken, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", broken, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", broken, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(broken, "x"), "x")
      {_, 0} = System.cmd("git", ["-C", broken, "add", "x"])
      {_, 0} = System.cmd("git", ["-C", broken, "commit", "-q", "-m", "i"])
      # Origin points at a path that doesn't exist — `git fetch` will fail.
      {_, 0} =
        System.cmd("git", ["-C", broken, "remote", "add", "origin", Path.join(tmp, "no-such")])

      Application.put_env(:arbiter, :repo_paths, %{"broken/repo" => broken})

      {:ok, task} = Ash.create(Issue, %{title: "fetch failure", workspace_id: ws.id})

      assert {:error, {:worktree_failed, reason}} =
               Dispatch.dispatch(task.id, repo: "broken/repo", start_driver: false)

      assert match?({:fetch_failed, _}, reason) or match?({:missing_origin_ref, _}, reason),
             "expected fetch_failed or missing_origin_ref, got: #{inspect(reason)}"
    end

    test "per-task target_branch overrides the workspace default", %{repo: repo, remote: remote} do
      # Push a `dolphin` branch to origin so Worktree.create can fetch it.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "dolphin"])
      File.write!(Path.join(repo, "DOLPHIN.md"), "dolphin\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DOLPHIN.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      _ = remote

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "per-task-target-#{System.unique_integer([:positive])}",
          prefix: "pb",
          # Workspace default is the bare "main"; the task overrides to dolphin.
          config: %{"repo_paths" => %{"pb/repo" => repo}, "merge" => %{"base" => "main"}}
        })

      {:ok, task} =
        Ash.create(Issue, %{
          title: "per-task target",
          workspace_id: ws_local.id,
          target_branch: "dolphin"
        })

      {:ok, result} = Dispatch.dispatch(task.id, repo: "pb/repo", start_driver: false)

      # The task-specified target wins: the worktree carries the dolphin file
      # and the worker's meta records dolphin as the merge target.
      assert File.exists?(Path.join(result.worktree_path, "DOLPHIN.md"))
      assert %{target_branch: "dolphin"} = Worker.state(result.worker_pid).meta
    end

    test "per-repo target_branch default applies when task has none", %{repo: repo} do
      # Push a `dolphin` branch and configure the repo to default to it.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "dolphin"])
      File.write!(Path.join(repo, "DOLPHIN.md"), "dolphin\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DOLPHIN.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "repo-default-target-#{System.unique_integer([:positive])}",
          prefix: "rd",
          # Repo-level default beats the workspace default ("main").
          config: %{
            "repo_paths" => %{
              "rd/repo" => %{"path" => repo, "target_branch" => "dolphin"}
            },
            "merge" => %{"base" => "main"}
          }
        })

      {:ok, task} = Ash.create(Issue, %{title: "repo default", workspace_id: ws_local.id})

      {:ok, result} = Dispatch.dispatch(task.id, repo: "rd/repo", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "DOLPHIN.md"))
      assert %{target_branch: "dolphin"} = Worker.state(result.worker_pid).meta
    end
  end

  describe "work prompt fix-pass sections (bd-bw93c3)" do
    test "includes prior review findings when task has notes", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fix pass task", workspace_id: ws.id})

      {:ok, task} =
        Ash.update(
          task,
          %{notes: "## ReviewGate verdict: REQUEST_CHANGES\n\nFix the null guard."},
          action: :update
        )

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "Prior review findings"
      assert prompt =~ "Fix the null guard."
    end

    test "omits prior review findings section when task has no notes", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fresh task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "Prior review findings"
    end

    test "includes PR review instruction when task has a pr_ref", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "fix pass with pr", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "319"}, action: :update)

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "existing PR (#319)"
      assert prompt =~ "gh pr view 319 --json reviews,reviewComments"
      assert prompt =~ "Do NOT open a new PR"
    end

    test "omits PR review instruction when task has no pr_ref", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no pr task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "gh pr view"
    end

    test "review prompt is unaffected by notes or pr_ref in work mode", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review task", workspace_id: ws.id})
      {:ok, task} = Ash.update(task, %{pr_ref: "42", notes: "some notes"}, action: :update)

      review_prompt = Dispatch.prompt_for_task(task, review: true)
      refute review_prompt =~ "Prior review findings"
      refute review_prompt =~ "existing PR"
    end
  end

  describe "task-type dispatch prompt (bd-5lc99r)" do
    test "a task-type directive gets the findings-in-notes briefing, not the work prompt",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "investigate the flaky deploy",
          workspace_id: ws.id,
          issue_type: :task
        })

      prompt = Dispatch.prompt_for_task(task, [])

      # Frames the deliverable as a findings summary in notes via the MCP tool.
      assert prompt =~ "findings"
      assert prompt =~ "notes"
      assert prompt =~ "task_update_progress"
      assert prompt =~ "notes gate"

      # Explicitly NOT the code-change/PR work prompt.
      refute prompt =~ "author a pr_body"
      refute prompt =~ "git commit"
    end

    test "a non-task type still gets the standard work prompt", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "build the thing",
          workspace_id: ws.id,
          issue_type: :feature
        })

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "notes gate"
    end

    test "review: true wins over a task issue_type (reviewer still reviews)", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "task but reviewed",
          workspace_id: ws.id,
          issue_type: :task
        })

      prompt = Dispatch.prompt_for_task(task, review: true)
      refute prompt =~ "notes gate"
    end
  end

  describe "conflict_resolve_briefing/3 (#354, Phase 2b)" do
    test "embeds the task intent and the rebase/resolve/test/push steps", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "Widget refactor",
          description: "Extract the widget builder.",
          acceptance: "- builder is pure\n- tests pass",
          workspace_id: ws.id
        })

      briefing = Dispatch.conflict_resolve_briefing(task, "feature/widget", "main")

      # Intent context — resolve conflicts honoring the original task.
      assert briefing =~ "Widget refactor"
      assert briefing =~ "Extract the widget builder."
      assert briefing =~ "builder is pure"

      # The narrow, hardened job: rebase, resolve, run tests, force-push.
      assert briefing =~ "git fetch origin main"
      assert briefing =~ "git rebase origin/main"
      assert briefing =~ "Run the test suite"
      assert briefing =~ "git push --force-with-lease origin feature/widget"
      assert briefing =~ "arb done"

      # Must NOT invite re-implementation or a new PR.
      assert briefing =~ "open a new PR"
      assert briefing =~ "re-implement"
    end

    test "the legacy ConflictResolver prompt now delegates to the hardened briefing", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "Conflicty change", workspace_id: ws.id})

      via_resolver =
        Arbiter.Workflows.MergeQueue.ConflictResolver.prompt_for(%{
          task: task,
          branch: "feature/c",
          target_branch: "develop"
        })

      assert via_resolver == Dispatch.conflict_resolve_briefing(task, "feature/c", "develop")
      assert via_resolver =~ "git rebase origin/develop"
      assert via_resolver =~ "Run the test suite"
    end
  end

  describe "work prompt completion notes (tracker-backed tasks)" do
    test "instructs a tracker-backed worker to produce QA + Deployment notes", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "tracked work",
          workspace_id: ws.id,
          tracker_type: "jira",
          tracker_ref: "VR-17585",
          skip_upstream_create: true
        })

      prompt = Dispatch.prompt_for_task(task, [])

      # Notes persist via the MCP tool, never the arb escript (bd-53xrmi).
      assert prompt =~ "backed by an external tracker"
      assert prompt =~ "task_update_progress"
      assert prompt =~ "qa_notes"
      assert prompt =~ "deployment_notes"
      refute prompt =~ "arb issue update"
    end

    test "untracked tasks get no completion-notes step", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "local work", workspace_id: ws.id, tracker_type: "none"})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "qa_notes"
      refute prompt =~ "backed by an external tracker"
    end

    test "a tracker type without a tracker_ref gets no completion-notes step", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "tracked but unlinked",
          workspace_id: ws.id,
          tracker_type: "jira",
          tracker_ref: nil,
          skip_upstream_create: true
        })

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "qa_notes"
    end
  end

  describe "work prompt PR body authoring (bd-53xrmi)" do
    test "instructs the worker to author a pr_body via MCP and NOT open its own PR",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "author body", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      # Authors the body and persists it via the MCP tool, never the arb escript.
      assert prompt =~ "task_update_progress"
      assert prompt =~ "pr_body"
      assert prompt =~ "Summary"
      assert prompt =~ "Test plan"
      refute prompt =~ "arb issue update"

      # No longer tells the worker to open a PR; explicitly forbids it.
      refute prompt =~ "open a PR if appropriate"
      assert prompt =~ "Do NOT open a pull request"
      assert prompt =~ "gh pr create"
    end

    test "the PR-body step is present for untracked tasks too", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "local body", workspace_id: ws.id, tracker_type: "none"})

      prompt = Dispatch.prompt_for_task(task, [])
      assert prompt =~ "pr_body"
      assert prompt =~ "task_update_progress"
    end
  end

  describe "resume/2 (bd-auma3z)" do
    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-resume-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"rs/repo" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, worktree_root: worktree_root}
    end

    # Dispatch a task, provisioning its worktree, then simulate a mid-work stop:
    # the worker fails (lingers in :failed, registered) with the worktree left
    # on disk — exactly the state `arb resume` is built to recover from.
    defp stop_acolyte_with_outpost(task_id) do
      {:ok, first} = Dispatch.dispatch(task_id, repo: "rs/repo", start_driver: false)
      assert is_binary(first.worktree_path)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)
      first
    end

    test "reuses the worktree, links the new run, and boots into :resuming", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "resume work", workspace_id: ws.id})
      first = stop_acolyte_with_outpost(task.id)

      prior_run = latest_run(task.id)
      assert prior_run.status == :failed

      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      # Same worktree, fresh worker.
      assert result.worktree_path == first.worktree_path
      assert result.worker_pid != first.worker_pid

      snap = Worker.state(result.worker_pid)
      assert snap.meta[:resume] == true
      # The worker advanced :resuming -> :running when the claude session started.
      assert snap.status == :running

      # The new run is linked to the prior one.
      new_run = latest_run(task.id)
      assert new_run.id != prior_run.id
      assert new_run.resumed_from_run_id == prior_run.id
    end

    test "the resumed worker's prompt is briefed with the prior work", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "briefed resume", workspace_id: ws.id})
      first = stop_acolyte_with_outpost(task.id)

      # Commit some "prior work" into the worktree so the briefing has content.
      wt = first.worktree_path
      File.write!(Path.join(wt, "progress.ex"), "defmodule P, do: nil\n")
      {_, 0} = System.cmd("git", ["-C", wt, "add", "progress.ex"])
      {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "-m", "did half the work"])
      _ = repo

      # The worktree was cut from main, so the briefing diffs against main.
      {:ok, prefix} = Arbiter.Worker.ResumeContext.build(task, wt, "main")

      assert prefix =~ "did half the work"
      assert prefix =~ "RESUMING work on task #{task.id}"
    end

    test "refuses when there is no preserved worktree", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no worktree", workspace_id: ws.id})
      first = stop_acolyte_with_outpost(task.id)

      # Tear the worktree down — nothing left to resume.
      Arbiter.Worker.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      assert {:error, :no_outpost} = Dispatch.resume(task.id, start_driver: false)
    end

    test "refuses to resume a closed task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "closed resume", workspace_id: ws.id})
      _ = stop_acolyte_with_outpost(task.id)
      {:ok, _} = Ash.update(task, %{}, action: :close)

      assert {:error, {:task_closed, _}} = Dispatch.resume(task.id, start_driver: false)
    end

    test "refuses while an worker is still actively working", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "active resume", workspace_id: ws.id})
      # Dispatch but DON'T stop — the worker is live (:idle/:running), not stopped.
      {:ok, _live} = Dispatch.dispatch(task.id, repo: "rs/repo", start_driver: false)

      assert {:error, {:acolyte_active, _status}} =
               Dispatch.resume(task.id, start_driver: false)
    end

    test "inherits the repo from the prior run when omitted", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "repo inherit", workspace_id: ws.id})
      _ = stop_acolyte_with_outpost(task.id)

      # No repo passed — must inherit "rs/repo" from the prior run record.
      {:ok, result} =
        Dispatch.resume(task.id, start_driver: false, claude_command: ["sleep", "2"])

      assert is_binary(result.worktree_path)
    end
  end

  describe "review dispatch (review: true)" do
    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-review-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      prior = Application.get_env(:arbiter, @env_key)
      Application.put_env(:arbiter, @env_key, %{"rv/repo" => repo})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, @env_key, prior),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "review: true skips the worktree and attaches the CodeReview workflow",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review me", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id, repo: "rv/repo", review: true, start_driver: false)

      # No per-task branch, no worktree.
      assert result.worktree_path == nil

      # Workflow attached is CodeReview, not Work.
      machine_state = Arbiter.Workflows.MachineState |> Ash.get!(result.machine_id)
      assert machine_state.workflow_module == inspect(Arbiter.Workflows.CodeReview)

      # Worker is tagged review_only so completion bypasses the merge queue.
      snap = Worker.state(result.worker_pid)
      assert snap.meta[:review_only] == true
      refute Map.has_key?(snap.meta, :branch)
    end

    test "review prompt mentions the task's tracker ref and bans pushes/merges",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "external pr review",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "999"
        })

      prompt =
        Arbiter.Worker.Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "reviewer worker"
      assert prompt =~ "github:999"
      assert prompt =~ "Do NOT push"
      assert prompt =~ "Do NOT merge"
      assert prompt =~ "arb done"

      # The work prompt is still produced by default for non-review dispatches.
      work = Arbiter.Worker.Dispatch.prompt_for_task(task, [])
      assert work =~ "working autonomously"
      refute work =~ "reviewer worker"
    end

    test "review prompt uses pr_ref when set, not tracker_ref (issue vs PR number fix)",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "pr ref takes precedence",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "93"
        })

      {:ok, task} = Ash.update(task, %{pr_ref: "123"}, action: :update)

      prompt = Arbiter.Worker.Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "github:123"
      refute prompt =~ "github:93"
    end

    test "review with start_claude: true uses the repo path as cwd when no worktree",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review w/ claude", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "rv/repo",
          review: true,
          start_claude: true,
          start_driver: false,
          # A no-op argv standing in for a real claude session — proves the
          # port opened, which means the cwd resolution succeeded.
          claude_command: ["true"]
        )

      assert is_port(result.claude_port)
      assert result.worktree_path == nil
    end

    test "review with start_claude: true and an unresolvable repo errors",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no cwd", workspace_id: ws.id})

      assert {:error, {:repo_not_found, "no-such-repo"}} =
               Dispatch.dispatch(task.id,
                 repo: "no-such-repo",
                 review: true,
                 start_claude: true,
                 claude_command: ["true"]
               )
    end
  end

  describe "real-work repo resolution (bd-1ziw04)" do
    # Tests verify that start_claude: true dispatches fail loudly when no repo
    # can be resolved, and auto-select when exactly one repo is available.

    @env_key :repo_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "dispatch-repo-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_repo_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_repo_paths,
          do: Application.put_env(:arbiter, @env_key, prior_repo_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "0 repos: start_claude: true with no repo and empty :repo_paths fails loudly",
         %{ws: ws} do
      Application.delete_env(:arbiter, @env_key)
      {:ok, task} = Ash.create(Issue, %{title: "no repos", workspace_id: ws.id})

      assert {:error, :no_repo_configured} =
               Dispatch.dispatch(task.id,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      # Refused BEFORE any state mutation: task still :open, no worker.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil
    end

    test "1 repo: start_claude: true with no repo auto-selects the sole configured repo",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"sole/repo" => repo})
      {:ok, task} = Ash.create(Issue, %{title: "auto-select", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["sleep", "2"],
                 preflight: false
               )

      # Worktree provisioned using the auto-selected repo.
      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "multi-repo: start_claude: true with no repo and multiple :repo_paths fails loudly",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"repo/a" => repo, "repo/b" => repo})
      {:ok, task} = Ash.create(Issue, %{title: "multi repos", workspace_id: ws.id})

      assert {:error, {:ambiguous_repo, repos}} =
               Dispatch.dispatch(task.id,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert "repo/a" in repos
      assert "repo/b" in repos

      # Refused before any state mutation.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil
    end

    test "explicit repo not in :repo_paths fails with {:repo_not_found, repo}",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"real/repo" => repo})
      {:ok, task} = Ash.create(Issue, %{title: "bad repo", workspace_id: ws.id})

      assert {:error, {:repo_not_found, "no-such/repo"}} =
               Dispatch.dispatch(task.id,
                 repo: "no-such/repo",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      # Refused before any state mutation.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :open
      assert Worker.whereis(task.id) == nil
    end

    test "dry dispatch (no start_claude) is unaffected — still parks without a repo", %{ws: ws} do
      Application.delete_env(:arbiter, @env_key)
      {:ok, task} = Ash.create(Issue, %{title: "dry dispatch", workspace_id: ws.id})

      # No --with-claude → no repo required → succeeds and parks as :in_progress.
      assert {:ok, result} = Dispatch.dispatch(task.id, start_driver: false)
      assert result.task.status == :in_progress
      assert result.worktree_path == nil
    end
  end
end
