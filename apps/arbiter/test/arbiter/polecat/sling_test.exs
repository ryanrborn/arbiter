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

    # Build a `claude`-named shim on PATH that writes its argv (one per line) to
    # `argv_file` and exits 0. Used to verify the spawn argv assembled by the
    # adapter path (Agents.Claude.default_argv) — `--model <name>` is the bit
    # Phase A specifically wires up.
    defp stub_claude_on_path(tmp, argv_file) do
      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, "claude")

      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> #{argv_file}; done
      exit 0
      """)

      File.chmod!(stub, 0o755)

      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{stub_dir}:#{old_path}")

      on_exit(fn -> System.put_env("PATH", old_path) end)

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
      repo = seed_repo!(tmp, "repo")

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

      repo = seed_repo!(tmp, "drvrepo")

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
      # the polecat would stay :idle until "arb done" fires.
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

    test "passes the workspace `agent.config.model` as `--model` to claude",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "model-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "mwt"))
      Application.put_env(:arbiter, :rig_paths, %{"m/rig" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :rig_paths)
      end)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
          }
        })

      {:ok, bead} = Ash.create(Issue, %{title: "model bead", workspace_id: ws.id})

      {:ok, _result} =
        Sling.sling(bead.id,
          rig: "m/rig",
          start_driver: false,
          start_claude: true
        )

      wait_until(fn -> File.exists?(argv_file) end)
      args = File.read!(argv_file) |> String.split("\n", trim: true)
      assert "--model" in args
      assert "sonnet" in args
    end

    test "per-sling :model opt overrides the workspace's routed model",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "override-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "owt"))
      Application.put_env(:arbiter, :rig_paths, %{"o/rig" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :rig_paths)
      end)

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}}
          }
        })

      {:ok, bead} = Ash.create(Issue, %{title: "override", workspace_id: ws.id})

      {:ok, _result} =
        Sling.sling(bead.id,
          rig: "o/rig",
          start_driver: false,
          start_claude: true,
          model: "opus"
        )

      wait_until(fn -> File.exists?(argv_file) end)
      args = File.read!(argv_file) |> String.split("\n", trim: true)
      assert "--model" in args
      assert "opus" in args
      refute "sonnet" in args
    end

    test "ByPriority routing picks --model from `routing.rules[Pn]`",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "prio-repo")
      Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "pwt"))
      Application.put_env(:arbiter, :rig_paths, %{"p/rig" => repo})

      on_exit(fn ->
        Application.delete_env(:arbiter, :worktree_root)
        Application.delete_env(:arbiter, :rig_paths)
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
      {:ok, bead} =
        Ash.create(Issue, %{title: "trivial", workspace_id: ws.id, priority: 4})

      {:ok, _result} =
        Sling.sling(bead.id, rig: "p/rig", start_driver: false, start_claude: true)

      wait_until(fn -> File.exists?(argv_file) end)
      args = File.read!(argv_file) |> String.split("\n", trim: true)
      assert "--model" in args
      assert "haiku" in args
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

      # Bare origin: Worktree.create fetches from `origin` and branches from
      # `origin/<base>`. Tests set it up explicitly so the rig has an upstream
      # the provisioning path can consult.
      remote = Path.join(tmp, "remote.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

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

      %{repo: repo, remote: remote, worktree_root: worktree_root, tmp: tmp}
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
            "rig_paths" => %{"bb/rig" => repo},
            "merge" => %{"base" => "develop"}
          }
        })

      {:ok, bead} = Ash.create(Issue, %{title: "non-main base", workspace_id: ws_local.id})

      {:ok, result} = Sling.sling(bead.id, rig: "bb/rig", start_driver: false)

      # Worktree was cut from `develop`: the develop-only file is present.
      assert is_binary(result.worktree_path)
      assert File.exists?(Path.join(result.worktree_path, "DEVELOP_ONLY.md"))

      # Merge target_branch threaded into the polecat's meta matches the base,
      # so the completed branch merges back into `develop`, not `main`.
      assert %{target_branch: "develop"} = Polecat.state(result.polecat_pid).meta
    end

    test "skips worktree when provision_worktree: false", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "opt-out", workspace_id: ws.id})

      {:ok, result} =
        Sling.sling(bead.id, rig: "st/rig", start_driver: false, provision_worktree: false)

      assert result.worktree_path == nil
    end

    test "worktree starts from upstream tip even when the rig's local base is stale",
         %{repo: repo, remote: remote, tmp: tmp, ws: ws} do
      # Reproduces the 2026-06-04 incident: a second clone advances origin/main;
      # the rig's local `main` stays put. Sling must still produce a worktree
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

      {:ok, bead} = Ash.create(Issue, %{title: "stale local base", workspace_id: ws.id})

      {:ok, result} = Sling.sling(bead.id, rig: "st/rig", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "UPSTREAM.md"))
    end

    test "fetch failure aborts the sling with a clear error", %{ws: ws, tmp: tmp} do
      # Rig with a broken `origin` (points at a nonexistent path): the fetch
      # must fail and the sling abort with a structured error rather than
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

      Application.put_env(:arbiter, :rig_paths, %{"broken/rig" => broken})

      {:ok, bead} = Ash.create(Issue, %{title: "fetch failure", workspace_id: ws.id})

      assert {:error, {:worktree_failed, reason}} =
               Sling.sling(bead.id, rig: "broken/rig", start_driver: false)

      assert match?({:fetch_failed, _}, reason) or match?({:missing_origin_ref, _}, reason),
             "expected fetch_failed or missing_origin_ref, got: #{inspect(reason)}"
    end

    test "per-bead target_branch overrides the workspace default", %{repo: repo, remote: remote} do
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
          name: "per-bead-target-#{System.unique_integer([:positive])}",
          prefix: "pb",
          # Workspace default is the bare "main"; the bead overrides to dolphin.
          config: %{"rig_paths" => %{"pb/rig" => repo}, "merge" => %{"base" => "main"}}
        })

      {:ok, bead} =
        Ash.create(Issue, %{
          title: "per-bead target",
          workspace_id: ws_local.id,
          target_branch: "dolphin"
        })

      {:ok, result} = Sling.sling(bead.id, rig: "pb/rig", start_driver: false)

      # The bead-specified target wins: the worktree carries the dolphin file
      # and the polecat's meta records dolphin as the merge target.
      assert File.exists?(Path.join(result.worktree_path, "DOLPHIN.md"))
      assert %{target_branch: "dolphin"} = Polecat.state(result.polecat_pid).meta
    end

    test "per-rig target_branch default applies when bead has none", %{repo: repo} do
      # Push a `dolphin` branch and configure the rig to default to it.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "dolphin"])
      File.write!(Path.join(repo, "DOLPHIN.md"), "dolphin\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "DOLPHIN.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "dolphin"])
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "main"])

      {:ok, ws_local} =
        Ash.create(Workspace, %{
          name: "rig-default-target-#{System.unique_integer([:positive])}",
          prefix: "rd",
          # Rig-level default beats the workspace default ("main").
          config: %{
            "rig_paths" => %{
              "rd/rig" => %{"path" => repo, "target_branch" => "dolphin"}
            },
            "merge" => %{"base" => "main"}
          }
        })

      {:ok, bead} = Ash.create(Issue, %{title: "rig default", workspace_id: ws_local.id})

      {:ok, result} = Sling.sling(bead.id, rig: "rd/rig", start_driver: false)

      assert File.exists?(Path.join(result.worktree_path, "DOLPHIN.md"))
      assert %{target_branch: "dolphin"} = Polecat.state(result.polecat_pid).meta
    end
  end

  describe "review dispatch (review: true)" do
    @env_key :rig_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "sling-review-#{:erlang.unique_integer([:positive])}")
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
      Application.put_env(:arbiter, @env_key, %{"rv/rig" => repo})

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
      {:ok, bead} = Ash.create(Issue, %{title: "review me", workspace_id: ws.id})

      {:ok, result} =
        Sling.sling(bead.id, rig: "rv/rig", review: true, start_driver: false)

      # No per-bead branch, no worktree.
      assert result.worktree_path == nil

      # Workflow attached is CodeReview, not Work.
      machine_state = Arbiter.Workflows.MachineState |> Ash.get!(result.machine_id)
      assert machine_state.workflow_module == inspect(Arbiter.Workflows.CodeReview)

      # Polecat is tagged review_only so completion bypasses the Crucible.
      snap = Polecat.state(result.polecat_pid)
      assert snap.meta[:review_only] == true
      refute Map.has_key?(snap.meta, :branch)
    end

    test "review prompt mentions the bead's tracker ref and bans pushes/merges",
         %{ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "external pr review",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "999"
        })

      prompt =
        Arbiter.Polecat.Sling.prompt_for_bead(bead, review: true)

      assert prompt =~ "reviewer polecat"
      assert prompt =~ "github:999"
      assert prompt =~ "Do NOT push"
      assert prompt =~ "Do NOT merge"
      assert prompt =~ "arb done"

      # The work prompt is still produced by default for non-review dispatches.
      work = Arbiter.Polecat.Sling.prompt_for_bead(bead, [])
      assert work =~ "working autonomously"
      refute work =~ "reviewer polecat"
    end

    test "review with start_claude: true uses the rig path as cwd when no worktree",
         %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "review w/ claude", workspace_id: ws.id})

      {:ok, result} =
        Sling.sling(bead.id,
          rig: "rv/rig",
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

    test "review without a worktree AND without a mapped rig errors",
         %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no cwd", workspace_id: ws.id})

      assert {:error, :missing_worktree} =
               Sling.sling(bead.id,
                 rig: "no-such-rig",
                 review: true,
                 start_claude: true,
                 claude_command: ["true"]
               )
    end
  end
end
