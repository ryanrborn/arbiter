defmodule Arbiter.Polecat.TribunalTest do
  @moduledoc """
  The review (Tribunal) gate that sits between an acolyte's `arb done` and the
  merger — Stage 1 (bd-4g1rg1) plus the Stage 2 revise-and-rediscuss loop
  (bd-3jm700).

  Stage 1 covers the four required paths plus verdict parsing:

    * gate parks at `:awaiting_tribunal` (and does NOT merge) when review is
      required,
    * APPROVE → the branch merges (a real `git merge --no-ff` on main),
    * REQUEST_CHANGES → the branch is NOT merged, the bead is parked with the
      findings, and the Admiral is escalated,
    * review-off (default) → completion routes straight to the merger, no gate.

  Plus a full end-to-end path where a **distinct** reviewer acolyte (a second
  polecat + a fixture "claude" subprocess) emits the verdict.

  Stage 2 covers the revise-and-rediscuss loop (`describe "revise-and-rediscuss
  loop"`): a REQUEST_CHANGES within the round cap spawns a fresh implementer to
  address the findings on the same branch (the thread persisted to the mailbox),
  then re-reviews — converging to a merge, or escalating to Darth Gnosis with the
  full transcript once the `config["review"]["rounds"]` cap is hit.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Beads.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Polecat
  alias Arbiter.Polecat.Tribunal

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)
  @reprompt Path.expand("../../fixtures/review_reprompt.sh", __DIR__)
  @empty_findings Path.expand("../../fixtures/review_empty_findings.sh", __DIR__)
  @rounds Path.expand("../../fixtures/review_rounds.sh", __DIR__)
  @revise Path.expand("../../fixtures/revise.sh", __DIR__)

  # ---- pure verdict parsing ------------------------------------------------

  describe "parse_verdict/1" do
    test "recognizes APPROVE" do
      assert {:approve, findings} =
               Tribunal.parse_verdict(["looks good", "VERDICT: APPROVE", "ship it"])

      assert findings =~ "VERDICT: APPROVE"
      assert findings =~ "ship it"
    end

    test "recognizes REQUEST_CHANGES and captures findings from the verdict line on" do
      lines = [
        "preamble noise",
        "VERDICT: REQUEST_CHANGES",
        "- [high] foo.ex:12 missing nil guard"
      ]

      assert {:request_changes, findings} = Tribunal.parse_verdict(lines)
      refute findings =~ "preamble noise"
      assert findings =~ "missing nil guard"
    end

    test "treats REJECT as a request-changes alias" do
      assert {:request_changes, _} = Tribunal.parse_verdict(["VERDICT: REJECT now"])
    end

    test "is case-insensitive and tolerates leading whitespace" do
      assert {:approve, _} = Tribunal.parse_verdict(["   verdict:  approve"])
    end

    test "returns :no_verdict when no sentinel is present" do
      assert :no_verdict = Tribunal.parse_verdict(["just some output", "no decision here"])
    end

    test "the first verdict line wins (APPROVE before REQUEST_CHANGES)" do
      assert {:approve, _} =
               Tribunal.parse_verdict(["VERDICT: APPROVE", "VERDICT: REQUEST_CHANGES"])
    end
  end

  # ---- cap/2 truncation (escalation payload safety) ------------------------

  describe "cap/2" do
    test "returns the text unchanged when within the byte cap" do
      assert Tribunal.cap("short", 50) == "short"
    end

    test "truncating mid-codepoint backs off to a valid UTF-8 boundary" do
      # "€" is 3 bytes (0xE2 0x82 0xAC); cap at 10 lands one byte into it, so a
      # naive binary_part/3 would yield an invalid-UTF-8 binary. The escalation
      # payload then runs String.trim/1 (outside any rescue) and persists to a
      # Postgres UTF8 column — both reject malformed bytes.
      text = String.duplicate("a", 9) <> "€uro"
      capped = Tribunal.cap(text, 10)

      assert String.valid?(capped), "cap/2 must never emit invalid UTF-8"
      assert capped == "aaaaaaaaa\n… (truncated)"
      # The whole-codepoint guarantee is what lets the downstream String.trim/1
      # in escalation_payload/1 run without raising on malformed bytes.
      assert String.trim(capped) == "aaaaaaaaa\n… (truncated)"
    end

    test "an exact-byte boundary on a multibyte char is preserved" do
      # cap == 12 lands exactly after the full "€" (bytes 10..12), nothing to shave.
      text = String.duplicate("a", 9) <> "€uro"
      assert Tribunal.cap(text, 12) == "aaaaaaaaa€\n… (truncated)"
    end
  end

  # ---- git rig helpers (mirrors CompletionMergeTest) -----------------------

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_rig(dir) do
    repo = Path.join(dir, "rig")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "rig@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Rig"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    repo
  end

  # Create a feature branch with one commit ahead of main, then return to main.
  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "acolyte work\n")
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
    tmp = Path.join(System.tmp_dir!(), "tribunal-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_rig(tmp)

    Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    Application.put_env(:arbiter, :rig_paths, %{"trib/rig" => repo})

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

  # Start a polecat already seeded with branch/merge meta and parked-ready to
  # accept a verdict, WITHOUT spawning a live reviewer (`review_spawn: false`),
  # so the verdict transitions can be driven directly.
  defp start_author(bead, repo, extra_meta) do
    branch = "feature/rev"
    :ok = seed_feature_branch(repo, branch)

    meta =
      Map.merge(
        %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{bead.id}",
          review_required: true,
          review_spawn: false
        },
        extra_meta
      )

    {:ok, pid} =
      Polecat.start(
        bead_id: bead.id,
        rig: "trib/rig",
        workspace_id: bead.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Polecat.advance(pid, :claude)
    {pid, branch}
  end

  defp new_bead(ws, attrs \\ %{}) do
    {:ok, bead} =
      Ash.create(
        Issue,
        Map.merge(%{title: "tribunal bead", workspace_id: ws.id, issue_type: :feature}, attrs)
      )

    {:ok, bead} = Ash.update(bead, %{status: :in_progress})
    bead
  end

  # ---- gate behaviour ------------------------------------------------------

  describe "the gate" do
    test "parks at :awaiting_tribunal and does NOT merge when review is required",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      {pid, _branch} = start_author(bead, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(pid)) end)

      # The gate held: no merge happened.
      assert merge_commit_count(repo) == 0
    end

    test "APPROVE proceeds to the merger — a real --no-ff merge lands on main",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      {pid, _branch} = start_author(bead, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(pid)) end)

      :ok = Polecat.tribunal_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      # Direct merges synchronously; the Warden then completes the polecat.
      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end)
      assert merge_commit_count(repo) == 1

      # The approval is recorded on the bead notes (visible via arb show).
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.notes =~ "Tribunal verdict: APPROVE"
    end

    test "APPROVE with a hosted-forge stub adapter that never reports approval still merges (bd-66ey1o)",
         %{repo: repo, ws: ws} do
      # Reproduces the production bug: a Tribunal APPROVE arrives, the merger
      # opens (or reuses) an MR, and the adapter's get/1 reports
      # `%{status: :open, approved: false}` (no GitHub-side approval). Before
      # bd-66ey1o the Warden polled forever waiting for `approved: true`. The
      # fix plumbs `via_tribunal: true` through to the Warden so the merge
      # fires on its first poll.
      Arbiter.Test.StubMerger.reset()
      Arbiter.Test.StubMerger.next_open_ref("!76")
      # Don't queue any get results → default :open/approved=false forever.

      bead = new_bead(ws)

      {pid, _branch} =
        start_author(bead, repo, %{
          merger_adapter_override: Arbiter.Test.StubMerger,
          warden_interval_ms: 20,
          warden_initial_delay_ms: 0,
          warden_max_polls: 50
        })

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(pid)) end)

      :ok = Polecat.tribunal_verdict(pid, {:approve, "VERDICT: APPROVE\nlgtm"})

      # The Warden must merge despite never seeing a forge-side approval.
      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end, 3_000)
      assert Arbiter.Test.StubMerger.merge_count("!76") >= 1
      # The local repo was NOT git-merged (StubMerger is a stub) — the merge
      # happened entirely through the adapter callback.
      assert merge_commit_count(repo) == 0
    end

    test "REQUEST_CHANGES parks the bead with findings and does NOT merge",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      {pid, _branch} = start_author(bead, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(pid)) end)

      findings = "VERDICT: REQUEST_CHANGES\n- [high] feature.txt:1 needs a guard"
      :ok = Polecat.tribunal_verdict(pid, {:request_changes, findings})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end)

      # Not merged.
      assert merge_commit_count(repo) == 0

      snap = Polecat.state(pid)
      assert snap.meta.failure_reason == :tribunal_rejected
      assert snap.meta.tribunal_verdict == :request_changes
      assert snap.meta.tribunal_findings =~ "needs a guard"

      # Bead parked (still in_progress, not closed) with findings in its notes.
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.status == :in_progress
      assert reloaded.notes =~ "Tribunal verdict: REQUEST_CHANGES"
      assert reloaded.notes =~ "needs a guard"

      # The Admiral was escalated.
      escalations = Message.inbox("admiral", workspace_id: ws.id)
      assert Enum.any?(escalations, &(&1.kind == :escalation and &1.directive_ref == bead.id))
    end

    test "an inconclusive review (no verdict) escalates and does NOT merge",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      {pid, _branch} = start_author(bead, repo, %{})

      send(pid, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(pid)) end)

      :ok = Polecat.tribunal_verdict(pid, {:no_verdict, "reviewer crashed"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_inconclusive
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
      bead = new_bead(ws)
      # No meta review override; review_spawn left default — the gate must never
      # engage because the workspace doesn't require review.
      {pid, _branch} =
        start_author(bead, repo, %{review_required: false, review_spawn: true})

      send(pid, {:__claude_session_done__, "arb done"})

      # Straight to the merger — never parks at :awaiting_tribunal.
      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end)
      assert merge_commit_count(repo) == 1
      refute Polecat.state(pid).meta[:tribunal_verdict]
    end

    test "tribunal_verdict/2 is rejected outside :awaiting_tribunal", %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      {pid, _branch} = start_author(bead, repo, %{})

      # Still :running — no verdict expected yet.
      assert {:error, {:invalid_transition, :running, :tribunal_verdict}} =
               Polecat.tribunal_verdict(pid, {:approve, "x"})
    end
  end

  # ---- end-to-end: a distinct reviewer acolyte emits the verdict -----------

  describe "full path with a live (fixture) reviewer" do
    test "a reviewer approves → the branch merges, by a process distinct from the author",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        # Real reviewer spawn, but the "claude" subprocess is our fixture script.
        worktree_path: repo,
        review_command: [@reviewer, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(
          bead_id: bead.id,
          rig: "trib/rig",
          workspace_id: ws.id,
          meta: meta
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      # Reviewer approves → merge fires → author completes.
      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 1

      # The review was run by a DISTINCT acolyte (different mind, different
      # process): it recorded its OWN run row under the #review-suffixed id,
      # separate from the author's run. (Asserting on the persisted run avoids
      # racing the short-lived reviewer process in the registry.)
      review_id = Tribunal.reviewer_bead_id(bead.id)
      runs = Ash.read!(Arbiter.Polecats.Run)
      assert Enum.any?(runs, &(&1.bead_id == review_id)), "expected a distinct reviewer run row"
      assert Enum.any?(runs, &(&1.bead_id == bead.id)), "expected the author's own run row"
    end

    test "a reviewer requests changes → no merge, bead parked + escalated",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        # rounds: 1 — a single review pass, so a reject escalates immediately with
        # no revise loop (the Stage 2 loop is exercised separately below).
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@reviewer, "REQUEST_CHANGES"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)

      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_rejected

      escalations = Message.inbox("admiral", workspace_id: ws.id)
      assert Enum.any?(escalations, &(&1.directive_ref == bead.id))
    end

    test "review_agent.config.model is passed as `--model` when no command override is given",
         %{repo: repo, tmp: tmp} do
      # Build a `claude` shim on PATH that writes its argv to a file. Without
      # `review_command` in meta the Tribunal walks the adapter path
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

      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        review_rounds: 1,
        worktree_path: repo,
        # Re-prompt budget 0 + short timeout keeps the test snappy when the
        # stub exits without a verdict.
        review_verdict_retries: 0,
        review_timeout_ms: 3_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
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
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        worktree_path: repo,
        review_command: [@reprompt, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 1

      # The re-prompt ran as a distinct follow-up reviewer (its own run row under
      # the versioned id), separate from the first (verdict-less) pass.
      reprompt_id = Tribunal.reviewer_bead_id(bead.id) <> "#v2"
      runs = Ash.read!(Arbiter.Polecats.Run)

      assert Enum.any?(runs, &(&1.bead_id == reprompt_id)),
             "expected a distinct re-prompt reviewer run row"
    end

    test "REQUEST_CHANGES on re-prompt is honored — no merge, bead parked + escalated",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        # rounds: 1 — the re-prompt yields a verdict in the same (only) round; a
        # REQUEST_CHANGES there escalates immediately, no revise loop.
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@reprompt, "REQUEST_CHANGES"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_rejected

      escalations = Message.inbox("admiral", workspace_id: ws.id)
      assert Enum.any?(escalations, &(&1.directive_ref == bead.id))
    end

    # Only a SECOND empty result escalates as inconclusive: the fixture withholds
    # the verdict on both the first pass and the re-prompt ("NONE").
    test "a reviewer that omits the verdict twice escalates as inconclusive",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        worktree_path: repo,
        review_command: [@reprompt, "NONE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_inconclusive

      # The re-prompt WAS attempted before escalating — its run row exists.
      reprompt_id = Tribunal.reviewer_bead_id(bead.id) <> "#v2"
      runs = Ash.read!(Arbiter.Polecats.Run)

      assert Enum.any?(runs, &(&1.bead_id == reprompt_id)),
             "expected a re-prompt to have been attempted before escalating"
    end

    # bd-3y2mda: a REQUEST_CHANGES verdict with NO findings is useless (the
    # implementer has nothing to act on). The Tribunal treats it as malformed and
    # re-prompts — exactly like a missing sentinel — rather than entering the
    # revise loop empty-handed.
    test "REQUEST_CHANGES with no findings is re-prompted; a valid re-prompt is honored",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        worktree_path: repo,
        # First pass: REQUEST_CHANGES with no findings → re-prompt → APPROVE.
        review_command: [@empty_findings, "APPROVE"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end, 6_000)
      # The findings-less verdict did NOT enter the revise loop; the re-prompt's
      # APPROVE merged. A merge at all proves the empty verdict was re-prompted.
      assert merge_commit_count(repo) == 1

      reprompt_id = Tribunal.reviewer_bead_id(bead.id) <> "#v2"
      runs = Ash.read!(Arbiter.Polecats.Run)

      assert Enum.any?(runs, &(&1.bead_id == reprompt_id)),
             "expected a distinct re-prompt reviewer run row"
    end

    # The acceptance's hard guarantee: a reviewer that requests changes but never
    # lists findings, even after the re-prompt, is escalated as inconclusive —
    # never silently accepted, never merged.
    test "REQUEST_CHANGES with no findings twice escalates as inconclusive — no merge",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        review_rounds: 1,
        worktree_path: repo,
        review_command: [@empty_findings, "EMPTY"],
        review_timeout_ms: 5_000
      }

      {:ok, pid} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_inconclusive
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
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Polecat.start(
          bead_id: bead.id,
          rig: "trib/rig",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{bead.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: repo,
            review_command: [@rounds, "APPROVE"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      # Round 1 rejects → implementer revises → round 2 approves → merge.
      wait_until(fn -> match?(%{status: :completed}, Polecat.state(pid)) end, 8_000)
      assert merge_commit_count(repo) == 1

      # A distinct implementer acolyte ran between the rounds (its own run row
      # under the round-1 #impl id), proving a fresh mind addressed the findings.
      review_id = Tribunal.reviewer_bead_id(bead.id)
      runs = Ash.read!(Arbiter.Polecats.Run)

      assert Enum.any?(runs, &(&1.bead_id == review_id <> "#impl1")),
             "expected a distinct implementer run row for round 1"

      # A distinct round-2 reviewer ran too.
      assert Enum.any?(runs, &(&1.bead_id == review_id <> "#r2")),
             "expected a distinct round-2 reviewer run row"

      # The implementer↔reviewer back-and-forth was persisted to the mailbox as a
      # durable thread (reviewer findings + implementer response), oldest first.
      thread = Message.thread(bead.id, workspace_id: ws.id)
      flags = Enum.filter(thread, &(&1.kind == :flag))
      assert length(flags) >= 2

      assert Enum.any?(flags, &(&1.from_ref == review_id and &1.to_ref == bead.id)),
             "expected a reviewer→implementer findings message"

      assert Enum.any?(flags, &(&1.from_ref == bead.id and &1.to_ref == review_id)),
             "expected an implementer→reviewer response message"
    end

    # The reviewer holds the line on BOTH rounds (the @rounds fixture rejects
    # first, then emits REQUEST_CHANGES again). After the 2-round cap the Tribunal
    # escalates to Darth Gnosis with the FULL transcript + diff — no merge.
    test "not converged after the cap → escalate with the full transcript, no merge",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Polecat.start(
          bead_id: bead.id,
          rig: "trib/rig",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{bead.id}",
            review_required: true,
            review_rounds: 2,
            worktree_path: repo,
            review_command: [@rounds, "REQUEST_CHANGES"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 8_000)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_rejected

      # The escalation to the Admiral carries the FULL ordered transcript (both
      # rounds of findings + the implementer's response) and the current diff —
      # Darth Gnosis judges with the whole argument, not a summary.
      escalations = Message.inbox("admiral", workspace_id: ws.id)
      escalation = Enum.find(escalations, &(&1.directive_ref == bead.id))
      assert escalation, "expected an escalation to the Admiral"
      assert escalation.body =~ "transcript"
      assert escalation.body =~ "Round 1"
      assert escalation.body =~ "Round 2"
      assert escalation.body =~ "Implementer → Reviewer"
      assert escalation.body =~ "Current diff"

      # The same transcript is on the bead notes (visible via arb show).
      {:ok, reloaded} = Ash.get(Issue, bead.id)
      assert reloaded.notes =~ "REQUEST_CHANGES"

      # The full thread persisted as durable mailbox rows: r1 findings, r1
      # response, r2 findings — three :flag entries, oldest first.
      review_id = Tribunal.reviewer_bead_id(bead.id)
      flags = bead.id |> Message.thread(workspace_id: ws.id) |> Enum.filter(&(&1.kind == :flag))
      assert length(flags) == 3

      assert Enum.count(flags, &(&1.from_ref == review_id)) == 2,
             "expected two reviewer→implementer findings rows (round 1 and round 2)"

      assert Enum.count(flags, &(&1.from_ref == bead.id)) == 1,
             "expected one implementer→reviewer response row"
    end

    # The cap is a HARD limit: rounds: 1 means a single review pass. A reject
    # escalates immediately — no implementer is ever spawned, no revise loop.
    test "rounds: 1 escalates on the first reject with no revise loop",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, pid} =
        Polecat.start(
          bead_id: bead.id,
          rig: "trib/rig",
          workspace_id: ws.id,
          meta: %{
            branch: branch,
            repo_path: repo,
            target_branch: "main",
            merge_title: "Merge #{bead.id}",
            review_required: true,
            review_rounds: 1,
            worktree_path: repo,
            review_command: [@reviewer, "REQUEST_CHANGES"],
            revise_command: [@revise],
            review_timeout_ms: 5_000
          }
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Polecat.advance(pid, :claude)
      send(pid, {:__claude_session_done__, "arb done"})

      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 6_000)
      assert merge_commit_count(repo) == 0
      assert Polecat.state(pid).meta.failure_reason == :tribunal_rejected

      # No implementer was ever spawned — the round cap was 1.
      review_id = Tribunal.reviewer_bead_id(bead.id)
      runs = Ash.read!(Arbiter.Polecats.Run)

      refute Enum.any?(runs, &(&1.bead_id == review_id <> "#impl1")),
             "rounds: 1 must not spawn an implementer"
    end
  end

  # ---- Stage 3: same-mind continuity briefing (bd-1na62i) ------------------

  describe "revise_prompt/2 git-state briefing" do
    # The revise-round implementer is a fresh mind. Stage 3 prepends a
    # git-derived "work so far" briefing so it continues the prior round's
    # thread instead of re-deriving it from a raw diff.
    test "prepends the prior round's committed + uncommitted work", %{repo: repo, ws: ws} do
      bead = new_bead(ws, %{description: "the directive", acceptance: "it works"})
      branch = "feature/rev"

      # Put HEAD on the feature branch with a commit ahead of main, plus an
      # uncommitted edit — exactly the state a prior revise round would leave.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      File.write!(Path.join(repo, "fix.ex"), "defmodule Fix, do: nil\n")
      {_, 0} = git(["add", "fix.ex"], repo)
      {_, 0} = git(["commit", "-q", "-m", "round 1 fix from prior implementer"], repo)
      File.write!(Path.join(repo, "README.md"), "seed\nstraggler edit\n")

      state = %{
        bead_id: bead.id,
        branch: branch,
        target_branch: "main",
        worktree_path: repo,
        round: 2
      }

      prompt = Tribunal.revise_prompt(state, "VERDICT: REQUEST_CHANGES\n1. fix the thing")

      # The briefing surfaces both the committed work and the uncommitted WIP.
      assert prompt =~ "Work done so far on this branch"
      assert prompt =~ "round 1 fix from prior implementer"
      assert prompt =~ "Uncommitted work-in-progress"
      assert prompt =~ "straggler edit"
      # The findings and directive still travel alongside the briefing.
      assert prompt =~ "fix the thing"
      assert prompt =~ "the directive"
    end

    # A worktree-less Tribunal (ad-hoc / test run) must degrade to the
    # directive-only prompt rather than crash trying to read git state.
    test "degrades gracefully with no worktree", %{ws: ws} do
      bead = new_bead(ws, %{description: "the directive"})

      state = %{
        bead_id: bead.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1
      }

      prompt = Tribunal.revise_prompt(state, "VERDICT: REQUEST_CHANGES\n1. fix it")

      refute prompt =~ "Work done so far on this branch"
      assert prompt =~ "fix it"
      assert prompt =~ "the directive"
    end
  end

  # ---- Pre-spawn commit gate and HEAD-SHA anchoring (bd-1mksks) ------------

  describe "pre-spawn commit gate (bd-1mksks)" do
    # The Tribunal must gate on commits BEFORE spawning the reviewer. Even if the
    # polecat commit gate already fired, this second layer catches the revise-round
    # case (the revise implementer's polecat has no worktree_path in meta, so its
    # commit gate does not fire).
    test "Tribunal escalates as request_changes when branch has no commits",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws)
      branch = "feature/no-commits"

      # Create the branch at the same commit as main — no commits ahead.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      # HEAD is NOW on feature/no-commits at the same SHA as main.
      # Return to main so the repo state is clear.
      {_, 0} = git(["checkout", "-q", "main"], repo)

      # Park the author polecat at :awaiting_tribunal via review_spawn: false so
      # the polecat commit gate does NOT fire (no worktree_path in meta → gate
      # skips). We then start a Tribunal manually, pointing at a worktree that is
      # actually on feature/no-commits with 0 commits ahead.
      meta = %{
        branch: branch,
        repo_path: repo,
        target_branch: "main",
        merge_title: "Merge #{bead.id}",
        review_required: true,
        review_spawn: false
      }

      {:ok, author} =
        Polecat.start(bead_id: bead.id, rig: "trib/rig", workspace_id: ws.id, meta: meta)

      on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
      :ok = Polecat.advance(author, :claude)
      send(author, {:__claude_session_done__, "arb done"})
      wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(author)) end)

      # Switch the branch worktree to `feature/no-commits` so the Tribunal sees
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

      # Directly spawn a Tribunal that points at the zero-commit worktree.
      # A real reviewer command is supplied but should NEVER be reached — the
      # Tribunal must escalate before it spawns the reviewer.
      {:ok, _tribunal} =
        Tribunal.start(
          author: author,
          bead_id: bead.id,
          workspace_id: ws.id,
          rig: "trib/rig",
          worktree_path: sub_wt,
          branch: branch,
          target_branch: "main",
          command: [@reviewer, "APPROVE"],
          timeout_ms: 5_000
        )

      # The Tribunal should report :request_changes immediately (no reviewer spawn).
      wait_until(fn -> match?(%{status: :failed}, Polecat.state(author)) end, 4_000)
      snap = Polecat.state(author)
      assert snap.meta.failure_reason == :tribunal_rejected
      assert snap.meta.tribunal_findings =~ "no commits ahead"
      # The branch was NOT merged.
      assert merge_commit_count(repo) == 0
    end
  end

  describe "review_prompt/1 HEAD-SHA anchoring (bd-1mksks)" do
    # The review prompt must embed the HEAD SHA verified at spawn time so the
    # reviewer can confirm it is on the correct commit before diffing.
    test "includes the HEAD SHA when the worktree is on the expected branch",
         %{repo: repo, ws: ws} do
      bead = new_bead(ws, %{description: "impl desc", acceptance: "it works"})
      branch = "feature/rev"

      # Put the repo HEAD on the feature branch with a commit ahead of main.
      {_, 0} = git(["checkout", "-q", "-b", branch], repo)
      File.write!(Path.join(repo, "work.txt"), "done\n")
      {_, 0} = git(["add", "work.txt"], repo)
      {_, 0} = git(["commit", "-q", "-m", "the work"], repo)

      {sha_out, 0} = git(["rev-parse", "--short", "HEAD"], repo)
      expected_sha = String.trim(sha_out)

      state = %{
        bead_id: bead.id,
        branch: branch,
        target_branch: "main",
        worktree_path: repo,
        round: 1,
        head_sha: expected_sha
      }

      prompt = Tribunal.review_prompt(state)

      assert prompt =~ expected_sha,
             "review_prompt must embed the HEAD SHA so the reviewer can verify the commit"

      assert prompt =~ "git log --oneline -1",
             "review_prompt must instruct the reviewer to confirm HEAD"
    end

    test "omits the HEAD SHA anchor when head_sha is nil (no worktree / ad-hoc)",
         %{ws: ws} do
      bead = new_bead(ws)

      state = %{
        bead_id: bead.id,
        branch: "feature/rev",
        target_branch: "main",
        worktree_path: nil,
        round: 1,
        head_sha: nil
      }

      prompt = Tribunal.review_prompt(state)

      # No SHA anchor — the prompt must still be valid.
      refute prompt =~ "HEAD at dispatch time was commit",
             "review_prompt must not emit a SHA anchor when head_sha is nil"

      assert prompt =~ "git diff main...HEAD",
             "review_prompt must still include the diff command"
    end
  end

  describe "review-gate hardening (bd-2y0gd5)" do
    test "snapshotting the supervisor's children never crashes the Tribunal",
         %{repo: repo, ws: ws} do
      pid = start_live_gate(repo, ws)
      tribunal = wait_until_tribunal()

      # The crash trigger: enumerate + :snapshot every supervisor child.
      children = Polecat.list_children()

      # The Tribunal is NOT a polecat, so it must be filtered OUT of the list...
      refute Enum.any?(children, &(&1.pid == tribunal))
      # ...and the probe must not have killed it.
      assert Process.alive?(tribunal)
      # A direct :snapshot also answers gracefully instead of crashing.
      assert %{role: :tribunal, status: :reviewing} = GenServer.call(tribunal, :snapshot)
      # Gate intact: the author is still parked, nothing merged.
      assert %{status: :awaiting_tribunal} = Polecat.state(pid)
      assert merge_commit_count(repo) == 0
    end

    test "a Tribunal that dies before a verdict escalates the author (no strand, no merge)",
         %{repo: repo, ws: ws} do
      pid = start_live_gate(repo, ws)
      tribunal = wait_until_tribunal()

      # Kill the gate before it can deliver a verdict.
      Process.exit(tribunal, :kill)

      # The author must escalate to :failed (no_verdict) — NOT hang at
      # :awaiting_tribunal — and must NOT merge.
      wait_until(fn -> match?(%{status: :failed}, Polecat.state(pid)) end, 4_000)
      assert merge_commit_count(repo) == 0
    end
  end

  # Start an author through the gate with a *lingering* reviewer (so the Tribunal
  # stays alive while a test probes or kills it). Cleanup cascades: stopping the
  # author trips the Tribunal's author-monitor, which stops the reviewer.
  defp start_live_gate(repo, ws) do
    bead = new_bead(ws)
    branch = "feature/rev"
    :ok = seed_feature_branch(repo, branch)
    sleep = System.find_executable("sleep") || "/bin/sleep"

    {:ok, pid} =
      Polecat.start(
        bead_id: bead.id,
        rig: "trib/rig",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{bead.id}",
          review_required: true,
          worktree_path: repo,
          review_command: [sleep, "10"],
          review_timeout_ms: 30_000
        }
      )

    on_exit(fn ->
      review_id = Tribunal.reviewer_bead_id(bead.id)
      if rp = Polecat.whereis(review_id), do: safe_stop(rp)
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)

    :ok = Polecat.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{status: :awaiting_tribunal}, Polecat.state(pid)) end, 4_000)
    pid
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  # Poll for the live Tribunal child of the polecat supervisor; return its pid.
  defp wait_until_tribunal(timeout \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_tribunal(deadline)
  end

  defp do_wait_tribunal(deadline) do
    pid =
      Arbiter.Polecat.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {_, p, _, [Arbiter.Polecat.Tribunal]} when is_pid(p) -> p
        _ -> nil
      end)

    cond do
      is_pid(pid) ->
        pid

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Tribunal child did not appear within timeout")

      true ->
        Process.sleep(15)
        do_wait_tribunal(deadline)
    end
  end
end
