defmodule Arbiter.Worker.ReviewGateReviewCheckoutTest do
  @moduledoc """
  bd-a22hib / #2055 — the in-gate reviewer ran inside the implementer's own
  writable worktree, with the plain workspace policy.

  It saw the implementer's LOCAL state rather than what was pushed (the cause
  bd-2jkrqu's `PushState` guard only patches), it could write to the branch it
  was reviewing, and its test runs shared the implementer's build dir.

  Each review round now provisions its own detached checkout at the head SHA
  `origin` carries after the push gate, runs the reviewer there under the same
  write-denied posture dispatched reviews get
  (`Dispatch.review_security_policy/2`), records THAT SHA as the reviewed SHA,
  and removes the checkout when the round ends. Implementer / fix-pass rounds
  are unchanged: they still run in the implementer's worktree.

  Pinned against real git repos with a real bare origin; the reviewer fixture
  (`review_checkout_probe.sh`) logs where it actually ran.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.CircuitBreaker
  alias Arbiter.Messages.Message
  alias Arbiter.Reviews.Coverage.Entry
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{Dispatch, ReviewGate}

  @probe Path.expand("../../fixtures/review_checkout_probe.sh", __DIR__)
  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "rg-checkout-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    tmp = resolve_symlinks(tmp)
    repo = init_repo(tmp)
    root = Path.join(tmp, "worktrees")

    put_app_env(:arbiter, :worktree_root, root)
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-checkout-#{System.unique_integer([:positive])}",
        prefix: "rk",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp, root: root, log: Path.join(tmp, "probe.log")}
  end

  # ---- git rig -------------------------------------------------------------

  defp resolve_symlinks(path) do
    {out, 0} = System.cmd("pwd", ["-P"], cd: path)
    String.trim(out)
  end

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    git!(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], repo)
    git!(["commit", "-q", "-m", "feature work"], repo)
    git!(["checkout", "-q", "main"], repo)
    :ok
  end

  defp branch_worktree(repo, tmp, branch) do
    wt = Path.join(tmp, "wt-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: repo)
    git!(["config", "user.email", "wt@example.com"], wt)
    git!(["config", "user.name", "WT"], wt)
    git!(["config", "commit.gpgsign", "false"], wt)
    wt
  end

  defp sha(repo, ref) do
    case git(["rev-parse", ref], repo) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  end

  defp commit_in(wt, name, body) do
    File.write!(Path.join(wt, name), body)
    git!(["add", name], wt)
    git!(["commit", "-q", "-m", "local #{name}"], wt)
    sha(wt, "HEAD")
  end

  defp remote_head(repo, branch) do
    {out, 0} = git(["ls-remote", "--heads", "origin", branch], repo)

    case String.split(out) do
      [sha | _] -> sha
      [] -> nil
    end
  end

  defp gate_checkouts(root), do: Path.wildcard(Path.join(root, "gate-review-*"))

  defp registered_worktrees(repo) do
    {out, 0} = git(["worktree", "list", "--porcelain"], repo)

    for "worktree " <> path <- String.split(out, "\n"), do: path
  end

  # One map per reviewer pass the probe fixture logged.
  defp probe_passes(log) do
    case File.read(log) do
      {:ok, body} ->
        for line <- String.split(body, "\n", trim: true) do
          ~r/(\w+)=(\S*)/
          |> Regex.scan(line, capture: :all_but_first)
          |> Map.new(fn [k, v] -> {k, v} end)
        end

      {:error, :enoent} ->
        []
    end
  end

  # ---- app rig -------------------------------------------------------------

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "checkout task", workspace_id: ws.id, issue_type: :feature})

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp start_author(task, ws, repo, branch, wt) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(author)) end)
    author
  end

  defp start_gate(author, task, ws, branch, wt, opts) do
    {:ok, gate} =
      ReviewGate.start(
        [
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "trib/repo",
          worktree_path: wt,
          branch: branch,
          target_branch: "main",
          timeout_ms: 20_000
        ] ++ opts
      )

    ref = Process.monitor(gate)
    {gate, ref}
  end

  defp await_gate_down(gate, ref, timeout \\ 30_000) do
    assert_receive {:DOWN, ^ref, :process, ^gate, _reason}, timeout
  end

  defp escalations(ws, task) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == task.id))
  end

  defp coverage_rows(task_id) do
    Entry |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
  end

  defp wait_until(fun, timeout \\ 5_000) do
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
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end

  # ---- AC1 / AC4 / AC5: the round's own checkout at the pushed head --------

  describe "a review round (AC1, AC4, AC5)" do
    test "runs the reviewer in a detached checkout at the remote head, stamps that SHA, " <>
           "and removes the checkout on approval",
         %{repo: repo, ws: ws, tmp: tmp, root: root, log: log} do
      task = new_task(ws)
      branch = "feature/checkout-1"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      pushed = sha(wt, "HEAD")

      author = start_author(task, ws, repo, branch, wt)

      # Uncommitted scratch in the implementer's worktree: never pushed, so the
      # reviewer must not see it. Written after the author's own commit gate,
      # which would otherwise (rightly) refuse to hand a dirty tree to review.
      File.write!(Path.join(wt, "dirty.txt"), "not committed\n")

      {gate, ref} =
        start_gate(author, task, ws, branch, wt,
          command: [@probe, log, "APPROVE"],
          pr_ref: "owner/repo#2055"
        )

      await_gate_down(gate, ref)

      assert [pass] = probe_passes(log)

      refute pass["cwd"] == wt, "the reviewer ran in the implementer's worktree"
      assert String.starts_with?(pass["cwd"], root <> "/gate-review-")
      assert pass["head"] == remote_head(repo, branch)
      assert pass["head"] == pushed
      assert pass["dirty"] == "no", "the implementer's uncommitted scratch leaked in"

      # AC4: the reviewed SHA the merge guard reads is the one checked out.
      task = Ash.get!(Issue, task.id)
      assert task.last_reviewed_sha == pass["head"]
      assert [%{head_sha: covered}] = coverage_rows(task.id)
      assert covered == pass["head"]

      # AC5: gone from disk AND from git's worktree registry.
      refute File.exists?(pass["cwd"])
      assert gate_checkouts(root) == []
      refute pass["cwd"] in registered_worktrees(repo)

      # AC6-adjacent: the implementer's worktree is untouched.
      assert sha(wt, "HEAD") == pushed
      assert File.exists?(Path.join(wt, "dirty.txt"))
    end

    test "each round gets a fresh checkout; the fix round still runs in the implementer's " <>
           "worktree; rejection removes the round's checkout (AC5, AC6)",
         %{repo: repo, ws: ws, tmp: tmp, root: root, log: log} do
      task = new_task(ws)
      branch = "feature/checkout-2"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      round1_head = sha(wt, "HEAD")

      author = start_author(task, ws, repo, branch, wt)

      {gate, ref} =
        start_gate(author, task, ws, branch, wt,
          command: [@probe, log, "ROUND2"],
          revise_command: [@revise_commit],
          rounds: 2
        )

      await_gate_down(gate, ref, 60_000)

      assert [r1, r2] = probe_passes(log)

      # AC6: the fix pass committed in the implementer's worktree, on the branch.
      fix_head = sha(wt, "HEAD")
      refute fix_head == round1_head
      assert File.read!(Path.join(wt, "guard.txt")) =~ "anchored guard"
      assert remote_head(repo, branch) == fix_head

      assert r1["head"] == round1_head
      assert r2["head"] == fix_head
      refute r1["cwd"] == r2["cwd"], "round 2 reused round 1's checkout"

      for pass <- [r1, r2] do
        refute pass["cwd"] == wt
        refute File.exists?(pass["cwd"]), "round checkout #{pass["cwd"]} leaked"
      end

      assert gate_checkouts(root) == []
      assert Ash.get!(Issue, task.id).last_reviewed_sha == fix_head
    end

    test "a reviewer killed mid-round leaks no checkout (AC5)",
         %{repo: repo, ws: ws, tmp: tmp, root: root, log: log} do
      task = new_task(ws)
      branch = "feature/checkout-3"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)

      author = start_author(task, ws, repo, branch, wt)

      {gate, ref} =
        start_gate(author, task, ws, branch, wt,
          command: [@probe, log, "HANG"],
          verdict_retries: 0,
          timeout_retries: 0
        )

      wait_until(fn -> File.exists?(log <> ".pid") end, 20_000)
      assert [pass] = probe_passes(log)
      assert File.dir?(pass["cwd"]), "the reviewer had no checkout to leak"

      pid = log |> Kernel.<>(".pid") |> File.read!() |> String.trim()
      {_, 0} = System.cmd("kill", ["-9", pid])

      await_gate_down(gate, ref)

      refute File.exists?(pass["cwd"])
      assert gate_checkouts(root) == []
      refute pass["cwd"] in registered_worktrees(repo)
    end
  end

  # ---- AC5: a gate that never reached terminate/2 -----------------------------

  describe "the boot sweep (AC5)" do
    test "reclaims the checkout of a gate killed outright mid-round — primary only",
         %{repo: repo, ws: ws, tmp: tmp, root: root, log: log} do
      task = new_task(ws)
      branch = "feature/checkout-7"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)

      author = start_author(task, ws, repo, branch, wt)
      {gate, ref} = start_gate(author, task, ws, branch, wt, command: [@probe, log, "HANG"])

      wait_until(fn -> File.exists?(log <> ".pid") end, 20_000)
      assert [pass] = probe_passes(log)

      # The server-restart shape: the gate dies with no terminate/2.
      Process.exit(gate, :kill)
      await_gate_down(gate, ref)
      {_, _} = System.cmd("kill", ["-9", String.trim(File.read!(log <> ".pid"))])

      assert File.dir?(pass["cwd"]), "nothing leaked, so the sweep is untested"

      # "Before this VM started" — every leaf so far predates the new boot.
      before = System.os_time(:second) + 5

      assert [] ==
               ReviewGate.sweep_orphaned_review_checkouts(primary?: false, before: before)

      assert File.dir?(pass["cwd"])

      assert [swept] = ReviewGate.sweep_orphaned_review_checkouts(primary?: true, before: before)
      assert swept == pass["cwd"]
      assert gate_checkouts(root) == []
      refute pass["cwd"] in registered_worktrees(repo)
    end
  end

  # ---- AC2: unpushed commits are never what the reviewer sees ---------------

  describe "unpushed local commits (AC2)" do
    test "the round's checkout is the remote head, not the implementer's local head",
         %{repo: repo, tmp: tmp, root: root} do
      branch = "feature/checkout-4"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      pushed = sha(wt, "HEAD")

      local = commit_in(wt, "unpushed.txt", "local only\n")
      refute local == pushed

      state = %{worktree_path: wt, branch: branch, task_id: "rk-unit", review_checkout: nil}

      assert {:ok, %{review_checkout: %{path: path, head_sha: ^pushed}} = state} =
               ReviewGate.provision_review_checkout(state)

      assert sha(path, "HEAD") == pushed
      refute File.exists?(Path.join(path, "unpushed.txt"))
      assert String.starts_with?(path, root)

      assert %{review_checkout: nil} = ReviewGate.release_review_checkout(state)
      refute File.exists?(path)
    end

    test "the round's checkout is seeded with the implementer's fetched and compiled deps",
         %{repo: repo, tmp: tmp} do
      branch = "feature/checkout-8"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)

      # Untracked build state, as a real worker worktree carries it.
      File.mkdir_p!(Path.join([wt, "deps", "jason"]))
      File.write!(Path.join([wt, "deps", "jason", "mix.exs"]), "# dep\n")
      File.mkdir_p!(Path.join([wt, "_build", "test", "lib", "jason", "ebin"]))

      state = %{worktree_path: wt, branch: branch, task_id: "rk-seed", review_checkout: nil}

      assert {:ok, %{review_checkout: %{path: path}} = state} =
               ReviewGate.provision_review_checkout(state)

      assert File.exists?(Path.join([path, "deps", "jason", "mix.exs"]))
      assert File.dir?(Path.join([path, "_build", "test", "lib", "jason", "ebin"]))

      ReviewGate.release_review_checkout(state)
      refute File.exists?(path)
    end

    test "an unpushed head the gate cannot push parks before any checkout is provisioned",
         %{repo: repo, ws: ws, tmp: tmp, root: root, log: log} do
      task = new_task(ws)
      branch = "feature/checkout-5"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)
      base = sha(wt, "HEAD")

      other = Path.join(tmp, "other")
      {_, 0} = System.cmd("git", ["clone", "-q", Path.join(tmp, "origin.git"), other])
      git!(["config", "user.email", "o@example.com"], other)
      git!(["config", "user.name", "O"], other)
      git!(["config", "commit.gpgsign", "false"], other)
      git!(["checkout", "-q", branch], other)
      File.write!(Path.join(other, "theirs.txt"), "theirs\n")
      git!(["add", "theirs.txt"], other)
      git!(["commit", "-q", "-m", "theirs"], other)
      git!(["push", "-q", "origin", branch], other)

      git!(["reset", "-q", "--hard", base], wt)
      commit_in(wt, "mine.txt", "mine\n")

      author = start_author(task, ws, repo, branch, wt)
      {gate, ref} = start_gate(author, task, ws, branch, wt, command: [@probe, log, "APPROVE"])
      await_gate_down(gate, ref)

      assert Ash.get!(Issue, task.id).review_park_reason == "head_not_pushed"
      assert probe_passes(log) == [], "a reviewer ran on an unpushed head"
      assert gate_checkouts(root) == []
    end
  end

  # ---- AC3: one write-denied posture ------------------------------------------

  describe "the reviewer's security policy (AC3)" do
    test "denies Edit/Write/NotebookEdit through Dispatch.review_security_policy/2", %{ws: ws} do
      checkout = %{path: "/tmp/gate-review-x", head_sha: "abc"}
      state = %{repo: "trib/repo", review_checkout: checkout}

      reviewer = ReviewGate.session_security_policy(ws, state, :reviewer)

      assert reviewer ==
               ws
               |> SecurityPolicy.resolve(%{}, "trib/repo")
               |> Dispatch.review_security_policy(review_checkout: checkout)

      denied = reviewer.permissions.deny

      for tool <- ~w(Edit Write NotebookEdit) do
        assert tool in denied, "#{tool} is not denied to the in-gate reviewer"
      end

      # The implementer keeps the plain workspace posture.
      assert ReviewGate.session_security_policy(ws, state, :implementer) ==
               SecurityPolicy.resolve(ws, %{}, "trib/repo")
    end
  end

  # ---- AC1 + AC3 through the real adapter spawn -------------------------------

  describe "the production spawn path (AC1, AC3)" do
    # Every other test here drives the fixture `command:` escape hatch, which
    # bypasses the adapter. This one leaves `command:` unset so the reviewer is
    # spawned exactly as in production — workspace → `Arbiter.Agents` adapter →
    # `default_argv/2` with the resolved security policy — against a stubbed
    # `claude` (TestSandbox stubs every agent binary) that logs where it ran and
    # what it was told.
    test "the real reviewer argv runs in the round's checkout with writes denied",
         %{ws: ws} do
      stub = """
      log="$(dirname "$0")/../gate-spawn.log"
      printf 'cwd=%s\\n' "$(pwd -P)" >> "$log"
      for a in "$@"; do printf 'arg=%s\\n' "$a" >> "$log"; done
      echo "arb done"
      exit 0
      """

      sandbox = Arbiter.TestSandbox.provision!("rg-checkout-spawn", stub: stub)
      put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
      put_app_env(:arbiter, :repo_paths, %{"trib/repo" => sandbox.repo})

      branch = "feature/checkout-spawn"
      :ok = Arbiter.TestSandbox.seed_branch!(sandbox, branch)
      wt = branch_worktree(sandbox.repo, sandbox.root, branch)
      log = Path.join(sandbox.root, "gate-spawn.log")

      task = new_task(ws)
      author = start_author(task, ws, sandbox.repo, branch, wt)

      {gate, ref} = start_gate(author, task, ws, branch, wt, verdict_retries: 0)
      Arbiter.TestSandbox.own!(sandbox, gate)

      wait_until(fn -> File.exists?(log) end, 20_000)
      await_gate_down(gate, ref)

      lines = log |> File.read!() |> String.split("\n", trim: true)
      assert ["cwd=" <> cwd | _] = lines

      refute cwd == resolve_symlinks(wt), "the reviewer spawned in the implementer's worktree"
      assert String.starts_with?(cwd, resolve_symlinks(sandbox.worktree_root) <> "/gate-review-")

      argv =
        Enum.flat_map(lines, fn
          "arg=" <> a -> [a]
          _ -> []
        end)

      settings = Enum.find(argv, &(&1 =~ ~s("deny")))
      assert settings, "no deny settings in the reviewer argv: #{inspect(argv)}"

      for tool <- ~w(Edit Write NotebookEdit) do
        assert settings =~ ~s("#{tool}"), "#{tool} not denied in #{settings}"
      end

      refute File.exists?(cwd), "the round's checkout leaked"
    end
  end

  # ---- AC7: provisioning failure is loud ---------------------------------------

  describe "a checkout that cannot be provisioned (AC7)" do
    test "parks the round with the reason instead of reviewing in the implementer's worktree",
         %{repo: repo, ws: ws, tmp: tmp, log: log} do
      task = new_task(ws)
      branch = "feature/checkout-6"
      :ok = seed_feature_branch(repo, branch)
      wt = branch_worktree(repo, tmp, branch)
      git!(["push", "-q", "-u", "origin", branch], wt)

      # A worktree root nested under a regular file: `mkdir -p` cannot succeed.
      blocker = Path.join(tmp, "not-a-dir")
      File.write!(blocker, "")
      put_app_env(:arbiter, :worktree_root, Path.join(blocker, "worktrees"))

      author = start_author(task, ws, repo, branch, wt)
      {gate, ref} = start_gate(author, task, ws, branch, wt, command: [@probe, log, "APPROVE"])
      await_gate_down(gate, ref)

      assert probe_passes(log) == [], "the reviewer ran without its own checkout"
      assert Ash.get!(Issue, task.id).review_park_reason == "reviewer_failed"
      assert Ash.get!(Issue, task.id).last_reviewed_sha == nil

      wait_until(fn -> escalations(ws, task) != [] end)
      body = Enum.map_join(escalations(ws, task), "\n", & &1.body)
      assert body =~ "review checkout"
      assert body =~ "enotdir"
    end
  end
end
