defmodule Arbiter.Polecat.SlingTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Sling

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "sling-test-ws", prefix: "st"})
    {:ok, ws: ws}
  end

  describe "sling/2 happy path" do
    test "spawns a polecat and starts a workflow machine", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "hello world", workspace_id: ws.id})

      assert {:ok, result} = Sling.sling(bead.id, rig: "test/rig", start_driver: false)
      assert result.bead.status == :in_progress
      assert is_pid(result.polecat_pid)
      assert is_pid(result.machine_pid)
      assert is_binary(result.machine_id)
      assert result.driver_pid == nil

      # polecat is registered
      assert Polecat.whereis(bead.id) == result.polecat_pid
    end

    test "idempotent for already-in_progress beads", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _first} = Sling.sling(bead.id, rig: "r", start_driver: false)

      # Second sling: bead is already :in_progress; polecat already exists.
      # Should NOT crash; should return the existing polecat pid.
      assert {:ok, second} = Sling.sling(bead.id, rig: "r", start_driver: false)
      assert second.bead.status == :in_progress
      assert Polecat.whereis(bead.id) == second.polecat_pid
    end

    test "starts a Driver by default and drives bead to :closed", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "drive me", workspace_id: ws.id})

      assert {:ok, result} = Sling.sling(bead.id, rig: "test/rig", interval_ms: 5)
      assert is_pid(result.driver_pid)
      assert Process.alive?(result.driver_pid)

      # Wait for the driver to walk Workflows.Work to completion. The work
      # workflow has 5 no-op steps; at 5ms intervals it should finish well
      # under 500ms.
      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe "sling/2 error cases" do
    test "non-existent bead returns {:error, {:bead_not_found, _}}" do
      assert {:error, {:bead_not_found, "no-such-bead-123"}} =
               Sling.sling("no-such-bead-123")
    end

    test "closed beads cannot be slung", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      {:ok, _closed} = Ash.update(bead, %{}, action: :close)

      assert {:error, {:bead_closed, _}} = Sling.sling(bead.id)
    end
  end

  describe "sling/2 result shape" do
    test "returns a map with the standard keys", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "shape", workspace_id: ws.id})
      {:ok, result} = Sling.sling(bead.id, rig: "test/rig", start_driver: false)

      for key <- [:bead, :polecat_pid, :machine_id, :machine_pid, :driver_pid, :worktree_path] do
        assert Map.has_key?(result, key), "missing #{key}"
      end
    end
  end

  describe "Claude session (start_claude opt)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "sling-claude-#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      on_exit(fn -> File.rm_rf!(tmp) end)

      %{tmp: tmp}
    end

    test "defaults to start_claude: false → claude_port is nil", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no claude", workspace_id: ws.id})

      {:ok, result} = Sling.sling(bead.id, rig: "test/rig", start_driver: false)
      assert result.claude_port == nil
    end

    test "start_claude: true with claude_command spawns a subprocess in the worktree",
         %{ws: ws, tmp: tmp} do
      {:ok, bead} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

      # Use the tmp dir as a stand-in worktree by passing it through manually.
      # Sling.maybe_provision_worktree returns nil when rig is unmapped, but
      # we need a worktree_path for ClaudeSession; so we point a tmp rig at
      # a real git repo and let Sling provision the worktree itself.
      repo = Path.join(tmp, "repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      Application.put_env(:arbiter, :rig_paths, %{"claude/rig" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :rig_paths)
      end)

      {:ok, result} =
        Sling.sling(bead.id,
          rig: "claude/rig",
          start_driver: false,
          start_claude: true,
          # Stand-in for `claude --print prompt` — runs and exits quickly,
          # but proves ClaudeSession.start was wired into Sling.
          claude_command: ["echo", "hello from a polecat"]
        )

      assert is_port(result.claude_port)
      assert is_binary(result.worktree_path)
    end

    test "start_claude: true without a worktree returns {:error, :missing_worktree}",
         %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no wt", workspace_id: ws.id})

      assert {:error, :missing_worktree} =
               Sling.sling(bead.id,
                 rig: "no-such-rig",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["echo", "x"]
               )
    end

    test "start_claude: true implies claude_driven Driver mode (no workflow ticking)",
         %{ws: ws, tmp: tmp} do
      {:ok, bead} = Ash.create(Issue, %{title: "drvr-mode", workspace_id: ws.id})

      repo = Path.join(tmp, "drvrepo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "drv-wt"))
      Application.put_env(:arbiter, :rig_paths, %{"drvr/rig" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :rig_paths)
      end)

      {:ok, result} =
        Sling.sling(bead.id,
          rig: "drvr/rig",
          start_claude: true,
          claude_command: ["true"],
          # Speed up the polecat-status polling for the assertion below.
          interval_ms: 5,
          max_ticks: 50
        )

      assert is_pid(result.driver_pid)

      # Sling must have nudged the polecat out of :idle so the UI/CLI
      # report a meaningful status while Claude works. In claude_driven
      # mode the Driver never ticks the Machine, so without this nudge
      # the polecat would stay :idle until "gt done" fires.
      snap = Polecat.state(result.polecat_pid)
      assert snap.status == :running
      assert snap.current_step == :claude

      # If the Driver were in workflow mode, the no-op steps would close
      # the bead in ~500ms. Wait that long and verify the bead is still
      # :in_progress — the Driver is waiting on the polecat instead.
      Process.sleep(150)

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :in_progress

      # Now simulate Claude completion and let the Driver react.
      :ok = Polecat.complete(result.polecat_pid, :claude_done)

      ref = Process.monitor(result.driver_pid)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 2_000

      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :closed
    end
  end

  describe "worktree provisioning" do
    @env_key :rig_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "sling-wt-#{:erlang.unique_integer([:positive])}")
      repo = Path.join(tmp, "source")
      File.mkdir_p!(repo)

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test User"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "initial"])

      worktree_root = Path.join(tmp, "worktrees")
      File.mkdir_p!(worktree_root)

      prior_wt_root = Application.get_env(:arbiter, :worktree_root)
      prior_rig_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"st/rig" => repo})

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_rig_paths,
          do: Application.put_env(:arbiter, @env_key, prior_rig_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo, worktree_root: worktree_root}
    end

    test "creates a worktree on a derived branch when rig is configured",
         %{ws: ws, worktree_root: root} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "implement the thing",
          workspace_id: ws.id,
          issue_type: :feature
        })

      {:ok, result} =
        Sling.sling(bead.id, rig: "st/rig", start_driver: false)

      assert is_binary(result.worktree_path)
      assert String.starts_with?(result.worktree_path, root)
      assert File.dir?(result.worktree_path)

      # Branch matches BranchNamer's derivation.
      branch = Arbiter.Polecat.BranchNamer.derive(bead)
      assert {:ok, ^branch} = Arbiter.Polecat.Worktree.current_branch(result.worktree_path)
    end

    test "skips worktree when rig is not in rig_paths", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "unmapped", workspace_id: ws.id})

      {:ok, result} = Sling.sling(bead.id, rig: "no-such-rig", start_driver: false)
      assert result.worktree_path == nil
    end

    test "per-workspace rig_paths overrides the Application env", %{repo: repo} do
      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "per-ws-#{System.unique_integer([:positive])}",
          prefix: "pw",
          config: %{"rig_paths" => %{"per-ws/rig" => repo}}
        })

      {:ok, bead} = Ash.create(Issue, %{title: "per-ws", workspace_id: ws_local.id})

      # `per-ws/rig` is NOT in Application env — only in this workspace's
      # config. Sling must still find it.
      {:ok, result} = Sling.sling(bead.id, rig: "per-ws/rig", start_driver: false)
      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "skips worktree when provision_worktree: false", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "opt-out", workspace_id: ws.id})

      {:ok, result} =
        Sling.sling(bead.id, rig: "st/rig", start_driver: false, provision_worktree: false)

      assert result.worktree_path == nil
    end
  end
end
