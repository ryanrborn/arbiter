defmodule Arbiter.Polecat.SlingTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Sling
  alias Arbiter.Polecats.Run
  require Ash.Query

  # The most recent polecat_run for a bead — used by the resume tests to assert
  # run lineage (resumed_from_run_id) and terminal status.
  defp latest_run(bead_id) do
    Run
    |> Ash.Query.filter(bead_id == ^bead_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

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

  describe "pre-flight auth check (bd-awi4nw)" do
    alias Arbiter.Messages.Message

    # bd-1ziw04: real-work slings now require the rig to be in :rig_paths.
    # Configure a minimal entry so rig validation passes and the preflight check
    # actually fires. No real git repo is needed — the probe aborts before the
    # worktree provisioning step.
    setup do
      prior = Application.get_env(:arbiter, :rig_paths)
      Application.put_env(:arbiter, :rig_paths, %{"test/rig" => "/tmp"})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :rig_paths, prior),
          else: Application.delete_env(:arbiter, :rig_paths)
      end)
    end

    test "a failing auth probe REFUSES to sling and leaves the bead untouched", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "auth gate", workspace_id: ws.id})

      assert {:error, {:auth_check_failed, reason}} =
               Sling.sling(bead.id,
                 rig: "test/rig",
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

      # Refused BEFORE any state mutation: bead is still :open, no polecat spawned.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :open
      assert Polecat.whereis(bead.id) == nil
    end

    test "a failed pre-flight escalates to the Admiral with a re-auth message", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "auth escalate", workspace_id: ws.id})

      {:error, {:auth_check_failed, _}} =
        Sling.sling(bead.id,
          rig: "test/rig",
          start_driver: false,
          start_claude: true,
          probe_command: ["sh", "-c", "echo '401 invalid authentication credentials'; exit 1"],
          probe_env: []
        )

      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.directive_ref == bead.id))

      assert escalation.subject =~ "pre-flight auth failed"
      assert escalation.body =~ "Re-authenticate"
    end

    test "pre-flight is skipped when start_claude is false (default path unaffected)", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no preflight", workspace_id: ws.id})

      # Even with a probe_command that would 401, no start_claude means no probe.
      # provision_worktree: false so we don't try to git-fetch /tmp.
      assert {:ok, result} =
               Sling.sling(bead.id,
                 rig: "test/rig",
                 start_driver: false,
                 provision_worktree: false,
                 probe_command: ["sh", "-c", "exit 1"]
               )

      assert result.bead.status == :in_progress
    end

    test "preflight: false bypasses the probe even with start_claude", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "bypass", workspace_id: ws.id})

      # start_claude + preflight: false + provision_worktree: false errors at the
      # claude-start step (:missing_worktree) — proving we got PAST the (disabled)
      # preflight rather than being refused by it. The rig must be valid so the
      # rig-resolution guard (bd-1ziw04) passes before reaching the preflight gate.
      assert {:error, :missing_worktree} =
               Sling.sling(bead.id,
                 rig: "test/rig",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false,
                 probe_command: ["sh", "-c", "echo 401; exit 1"]
               )
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
          # Stand-in for a running `claude --print` session — stays alive (so it
          # isn't caught by bd-awi4nw stop-detection as a died-early acolyte),
          # but proves ClaudeSession.start was wired into Sling.
          claude_command: ["sleep", "2"]
        )

      assert is_port(result.claude_port)
      assert is_binary(result.worktree_path)
    end

    test "start_claude: true with an unresolvable rig returns {:error, {:rig_not_found, rig}}",
         %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no wt", workspace_id: ws.id})

      assert {:error, {:rig_not_found, "no-such-rig"}} =
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
          # A stand-in for a *running* Claude session: it must stay alive for the
          # duration of this test. A command that exits immediately would (since
          # bd-awi4nw) trip stop-detection and fail the polecat — exactly the
          # "acolyte died without `arb done`" path we now catch.
          claude_command: ["sleep", "2"],
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
          start_claude: true,
          # This test asserts the WORK-spawn argv; disable the bd-awi4nw auth
          # pre-flight so its probe (which invokes the same `claude` stub) doesn't
          # write to the shared argv file and race the work spawn's capture.
          preflight: false
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
          model: "opus",
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw).
          preflight: false
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
        Sling.sling(bead.id,
          rig: "p/rig",
          start_driver: false,
          start_claude: true,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw).
          preflight: false
        )

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

    test "attaches to existing branch when re-slinging a reopened bead", %{repo: repo, ws: ws} do
      # Reproduces bd-4tta5n: bead is slung once (branch created), the worktree
      # is cleaned up but the branch remains, then the bead is reopened and
      # re-slung. Worktree.create fails with "already exists"; sling must fall
      # back to Worktree.attach and succeed.
      {:ok, bead} =
        Ash.create(Issue, %{title: "re-sling after review", workspace_id: ws.id})

      # First sling — provisions the worktree, creating the branch locally.
      {:ok, first} = Sling.sling(bead.id, rig: "st/rig", start_driver: false)
      assert is_binary(first.worktree_path)
      branch = Arbiter.Polecat.BranchNamer.derive(bead)

      # Simulate Driver cleanup: remove the worktree directory but leave the
      # branch (Worktree.cleanup removes the worktree, not the branch).
      Arbiter.Polecat.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      # Confirm the branch still exists in the repo.
      {branches, 0} = System.cmd("git", ["-C", repo, "branch", "--list", branch])
      assert String.contains?(branches, branch)

      # Reopen bead so it can be re-slung.
      {:ok, bead} = Ash.update(bead, %{status: :open})

      # Second sling — branch already exists; must attach instead of creating.
      assert {:ok, second} = Sling.sling(bead.id, rig: "st/rig", start_driver: false)
      assert is_binary(second.worktree_path)
      assert File.dir?(second.worktree_path)
      assert {:ok, ^branch} = Arbiter.Polecat.Worktree.current_branch(second.worktree_path)
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

  describe "work prompt completion notes (tracker-backed beads)" do
    test "instructs a tracker-backed acolyte to produce QA + Deployment notes", %{ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "tracked work",
          workspace_id: ws.id,
          tracker_type: "jira",
          tracker_ref: "VR-17585",
          skip_upstream_create: true
        })

      prompt = Sling.prompt_for_bead(bead, [])

      assert prompt =~ "backed by an external tracker"
      assert prompt =~ "--qa-notes"
      assert prompt =~ "--deployment-notes"
      assert prompt =~ "arb issue update #{bead.id}"
    end

    test "untracked beads get no completion-notes step", %{ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{title: "local work", workspace_id: ws.id, tracker_type: "none"})

      prompt = Sling.prompt_for_bead(bead, [])

      refute prompt =~ "--qa-notes"
      refute prompt =~ "backed by an external tracker"
    end

    test "a tracker type without a tracker_ref gets no completion-notes step", %{ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "tracked but unlinked",
          workspace_id: ws.id,
          tracker_type: "jira",
          tracker_ref: nil,
          skip_upstream_create: true
        })

      prompt = Sling.prompt_for_bead(bead, [])

      refute prompt =~ "--qa-notes"
    end
  end

  describe "resume/2 (bd-auma3z)" do
    @env_key :rig_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "sling-resume-#{:erlang.unique_integer([:positive])}")
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
      prior_rig_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)
      Application.put_env(:arbiter, @env_key, %{"rs/rig" => repo})

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

    # Sling a bead, provisioning its worktree, then simulate a mid-work stop:
    # the polecat fails (lingers in :failed, registered) with the outpost left
    # on disk — exactly the state `arb resume` is built to recover from.
    defp stop_acolyte_with_outpost(bead_id) do
      {:ok, first} = Sling.sling(bead_id, rig: "rs/rig", start_driver: false)
      assert is_binary(first.worktree_path)
      :ok = Polecat.fail(first.polecat_pid, :token_exhausted)
      first
    end

    test "reuses the outpost, links the new run, and boots into :resuming", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "resume work", workspace_id: ws.id})
      first = stop_acolyte_with_outpost(bead.id)

      prior_run = latest_run(bead.id)
      assert prior_run.status == :failed

      {:ok, result} =
        Sling.resume(bead.id, start_driver: false, claude_command: ["sleep", "2"])

      # Same outpost, fresh polecat.
      assert result.worktree_path == first.worktree_path
      assert result.polecat_pid != first.polecat_pid

      snap = Polecat.state(result.polecat_pid)
      assert snap.meta[:resume] == true
      # The polecat advanced :resuming -> :running when the claude session started.
      assert snap.status == :running

      # The new run is linked to the prior one.
      new_run = latest_run(bead.id)
      assert new_run.id != prior_run.id
      assert new_run.resumed_from_run_id == prior_run.id
    end

    test "the resumed acolyte's prompt is briefed with the prior work", %{ws: ws, repo: repo} do
      {:ok, bead} = Ash.create(Issue, %{title: "briefed resume", workspace_id: ws.id})
      first = stop_acolyte_with_outpost(bead.id)

      # Commit some "prior work" into the outpost so the briefing has content.
      wt = first.worktree_path
      File.write!(Path.join(wt, "progress.ex"), "defmodule P, do: nil\n")
      {_, 0} = System.cmd("git", ["-C", wt, "add", "progress.ex"])
      {_, 0} = System.cmd("git", ["-C", wt, "commit", "-q", "-m", "did half the work"])
      _ = repo

      # The outpost was cut from main, so the briefing diffs against main.
      {:ok, prefix} = Arbiter.Polecat.ResumeContext.build(bead, wt, "main")

      assert prefix =~ "did half the work"
      assert prefix =~ "RESUMING work on bead #{bead.id}"
    end

    test "refuses when there is no preserved outpost", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no outpost", workspace_id: ws.id})
      first = stop_acolyte_with_outpost(bead.id)

      # Tear the outpost down — nothing left to resume.
      Arbiter.Polecat.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      assert {:error, :no_outpost} = Sling.resume(bead.id, start_driver: false)
    end

    test "refuses to resume a closed bead", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "closed resume", workspace_id: ws.id})
      _ = stop_acolyte_with_outpost(bead.id)
      {:ok, _} = Ash.update(bead, %{}, action: :close)

      assert {:error, {:bead_closed, _}} = Sling.resume(bead.id, start_driver: false)
    end

    test "refuses while an acolyte is still actively working", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "active resume", workspace_id: ws.id})
      # Sling but DON'T stop — the polecat is live (:idle/:running), not stopped.
      {:ok, _live} = Sling.sling(bead.id, rig: "rs/rig", start_driver: false)

      assert {:error, {:acolyte_active, _status}} =
               Sling.resume(bead.id, start_driver: false)
    end

    test "inherits the rig from the prior run when omitted", %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "rig inherit", workspace_id: ws.id})
      _ = stop_acolyte_with_outpost(bead.id)

      # No rig passed — must inherit "rs/rig" from the prior run record.
      {:ok, result} =
        Sling.resume(bead.id, start_driver: false, claude_command: ["sleep", "2"])

      assert is_binary(result.worktree_path)
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

    test "review prompt uses pr_ref when set, not tracker_ref (issue vs PR number fix)",
         %{ws: ws} do
      {:ok, bead} =
        Ash.create(Issue, %{
          title: "pr ref takes precedence",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "93"
        })

      {:ok, bead} = Ash.update(bead, %{pr_ref: "123"}, action: :update)

      prompt = Arbiter.Polecat.Sling.prompt_for_bead(bead, review: true)

      assert prompt =~ "github:123"
      refute prompt =~ "github:93"
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

    test "review with start_claude: true and an unresolvable rig errors",
         %{ws: ws} do
      {:ok, bead} = Ash.create(Issue, %{title: "no cwd", workspace_id: ws.id})

      assert {:error, {:rig_not_found, "no-such-rig"}} =
               Sling.sling(bead.id,
                 rig: "no-such-rig",
                 review: true,
                 start_claude: true,
                 claude_command: ["true"]
               )
    end
  end

  describe "real-work rig resolution (bd-1ziw04)" do
    # Tests verify that start_claude: true dispatches fail loudly when no rig
    # can be resolved, and auto-select when exactly one rig is available.

    @env_key :rig_paths

    setup do
      tmp = Path.join(System.tmp_dir!(), "sling-rig-#{:erlang.unique_integer([:positive])}")
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
      prior_rig_paths = Application.get_env(:arbiter, @env_key)

      Application.put_env(:arbiter, :worktree_root, worktree_root)

      on_exit(fn ->
        if prior_wt_root,
          do: Application.put_env(:arbiter, :worktree_root, prior_wt_root),
          else: Application.delete_env(:arbiter, :worktree_root)

        if prior_rig_paths,
          do: Application.put_env(:arbiter, @env_key, prior_rig_paths),
          else: Application.delete_env(:arbiter, @env_key)

        File.rm_rf!(tmp)
      end)

      %{repo: repo}
    end

    test "0 rigs: start_claude: true with no rig and empty :rig_paths fails loudly",
         %{ws: ws} do
      Application.delete_env(:arbiter, @env_key)
      {:ok, bead} = Ash.create(Issue, %{title: "no rigs", workspace_id: ws.id})

      assert {:error, :no_rig_configured} =
               Sling.sling(bead.id,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      # Refused BEFORE any state mutation: bead still :open, no polecat.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :open
      assert Polecat.whereis(bead.id) == nil
    end

    test "1 rig: start_claude: true with no rig auto-selects the sole configured rig",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"sole/rig" => repo})
      {:ok, bead} = Ash.create(Issue, %{title: "auto-select", workspace_id: ws.id})

      assert {:ok, result} =
               Sling.sling(bead.id,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["sleep", "2"],
                 preflight: false
               )

      # Worktree provisioned using the auto-selected rig.
      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
    end

    test "multi-rig: start_claude: true with no rig and multiple :rig_paths fails loudly",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"rig/a" => repo, "rig/b" => repo})
      {:ok, bead} = Ash.create(Issue, %{title: "multi rigs", workspace_id: ws.id})

      assert {:error, {:ambiguous_rig, rigs}} =
               Sling.sling(bead.id,
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert "rig/a" in rigs
      assert "rig/b" in rigs

      # Refused before any state mutation.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :open
      assert Polecat.whereis(bead.id) == nil
    end

    test "explicit rig not in :rig_paths fails with {:rig_not_found, rig}",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{"real/rig" => repo})
      {:ok, bead} = Ash.create(Issue, %{title: "bad rig", workspace_id: ws.id})

      assert {:error, {:rig_not_found, "no-such/rig"}} =
               Sling.sling(bead.id,
                 rig: "no-such/rig",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      # Refused before any state mutation.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :open
      assert Polecat.whereis(bead.id) == nil
    end

    test "dry sling (no start_claude) is unaffected — still parks without a rig", %{ws: ws} do
      Application.delete_env(:arbiter, @env_key)
      {:ok, bead} = Ash.create(Issue, %{title: "dry sling", workspace_id: ws.id})

      # No --with-claude → no rig required → succeeds and parks as :in_progress.
      assert {:ok, result} = Sling.sling(bead.id, start_driver: false)
      assert result.bead.status == :in_progress
      assert result.worktree_path == nil
    end
  end
end
