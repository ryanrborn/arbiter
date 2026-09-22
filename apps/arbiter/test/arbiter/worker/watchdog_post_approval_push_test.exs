defmodule Arbiter.Worker.WatchdogPostApprovalPushTest do
  @moduledoc """
  P7 (bd-60r6wp / #1738) — `docs/review-coverage-and-guard-policy.md` §4.5.

  A post-approval CI `fix_pass`, or a conflict-resolver push, is the FLEET
  advancing an approved branch. Before P7 `clear_reviewed_latch/1` suspended
  the guard for both and then re-latched onto whatever head landed, so the old
  `last_reviewed_sha` path stamped the fix-pass commit as reviewed and merged
  it. P3's shadow caught three PRs that merged that way (#1702, #1723, #1725).

  After P7:

    * the fleet's authored push keeps the approved baseline, so the old path
      never treats the new head as reviewed (AC1);
    * a push whose net diff equals the approved one merges and leaves a
      `:mechanical` coverage row behind it (AC2);
    * a push that changed content routes to a review round instead of merging
      (AC3 — the delta scoping of that round is pinned in
      `review_gate_delta_scope_test.exs`);
    * flag on, `decide/3` refuses the same heads; flag off, the shadow records
      no `authored_content` disagreement for them (AC4).
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.CoverageShadow.Tally
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

  defmodule PushedResolver do
    @moduledoc false
    # A resolver pass that has already force-pushed by the time it returns.
    @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

    @impl true
    def resolve(_args), do: {:ok, %{worker_pid: nil, branch: "feat/p7"}}

    @impl true
    def escalate_unresolved(_task_id, _workspace_id, _branch, _reason), do: :ok
  end

  # What the ReviewGate approved at A.
  @approved_diff """
  diff --git a/lib/arbiter/thing.ex b/lib/arbiter/thing.ex
  index 1111111..2222222 100644
  --- a/lib/arbiter/thing.ex
  +++ b/lib/arbiter/thing.ex
  @@ -10,6 +10,9 @@ defmodule Arbiter.Thing do
     def run(opts) do
  +    if Keyword.get(opts, :fast) do
  +      :fast
  +    end
       :ok
     end
   end
  """

  # The three live shapes P3's shadow caught. Each is the approved change plus
  # something the fix pass authored after the approval.
  @shapes [
    {"#1702 / bd-a3lzrk: credo fix (nested if -> with)",
     """
     diff --git a/lib/arbiter/thing.ex b/lib/arbiter/thing.ex
     index 1111111..5555555 100644
     --- a/lib/arbiter/thing.ex
     +++ b/lib/arbiter/thing.ex
     @@ -10,6 +10,8 @@ defmodule Arbiter.Thing do
        def run(opts) do
     +    fast? = Keyword.get(opts, :fast)
     +    if fast?, do: :fast
          :ok
        end
      end
     """},
    {"#1723 / bd-38of5i: credo fix (alias ordering)",
     """
     diff --git a/lib/arbiter/thing.ex b/lib/arbiter/thing.ex
     index 1111111..6666666 100644
     --- a/lib/arbiter/thing.ex
     +++ b/lib/arbiter/thing.ex
     @@ -1,4 +1,5 @@
      defmodule Arbiter.Thing do
     +  alias Arbiter.Other
     @@ -10,6 +10,9 @@ defmodule Arbiter.Thing do
        def run(opts) do
     +    if Keyword.get(opts, :fast) do
     +      :fast
     +    end
          :ok
        end
      end
     """},
    {"#1725 / bd-2wmxt5: dialyzer ignore entry",
     """
     diff --git a/.dialyzer_ignore.exs b/.dialyzer_ignore.exs
     index 7777777..8888888 100644
     --- a/.dialyzer_ignore.exs
     +++ b/.dialyzer_ignore.exs
     @@ -1,2 +1,3 @@
      [
     +  {"lib/arbiter/thing.ex", :pattern_match}
      ]
     diff --git a/lib/arbiter/thing.ex b/lib/arbiter/thing.ex
     index 1111111..2222222 100644
     --- a/lib/arbiter/thing.ex
     +++ b/lib/arbiter/thing.ex
     @@ -10,6 +10,9 @@ defmodule Arbiter.Thing do
        def run(opts) do
     +    if Keyword.get(opts, :fast) do
     +      :fast
     +    end
          :ok
        end
      end
     """}
  ]

  # The approved change, replayed onto a moved base: offsets and blob hashes
  # differ, not one content line does.
  @rebased_diff """
  diff --git a/lib/arbiter/thing.ex b/lib/arbiter/thing.ex
  index 3333333..4444444 100644
  --- a/lib/arbiter/thing.ex
  +++ b/lib/arbiter/thing.ex
  @@ -52,6 +52,9 @@ defmodule Arbiter.Thing do
     def run(opts) do
  +    if Keyword.get(opts, :fast) do
  +      :fast
  +    end
       :ok
     end
   end
  """

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    StubFixPassDispatcher.reset()
    Tally.reset()
    on_exit(&Tally.reset/0)
    :ok
  end

  defp sha(seed), do: Base.encode16(:crypto.hash(:sha, seed), case: :lower)

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp workspace(coverage_enabled?) do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "pa#{System.unique_integer([:positive])}",
      config: %{"merge" => %{"coverage_enabled" => coverage_enabled?}}
    })
  end

  # The state a ReviewGate approval at `approved` leaves behind: the task's
  # `last_reviewed_sha` stamp and a `:reviewed` coverage row.
  defp approved_task(ws, mr_ref, approved) do
    task =
      Ash.create!(Issue, %{
        title: "post-approval push",
        description: "body",
        workspace_id: ws.id,
        last_reviewed_sha: approved
      })

    {:ok, entry} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: mr_ref,
        head_sha: approved,
        base_ref: "main",
        net_diff_id: NetDiff.fingerprint(@approved_diff),
        kind: :reviewed,
        source: :review_gate,
        round: 1
      })

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(pid) end)

    {pid, task, entry}
  end

  defp start_watchdog(worker_pid, task_id, mr_ref, ws, opts \\ []) do
    base = [
      task_id: task_id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      via_review_gate: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      max_auto_resolve_attempts: 1,
      fix_pass_dispatcher: StubFixPassDispatcher,
      auto_resume_dispatcher: StubAutoResumeDispatcher
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  # Approve at A → CI red → fix pass dispatched → (still running) → the fix
  # pass's commit B lands and CI goes green → the merge is attempted at B.
  defp fix_pass_timeline(mr_ref, approved, pushed) do
    StubMerger.queue_get(mr_ref, [
      %{
        status: :open,
        approved: true,
        head_sha: approved,
        base_ref: "main",
        block_reason: :ci_failed
      },
      %{
        status: :open,
        approved: true,
        head_sha: approved,
        base_ref: "main",
        block_reason: :ci_failed
      },
      %{status: :open, approved: true, head_sha: pushed, base_ref: "main"}
    ])
  end

  defp wait_until(fun, timeout \\ 3_000) do
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
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  defp coverage_for(mr_ref, head),
    do: Enum.filter(Coverage.for_mr(mr_ref), &(&1.head_sha == head))

  defp shadow_results do
    Arbiter.Events.Record
    |> Ash.Query.filter(topic == "coverage_shadow")
    |> Ash.read!()
    |> Enum.map(&{&1.payload["result"], &1.payload["old"], &1.payload["new"]})
  end

  defp disagreements, do: Enum.filter(shadow_results(), &match?({"disagree", _, _}, &1))

  # ---- AC1 + AC3 + AC4 (flag off): the three live shapes -------------------

  for {{label, diff}, n} <- Enum.with_index(@shapes) do
    @diff diff
    @n n

    describe "#{label} — flag off" do
      test "the fix-pass head is not stamped as reviewed: no merge, a review round instead, and no shadow disagreement" do
        ws = workspace(false)
        mr_ref = "!p7off#{@n}"
        approved = sha("approved-#{@n}")
        pushed = sha("fixpass-#{@n}")

        {pid, task, _entry} = approved_task(ws, mr_ref, approved)
        StubMerger.set_diff(mr_ref, approved, @approved_diff)
        StubMerger.set_diff(mr_ref, pushed, @diff)
        fix_pass_timeline(mr_ref, approved, pushed)

        wpid = start_watchdog(pid, task.id, mr_ref, ws)
        ref = Process.monitor(wpid)

        assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 3_000

        assert StubFixPassDispatcher.call_count() == 1

        assert StubMerger.merge_count(mr_ref) == 0,
               "a post-approval fix-pass commit merged unreviewed"

        assert [%{task_id: task_id, mr_ref: ^mr_ref}] = StubAutoResumeDispatcher.resumes()
        assert task_id == task.id

        # The old path did not record the head as reviewed anywhere.
        assert coverage_for(mr_ref, pushed) == []
        assert Ash.get!(Issue, task.id).last_reviewed_sha == approved

        # AC4: both predicates call the head uncovered.
        assert disagreements() == []
        assert {"agree", "uncovered", "uncovered"} in shadow_results()
      end
    end

    describe "#{label} — flag on" do
      test "decide/3 blocks the merge at the uncovered fix-pass head and routes it to review" do
        ws = workspace(true)
        mr_ref = "!p7on#{@n}"
        approved = sha("approved-on-#{@n}")
        pushed = sha("fixpass-on-#{@n}")

        {pid, task, _entry} = approved_task(ws, mr_ref, approved)
        StubMerger.set_diff(mr_ref, approved, @approved_diff)
        StubMerger.set_diff(mr_ref, pushed, @diff)
        fix_pass_timeline(mr_ref, approved, pushed)

        wpid = start_watchdog(pid, task.id, mr_ref, ws)
        ref = Process.monitor(wpid)

        assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 3_000

        assert StubMerger.merge_count(mr_ref) == 0
        assert StubAutoResumeDispatcher.resume_count() == 1
        assert coverage_for(mr_ref, pushed) == []
        assert disagreements() == []
      end
    end
  end

  # ---- AC2: a content-equal push merges on a :mechanical row ---------------

  describe "a fleet push whose net diff equals the approved one" do
    for coverage_enabled? <- [false, true] do
      @coverage_enabled? coverage_enabled?

      test "merges at the new head and records a :mechanical row derived from the approval (flag #{coverage_enabled?})" do
        ws = workspace(@coverage_enabled?)
        mr_ref = "!p7eq#{@coverage_enabled?}"
        approved = sha("approved-eq-#{@coverage_enabled?}")
        pushed = sha("rebased-eq-#{@coverage_enabled?}")

        {pid, task, entry} = approved_task(ws, mr_ref, approved)
        StubMerger.set_diff(mr_ref, approved, @approved_diff)
        StubMerger.set_diff(mr_ref, pushed, @rebased_diff)
        fix_pass_timeline(mr_ref, approved, pushed)

        start_watchdog(pid, task.id, mr_ref, ws)

        wait_until(fn -> Worker.state(pid).status == :completed end)

        assert StubMerger.last_merge() == {mr_ref, pushed}
        assert StubAutoResumeDispatcher.resume_count() == 0

        assert [%{kind: :mechanical} = row] = coverage_for(mr_ref, pushed)
        assert row.derived_from == entry.id
        assert row.net_diff_id == NetDiff.fingerprint(@approved_diff)
        assert disagreements() == []
      end
    end
  end

  describe "a conflict-resolver push" do
    test "is not stamped as reviewed either: authored content goes to review" do
      ws = workspace(false)
      mr_ref = "!p7conflict"
      approved = sha("approved-conflict")
      pushed = sha("resolved-conflict")
      {_label, authored} = hd(@shapes)

      {pid, task, _entry} = approved_task(ws, mr_ref, approved)
      StubMerger.set_diff(mr_ref, approved, @approved_diff)
      StubMerger.set_diff(mr_ref, pushed, authored)

      StubMerger.queue_get(mr_ref, [
        %{
          status: :open,
          approved: true,
          head_sha: approved,
          base_ref: "main",
          block_reason: :conflict
        },
        %{status: :open, approved: true, head_sha: pushed, base_ref: "main"}
      ])

      wpid =
        start_watchdog(pid, task.id, mr_ref, ws,
          conflict_resolver: PushedResolver,
          max_conflict_attempts: 2
        )

      ref = Process.monitor(wpid)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 3_000

      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 1
      assert coverage_for(mr_ref, pushed) == []
      assert disagreements() == []
    end
  end

  describe "an update-branch after the fix pass, before the fix-pass head is covered" do
    test "does not re-open the suspension that would stamp the fix-pass content as reviewed" do
      ws = workspace(false)
      mr_ref = "!p7ub"
      approved = sha("approved-ub")
      pushed = sha("fixpass-ub")
      merged = sha("update-branch-ub")
      {_label, authored} = hd(@shapes)

      {pid, task, _entry} = approved_task(ws, mr_ref, approved)
      StubMerger.set_diff(mr_ref, approved, @approved_diff)
      StubMerger.set_diff(mr_ref, merged, authored)

      StubMerger.queue_get(mr_ref, [
        %{
          status: :open,
          approved: true,
          head_sha: approved,
          base_ref: "main",
          block_reason: :ci_failed
        },
        %{
          status: :open,
          approved: true,
          head_sha: pushed,
          base_ref: "main",
          block_reason: :behind_base
        },
        %{status: :open, approved: true, head_sha: merged, base_ref: "main"}
      ])

      wpid = start_watchdog(pid, task.id, mr_ref, ws, max_auto_resolve_attempts: 2)
      ref = Process.monitor(wpid)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 3_000

      assert StubMerger.update_branch_count(mr_ref) >= 1
      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 1
    end
  end

  describe "a fix pass dispatched while an update-branch suspension is still open" do
    test "ends the suspension on the approved content, so the fix-pass head is not the one latched" do
      ws = workspace(false)
      mr_ref = "!p7susp"
      approved = sha("approved-susp")
      pushed = sha("fixpass-susp")
      {_label, authored} = hd(@shapes)

      {pid, task, _entry} = approved_task(ws, mr_ref, approved)
      StubMerger.set_diff(mr_ref, approved, @approved_diff)
      StubMerger.set_diff(mr_ref, pushed, authored)

      StubMerger.queue_get(mr_ref, [
        # update-branch issued: the latch is suspended at the approved head.
        %{
          status: :open,
          approved: true,
          head_sha: approved,
          base_ref: "main",
          block_reason: :behind_base
        },
        # CI goes red before the update lands: the fix pass is dispatched.
        %{
          status: :open,
          approved: true,
          head_sha: approved,
          base_ref: "main",
          block_reason: :ci_failed
        },
        # The fix pass's commit is the first new head the Watchdog sees.
        %{status: :open, approved: true, head_sha: pushed, base_ref: "main"}
      ])

      wpid = start_watchdog(pid, task.id, mr_ref, ws, max_auto_resolve_attempts: 2)
      ref = Process.monitor(wpid)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 3_000

      assert StubMerger.update_branch_count(mr_ref) == 1
      assert StubFixPassDispatcher.call_count() == 1
      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 1
    end
  end

  # ---- AC5 / bd-985tkl: the review round is not stranded by the fix pass ---

  describe "a review round refused because the fix pass still holds the task's registry family" do
    test "defers and re-fires when the fix pass finishes, instead of paging and stopping" do
      ws = workspace(false)
      mr_ref = "!p7defer"
      approved = sha("approved-defer")
      pushed = sha("fixpass-defer")
      {_label, authored} = hd(@shapes)

      {pid, task, _entry} = approved_task(ws, mr_ref, approved)
      StubMerger.set_diff(mr_ref, approved, @approved_diff)
      StubMerger.set_diff(mr_ref, pushed, authored)
      fix_pass_timeline(mr_ref, approved, pushed)

      blocker =
        spawn(fn ->
          receive do
            :finish -> :ok
          after
            30_000 -> :ok
          end
        end)

      StubAutoResumeDispatcher.arm_resume_error(
        {:worker_start_failed,
         {:task_worker_live,
          %{
            pid: blocker,
            status: :running,
            task_id: task.id,
            registry_key: task.id <> ":fixpass",
            requested_key: task.id
          }}}
      )

      wpid = start_watchdog(pid, task.id, mr_ref, ws, interval_ms: 60_000, initial_delay_ms: 0)
      ref = Process.monitor(wpid)

      # The first three polls are scheduled at `interval_ms`, so drive them.
      for _ <- 1..3, do: send(wpid, :poll)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 1 end)
      assert StubAutoResumeDispatcher.escalations() == []

      StubAutoResumeDispatcher.arm_resume_error(:unused, 0)
      send(blocker, :finish)

      wait_until(fn -> StubAutoResumeDispatcher.resume_count() >= 2 end)
      assert_receive {:DOWN, ^ref, :process, ^wpid, :normal}, 3_000
      assert StubAutoResumeDispatcher.escalations() == []
      assert StubMerger.merge_count(mr_ref) == 0
    end
  end
end
