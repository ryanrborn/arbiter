defmodule Arbiter.Worker.ReviewGateTest do
  @moduledoc """
  The review (ReviewGate) gate that sits between a worker's `arb done` and the
  merger — Stage 1 (bd-4g1rg1) plus the Stage 2 revise-and-rediscuss loop
  (bd-3jm700).

  Stage 1 covers the four required paths plus verdict parsing:

    * gate parks at `:awaiting_review_gate` (and does NOT merge) when review is
      required,
    * APPROVE → the branch merges (a real `git merge --no-ff` on main),
    * REQUEST_CHANGES → the branch is NOT merged, the task is parked with the
      findings, and the Coordinator is escalated,
    * review-off (default) → completion routes straight to the merger, no gate.

  Plus a full end-to-end path where a **distinct** reviewer worker (a second
  worker + a fixture "claude" subprocess) emits the verdict.

  Stage 2 covers the revise-and-rediscuss loop (`describe "revise-and-rediscuss
  loop"`): a REQUEST_CHANGES within the round cap spawns a fresh implementer to
  address the findings on the same branch (the thread persisted to the mailbox),
  then re-reviews — converging to a merge, or escalating to Darth Gnosis with the
  full transcript once the `config["review"]["rounds"]` cap is hit.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)
  @reprompt Path.expand("../../fixtures/review_reprompt.sh", __DIR__)
  @empty_findings Path.expand("../../fixtures/review_empty_findings.sh", __DIR__)
  @rounds Path.expand("../../fixtures/review_rounds.sh", __DIR__)
  @rounds_empty_mid Path.expand("../../fixtures/review_rounds_empty_mid.sh", __DIR__)
  @rounds_empty_last Path.expand("../../fixtures/review_rounds_empty_last.sh", __DIR__)
  @retry_reset Path.expand("../../fixtures/review_retry_reset.sh", __DIR__)
  @revise Path.expand("../../fixtures/revise.sh", __DIR__)
  @revise_huge Path.expand("../../fixtures/revise_huge.sh", __DIR__)
  @timeout_retry Path.expand("../../fixtures/review_timeout_retry.sh", __DIR__)

  # ---- pure verdict parsing ------------------------------------------------

  describe "parse_verdict/1" do
    test "recognizes APPROVE" do
      assert {:approve, findings} =
               ReviewGate.parse_verdict(["looks good", "VERDICT: APPROVE", "ship it"])

      assert findings =~ "VERDICT: APPROVE"
      assert findings =~ "ship it"
    end

    test "recognizes REQUEST_CHANGES and captures findings from the verdict line on" do
      lines = [
        "preamble noise",
        "VERDICT: REQUEST_CHANGES",
        "- [high] foo.ex:12 missing nil guard"
      ]

      assert {:request_changes, findings} = ReviewGate.parse_verdict(lines)
      refute findings =~ "preamble noise"
      assert findings =~ "missing nil guard"
    end

    test "treats REJECT as a request-changes alias" do
      assert {:request_changes, _} = ReviewGate.parse_verdict(["VERDICT: REJECT now"])
    end

    test "is case-insensitive and tolerates leading whitespace" do
      assert {:approve, _} = ReviewGate.parse_verdict(["   verdict:  approve"])
    end

    test "returns :no_verdict when no sentinel is present" do
      assert :no_verdict = ReviewGate.parse_verdict(["just some output", "no decision here"])
    end

    test "the first verdict line wins (APPROVE before REQUEST_CHANGES)" do
      assert {:approve, _} =
               ReviewGate.parse_verdict(["VERDICT: APPROVE", "VERDICT: REQUEST_CHANGES"])
    end
  end

  # ---- cap/2 truncation (escalation payload safety) ------------------------

  describe "cap/2" do
    test "returns the text unchanged when within the byte cap" do
      assert ReviewGate.cap("short", 50) == "short"
    end

    test "truncating mid-codepoint backs off to a valid UTF-8 boundary" do
      # "€" is 3 bytes (0xE2 0x82 0xAC); cap at 10 lands one byte into it, so a
      # naive binary_part/3 would yield an invalid-UTF-8 binary. The escalation
      # payload then runs String.trim/1 (outside any rescue) and persists to a
      # Postgres UTF8 column — both reject malformed bytes.
      text = String.duplicate("a", 9) <> "€uro"
      capped = ReviewGate.cap(text, 10)

      assert String.valid?(capped), "cap/2 must never emit invalid UTF-8"
      assert capped == "aaaaaaaaa\n… (truncated)"
      # The whole-codepoint guarantee is what lets the downstream String.trim/1
      # in escalation_payload/1 run without raising on malformed bytes.
      assert String.trim(capped) == "aaaaaaaaa\n… (truncated)"
    end

    test "an exact-byte boundary on a multibyte char is preserved" do
      # cap == 12 lands exactly after the full "€" (bytes 10..12), nothing to shave.
      text = String.duplicate("a", 9) <> "€uro"
      assert ReviewGate.cap(text, 12) == "aaaaaaaaa€\n… (truncated)"
    end
  end

  describe "cap_transcript/2 (bd-78vg4v)" do
    test "returns the text unchanged when within the byte cap" do
      assert ReviewGate.cap_transcript("short", 50) == "short"
    end

    test "keeps BOTH the head and the tail, eliding the middle" do
      # The implementer's actionable conclusion lands at the END, so a correct
      # cap must preserve the tail — unlike cap/2, which keeps only the prefix.
      # A unique MIDDLE_MARKER buried in the centre must be elided.
      filler = String.duplicate("noise xxxxxxxxxx\n", 2000)

      text =
        "HEAD_MARKER opening context\n" <>
          filler <> "MIDDLE_MARKER buried\n" <> filler <> "TAIL_MARKER: FIXED the thing"

      capped = ReviewGate.cap_transcript(text, 2_000)

      assert byte_size(capped) < byte_size(text)
      assert byte_size(capped) <= 2_200, "capped output should be bounded near the cap"
      assert capped =~ "HEAD_MARKER", "head (opening context) must be kept"
      assert capped =~ "TAIL_MARKER: FIXED", "tail (the FIX conclusion) must be kept"
      assert capped =~ "elided", "must mark the elided middle"
      refute capped =~ "MIDDLE_MARKER", "the middle must be dropped"
    end

    test "never emits invalid UTF-8 when head/tail land mid-codepoint" do
      # Fill with multibyte chars so the byte-offset head/tail slices are very
      # likely to sever a codepoint; the head+tail guards must back off.
      text = String.duplicate("€", 5000)
      capped = ReviewGate.cap_transcript(text, 1_000)

      assert String.valid?(capped), "cap_transcript/2 must never emit invalid UTF-8"
      assert String.trim(capped) == capped |> String.trim()
    end
  end

  # ---- git repo helpers (mirrors CompletionMergeTest) -----------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_rig(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Rig"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  # Create a feature branch with one commit ahead of main, then return to main.
  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
  end

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

  setup do
    tmp = Path.join(System.tmp_dir!(), "review_gate-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_rig(tmp)

    Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    Application.put_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn ->
      Application.delete_env(:arbiter, :worktree_root)
      Application.delete_env(:arbiter, :rig_paths)
      File.rm_rf!(tmp)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "trib-ws-#{System.unique_integer([:positive])}",
        prefix: "tb",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

  # Start a worker already seeded with branch/merge meta and parked-ready to
  # accept a verdict, WITHOUT spawning a live reviewer (`review_spawn: false`),
  # so the verdict transitions can be driven directly.
  defp start_author(task, repo, extra_meta) do
    branch = "feature/rev"
    :ok = seed_feature_branch(repo, branch)

    meta =
      Map.merge(
        %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    {pid, branch}
  end

  defp new_task(ws, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(%{title: "review_gate task", workspace_id: ws.id, issue_type: :feature}, attrs)
      )

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  # ---- gate behaviour ------------------------------------------------------

  describe "the gate" do
    test "parks at :awaiting_review_gate and does NOT merge when review is required",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_author(task, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      # The gate held: no merge happened.
      assert merge_commit_count(repo) == 0
    end

    test "APPROVE proceeds to the merger — a real --no-ff merge lands on main",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_author(task, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      # Direct merges synchronously; the Watchdog then completes the worker.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)
      assert merge_commit_count(repo) == 1

      # The approval is recorded on the task notes (visible via arb show).
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.notes =~ "ReviewGate verdict: APPROVE"
    end

    test "APPROVE with a hosted-forge stub adapter that never reports approval still merges when auto_merge is on (bd-66ey1o)",
         %{repo: repo} do
      # Reproduces the production bug: a ReviewGate APPROVE arrives, the merger
      # opens (or reuses) an MR, and the adapter's get/1 reports
      # `%{status: :open, approved: false}` (no GitHub-side approval). Before
      # bd-66ey1o the Watchdog polled forever waiting for `approved: true`. The
      # fix plumbs `via_review_gate: true` through to the Watchdog so a
      # non-terminal poll is treated as approved on the first poll. Whether the
      # Watchdog then actually clicks merge is a separate decision gated on the
      # workspace's `auto_merge` setting (bd-dkwhbn) — this workspace opts in.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "trib-ws-automerge-#{System.unique_integer([:positive])}",
          prefix: "tb",
          config: %{"review" => %{"required" => true}, "merge" => %{"auto_merge" => true}}
        })

      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("!76")
      # Don't queue any get results → default :open/approved=false forever.

      task = new_task(ws)

      {pid, _branch} =
        start_author(task, repo, %{
          merger_adapter_override: Arbiter.Test.StubMerger,
          merger_workspace_override: ws,
          watchdog_interval_ms: 20,
          watchdog_initial_delay_ms: 0,
          watchdog_max_polls: 50
        })

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      # The Watchdog must merge despite never seeing a forge-side approval.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 3_000)
      assert Arbiter.Test.StubMerger.merge_count("!76") >= 1
      # The local repo was NOT git-merged (StubMerger is a stub) — the merge
      # happened entirely through the adapter callback.
      assert merge_commit_count(repo) == 0
    end

    test "APPROVE with a hosted-forge stub adapter does NOT merge when workspace auto_merge is off (bd-dkwhbn)",
         %{repo: repo} do
      # bd-dkwhbn: leotech has `merge.auto_merge = false` ("human merges company
      # repos"), yet a ReviewGate APPROVE on a fleet-authored branch was
      # force-merging into the hosted-forge target regardless of that setting.
      # via_review_gate must still prevent the bd-66ey1o hang (a non-terminal
      # poll counts as approved), but the actual merge click has to respect
      # auto_merge: false and leave the PR for a human.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "trib-ws-humanmerge-#{System.unique_integer([:positive])}",
          prefix: "tb",
          config: %{"review" => %{"required" => true}, "merge" => %{"auto_merge" => false}}
        })

      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("!77")
      # Don't queue any get results → default :open/approved=false forever.

      task = new_task(ws)

      {pid, _branch} =
        start_author(task, repo, %{
          merger_adapter_override: Arbiter.Test.StubMerger,
          merger_workspace_override: ws,
          watchdog_interval_ms: 20,
          watchdog_initial_delay_ms: 0,
          watchdog_max_polls: 50
        })

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      # Give the Watchdog several poll cycles to (wrongly) auto-merge if the
      # bug is present.
      wait_until(fn -> match?(%{status: :awaiting_review}, Worker.state(pid)) end)
      Process.sleep(150)

      assert Arbiter.Test.StubMerger.merge_count("!77") == 0
      assert merge_commit_count(repo) == 0
      assert match?(%{status: :awaiting_review}, Worker.state(pid))
    end

    test "REQUEST_CHANGES parks the task with findings and does NOT merge",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_author(task, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      findings = "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:1 needs a guard"
      :ok = Worker.review_gate_verdict(pid, {:request_changes, findings})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)

      # Not merged.
      assert merge_commit_count(repo) == 0

      snap = Worker.state(pid)
      assert snap.meta.failure_reason == :review_gate_rejected
      assert snap.meta.review_gate_verdict == :request_changes
      assert snap.meta.review_gate_findings =~ "needs a guard"

      # Task parked (still in_progress, not closed) with findings in its notes.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.status == :in_progress
      assert reloaded.notes =~ "ReviewGate verdict: REQUEST_CHANGES"
      assert reloaded.notes =~ "needs a guard"

      # The Coordinator was escalated.
      escalations = Message.inbox("admiral", workspace_id: ws.id)
      assert Enum.any?(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))
    end

    test "an inconclusive review (no verdict) escalates and does NOT merge",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_author(task, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      :ok = Worker.review_gate_verdict(pid, {:no_verdict, "reviewer crashed"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive
    end

    test "review-off (default) bypasses the gate and merges immediately",
         %{repo: repo, tmp: tmp} do
      # A workspace with no review config → review_required? is false.
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "noreview-#{System.unique_integer([:positive])}",
          prefix: "nr"
        })

      _ = tmp
      task = new_task(ws)
      # No meta review override; review_spawn left default — the gate must never
      # engage because the workspace doesn't require review.
      {pid, _branch} =
        start_author(task, repo, %{review_required: false, review_spawn: true})

      send(pid, {:__claude_session_done__, "arb done"})

      # Straight to the merger — never parks at :awaiting_review_gate.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end)
      assert merge_commit_count(repo) == 1
      refute Worker.state(pid).meta[:review_gate_verdict]
    end

    test "review_gate_verdict/2 is rejected outside :awaiting_review_gate", %{repo: repo, ws: ws} do
      task = new_task(ws)
      {pid, _branch} = start_author(task, repo, %{})

      # Still :running — no verdict expected yet.
      assert {:error, {:invalid_transition, :running, :review_gate_verdict}} =
               Worker.review_gate_verdict(pid, {:approve, "x"})
    end
  end

  # ---- end-to-end: a distinct reviewer worker emits the verdict -----------

  describe "full path with a live (fixture) reviewer" do
    test "a reviewer approves → the branch merges, by a process distinct from the author",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        # Real reviewer spawn, but the "claude" subprocess is our fixture script.
        worktree_path: repo,
        review_command: [@reviewer, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: meta
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      # Reviewer approves → merge fires → author completes.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 1

      # The review was run by a DISTINCT worker (different mind, different
      # process): it recorded its OWN run row under the #review-suffixed id,
      # separate from the author's run. (Asserting on the persisted run avoids
      # racing the short-lived reviewer process in the registry.)
      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)
      assert Enum.any?(runs, &(&1.task_id == review_id)), "expected a distinct reviewer run row"
      assert Enum.any?(runs, &(&1.task_id == task.id)), "expected the author's own run row"
    end

    # bd-78vg4v: a reviewing pass that hangs past the timeout ceiling is retried
    # once with a FRESH reviewer mind before escalating. The @timeout_retry
    # fixture hangs on its first pass, then APPROVEs on the retry → the branch
    # merges rather than escalating as timed-out.
    test "a reviewer that hangs is retried with a fresh mind and converges → merge",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        worktree_path: repo,
        review_command: [@timeout_retry, "APPROVE"],
        # Short per-pass timeout so the hung first pass trips it quickly; the
        # default timeout-retry budget (1) drives the retry.
        review_timeout_ms: 800
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # First pass hangs → timeout fires → retry approves → merge.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 8_000)
      assert merge_commit_count(repo) == 1

      # The retry ran under a distinct timeout-retry id (#t2 suffix), proving the
      # pass was respawned as a fresh worker rather than re-prompting a hung one.
      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &String.starts_with?(&1.task_id, review_id <> "#t")),
             "expected a distinct timeout-retry reviewer run row"
    end

    # bd-78vg4v: with the timeout-retry budget exhausted (0), a hung reviewing
    # pass escalates as timed-out with no merge — the pre-existing behaviour is
    # preserved when retries are disabled.
    test "a hung reviewer with no retry budget escalates as timed out — no merge",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@timeout_retry, "APPROVE"],
        review_timeout_ms: 800,
        # Disable the retry so the hung pass escalates immediately.
        review_timeout_retries: 0
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 6_000)
      snap = Worker.state(pid)
      assert snap.meta.failure_reason == :review_gate_rejected
      assert snap.meta.review_gate_findings =~ "timed out"
      assert merge_commit_count(repo) == 0
    end

    test "a reviewer requests changes → no merge, task parked + escalated",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        # rounds: 1 — a single review pass, so a reject escalates immediately with
        # no revise loop (the Stage 2 loop is exercised separately below).
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@reviewer, "REQUEST_CHANGES"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected

      escalations = Message.inbox("admiral", workspace_id: ws.id)
      assert Enum.any?(escalations, &(&1.directive_ref == task.id))
    end

    test "sync_from_origin fast-forwards the worktree to the latest pushed commit before review (bd-31bh37 regression)",
         %{repo: repo, ws: ws, tmp: tmp} do
      # Simulate the scenario: the per-task worktree has SOME commits (so the
      # Worker commit gate passes) but is BEHIND origin — e.g. the implementer
      # added a second commit from a different session and pushed it, but the
      # local worktree was not updated. Without the fix, the reviewer sees a
      # stale diff (only commit1, missing commit2). With the fix, sync_from_origin
      # fast-forwards the worktree to the pushed tip (commit2) before computing
      # SHAs, so the reviewer sees the full set of changes and the correct HEAD
      # ends up in the merged main.
      task = new_task(ws)
      branch = "feature/sync-test"

      # 1. Create the branch with commit1 and push it. Then checkout main so
      #    the branch is free for `git worktree add`.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      File.write!(Path.join(repo, "step1.txt"), "first commit\n")
      {_, 0} = git(["add", "step1.txt"], repo)
      {_, 0} = git(["commit", "-q", "-m", "step 1"], repo)
      {commit1_sha, 0} = git(["rev-parse", "HEAD"], repo)
      commit1_sha = String.trim(commit1_sha)
      {_, 0} = git(["push", "-q", "origin", branch], repo)
      {_, 0} = git(["checkout", "-q", "main"], repo)

      # 2. Create a per-task worktree at commit1. repo is on main so the branch
      #    is not locked and git worktree add succeeds.
      wt_path = Path.join(tmp, "task-worktree")
      {_, 0} = git(["worktree", "add", "-q", wt_path, branch], repo)

      # 3. From the worktree, add commit2 and push it to origin — simulating a
      #    second commit pushed from a different session. Then reset the worktree
      #    back to commit1 so local lags origin (local = 1 ahead of main; origin
      #    = 2 ahead of main). The Worker commit gate sees 1 commit → passes.
      File.write!(Path.join(wt_path, "step2.txt"), "second commit\n")
      {_, 0} = System.cmd("git", ["-C", wt_path, "add", "step2.txt"])
      {_, 0} = System.cmd("git", ["-C", wt_path, "commit", "-q", "-m", "step 2"])
      {commit2_sha, 0} = System.cmd("git", ["-C", wt_path, "rev-parse", "HEAD"])
      commit2_sha = String.trim(commit2_sha)
      {_, 0} = System.cmd("git", ["-C", wt_path, "push", "-q", "origin", branch])
      {_, 0} = System.cmd("git", ["-C", wt_path, "reset", "-q", "--hard", commit1_sha])

      # At this point: wt_path branch ref = commit1 (1 ahead of main);
      # origin/feature/sync-test = commit2 (2 ahead of main).
      # sync_from_origin must advance wt_path to commit2 before computing
      # head_sha so the merged main ends up at the correct tip.

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        worktree_path: wt_path,
        review_command: [@reviewer, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 1

      # sync_from_origin fast-forwarded the worktree to commit2 before review;
      # the merged main must include commit2 (not just commit1).
      {main_log, 0} = git(["log", "--format=%H", "main"], repo)
      commits = String.split(main_log, "\n", trim: true)

      assert commit2_sha in commits,
             "expected commit2 (#{commit2_sha}) reachable from main after merge"

      assert commit1_sha in commits,
             "expected commit1 (#{commit1_sha}) reachable from main after merge"
    end

    test "review_agent.config.model is passed as `--model` when no command override is given",
         %{repo: repo, tmp: tmp} do
      # Build a `claude` shim on PATH that writes its argv to a file. Without
      # `review_command` in meta the ReviewGate walks the adapter path
      # (Arbiter.Agents.Claude.default_argv) — we want to see `--model haiku`
      # on the reviewer's spawn because the workspace sets review_agent to
      # Haiku while the worker stays on Sonnet.
      argv_file = Path.join(tmp, "reviewer-argv.txt")
      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      stub = Path.join(stub_dir, "claude")

      File.write!(stub, """
      #!/bin/sh
      for a in "$@"; do echo "$a" >> #{argv_file}; done
      # Exit without printing a verdict — we don't care about the outcome here.
      exit 0
      """)

      File.chmod!(stub, 0o755)
      old_path = System.get_env("PATH") || ""
      System.put_env("PATH", "#{stub_dir}:#{old_path}")
      on_exit(fn -> System.put_env("PATH", old_path) end)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "trib-model-ws-#{System.unique_integer([:positive])}",
          prefix: "tm",
          config: %{
            "review" => %{"required" => true, "rounds" => 1},
            "agent" => %{"type" => "claude", "config" => %{"model" => "sonnet"}},
            "review_agent" => %{"type" => "claude", "config" => %{"model" => "haiku"}}
          }
        })

      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_rounds: 1,
        worktree_path: repo,
        # Re-prompt budget 0 + short timeout keeps the test snappy when the
        # stub exits without a verdict.
        review_verdict_retries: 0,
        review_timeout_ms: 3_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # The reviewer subprocess fires and exits; argv lands on disk. Outcome
      # (escalation as :no_verdict) is incidental — we assert on the spawn.
      wait_until(fn -> File.exists?(argv_file) end, 6_000)
      args = File.read!(argv_file) |> String.split("\n", trim: true)
      assert "--model" in args
      assert "haiku" in args
    end
  end

  # ---- verdict re-prompt (bd-8v8ays) ---------------------------------------

  describe "verdict re-prompt" do
    # A reviewer that produces substantive output but forgets the sentinel must
    # be re-prompted; a verdict on the re-prompt is honored. The fixture emits NO
    # verdict on its first pass, so a merge happening at all proves the re-prompt
    # ran and its APPROVE was honored.
    test "a reviewer that omits the verdict is re-prompted; APPROVE on re-prompt merges",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        worktree_path: repo,
        review_command: [@reprompt, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 1

      # The re-prompt ran as a distinct follow-up reviewer (its own run row under
      # the versioned id), separate from the first (verdict-less) pass.
      reprompt_id = ReviewGate.reviewer_task_id(task.id) <> "#v2"
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == reprompt_id)),
             "expected a distinct re-prompt reviewer run row"
    end

    test "REQUEST_CHANGES on re-prompt is honored — no merge, task parked + escalated",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        # rounds: 1 — the re-prompt yields a verdict in the same (only) round; a
        # REQUEST_CHANGES there escalates immediately, no revise loop.
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@reprompt, "REQUEST_CHANGES"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected

      escalations = Message.inbox("admiral", workspace_id: ws.id)
      assert Enum.any?(escalations, &(&1.directive_ref == task.id))
    end

    # Only a SECOND empty result escalates as inconclusive: the fixture withholds
    # the verdict on both the first pass and the re-prompt ("NONE").
    test "a reviewer that omits the verdict twice escalates as inconclusive",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        worktree_path: repo,
        review_command: [@reprompt, "NONE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive

      # The re-prompt WAS attempted before escalating — its run row exists.
      reprompt_id = ReviewGate.reviewer_task_id(task.id) <> "#v2"
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == reprompt_id)),
             "expected a re-prompt to have been attempted before escalating"
    end

    # bd-3y2mda: a REQUEST_CHANGES verdict with NO findings is useless (the
    # implementer has nothing to act on). The ReviewGate treats it as malformed and
    # re-prompts — exactly like a missing sentinel — rather than entering the
    # revise loop empty-handed.
    test "REQUEST_CHANGES with no findings is re-prompted; a valid re-prompt is honored",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        worktree_path: repo,
        # First pass: REQUEST_CHANGES with no findings → re-prompt → APPROVE.
        review_command: [@empty_findings, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 6_000)
      # The findings-less verdict did NOT enter the revise loop; the re-prompt's
      # APPROVE merged. A merge at all proves the empty verdict was re-prompted.
      assert merge_commit_count(repo) == 1

      reprompt_id = ReviewGate.reviewer_task_id(task.id) <> "#v2"
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == reprompt_id)),
             "expected a distinct re-prompt reviewer run row"
    end

    # The acceptance's hard guarantee: a reviewer that requests changes but never
    # lists findings, even after the re-prompt, is escalated as inconclusive —
    # never silently accepted, never merged.
    test "REQUEST_CHANGES with no findings twice escalates as inconclusive — no merge",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@empty_findings, "EMPTY"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive
    end

    # bd-79goxj: an empty-findings REQUEST_CHANGES in the last allowed round must
    # not consume that round. The re-prompt's real findings must reach the
    # implementer via enter_revise. Without the fix: handle_reject sees
    # round == max_rounds and escalates immediately (the implementer never gets to
    # address those findings). With the fix: max_rounds is extended by 1 when the
    # empty-findings re-prompt fires, so enter_revise runs, the implementer
    # addresses the findings, and the round-3 reviewer can approve → merge.
    test "empty-findings verdict does not consume the round cap — implementer gets to revise",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            # 2-round cap: round 1 real reject → revise → round 2 empty verdict
            # (malformed) → re-prompt real findings → (fix) round 3 reviewer.
            review_rounds: 2,
            worktree_path: repo,
            review_command: [@rounds_empty_mid, "APPROVE"],
            revise_command: [@revise],
            review_timeout_ms: 10_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # With the fix: round 2 empty-findings extends the cap to 3 so
      # enter_revise fires, the implementer addresses the re-prompt findings, and
      # the round-3 reviewer approves → merge.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 12_000)
      assert merge_commit_count(repo) == 1

      # A round-2 implementer ran, proving the findings DID reach it.
      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == review_id <> "#impl2")),
             "expected a round-2 implementer run (findings reached the implementer)"
    end

    # bd-79goxj: the verdict retry budget is per-round, not ReviewGate-lifetime.
    # The fixture produces empty REQUEST_CHANGES on the first pass of BOTH round 1
    # and round 2 — each needing one retry. Without the fix the ReviewGate exhausts
    # its 1-retry budget in round 1 and escalates inconclusive when round 2 also
    # needs a reprompt. With the fix retries_left resets to initial_retries at the
    # start of each new round, so round 2 still gets its reprompt → APPROVE → merge.
    test "per-round retry budget resets so round 2 can reprompt even after round 1 used its budget",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: repo,
            # Round 1 first pass → empty RC (uses 1 retry).
            # Round 1 reprompt → RC with real findings → revise implementer.
            # Round 2 first pass → empty RC (needs 1 retry — reset budget proves fix).
            # Round 2 reprompt → APPROVE → merge.
            review_command: [@retry_reset, "APPROVE"],
            revise_command: [@revise],
            review_timeout_ms: 12_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 14_000)
      # Merge proves round 2 got its reprompt (exhausted budget would have escalated).
      assert merge_commit_count(repo) == 1

      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == review_id <> "#impl1")),
             "expected a round-1 implementer run"
    end

    # bd-b0x3jy / bd-40v3w1: the default task difficulty uses 3 review rounds.
    # An empty-findings REQUEST_CHANGES in round 3 (the last allowed round) must
    # NOT consume that round — the fix (bd-79goxj) extends max_rounds to 4 so
    # the re-prompt's real findings still reach an implementer, and a round-4
    # reviewer can then approve → merge. Without the fix: handle_reject sees
    # round(3) >= max_rounds(3) and escalates; the Coordinator gets an unresolved
    # task even though the work was sound.
    test "empty-findings in the LAST round of a 3-round gate does not consume that round",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            # 3-round cap: default difficulty. Rounds 1 and 2 reject with real
            # findings; round 3 (last) gives an empty verdict → reprompt fires
            # → re-prompt gives real findings → max_rounds extends to 4 so
            # enter_revise runs → implementer addresses findings → round-4
            # reviewer approves → merge.
            review_rounds: 3,
            worktree_path: repo,
            review_command: [@rounds_empty_last, "APPROVE"],
            revise_command: [@revise],
            review_timeout_ms: 14_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 16_000)
      # Merge proves round 3's empty verdict was re-prompted (not treated as a
      # final round-3 cap hit) and that the implementer got to revise.
      assert merge_commit_count(repo) == 1

      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == review_id <> "#impl3")),
             "expected a round-3 implementer run (empty-findings re-prompt reached implementer)"
    end
  end

  # ---- Stage 2: the revise-and-rediscuss loop (bd-3jm700) ------------------

  describe "revise-and-rediscuss loop" do
    # The reviewer rejects round 1; a fresh implementer revises; the reviewer
    # approves round 2 → the branch merges. The @rounds fixture rejects on its
    # first pass and approves on every later one; @revise stands in for the
    # implementer between the two reviews.
    test "reject → revise → approve converges and merges within the round cap",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: repo,
            review_command: [@rounds, "APPROVE"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # Round 1 rejects → implementer revises → round 2 approves → merge.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 8_000)
      assert merge_commit_count(repo) == 1

      # A distinct implementer worker ran between the rounds (its own run row
      # under the round-1 #impl id), proving a fresh mind addressed the findings.
      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      assert Enum.any?(runs, &(&1.task_id == review_id <> "#impl1")),
             "expected a distinct implementer run row for round 1"

      # A distinct round-2 reviewer ran too.
      assert Enum.any?(runs, &(&1.task_id == review_id <> "#r2")),
             "expected a distinct round-2 reviewer run row"

      # The implementer↔reviewer back-and-forth was persisted to the mailbox as a
      # durable thread (reviewer findings + implementer response), oldest first.
      thread = Message.thread(task.id, workspace_id: ws.id)
      flags = Enum.filter(thread, &(&1.kind == :flag))
      assert length(flags) >= 2

      assert Enum.any?(flags, &(&1.from_ref == review_id and &1.to_ref == task.id)),
             "expected a reviewer→implementer findings message"

      assert Enum.any?(flags, &(&1.from_ref == task.id and &1.to_ref == review_id)),
             "expected an implementer→reviewer response message"
    end

    # bd-78vg4v: a large implementer transcript is CAPPED (head+tail) when
    # recorded into the durable thread, so the round-2 re-review prompt stays
    # bounded instead of ballooning past round-1's. The @revise_huge fixture
    # emits ~280 KB with distinctive HEAD/TAIL markers; the persisted
    # implementer→reviewer message must keep both markers but be far smaller.
    test "a large implementer transcript is capped in the persisted thread",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: repo,
            review_command: [@rounds, "APPROVE"],
            revise_command: [@revise_huge],
            review_timeout_ms: 10_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # Round 1 rejects → huge revise → round 2 approves → merge.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 12_000)

      review_id = ReviewGate.reviewer_task_id(task.id)
      thread = Message.thread(task.id, workspace_id: ws.id)

      impl_msg =
        Enum.find(
          thread,
          &(&1.kind == :flag and &1.from_ref == task.id and &1.to_ref == review_id)
        )

      assert impl_msg, "expected an implementer→reviewer response in the thread"

      # The recorded transcript is capped well below the raw ~280 KB output but
      # preserves BOTH the opening context and the actionable FIX conclusion.
      assert byte_size(impl_msg.body) <= 20_000,
             "implementer transcript must be capped, was #{byte_size(impl_msg.body)} bytes"

      assert impl_msg.body =~ "IMPL_HEAD_MARKER", "head (opening context) must survive the cap"

      assert impl_msg.body =~ "IMPL_TAIL_MARKER: FIXED",
             "tail (the FIX conclusion) must survive the cap"

      assert impl_msg.body =~ "elided", "the elided middle must be marked"
    end

    # The reviewer holds the line on BOTH rounds (the @rounds fixture rejects
    # first, then emits REQUEST_CHANGES again). After the 2-round cap the ReviewGate
    # escalates to Darth Gnosis with the FULL transcript + diff — no merge.
    test "not converged after the cap → escalate with the full transcript, no merge",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: repo,
            review_command: [@rounds, "REQUEST_CHANGES"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 8_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected

      # The escalation to the Coordinator carries the FULL ordered transcript (both
      # rounds of findings + the implementer's response) and the current diff —
      # Darth Gnosis judges with the whole argument, not a summary.
      escalations = Message.inbox("admiral", workspace_id: ws.id)
      escalation = Enum.find(escalations, &(&1.directive_ref == task.id))
      assert escalation, "expected an escalation to the coordinator"
      assert escalation.body =~ "transcript"
      assert escalation.body =~ "Round 1"
      assert escalation.body =~ "Round 2"
      assert escalation.body =~ "Implementer → Reviewer"
      assert escalation.body =~ "Current diff"

      # The same transcript is on the task notes (visible via arb show), including
      # the round count so operators can see it ran the full 2-round cap.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.notes =~ "REQUEST_CHANGES"
      assert reloaded.notes =~ "rounds: 2"

      # The full thread persisted as durable mailbox rows: r1 findings, r1
      # response, r2 findings — three :flag entries, oldest first.
      review_id = ReviewGate.reviewer_task_id(task.id)
      flags = task.id |> Message.thread(workspace_id: ws.id) |> Enum.filter(&(&1.kind == :flag))
      assert length(flags) == 3

      assert Enum.count(flags, &(&1.from_ref == review_id)) == 2,
             "expected two reviewer→implementer findings rows (round 1 and round 2)"

      assert Enum.count(flags, &(&1.from_ref == task.id)) == 1,
             "expected one implementer→reviewer response row"
    end

    # The cap is a HARD limit: rounds: 1 means a single review pass. A reject
    # escalates immediately — no implementer is ever spawned, no revise loop.
    test "rounds: 1 escalates on the first reject with no revise loop",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            review_rounds: 1,
            worktree_path: repo,
            review_command: [@reviewer, "REQUEST_CHANGES"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected

      # No implementer was ever spawned — the round cap was 1.
      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      refute Enum.any?(runs, &(&1.task_id == review_id <> "#impl1")),
             "rounds: 1 must not spawn an implementer"
    end
  end

  # ---- Stage 3: same-mind continuity briefing (bd-1na62i) ------------------

  describe "revise_prompt/2 git-state briefing" do
    # The revise-round implementer is a fresh mind. Stage 3 prepends a
    # git-derived "work so far" briefing so it continues the prior round's
    # thread instead of re-deriving it from a raw diff.
    test "prepends the prior round's committed + uncommitted work", %{repo: repo, ws: ws} do
      task = new_task(ws, %{description: "the directive", acceptance: "it works"})
      branch = "feature/rev"

      # Put HEAD on the feature branch with a commit ahead of main, plus an
      # uncommitted edit — exactly the state a prior revise round would leave.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      File.write!(Path.join(repo, "fix.ex"), "defmodule Fix, do: nil\n")
      {_, 0} = git(["add", "fix.ex"], repo)
      {_, 0} = git(["commit", "-q", "-m", "round 1 fix from prior implementer"], repo)
      File.write!(Path.join(repo, "README.md"), "seed\nstraggler edit\n")

      state = %{
        task_id: task.id,
        branch: branch,
        target_branch: "main",
        worktree_path: repo,
        round: 2
      }

      prompt = ReviewGate.revise_prompt(state, "VERDICT: REQUEST_CHANGES\n1. fix the thing")

      # The briefing surfaces both the committed work and the uncommitted WIP.
      assert prompt =~ "Work done so far on this branch"
      assert prompt =~ "round 1 fix from prior implementer"
      assert prompt =~ "Uncommitted work-in-progress"
      assert prompt =~ "straggler edit"
      # The findings and directive still travel alongside the briefing.
      assert prompt =~ "fix the thing"
      assert prompt =~ "the directive"
    end

    # A worktree-less ReviewGate (ad-hoc / test run) must degrade to the
    # directive-only prompt rather than crash trying to read git state.
    test "degrades gracefully with no worktree", %{ws: ws} do
      task = new_task(ws, %{description: "the directive"})

      state = %{
        task_id: task.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1
      }

      prompt = ReviewGate.revise_prompt(state, "VERDICT: REQUEST_CHANGES\n1. fix it")

      refute prompt =~ "Work done so far on this branch"
      assert prompt =~ "fix it"
      assert prompt =~ "the directive"
    end

    test "clean_findings/1 strips sentinel lines and arb done markers from findings", %{ws: ws} do
      task = new_task(ws, %{description: "the directive"})

      state = %{
        task_id: task.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1
      }

      # Findings contain both the REQUEST_CHANGES sentinel and an arb done marker
      findings = "VERDICT: REQUEST_CHANGES\n1. fix it\narb done"
      prompt = ReviewGate.revise_prompt(state, findings)

      # The prompt has the template instructions containing 'arb done' at the end,
      # but the findings section itself must be clean.
      findings_section =
        prompt
        |> String.split("Reviewer findings (round 1):")
        |> Enum.at(1)
        |> String.split("For EACH finding")
        |> Enum.at(0)

      refute findings_section =~ "VERDICT: REQUEST_CHANGES"
      refute findings_section =~ "arb done"
      assert findings_section =~ "1. fix it"
    end
  end

  # ---- Pre-spawn commit gate and HEAD-SHA anchoring (bd-1mksks) ------------

  describe "pre-spawn commit gate (bd-1mksks)" do
    # The ReviewGate must gate on commits BEFORE spawning the reviewer. Even if the
    # worker commit gate already fired, this second layer catches the revise-round
    # case (the revise implementer's worker has no worktree_path in meta, so its
    # commit gate does not fire).
    test "ReviewGate escalates as request_changes when branch has no commits",
         %{repo: repo, ws: ws} do
      task = new_task(ws)
      branch = "feature/no-commits"

      # Create the branch at the same commit as main — no commits ahead.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      # HEAD is NOW on feature/no-commits at the same SHA as main.
      # Return to main so the repo state is clear.
      {_, 0} = git(["checkout", "-q", "main"], repo)

      # Park the author worker at :awaiting_review_gate via review_spawn: false so
      # the worker commit gate does NOT fire (no worktree_path in meta → gate
      # skips). We then start a ReviewGate manually, pointing at a worktree that is
      # actually on feature/no-commits with 0 commits ahead.
      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_spawn: false
      }

      {:ok, author} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
      :ok = Worker.advance(author, :claude)
      send(author, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(author)) end)

      # Switch the branch worktree to `feature/no-commits` so the ReviewGate sees
      # the branch with 0 commits ahead. We use a fresh sub-worktree for this.
      sub_wt = Path.join(Path.dirname(repo), "no-commits-wt")
      File.mkdir_p!(sub_wt)

      on_exit(fn ->
        _ = System.cmd("git", ["-C", sub_wt, "worktree", "remove", "--force", sub_wt])
        File.rm_rf!(sub_wt)
      end)

      {_, 0} =
        System.cmd("git", ["worktree", "add", sub_wt, branch],
          cd: repo,
          stderr_to_stdout: true
        )

      # Directly spawn a ReviewGate that points at the zero-commit worktree.
      # A real reviewer command is supplied but should NEVER be reached — the
      # ReviewGate must escalate before it spawns the reviewer.
      {:ok, _review_gate} =
        ReviewGate.start(
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "trib/repo",
          worktree_path: sub_wt,
          branch: branch,
          target_branch: "main",
          command: [@reviewer, "APPROVE"],
          timeout_ms: 5_000
        )

      # The ReviewGate should report :request_changes immediately (no reviewer spawn).
      wait_until(fn -> match?(%{status: :failed}, Worker.state(author)) end, 4_000)
      snap = Worker.state(author)
      assert snap.meta.failure_reason == :review_gate_rejected
      assert snap.meta.review_gate_findings =~ "no commits ahead"
      # The branch was NOT merged.
      assert merge_commit_count(repo) == 0
    end
  end

  describe "stale-base defence (bd-ased52)" do
    # The reviewer must diff against the merge-base, not the moving target tip,
    # so a target that advanced mid-run can't be mis-attributed to the branch.
    test "review_prompt anchors the diff on the merge-base and warns off two-dot",
         %{ws: ws} do
      task = new_task(ws)

      state = %{
        task_id: task.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil,
        base_sha: "abc1234"
      }

      prompt = ReviewGate.review_prompt(state)

      assert prompt =~ "git diff abc1234..HEAD",
             "review_prompt must point the reviewer at the merge-base diff"

      assert prompt =~ "Do NOT use `git diff main..HEAD`",
             "review_prompt must warn against the two-dot diff that leaks target commits"
    end

    # A branch that conflicts with the advanced target must escalate (a conflict escalation)
    # rather than be reviewed against a stale base — and the reviewer must never
    # be spawned (mirrors the #97 abort-on-conflict posture).
    test "a branch that conflicts with an advanced target escalates before the reviewer spawns",
         %{repo: repo, ws: ws} do
      # Give the rig an origin remote and push main, so update_from_target can
      # fetch + merge origin/main. init_rig already added origin (origin.git), so
      # point it at this test's bare conflict repo instead.
      remote = Path.join(Path.dirname(repo), "remote-conflict.git")
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
      {_, 0} = git(["remote", "set-url", "origin", remote], repo)
      {_, 0} = git(["push", "-q", "origin", "main"], repo)

      task = new_task(ws)
      branch = "feature/conflict"

      sub_wt = Path.join(Path.dirname(repo), "conflict-wt")

      on_exit(fn ->
        _ = System.cmd("git", ["-C", repo, "worktree", "remove", "--force", sub_wt])
        File.rm_rf!(sub_wt)
        File.rm_rf!(remote)
      end)

      # Branch cut from origin/main; it edits README.md and commits.
      {_, 0} =
        System.cmd("git", ["-C", repo, "worktree", "add", sub_wt, "-b", branch, "origin/main"],
          stderr_to_stdout: true
        )

      File.write!(Path.join(sub_wt, "README.md"), "branch version\n")
      {_, 0} = git(["add", "README.md"], sub_wt)
      {_, 0} = git(["commit", "-q", "-m", "branch readme"], sub_wt)

      # The target advances mid-run, editing the SAME file differently → conflict.
      File.write!(Path.join(repo, "README.md"), "fleet version\n")
      {_, 0} = git(["add", "README.md"], repo)
      {_, 0} = git(["commit", "-q", "-m", "fleet readme"], repo)
      {_, 0} = git(["push", "-q", "origin", "main"], repo)

      # Park the author at :awaiting_review_gate (review_spawn: false, no
      # worktree_path so the worker commit gate skips).
      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{task.id}",
        review_required: true,
        review_spawn: false
      }

      {:ok, author} =
        Worker.start(task_id: task.id, repo: "trib/repo", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
      :ok = Worker.advance(author, :claude)
      send(author, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(author)) end)

      # The reviewer command must NEVER run — the gate escalates on conflict first.
      {:ok, _gate} =
        ReviewGate.start(
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "trib/repo",
          worktree_path: sub_wt,
          branch: branch,
          target_branch: "main",
          command: [@reviewer, "APPROVE"],
          timeout_ms: 5_000
        )

      wait_until(fn -> match?(%{status: :failed}, Worker.state(author)) end, 6_000)
      snap = Worker.state(author)
      assert snap.meta.failure_reason == :review_gate_rejected
      assert snap.meta.review_gate_findings =~ "conflicts with its target"
      assert snap.meta.review_gate_findings =~ "README.md"

      # The branch was NOT merged and the worktree is clean (merge aborted).
      assert merge_commit_count(repo) == 0
      assert {:ok, false} = Arbiter.Worker.Worktree.has_uncommitted?(sub_wt)

      # The reviewer was never spawned: no #review run row exists.
      review_id = ReviewGate.reviewer_task_id(task.id)
      runs = Ash.read!(Arbiter.Workers.Run)

      refute Enum.any?(runs, &(&1.task_id == review_id)),
             "the reviewer must NOT run when the branch conflicts with its target"
    end
  end

  describe "review_prompt/1 HEAD-SHA anchoring (bd-1mksks)" do
    # The review prompt must embed the HEAD SHA verified at spawn time so the
    # reviewer can confirm it is on the correct commit before diffing.
    test "includes the HEAD SHA when the worktree is on the expected branch",
         %{repo: repo, ws: ws} do
      task = new_task(ws, %{description: "impl desc", acceptance: "it works"})
      branch = "feature/rev"

      # Put the repo HEAD on the feature branch with a commit ahead of main.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      File.write!(Path.join(repo, "work.txt"), "done\n")
      {_, 0} = git(["add", "work.txt"], repo)
      {_, 0} = git(["commit", "-q", "-m", "the work"], repo)

      {sha_out, 0} = git(["rev-parse", "--short", "HEAD"], repo)
      expected_sha = String.trim(sha_out)

      state = %{
        task_id: task.id,
        branch: branch,
        target_branch: "main",
        worktree_path: repo,
        round: 1,
        head_sha: expected_sha
      }

      prompt = ReviewGate.review_prompt(state)

      assert prompt =~ expected_sha,
             "review_prompt must embed the HEAD SHA so the reviewer can verify the commit"

      assert prompt =~ "git log --oneline -1",
             "review_prompt must instruct the reviewer to confirm HEAD"
    end

    test "omits the HEAD SHA anchor when head_sha is nil (no worktree / ad-hoc)",
         %{ws: ws} do
      task = new_task(ws)

      state = %{
        task_id: task.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil
      }

      prompt = ReviewGate.review_prompt(state)

      # No SHA anchor — the prompt must still be valid.
      refute prompt =~ "HEAD at dispatch time was commit",
             "review_prompt must not emit a SHA anchor when head_sha is nil"

      assert prompt =~ "git diff main...HEAD",
             "review_prompt must still include the diff command"
    end
  end

  describe "review_prompt/1 PR-aware review (bd-129xh4)" do
    # When the author opened a PR before the gate ran, the reviewer prompt must
    # point at the real PR so it can `gh pr diff <n>` instead of only diffing
    # the local branch.
    test "embeds gh pr commands when a pr_ref is present", %{ws: ws} do
      task = new_task(ws)

      state = %{
        task_id: task.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil,
        pr_ref: "ryanrborn/arbiter#42"
      }

      prompt = ReviewGate.review_prompt(state)

      assert prompt =~ "PR #42",
             "review_prompt must name the open PR number when a pr_ref is present"

      assert prompt =~ "gh pr diff 42",
             "review_prompt must offer `gh pr diff <n>` so the reviewer reads the PR diff"

      assert prompt =~ "gh pr review 42",
             "review_prompt must offer `gh pr review <n>` for inline comments"
    end

    test "accepts the bare '#42' ref form", %{ws: ws} do
      task = new_task(ws)
      state = %{task_id: task.id, branch: "feature/rev", target_branch: "main", pr_ref: "#42"}

      assert ReviewGate.review_prompt(state) =~ "gh pr diff 42"
    end

    test "omits the PR block when no pr_ref is set (branch-diff fallback)", %{ws: ws} do
      task = new_task(ws)
      state = %{task_id: task.id, branch: "feature/rev", target_branch: "main", pr_ref: nil}

      prompt = ReviewGate.review_prompt(state)

      refute prompt =~ "gh pr diff",
             "review_prompt must not mention gh pr when no PR was opened"

      assert prompt =~ "git diff main...HEAD",
             "review_prompt must still include the branch-diff command on the fallback path"
    end
  end

  describe "PR opened before the reviewer (bd-129xh4)" do
    # With a hosted merger configured, the author must OPEN the PR before parking
    # at :awaiting_review_gate — so the reviewer has a real PR to review. The
    # open must NOT merge; the merge still happens later, on APPROVE.
    test "opens the PR (without merging) before the review gate, recording pr_ref",
         %{repo: repo, ws: ws} do
      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("acme/repo#88")

      task = new_task(ws)

      {pid, _branch} =
        start_author(task, repo, %{merger_adapter_override: Arbiter.Test.StubMerger})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      # The PR was opened before the gate, but NOT merged yet.
      assert Arbiter.Test.StubMerger.last_open() != nil,
             "the author must open the PR before kicking off the reviewer"

      assert Arbiter.Test.StubMerger.merge_count("acme/repo#88") == 0,
             "opening the PR for review must not merge it"

      # The pr_ref is persisted so the reviewer (and later the MergeQueue) adopt
      # the same PR.
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.pr_ref == "acme/repo#88"
    end

    test "APPROVE after a pre-opened PR still merges the same PR", %{repo: repo} do
      # auto_merge: true — this test is about PR reuse (the already-open PR
      # gets merged rather than a duplicate being opened), not about the
      # human-merge policy covered separately under "the gate" (bd-dkwhbn).
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "trib-ws-preopened-#{System.unique_integer([:positive])}",
          prefix: "tb",
          config: %{"review" => %{"required" => true}, "merge" => %{"auto_merge" => true}}
        })

      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("acme/repo#88")

      task = new_task(ws)

      {pid, _branch} =
        start_author(task, repo, %{
          merger_adapter_override: Arbiter.Test.StubMerger,
          merger_workspace_override: ws,
          watchdog_interval_ms: 20,
          watchdog_initial_delay_ms: 0,
          watchdog_max_polls: 50
        })

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      :ok = Worker.review_gate_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 3_000)
      assert Arbiter.Test.StubMerger.merge_count("acme/repo#88") >= 1
    end

    # Regression for bd-7d5smn: the pre-review PR was opened with the internal
    # "Merge <id>: ..." title prefix instead of the clean task title.
    test "pre-review PR uses the clean task title, not the internal merge_title prefix",
         %{repo: repo, ws: ws} do
      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("acme/repo#89")

      task = new_task(ws, %{title: "Add frobulation support"})

      {pid, _branch} =
        start_author(task, repo, %{merger_adapter_override: Arbiter.Test.StubMerger})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      opened = Arbiter.Test.StubMerger.last_open()
      assert opened != nil, "pre-review PR must have been opened"

      assert opened.title == "Add frobulation support",
             "PR title must be the clean task title, got: #{inspect(opened.title)}"

      refute String.contains?(opened.title, "Merge #{task.id}"),
             "PR title must NOT carry the internal fleet prefix"
    end

    # Regression for bd-7d5smn: the pre-review PR was opened with a filled raw
    # template body rather than the worker-authored pr_body stored on the task.
    test "pre-review PR uses the worker-authored pr_body when present (bd-7d5smn)",
         %{repo: repo, ws: ws} do
      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("acme/repo#90")

      task = new_task(ws)
      worker_body = "## Summary\nFixed the thing.\n\n## Test plan\n- [x] mix test"
      {:ok, task} = Ash.update(task, %{pr_body: worker_body}, action: :update)

      {pid, _branch} =
        start_author(task, repo, %{merger_adapter_override: Arbiter.Test.StubMerger})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end)

      opened = Arbiter.Test.StubMerger.last_open()
      assert opened != nil, "pre-review PR must have been opened"

      assert opened.description == worker_body,
             "PR body must be the worker-authored pr_body, got: #{inspect(opened.description)}"
    end
  end

  describe "review-gate hardening (bd-2y0gd5)" do
    test "snapshotting the supervisor's children never crashes the ReviewGate",
         %{repo: repo, ws: ws} do
      pid = start_live_gate(repo, ws)
      review_gate = wait_until_review_gate()

      # The crash trigger: enumerate + :snapshot every supervisor child.
      children = Worker.list_children()

      # The ReviewGate is NOT a worker, so it must be filtered OUT of the list...
      refute Enum.any?(children, &(&1.pid == review_gate))
      # ...and the probe must not have killed it.
      assert Process.alive?(review_gate)
      # A direct :snapshot also answers gracefully instead of crashing.
      assert %{role: :review_gate, status: :reviewing} = GenServer.call(review_gate, :snapshot)
      # Gate intact: the author is still parked, nothing merged.
      assert %{status: :awaiting_review_gate} = Worker.state(pid)
      assert merge_commit_count(repo) == 0
    end

    test "a ReviewGate that dies before a verdict escalates the author (no strand, no merge)",
         %{repo: repo, ws: ws} do
      pid = start_live_gate(repo, ws)
      review_gate = wait_until_review_gate()

      # Kill the gate before it can deliver a verdict.
      Process.exit(review_gate, :kill)

      # The author must escalate to :failed (no_verdict) — NOT hang at
      # :awaiting_review_gate — and must NOT merge.
      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 4_000)
      assert merge_commit_count(repo) == 0
    end
  end

  # Start an author through the gate with a *lingering* reviewer (so the ReviewGate
  # stays alive while a test probes or kills it). Cleanup cascades: stopping the
  # author trips the ReviewGate's author-monitor, which stops the reviewer.
  defp start_live_gate(repo, ws) do
    task = new_task(ws)
    branch = "feature/rev"
    :ok = seed_feature_branch(repo, branch)
    sleep = System.find_executable("sleep") || "/bin/sleep"

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          worktree_path: repo,
          review_command: [sleep, "10"],
          review_timeout_ms: 30_000
        }
      )

    on_exit(fn ->
      review_id = ReviewGate.reviewer_task_id(task.id)
      if rp = Worker.whereis(review_id), do: safe_stop(rp)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_review_gate}, Worker.state(pid)) end, 4_000)
    pid
  end

  # ---- difficulty-derived round cap (bd-a5k6wb) ----------------------------

  describe "rounds_for_difficulty/1" do
    test "D0 and D1 tasks get a 2-round cap" do
      assert ReviewGate.rounds_for_difficulty(0) == 2
      assert ReviewGate.rounds_for_difficulty(1) == 2
    end

    test "D2 (moderate) and nil get the 3-round default" do
      assert ReviewGate.rounds_for_difficulty(2) == 3
      assert ReviewGate.rounds_for_difficulty(nil) == 3
    end

    test "D3 and D4 tasks get a 4-round cap" do
      assert ReviewGate.rounds_for_difficulty(3) == 4
      assert ReviewGate.rounds_for_difficulty(4) == 4
    end
  end

  describe "difficulty-derived and workspace-cap round resolution" do
    # A D0 task has a 2-round default. With the @rounds fixture (reject first,
    # approve second), a 2-round cap means one reject + one revise → approval.
    # Because only 2 rounds are allowed and the second approves, the task merges.
    test "D0 task escalates after 2 rounds (difficulty default applies)",
         %{repo: repo, ws: ws} do
      task = new_task(ws, %{difficulty: 0})
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            worktree_path: repo,
            # @rounds rejects round 1, approves round 2 — within a D0 cap of 2.
            review_command: [@rounds, "APPROVE"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # Round 1 rejects → revise → round 2 approves → merge.
      wait_until(fn -> match?(%{status: :completed}, Worker.state(pid)) end, 8_000)
      assert merge_commit_count(repo) == 1
    end

    # A D3 task has a 4-round default. A workspace with max_rounds: 2 caps it at
    # min(4, 2) = 2. The @rounds fixture rejects first then emits REQUEST_CHANGES
    # on all later passes, so after 2 rounds it escalates — proving the workspace
    # cap was applied rather than the difficulty default of 4.
    test "workspace cap overrides difficulty default (min wins)",
         %{repo: repo} do
      {:ok, ws_capped} =
        Ash.create(Workspace, %{
          name: "capped-ws-#{System.unique_integer([:positive])}",
          prefix: "cp",
          config: %{
            "review" => %{"required" => true},
            "review_gate" => %{"max_rounds" => 2}
          }
        })

      task = new_task(ws_capped, %{difficulty: 3})
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "trib/repo",
          workspace_id: ws_capped.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{task.id}",
            review_required: true,
            worktree_path: repo,
            # @rounds always REQUEST_CHANGES — the cap determines when to escalate.
            review_command: [@rounds, "REQUEST_CHANGES"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # The workspace cap of 2 is less than the D3 difficulty default of 4.
      # After 2 rounds of rejections the ReviewGate escalates — not 4.
      wait_until(fn -> match?(%{status: :failed}, Worker.state(pid)) end, 10_000)
      assert merge_commit_count(repo) == 0
      assert Worker.state(pid).meta.failure_reason == :review_gate_rejected

      escalation_body = Worker.state(pid).meta.review_gate_findings
      # The escalation payload names both rounds, proving it ran exactly 2.
      assert escalation_body =~ "Round 1"
      assert escalation_body =~ "Round 2"
      # It should NOT mention Round 3 — the cap held at 2.
      refute escalation_body =~ "Round 3"
    end
  end

  # ---- adapter-specific async-tool instruction (bd-1mlr56) -----------------

  describe "adapter-specific async tool instruction in review_prompt/1" do
    # Helper to build a minimal state map with a workspace_id for prompt tests.
    defp state_for(task, ws, opts \\ %{}) do
      Map.merge(
        %{
          task_id: task.id,
          branch: "feature/rev",
          target_branch: "main",
          worktree_path: nil,
          round: 1,
          head_sha: nil,
          workspace_id: ws.id
        },
        opts
      )
    end

    test "Claude workspace emits the async-parallel instruction block", %{ws: ws} do
      # The setup creates a Claude workspace (no `agent.type` set → defaults to claude).
      task = new_task(ws)
      prompt = ReviewGate.review_prompt(state_for(task, ws))

      assert prompt =~ "ASYNC TOOLS",
             "Claude workspace must include the ASYNC TOOLS block"

      assert prompt =~ "including in parallel or with background execution modes",
             "Claude workspace must permit parallel and background execution"

      refute prompt =~ "synchronously",
             "Claude workspace must not include the sync-only instruction"
    end

    test "Claude workspace emits async instruction in verdict_reprompt_prompt/1", %{ws: ws} do
      task = new_task(ws)
      prompt = ReviewGate.verdict_reprompt_prompt(state_for(task, ws), :no_verdict)

      assert prompt =~ "ASYNC TOOLS"
      assert prompt =~ "including in parallel or with background execution modes"
      refute prompt =~ "synchronously"
    end

    test "Gemini workspace emits the sync-only instruction block, not the async block",
         %{ws: _ws} do
      {:ok, gemini_ws} =
        Ash.create(Workspace, %{
          name: "gemini-ws-#{System.unique_integer([:positive])}",
          prefix: "gm",
          config: %{
            "review" => %{"required" => true},
            "review_agent" => %{"type" => "gemini"}
          }
        })

      task = new_task(gemini_ws)
      prompt = ReviewGate.review_prompt(state_for(task, gemini_ws))

      refute prompt =~ "ASYNC TOOLS",
             "Gemini workspace must not include the ASYNC TOOLS heading"

      refute prompt =~ "including in parallel or with background execution modes",
             "Gemini workspace must not include the Claude parallel-execution phrase"

      assert prompt =~ "synchronously",
             "Gemini workspace must include the sync-only instruction"
    end

    test "Gemini workspace emits sync-only instruction in verdict_reprompt_prompt/1" do
      {:ok, gemini_ws} =
        Ash.create(Workspace, %{
          name: "gemini-reprompt-ws-#{System.unique_integer([:positive])}",
          prefix: "gr",
          config: %{
            "review" => %{"required" => true},
            "review_agent" => %{"type" => "gemini"}
          }
        })

      task = new_task(gemini_ws)
      prompt = ReviewGate.verdict_reprompt_prompt(state_for(task, gemini_ws), :empty_findings)

      refute prompt =~ "ASYNC TOOLS"
      assert prompt =~ "synchronously"
    end

    test "review_prompt/1 always includes the timeout fallback note (bd-c1qbee)", %{ws: ws} do
      # Every reviewer — Claude or Gemini — must be told to wrap test commands
      # with a hard timeout and issue VERDICT-from-diff if they cannot complete.
      # Fixes the hang observed in bd-c8uki0#review#r2 (cold _build, mix test
      # background-jobbed, session exited with zero tokens and no VERDICT).
      task = new_task(ws)
      prompt = ReviewGate.review_prompt(state_for(task, ws))

      assert prompt =~ "timeout 120 mix test",
             "review_prompt must recommend a hard timeout wrapper for mix test"

      assert prompt =~ "VERDICT based on the diff alone",
             "review_prompt must instruct the reviewer to fall back to diff-only VERDICT when tests cannot complete"
    end

    test "nil workspace_id defaults to the Claude async block" do
      state = %{
        task_id: "no-ws-task",
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil,
        workspace_id: nil
      }

      prompt = ReviewGate.review_prompt(state)

      assert prompt =~ "ASYNC TOOLS",
             "nil workspace must fall back to the Claude async block"

      assert prompt =~ "background execution modes"
    end

    test "missing workspace_id key defaults to the Claude async block" do
      # Some test helpers build state maps without workspace_id. The prompt
      # must not crash and must fall back to the Claude block.
      state = %{
        task_id: "no-ws-key-task",
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil
      }

      prompt = ReviewGate.review_prompt(state)
      assert prompt =~ "ASYNC TOOLS"
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  # Poll for the live ReviewGate child of the worker supervisor; return its pid.
  defp wait_until_review_gate(timeout \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_review_gate(deadline)
  end

  defp do_wait_review_gate(deadline) do
    pid =
      Arbiter.Worker.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {_, p, _, [Arbiter.Worker.ReviewGate]} when is_pid(p) -> p
        _ -> nil
      end)

    cond do
      is_pid(pid) ->
        pid

      System.monotonic_time(:millisecond) > deadline ->
        flunk("ReviewGate child did not appear within timeout")

      true ->
        Process.sleep(15)
        do_wait_review_gate(deadline)
    end
  end
end
