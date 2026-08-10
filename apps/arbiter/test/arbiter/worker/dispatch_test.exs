defmodule Arbiter.Worker.DispatchTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Usage.Event
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch, Worktree}
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

  # bd-bi5pn0: a step AFTER start_worker/3 (e.g. the Claude subprocess spawn,
  # hit by a transient network/VPN outage in production) can fail while the
  # worker GenServer is already registered `:idle`. Previously that left a
  # zombie `:idle` registration on an `:in_progress` task forever — no retry,
  # no escalation — which also permanently blackholed PRPatrol dedup for the
  # underlying PR. dispatch/2 must instead fail the just-started worker and
  # escalate to the coordinator.
  describe "post-start_worker spawn failure does not zombie (bd-bi5pn0)" do
    alias Arbiter.Messages.Message

    # bd-1ziw04: real-work dispatches require the repo to be in :repo_paths.
    setup do
      prior = Application.get_env(:arbiter, :repo_paths)
      Application.put_env(:arbiter, :repo_paths, %{"test/repo" => "/tmp"})

      on_exit(fn ->
        if prior,
          do: Application.put_env(:arbiter, :repo_paths, prior),
          else: Application.delete_env(:arbiter, :repo_paths)
      end)
    end

    test "fails the worker instead of leaving it idle", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "spawn fails", workspace_id: ws.id})

      # provision_worktree: false + start_claude: true fails inside
      # maybe_start_claude/4 (:missing_worktree) — AFTER start_worker/3 already
      # registered a live `:idle` worker. preflight: false skips the real CLI
      # probe so the test never touches the network.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )

      pid = Worker.whereis(task.id)
      assert is_pid(pid)
      assert Worker.state(pid).status == :failed
      assert Worker.state(pid).meta.stop_reason.category == :spawn_failed
    end

    test "escalates to the Coordinator instead of silently stranding the bead", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "spawn fails escalate", workspace_id: ws.id})

      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 repo: "test/repo",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )

      assert [escalation] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.directive_ref == task.id))

      assert escalation.subject =~ "spawn"
    end
  end

  # bd-49ajyt: PRPatrol/ReviewPatrol dispatch a follow-up with the PR's GitHub
  # "owner/repo" slug as the :repo opt, but a multi-repo workspace's
  # repo_paths/rig_paths map is keyed by *rig name* (e.g. "client"), not by
  # slug. The direct + normalized key lookup misses (a rig name never
  # normalizes to an owner/repo slug), so dispatch used to fail
  # {:repo_not_found}, spinning PRPatrol in a 1/min escalation loop. Dispatch
  # must resolve the slug the same way PRPatrolSupervisor derives patrol repos:
  # by reading each registered rig's `origin` remote.
  describe "owner/repo slug resolves against a rig-name-keyed registry (bd-49ajyt)" do
    # Init a git repo whose `origin` remote is a GitHub slug (SSH form). Not
    # fetched here (provision_worktree: false), so the remote need not exist.
    defp seed_repo_with_github_origin!(tmp, sub, slug) do
      repo = Path.join(tmp, sub)
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])

      {_, 0} =
        System.cmd("git", ["-C", repo, "remote", "add", "origin", "git@github.com:#{slug}.git"])

      repo
    end

    setup %{ws: ws} do
      tmp = Path.join(System.tmp_dir!(), "disp-slug-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      # Registry keyed by rig NAME "client"; the rig's origin resolves to the
      # differently-named slug "leo-technologies-llc/verus-client".
      rig_path = seed_repo_with_github_origin!(tmp, "client", "leo-technologies-llc/verus-client")

      {:ok, ws} =
        Ash.update(ws, %{config: %{"repo_paths" => %{"client" => rig_path}}}, action: :update)

      {:ok, ws: ws, tmp: tmp}
    end

    test "a slug whose rig name differs resolves + dispatches (not {:repo_not_found})",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "slug dispatch", workspace_id: ws.id})

      # If the slug resolves, dispatch gets past the repo guard and fails later
      # at worktree provisioning (:missing_worktree) — the same distinguishable
      # outcome the bd-bi5pn0 tests rely on. The pre-fix behavior was
      # {:error, {:repo_not_found, "leo-technologies-llc/verus-client"}}.
      assert {:error, :missing_worktree} =
               Dispatch.dispatch(task.id,
                 repo: "leo-technologies-llc/verus-client",
                 start_driver: false,
                 start_claude: true,
                 provision_worktree: false,
                 preflight: false
               )
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

    test "a failed pre-flight escalates to the Coordinator with a re-auth message", %{ws: ws} do
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

    # Push a commit to `repo`'s bare origin from a throwaway clone, so `repo`'s
    # own local refs stay stale — the "human checkout hasn't pulled in a month"
    # shape bd-9r1tta is about.
    defp advance_origin!(tmp, repo, file, content) do
      remote = rev_parse_remote!(repo)
      clone = Path.join(tmp, "advance-#{System.unique_integer([:positive])}")
      {_, 0} = System.cmd("git", ["clone", "-q", remote, clone])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", clone, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(clone, file), content)
      {_, 0} = System.cmd("git", ["-C", clone, "add", file])
      {_, 0} = System.cmd("git", ["-C", clone, "commit", "-q", "-m", "advance origin"])
      {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "main"])
      :ok
    end

    defp rev_parse_remote!(repo) do
      {out, 0} = System.cmd("git", ["-C", repo, "remote", "get-url", "origin"])
      String.trim(out)
    end

    defp rev_parse!(path, ref) do
      {out, 0} = System.cmd("git", ["-C", path, "rev-parse", ref])
      String.trim(out)
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

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
      put_app_env(:arbiter, :repo_paths, %{"claude/repo" => repo})

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

    # bd-d5hy7y: at dispatch, ONLY the layered effective skill set is
    # materialized into the worker's worktree as
    # `.claude/skills/<name>/SKILL.md`. A canary skill selected via the
    # workspace layer must land in the worktree; a registry skill NOT selected
    # must not — nothing global leaks (mirrors the spike's canary method).
    test "materializes only the resolved skill set into the worktree (canary)",
         %{tmp: tmp} do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "skill-canary-ws",
          prefix: "sk",
          config: %{"skills" => %{"workspace" => ["dispatch-canary"]}}
        })

      {:ok, _} =
        Arbiter.Skills.create_skill(%{
          name: "dispatch-canary",
          body: "# Canary\nMaterialized by dispatch.",
          activation_mode: :always_on
        })

      # A second skill that is NOT in the effective set — proves selectivity.
      {:ok, _} = Arbiter.Skills.create_skill(%{name: "not-selected", body: "# Nope"})

      repo = seed_repo!(tmp, "canaryrepo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "canary-wt"))
      put_app_env(:arbiter, :repo_paths, %{"canary/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "canary work", workspace_id: ws.id, issue_type: :feature})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "canary/repo",
          start_driver: false,
          start_claude: true,
          claude_command: ["sleep", "2"]
        )

      wt = result.worktree_path
      assert is_binary(wt)

      # The selected canary skill is materialized with its body …
      canary = Path.join(wt, ".claude/skills/dispatch-canary/SKILL.md")
      assert File.exists?(canary)
      assert File.read!(canary) =~ "Materialized by dispatch."

      # … and the unselected skill is NOT.
      refute File.exists?(Path.join(wt, ".claude/skills/not-selected/SKILL.md"))

      # The skills tree is git-excluded so a worker's `git add -A` can't commit
      # it. A linked worktree's `.git` is a gitfile; git only ever reads
      # `info/exclude` from the repo's COMMON dir (`--git-common-dir`), NOT the
      # worktree-private admin dir (`--git-dir`) — see bd-bhrji9 — so that's
      # where AgentConfig.add_to_git_exclude/2 writes it.
      {common_dir, 0} = System.cmd("git", ["-C", wt, "rev-parse", "--git-common-dir"])

      exclude =
        File.read!(Path.expand(Path.join([String.trim(common_dir), "info", "exclude"]), wt))

      assert exclude =~ ".claude/skills/"
    end

    # bd-d5hy7y: an always-on skill is auto-invoked in the worker prompt, while a
    # situational one is advertised but not forced.
    test "work prompt auto-invokes always-on skills and advertises situational ones",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{title: "prompt work", workspace_id: ws.id, issue_type: :feature})

      resolved = [
        %{
          skill: %Arbiter.Skills.Skill{
            name: "tdd",
            body: "x",
            activation_mode: :always_on,
            metadata: %{}
          },
          activation: :always_on
        },
        %{
          skill: %Arbiter.Skills.Skill{
            name: "debug",
            body: "x",
            activation_mode: :situational,
            metadata: %{}
          },
          activation: :situational
        }
      ]

      prompt =
        Dispatch.prompt_for_task(task, worktree_path: "/tmp/wt", resolved_skills: resolved)

      assert prompt =~ "Required skills"
      assert prompt =~ "/tdd"
      assert prompt =~ "Available skills"
      assert prompt =~ "/debug"
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

      put_app_env(:arbiter, :repo_paths, %{"rv/repo" => repo})
      enable_mcp_injection!()

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

    # bd-9r1tta: a review genuinely wants the shared checkout as its cwd — it
    # diffs local branches, which only exist there. But it must not inherit a
    # month-stale idea of what `origin/<target>` points at: a reviewer comparing
    # a PR against a stale base reports conflicts and "missing" upstream work
    # that aren't real. So the dispatch refreshes the remote-tracking ref first
    # — refs only, never the contributor's HEAD/index/working tree.
    test "review dispatch refreshes origin refs in the shared checkout without disturbing it",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "revstale")

      # The human's checkout: parked on a side branch with uncommitted work.
      {_, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-b", "human-wip"])
      File.write!(Path.join(repo, "dirty.md"), "uncommitted\n")
      head_before = rev_parse!(repo, "HEAD")
      origin_ref_before = rev_parse!(repo, "refs/remotes/origin/main")

      # Upstream moves behind the local checkout's back.
      advance_origin!(tmp, repo, "UPSTREAM.md", "merged upstream\n")

      put_app_env(:arbiter, :repo_paths, %{"rv/stale" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "review stale base", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "rv/stale",
          review: true,
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "1"]
        )

      assert result.worktree_path == nil
      assert is_port(result.claude_port)

      # The remote-tracking ref now points at current upstream ...
      assert rev_parse!(repo, "refs/remotes/origin/main") != origin_ref_before

      # ... while nothing the contributor cares about moved: same branch, same
      # HEAD, uncommitted file intact, and the fetched commit is NOT checked out.
      assert {:ok, "human-wip"} = Worktree.current_branch(repo)
      assert rev_parse!(repo, "HEAD") == head_before
      assert File.read!(Path.join(repo, "dirty.md")) == "uncommitted\n"
      refute File.exists?(Path.join(repo, "UPSTREAM.md"))
    end

    # bd-9fjy6j / bd-9r1tta: a task-type issue has no *branch* worktree (the
    # deliverable is notes, not a PR), but Claude still needs a cwd. It used to
    # get the repo's shared main checkout — a human contributor's working
    # directory, on whatever HEAD they left it. bd-9r1tta: it now gets an
    # isolated detached checkout cut from `origin/<target>`, so an audit reads
    # current upstream instead of a month-stale local tree.
    test "task-type dispatch with start_claude runs from a detached checkout at origin, not the stale local one",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "taskrepo")
      advance_origin!(tmp, repo, "ENCRYPTION.md", "PHI encryption merged upstream\n")

      # The local checkout has not fetched — exactly the tonic scenario.
      refute File.exists?(Path.join(repo, "ENCRYPTION.md"))
      local_head_before = rev_parse!(repo, "HEAD")

      # bd-dlv3no's concern, now inherited by task-type dispatches: with
      # injection on, the token-bearing `.mcp.json` must land in the isolated
      # worktree, never in the shared checkout.
      enable_mcp_injection!()

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "taskrepo-wt"))
      put_app_env(:arbiter, :repo_paths, %{"task/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "audit: parity check", issue_type: :task, workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "task/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sh", "-c", "pwd -P > agent-cwd.txt"]
        )

      # Still no *branch* worktree in meta — nothing to merge, nothing to PR.
      assert result.worktree_path == nil
      assert is_port(result.claude_port)

      # Its own leaf — never the branch leaf, so a later branch dispatch of the
      # same bead can't collide with it (round-1 review finding).
      inspect_path = Worktree.inspect_path(BranchNamer.derive(task))
      refute inspect_path == Worktree.worktree_path(BranchNamer.derive(task))

      # The agent's cwd IS that isolated checkout — observed from the child.
      cwd_file = Path.join(inspect_path, "agent-cwd.txt")
      wait_until(fn -> File.exists?(cwd_file) end)
      assert File.read!(cwd_file) |> String.trim() == Path.expand(inspect_path)

      # ... and it reflects current upstream, not the stale local checkout.
      assert File.exists?(Path.join(inspect_path, "ENCRYPTION.md"))

      # The human's checkout is untouched: same HEAD, and the agent wrote
      # nothing into it.
      assert rev_parse!(repo, "HEAD") == local_head_before
      refute File.exists?(Path.join(repo, "agent-cwd.txt"))

      # bd-dlv3no's guarantee still holds: the token-bearing config never lands
      # in the shared checkout. (It isn't written to the inspect worktree
      # either — injection is still keyed to a *branch* worktree. Now that this
      # cwd is isolated, injecting here would be safe; that's a follow-up, not
      # this fix.)
      refute File.exists?(Path.join(repo, ".mcp.json"))
    end

    # bd-9r1tta: a repo with no `origin` has nothing to be stale against, so a
    # task-type dispatch must still work there — falling back to the local
    # checkout rather than erroring.
    test "task-type dispatch falls back to the local checkout when the repo has no origin",
         %{ws: ws, tmp: tmp} do
      repo = Path.join(tmp, "no-origin-repo")
      File.mkdir_p!(repo)
      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
      {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
      File.write!(Path.join(repo, "README.md"), "x\n")
      {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
      {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "no-origin-wt"))
      put_app_env(:arbiter, :repo_paths, %{"local/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "audit: local only", issue_type: :task, workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "local/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sh", "-c", "pwd -P > agent-cwd.txt"]
        )

      assert is_port(result.claude_port)

      cwd_file = Path.join(repo, "agent-cwd.txt")
      wait_until(fn -> File.exists?(cwd_file) end)
      assert File.read!(cwd_file) |> String.trim() == Path.expand(repo)
    end

    # bd-9r1tta: when the repo HAS an origin but provisioning the isolated
    # checkout fails, the dispatch must surface the failure rather than quietly
    # handing the agent the stale shared checkout — the silent-wrong-answer
    # failure mode this fix exists to close.
    test "task-type dispatch errors rather than falling back when the target branch is missing upstream",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "badbase")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "badbase-wt"))
      put_app_env(:arbiter, :repo_paths, %{"bad/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{title: "audit: bad base", issue_type: :task, workspace_id: ws.id})

      assert {:error, {:inspect_worktree_failed, _}} =
               Dispatch.dispatch(task.id,
                 repo: "bad/repo",
                 base_branch: "no-such-upstream-branch",
                 start_driver: false,
                 start_claude: true,
                 preflight: false,
                 claude_command: ["sleep", "1"]
               )
    end

    # Round-1 review finding: the inspect checkout used to share the branch leaf,
    # so a branch dispatch of a bead that had already been audited hit
    # `create/3`'s "worktree exists … on a different branch" — which the
    # `already exists` → `attach/2` recovery does not match — and failed
    # permanently until someone deleted the directory by hand. Inspect trees now
    # use their own leaf, and a detached tree found at the branch leaf (left by a
    # pre-fix dispatch) is reclaimed rather than fatal.
    test "a branch dispatch reclaims a detached worktree left at the branch leaf",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "collide")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "collide-wt"))
      put_app_env(:arbiter, :repo_paths, %{"col/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "was an audit first", workspace_id: ws.id})
      branch = BranchNamer.derive(task)

      # The pre-fix state: a detached checkout squatting on the branch leaf.
      {:ok, squatter} = Worktree.create_detached(repo, branch, "main")
      assert squatter == Worktree.worktree_path(branch)
      assert {:ok, "HEAD"} = Worktree.current_branch(squatter)

      {:ok, result} = Dispatch.dispatch(task.id, repo: "col/repo", start_driver: false)

      assert result.worktree_path == squatter
      assert {:ok, ^branch} = Worktree.current_branch(squatter)
    end

    # Counterpart: the two leaves coexist, so an audit's checkout and the same
    # bead's branch worktree never contend for one directory.
    test "an inspect checkout and a branch worktree for the same bead coexist",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "coexist")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "coexist-wt"))
      put_app_env(:arbiter, :repo_paths, %{"cx/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "audited then built", workspace_id: ws.id})
      branch = BranchNamer.derive(task)

      {:ok, inspect_path} = Worktree.create_detached(repo, Worktree.inspect_name(branch), "main")

      {:ok, result} = Dispatch.dispatch(task.id, repo: "cx/repo", start_driver: false)

      assert result.worktree_path == Worktree.worktree_path(branch)
      refute result.worktree_path == inspect_path
      assert {:ok, ^branch} = Worktree.current_branch(result.worktree_path)
      assert {:ok, "HEAD"} = Worktree.current_branch(inspect_path)
    end

    # bd-ci2jl2: a PRPatrol follow-up used to be undispatchable. It carried
    # `issue_type: :task` (→ no worktree provisioned → start_claude 500'd with
    # :missing_worktree) and stored the merged PR number in `tracker_ref` (→ the
    # :in_progress transition tried to write lifecycle status onto a merged PR
    # and escalated `Validation Failed`). The follow-up is now a reviewable type
    # with `tracker_type: :none` + the PR linked via `source_pr`, so dispatch
    # provisions a FRESH worktree and never touches a tracker.
    test "PRPatrol follow-up shape dispatches with a fresh worktree and no tracker write-back",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "followup")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "followup-wt"))
      put_app_env(:arbiter, :repo_paths, %{"fu/repo" => repo})

      {:ok, task} =
        Ash.create(Issue, %{
          title: "PR #591: needs follow-up",
          issue_type: :feature,
          tracker_type: :none,
          source_pr: "591",
          workspace_id: ws.id
        })

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "fu/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          claude_command: ["sleep", "2"]
        )

      # Fresh worktree provisioned (the bug returned {:error, :missing_worktree}).
      assert is_binary(result.worktree_path)
      assert is_port(result.claude_port)
      # Transition to :in_progress succeeded without a tracker sync attempt.
      assert result.task.status == :in_progress
      assert result.task.tracker_type == :none
      assert result.task.source_pr == "591"
    end

    # Counterpart: a normal work dispatch DOES get the MCP config — but only ever
    # inside its own isolated worktree, never the repo.
    test "work dispatch writes .mcp.json into its isolated worktree (not the repo)",
         %{ws: ws, tmp: tmp} do
      repo = seed_repo!(tmp, "workrig")

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "work-wt"))
      put_app_env(:arbiter, :repo_paths, %{"work/repo" => repo})
      enable_mcp_injection!()

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

    test "codex agent_type dispatch writes .codex/config.toml, not .mcp.json (bd-bi5t54)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      codex_file = Path.join(tmp, "codex-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codex-mcp-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "codex-mcp-wt"))
      put_app_env(:arbiter, :repo_paths, %{"codexmcp/repo" => repo})
      enable_mcp_injection!()

      # Workspace's `agent.type` pool deliberately excludes codex — mirrors the
      # live `default` workspace so the explicit override must win.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => ["claude", "gemini"]}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "codex mcp task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "codexmcp/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :codex,
          preflight: false
        )

      _ = wait_for_argv!(codex_file)

      assert File.exists?(Path.join(result.worktree_path, ".codex/config.toml")),
             "codex dispatch must write .codex/config.toml, not fall back to .mcp.json"

      refute File.exists?(Path.join(result.worktree_path, ".mcp.json"))
    end

    test "codex dispatch runs a post-spawn MCP connect check and logs loudly on failure (bd-bi5t54)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      codex_file = Path.join(tmp, "codex-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codex-verify-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "codex-verify-wt"))
      put_app_env(:arbiter, :repo_paths, %{"codexverify/repo" => repo})
      enable_mcp_injection!()

      # Point the MCP endpoint at a closed local port so the post-spawn connect
      # check fails fast with a connection-refused error, exercising the
      # verify_connection/1 wiring end to end.
      prior_url = Application.get_env(:arbiter, Arbiter.MCP)
      put_app_env(:arbiter, Arbiter.MCP, Keyword.put(prior_url, :url, "http://127.0.0.1:1/mcp"))

      {:ok, task} = Ash.create(Issue, %{title: "codex verify task", workspace_id: ws.id})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _result} =
            Dispatch.dispatch(task.id,
              repo: "codexverify/repo",
              start_driver: false,
              start_claude: true,
              agent_type: :codex,
              preflight: false
            )

          _ = wait_for_argv!(codex_file)
          # The check runs off the dispatch path (Task.Supervisor) — give it a
          # moment to complete against the closed port.
          Process.sleep(300)
        end)

      assert log =~ "Codex MCP connect check failed"
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

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "gic-wt"))
      put_app_env(:arbiter, :repo_paths, %{"gic/repo" => repo})
      enable_mcp_injection!()

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

      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "drv-wt"))
      put_app_env(:arbiter, :repo_paths, %{"drvr/repo" => repo})

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
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "mwt"))
      put_app_env(:arbiter, :repo_paths, %{"m/repo" => repo})

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
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "owt"))
      put_app_env(:arbiter, :repo_paths, %{"o/repo" => repo})

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
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "gwt"))
      put_app_env(:arbiter, :repo_paths, %{"g/repo" => repo})

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

    test "agent_type: :codex dispatches the Codex adapter, not Claude (bd-dcvo3n)",
         %{ws: ws, tmp: tmp} do
      claude_file = Path.join(tmp, "claude-argv.txt")
      codex_file = Path.join(tmp, "codex-argv.txt")
      :ok = stub_claude_on_path(tmp, claude_file)
      :ok = stub_named_on_path(tmp, "codex", codex_file)

      repo = seed_repo!(tmp, "codex-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "cwt"))
      put_app_env(:arbiter, :repo_paths, %{"c/repo" => repo})

      # Workspace's `agent.type` pool deliberately excludes codex — mirrors the
      # live `default` workspace (`["claude","gemini"]`) so the explicit override
      # must win over the workspace default rather than fall back to it.
      {:ok, ws} =
        Ash.update(ws, %{
          config: %{"agent" => %{"type" => ["claude", "gemini"]}}
        })

      {:ok, task} = Ash.create(Issue, %{title: "codex task", workspace_id: ws.id})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "c/repo",
          start_driver: false,
          start_claude: true,
          agent_type: :codex,
          # WORK-spawn argv assertion — skip the auth pre-flight probe (bd-awi4nw)
          # so its probe doesn't also write to the stub argv files.
          preflight: false
        )

      codex_args = wait_for_argv!(codex_file)
      # The Codex adapter ran (`codex exec --json ...`) — and Claude did not.
      assert "exec" in codex_args
      refute File.exists?(claude_file)

      # The worker's routing config records the codex provider.
      snap = Worker.state(result.worker_pid)
      routing = snap.meta[:routing_config]
      assert routing.provider == "codex"
    end

    test "ByPriority routing picks --model from `routing.rules[Pn]`",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "prio-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "pwt"))
      put_app_env(:arbiter, :repo_paths, %{"p/repo" => repo})

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

    # bd-dzz6ly: worker_runs records what happened but not what governed it.
    # This proves the effective post-layering skill set, the routing policy
    # that decided the tier, the resolved tier/thinking, the standing_orders
    # digest, and the task's difficulty AT DISPATCH TIME all land on the Run
    # row — so "which runs had skill X active, grouped by outcome" is
    # answerable without reading a transcript.
    test "dispatch records provenance (resolved_skills, routing_policy, model_tier, thinking, standing_orders_digest, difficulty_at_dispatch) onto the Run row",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "prov-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "provwt"))
      put_app_env(:arbiter, :repo_paths, %{"prov/repo" => repo})

      {:ok, _skill} =
        Arbiter.Skills.create_skill(%{
          name: "prov-canary",
          body: "# Canary",
          activation_mode: :always_on
        })

      {:ok, ws} =
        Ash.update(ws, %{
          config: %{
            "agent" => %{"type" => "claude"},
            "routing" => %{"policy" => "by_difficulty"},
            "skills" => %{"workspace" => ["prov-canary"]},
            "standing_orders" => ["always run tests"]
          }
        })

      # D3 → premium / high per ByDifficulty's default mapping.
      {:ok, task} =
        Ash.create(Issue, %{
          title: "provenance work",
          workspace_id: ws.id,
          issue_type: :feature,
          difficulty: 3
        })

      {:ok, result} =
        Dispatch.dispatch(task.id,
          repo: "prov/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      _ = wait_for_argv!(argv_file)

      run = latest_run(task.id)
      assert run.difficulty_at_dispatch == 3
      assert run.routing_policy == "by_difficulty"
      assert run.model_tier == "premium"
      assert run.thinking == "high"
      assert is_binary(run.standing_orders_digest)
      assert String.length(run.standing_orders_digest) == 64

      assert [%{"name" => "prov-canary", "activation_mode" => "always_on"} = entry] =
               run.resolved_skills

      assert is_binary(entry["skill_version"])

      # Editing the task's difficulty AFTER dispatch must not retroactively
      # change what this run recorded — it ran under D3, not whatever the
      # task is corrected to later (bd-7rspia was D1 → D2).
      {:ok, _updated_task} = Ash.update(result.task, %{difficulty: 1})
      run_after_edit = latest_run(task.id)
      assert run_after_edit.difficulty_at_dispatch == 3
    end

    test "redispatch after a :context_thrash failure auto-escalates to the 1M model (bd-8cn795)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "thrash-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "twt"))
      put_app_env(:arbiter, :repo_paths, %{"t/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "large module fix", workspace_id: ws.id})

      # A prior run for this exact task already died with the autocompact-thrash
      # signature — no manual `model:` override is passed on this redispatch.
      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "t/repo",
          workspace_id: ws.id,
          status: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: [
            "reading apps/arbiter/lib/arbiter/workflows/review_patrol.ex",
            "Autocompact is thrashing: the context refilled to the limit within 3 " <>
              "turns of the previous compact, 3 times in a row"
          ]
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          repo: "t/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "claude-sonnet-5[1m]" in args
    end

    test "a clean prior run does NOT auto-escalate the model (bd-8cn795)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "clean-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "cwt2"))
      put_app_env(:arbiter, :repo_paths, %{"c2/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "ordinary fix", workspace_id: ws.id})

      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "c2/repo",
          workspace_id: ws.id,
          status: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: ["some other unrelated crash"]
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          repo: "c2/repo",
          start_driver: false,
          start_claude: true,
          preflight: false
        )

      args = wait_for_argv!(argv_file)
      refute "claude-sonnet-5[1m]" in args
    end

    test "an explicit :model opt still wins over the thrash auto-escalation (bd-8cn795)",
         %{ws: ws, tmp: tmp} do
      argv_file = Path.join(tmp, "argv.txt")
      :ok = stub_claude_on_path(tmp, argv_file)

      repo = seed_repo!(tmp, "override-repo")
      put_app_env(:arbiter, :worktree_root, Path.join(tmp, "owt"))
      put_app_env(:arbiter, :repo_paths, %{"o/repo" => repo})

      {:ok, task} = Ash.create(Issue, %{title: "large module fix 2", workspace_id: ws.id})

      {:ok, _prior_run} =
        Ash.create(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "o/repo",
          workspace_id: ws.id,
          status: :failed,
          started_at: DateTime.utc_now(),
          exit_code: 1,
          output_lines: ["autocompact is thrashing"]
        })

      {:ok, _result} =
        Dispatch.dispatch(task.id,
          repo: "o/repo",
          start_driver: false,
          start_claude: true,
          preflight: false,
          model: "opus"
        )

      args = wait_for_argv!(argv_file)
      assert "--model" in args
      assert "opus" in args
      refute "claude-sonnet-5[1m]" in args
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
      branch = BranchNamer.derive(task)
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
      branch = BranchNamer.derive(task)

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

    test "review prompt requires the VERIFICATION disclosure and forbids stale re-flags (bd-1j5x6u)",
         %{ws: ws} do
      # bd-4te55l's High finding: the coordinator-dispatched `worker_review` path
      # (this review_prompt/2, consumed by Worker.route_reviewer_completion/1)
      # never got the VERIFICATION: FULL/PARTIAL disclosure protocol that
      # ReviewGate's own in-band round loop got. Same coverage as
      # ReviewGate.review_prompt/1's equivalent test.
      {:ok, task} = Ash.create(Issue, %{title: "review task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "VERIFICATION: FULL",
             "review_prompt must require the reviewer to disclose full verification"

      assert prompt =~ "VERIFICATION: PARTIAL",
             "review_prompt must give the reviewer a way to disclose partial verification"

      assert prompt =~ "re-open the CURRENT file",
             "review_prompt must require re-confirming findings against the current diff, not memory"
    end

    test "includes worktree isolation section when worktree_path is given (bd-cwov25)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "coding task", workspace_id: ws.id})

      prompt =
        Dispatch.prompt_for_task(task, worktree_path: "/home/ryan/dev/arbiter-worktrees/feat-x")

      assert prompt =~ "FILESYSTEM ISOLATION"
      assert prompt =~ "/home/ryan/dev/arbiter-worktrees/feat-x"
      assert prompt =~ "Do NOT use absolute"
    end

    test "omits worktree isolation section when no worktree_path is given (bd-cwov25)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "coding task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "FILESYSTEM ISOLATION"
    end

    test "work prompt carries read-discipline guidance against context thrash (bd-8cn795)",
         %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "coding task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "grep",
             "work prompt must steer workers toward grep/symbol search before reading a file"

      assert prompt =~ "bounded",
             "work prompt must call out bounded offset/limit reads over whole-file reads"

      assert prompt =~ "whole-file reads",
             "work prompt must explicitly discourage whole-file reads of large modules"
    end

    test "review prompt carries the same read-discipline guidance (bd-8cn795)", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "review task", workspace_id: ws.id})

      prompt = Dispatch.prompt_for_task(task, review: true)

      assert prompt =~ "grep"
      assert prompt =~ "bounded"
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

  describe "PRPatrol follow-up prompt (bd-6v2my2)" do
    test "a task-type follow-up with source_pr is told it has no branch/PR of its own and may push to the original PR",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "PR #3679: needs follow-up",
          workspace_id: ws.id,
          issue_type: :task,
          source_pr: "3679"
        })

      prompt = Dispatch.prompt_for_task(task, worktree_path: "/tmp/wt-follow-up")

      assert prompt =~ "NO branch or pull request of its"
      assert prompt =~ "PRPatrol follow-up against EXISTING pull request #3679"
      assert prompt =~ "code change at all is SUCCESS"
      assert prompt =~ "gh pr checkout 3679"
      assert prompt =~ "git push -u origin <new-branch>"
      assert prompt =~ "arb create <title> --parent #{task.id} --type feature"

      # Still gets the notes gate (it's a `:task`) and its own worktree's
      # isolation warning (provisioned so it has a checkout to `gh`/`git` from).
      assert prompt =~ "notes gate"
      assert prompt =~ "FILESYSTEM ISOLATION"
      assert prompt =~ "/tmp/wt-follow-up"
    end

    test "a plain task-type directive (no source_pr) keeps the original 'do not edit a repo' framing",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "investigate the flaky deploy",
          workspace_id: ws.id,
          issue_type: :task
        })

      prompt = Dispatch.prompt_for_task(task, [])

      assert prompt =~ "you are not expected to edit a repo"
      refute prompt =~ "PRPatrol follow-up"
      refute prompt =~ "gh pr checkout"
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

      # Verify the adapter can be resolved and loaded independently of run order.
      # completion_notes_step/1 uses Code.ensure_loaded? so the check succeeds even
      # when the module hasn't been touched earlier in the test suite (bd-6aqgok).
      adapter = Arbiter.Trackers.for_task(task)
      assert Code.ensure_loaded?(adapter), "adapter #{inspect(adapter)} must be loadable"

      assert function_exported?(adapter, :gating_fields, 2),
             "jira adapter must export gating_fields/2"

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

    test "github-tracked tasks (bd/default workspace) get no completion-notes step", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "github work",
          workspace_id: ws.id,
          tracker_type: "github",
          tracker_ref: "42",
          skip_upstream_create: true
        })

      prompt = Dispatch.prompt_for_task(task, [])

      refute prompt =~ "qa_notes"
      refute prompt =~ "backed by an external tracker"
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
    defp stop_worker_with_outpost(task_id) do
      {:ok, first} = Dispatch.dispatch(task_id, repo: "rs/repo", start_driver: false)
      assert is_binary(first.worktree_path)
      :ok = Worker.fail(first.worker_pid, :token_exhausted)
      first
    end

    test "reuses the worktree, links the new run, and boots into :resuming", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "resume work", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

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
      first = stop_worker_with_outpost(task.id)

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
      first = stop_worker_with_outpost(task.id)

      # Tear the worktree down — nothing left to resume.
      Arbiter.Worker.Worktree.cleanup(first.worktree_path)
      refute File.dir?(first.worktree_path)

      assert {:error, :no_outpost} = Dispatch.resume(task.id, start_driver: false)
    end

    # Round-1 review finding: a detached inspect checkout is not preserved work.
    # If resume accepted it, `ResumeContext.build/3` would run `git log
    # <base>..HEAD` in a tree whose HEAD is `origin/<base>` while the local
    # `<base>` ref is the parent repo's stale one — listing UPSTREAM commits under
    # "the commits the prior worker made … DO NOT start over".
    test "refuses to resume from a detached checkout at the branch leaf", %{ws: ws, repo: repo} do
      {:ok, task} = Ash.create(Issue, %{title: "detached resume", workspace_id: ws.id})
      first = stop_worker_with_outpost(task.id)

      # Replace the branch worktree with a detached one at the same leaf — the
      # shape a pre-fix task-type dispatch left behind.
      path = first.worktree_path
      Worktree.cleanup(path)
      branch = BranchNamer.derive(task)
      {:ok, ^path} = Worktree.create_detached(repo, branch, "main")
      assert {:ok, "HEAD"} = Worktree.current_branch(path)

      assert {:error, :no_outpost} = Dispatch.resume(task.id, start_driver: false)
    end

    test "refuses to resume a closed task", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "closed resume", workspace_id: ws.id})
      _ = stop_worker_with_outpost(task.id)
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
      _ = stop_worker_with_outpost(task.id)

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

    test "review prompt includes pre-fetched tracker_context block when provided (bd-2eo4cg)",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "review coworker PR",
          workspace_id: ws.id,
          tracker_type: :none,
          tracker_context_type: :jira,
          tracker_context_ref: "VR-18004"
        })

      # Simulate a pre-fetched tracker context (normally done in build_agent_session_opts).
      context = %{
        ref: "VR-18004",
        type: :jira,
        title: "Some Jira ticket",
        description: "## Acceptance\n- feature works\n- tests pass"
      }

      prompt =
        Arbiter.Worker.Dispatch.prompt_for_task(task, review: true, tracker_context: context)

      assert prompt =~ "Tracker context (read-only, jira:VR-18004)"
      assert prompt =~ "Some Jira ticket"
      assert prompt =~ "feature works"
      # The task has no tracker_ref, so no "Tracker ref (PR/MR to review)" line
      refute prompt =~ "Tracker ref (PR/MR to review)"
    end

    test "review prompt omits tracker context block when no context is pre-fetched (bd-2eo4cg)",
         %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "review without context",
          workspace_id: ws.id,
          tracker_type: :none
        })

      prompt = Arbiter.Worker.Dispatch.prompt_for_task(task, review: true)

      refute prompt =~ "Tracker context (read-only"
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

    test "explicit repo slug resolves against a registered key differing only by _/- (bd-6rioa4)",
         %{ws: ws, repo: repo} do
      Application.put_env(:arbiter, @env_key, %{
        "leo-technologies-llc/verus-server" => repo
      })

      {:ok, task} = Ash.create(Issue, %{title: "underscore slug", workspace_id: ws.id})

      assert {:ok, result} =
               Dispatch.dispatch(task.id,
                 repo: "leo-technologies-llc/verus_server",
                 start_driver: false,
                 start_claude: true,
                 claude_command: ["true"],
                 preflight: false
               )

      assert is_binary(result.worktree_path)
      assert File.dir?(result.worktree_path)
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

  defmodule StubMigrationsPending do
    @moduledoc false
    def count_pending, do: 3
  end

  describe "pending migrations gate" do
    test "dispatch proceeds when migrations are current", %{ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "migrations current", workspace_id: ws.id})

      # In a test environment where migrations are applied, dispatch should proceed
      # (or fail for other reasons, but not due to pending migrations)
      case Dispatch.dispatch(task.id, repo: "test/repo", start_driver: false) do
        {:ok, result} ->
          assert result.task.status == :in_progress

        {:error, {:pending_migrations, _count}} ->
          # If we do have pending migrations in test, that's OK too — this just verifies
          # the check is in place and returns the expected error format
          :ok

        other ->
          flunk("unexpected dispatch result: #{inspect(other)}")
      end
    end

    test "dispatch is refused with a reason naming the migration state when migrations are pending",
         %{ws: ws} do
      Application.put_env(:arbiter, :migrations_module, StubMigrationsPending)

      on_exit(fn -> Application.delete_env(:arbiter, :migrations_module) end)

      {:ok, task} = Ash.create(Issue, %{title: "migrations pending", workspace_id: ws.id})

      assert Dispatch.dispatch(task.id, repo: "test/repo", start_driver: false) ==
               {:error, {:pending_migrations, 3}}

      reloaded = Ash.get!(Issue, task.id)
      assert reloaded.status != :in_progress
      assert Worker.whereis(task.id) == nil
    end
  end
end
