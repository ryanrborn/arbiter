defmodule Arbiter.Workflows.PendingMergeSweeperTest do
  @moduledoc """
  bd-a370ak / #2002 — an approved, green PR must not be orphaned when the
  worker that owned its merge exits before the merge could succeed.

  The live Watchdog stamps a durable `pending_merge` on the task whenever it
  defers or fails an approved merge; `Arbiter.Workflows.PendingMergeSweeper`
  re-arms a worker-less retry for any stamp nobody owns any more, and that
  retry runs the Watchdog's own merge guards.
  """
  # async: false — the Watchdog, the retry and the sweeper all touch the DB
  # from their own processes, and StubMerger is a singleton Agent.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.PendingMerge
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workflows.PendingMergeSweeper

  @reviewed_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -10,6 +10,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # The same net change after main was merged into the branch.
  @base_merged_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -80,6 +80,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  # A post-approval commit that added content nobody reviewed.
  @unreviewed_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -10,6 +10,8 @@ defmodule A do
     def run do
       :ok
  +    :extra
  +    :sneaked_in_after_approval
     end
   end
  """

  @draft_405 %Github.Error{
    kind: :not_mergeable,
    status: 405,
    message: "Pull Request is still a draft"
  }

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    :ok
  end

  # ---- helpers ------------------------------------------------------------

  defp sha(seed), do: :crypto.hash(:sha, seed) |> Base.encode16(case: :lower)

  defp stop_quietly(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_quietly(_), do: :ok

  defp workspace(merge_config \\ %{}) do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "pm#{System.unique_integer([:positive])}",
      config: %{"merge" => Map.merge(%{"auto_merge" => true}, merge_config)}
    })
  end

  defp task(ws, mr_ref) do
    Issue
    |> Ash.create!(%{title: "orphaned merge", description: "body", workspace_id: ws.id})
    |> Ash.update!(%{status: :in_progress, pr_ref: mr_ref})
  end

  defp running_worker(task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp start_live_watchdog(worker_pid, task, mr_ref, ws, opts \\ []) do
    base = [
      task_id: task.id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      via_review_gate: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      auto_resume_dispatcher: StubAutoResumeDispatcher
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  # The worker exits (its machine died, it was reaped, the server shut it
  # down). Its Watchdog monitors it and stops with it.
  defp kill_worker(worker_pid, task_id) do
    ref = Process.monitor(worker_pid)
    stop_quietly(worker_pid)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}, 2_000
    wait_until(fn -> is_nil(Watchdog.whereis(task_id)) end)
  end

  defp sweep(opts \\ []) do
    PendingMergeSweeper.sweep(Keyword.merge(sweep_opts(), opts))
  end

  defp sweep_opts do
    [
      adapter: StubMerger,
      primary?: fn -> true end,
      retry_opts: [interval_ms: 15, initial_delay_ms: 0]
    ]
  end

  defp stamp!(task, reviewed, attrs \\ %{}) do
    :ok =
      PendingMerge.stamp(
        task.id,
        Map.merge(
          %{
            mr_ref: task.pr_ref,
            reviewed_sha: reviewed,
            via_review_gate: true,
            reason: :ci_pending
          },
          attrs
        )
      )
  end

  defp reload(task), do: Ash.get!(Issue, task.id)

  defp escalations(task_id) do
    Message
    |> Ash.Query.filter(task_ref == ^task_id and kind == :escalation)
    |> Ash.read!()
  end

  defp cleanup_retry(task_id) do
    on_exit(fn -> stop_quietly(Watchdog.retry_whereis(task_id)) end)
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

  # ---- the live Watchdog leaves a durable stamp ----------------------------

  describe "the live Watchdog" do
    test "stamps the reviewed baseline when it defers an approved merge on CI" do
      reviewed = sha("live-ci")
      mr_ref = "!pm-live-ci"
      ws = workspace()
      task = task(ws, mr_ref)
      pid = running_worker(task)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :running}
      ])

      capture_log(fn ->
        start_live_watchdog(pid, task, mr_ref, ws)
        wait_until(fn -> PendingMerge.get(reload(task)) != nil end)
      end)

      pending = PendingMerge.get(reload(task))
      assert pending.mr_ref == mr_ref
      assert pending.reviewed_sha == reviewed
      assert pending.reason == "ci_pending"
      assert pending.via_review_gate == true
      assert pending.escalated_at == nil
    end

    test "clears the stamp when the task closes" do
      reviewed = sha("close-clears")
      ws = workspace()
      task = task(ws, "!pm-close")
      stamp!(task, reviewed)

      assert PendingMerge.get(reload(task))

      {:ok, closed} = Ash.update(reload(task), %{close_upstream: false}, action: :close)
      assert PendingMerge.get(closed) == nil
    end
  end

  # ---- AC1: re-evaluated after the worker exits -----------------------------

  describe "AC1 — an approved PR orphaned by its worker's exit" do
    test "draft → ready: merges once the PR leaves draft, with no live worker" do
      reviewed = sha("draft")
      mr_ref = "!pm-draft"
      ws = workspace()
      task = task(ws, mr_ref)
      pid = running_worker(task)
      cleanup_retry(task.id)

      # The incident shape (#1947/#1966): the gate approved, the PR is still a
      # draft, every merge attempt comes back 405.
      StubMerger.set_merge_result({:error, @draft_405})

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        start_live_watchdog(pid, task, mr_ref, ws)

        wait_until(fn ->
          match?(%{reason: "merge_failed"}, PendingMerge.get(reload(task)))
        end)

        kill_worker(pid, task.id)
      end)

      live_attempts = StubMerger.merge_count(mr_ref)
      assert live_attempts >= 1

      # Hours later the author marks it ready. Two draft polls, then clean.
      StubMerger.set_merge_result(:ok)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", block_reason: :draft},
        %{status: :open, head_sha: reviewed, base_ref: "main", block_reason: :draft},
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [id]} = sweep()
        assert id == task.id
        wait_until(fn -> reload(task).status == :closed end)
      end)

      assert StubMerger.merge_count(mr_ref) == live_attempts + 1,
             "the retry must not attempt a merge while the PR is still a draft"

      assert StubMerger.last_merge() == {mr_ref, reviewed}
      assert PendingMerge.get(reload(task)) == nil
      assert escalations(task.id) |> Enum.filter(&(&1.subject =~ "orphan")) == []
    end

    test "CI running → green: merges once CI concludes, with no live worker" do
      reviewed = sha("ci-green")
      mr_ref = "!pm-ci"
      ws = workspace()
      task = task(ws, mr_ref)
      pid = running_worker(task)
      cleanup_retry(task.id)

      # The #1932 shape: approved, the Watchdog defers on CI :running, then the
      # worker's machine dies.
      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :running}
      ])

      capture_log(fn ->
        start_live_watchdog(pid, task, mr_ref, ws)
        wait_until(fn -> match?(%{reason: "ci_pending"}, PendingMerge.get(reload(task))) end)
        kill_worker(pid, task.id)
      end)

      assert StubMerger.merge_count(mr_ref) == 0

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :running},
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> reload(task).status == :closed end)
      end)

      assert StubMerger.merge_count(mr_ref) == 1
      assert StubMerger.last_merge() == {mr_ref, reviewed}
      assert PendingMerge.get(reload(task)) == nil
    end

    test "a task whose live Watchdog still owns the merge is left alone" do
      reviewed = sha("owned")
      mr_ref = "!pm-owned"
      ws = workspace()
      task = task(ws, mr_ref)
      pid = running_worker(task)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :running}
      ])

      capture_log(fn ->
        start_live_watchdog(pid, task, mr_ref, ws, interval_ms: 5_000)
        wait_until(fn -> PendingMerge.get(reload(task)) != nil end)
        assert %{retried: []} = sweep()
      end)

      assert Watchdog.retry_whereis(task.id) == nil
    end
  end

  # ---- AC2: survives a restart --------------------------------------------

  describe "AC2 — a deferred merge still pending at boot" do
    test "is picked up by a freshly started sweeper and merges" do
      reviewed = sha("boot")
      mr_ref = "!pm-boot"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)

      # All that survives a restart: the durable row. No worker, no Watchdog.
      stamp!(task, reviewed)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        start_supervised!(
          {PendingMergeSweeper,
           Keyword.merge(sweep_opts(),
             name: nil,
             enabled: true,
             initial_delay_ms: 0,
             interval_ms: 60_000
           )}
        )

        wait_until(fn -> reload(task).status == :closed end)
      end)

      assert StubMerger.last_merge() == {mr_ref, reviewed}
    end

    test "a disabled sweeper never sweeps" do
      pid =
        start_supervised!(
          {PendingMergeSweeper, Keyword.merge(sweep_opts(), name: nil, enabled: false)}
        )

      assert %{enabled: false, sweeps: 0} = PendingMergeSweeper.status(pid)
    end
  end

  # ---- AC3: every guard still applies on the retry path ---------------------

  describe "AC3 — the retry path keeps the merge guards" do
    test "stale reviewed SHA: an unreviewed post-approval commit is never merged" do
      reviewed = sha("stale-reviewed")
      head = sha("stale-head")
      mr_ref = "!pm-stale"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.set_diff(mr_ref, reviewed, @reviewed_diff)
      StubMerger.set_diff(mr_ref, head, @unreviewed_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: head, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> PendingMerge.get(reload(task)).escalated_at != nil end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 0
      assert reload(task).status != :closed
      assert length(escalations(task.id)) == 1
    end

    test "a base-merge-only post-approval head is still covered and merges pinned to it" do
      reviewed = sha("basemerge-reviewed")
      head = sha("basemerge-head")
      mr_ref = "!pm-basemerge"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.set_diff(mr_ref, reviewed, @reviewed_diff)
      StubMerger.set_diff(mr_ref, head, @base_merged_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: head, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> reload(task).status == :closed end)
      end)

      assert StubMerger.last_merge() == {mr_ref, head}
    end

    test "zero net diff (#1996): an approved head that changes nothing is never merged" do
      reviewed = sha("empty")
      mr_ref = "!pm-empty"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.set_diff(mr_ref, reviewed, "")

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> PendingMerge.get(reload(task)).escalated_at != nil end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
      assert length(escalations(task.id)) == 1
    end

    test "coverage enabled: a head no coverage row covers is refused" do
      head = sha("uncovered")
      mr_ref = "!pm-uncovered"
      ws = workspace(%{"coverage_enabled" => true})
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      # The stamp names the head — the legacy guard alone would merge it.
      stamp!(task, head)

      StubMerger.set_diff(mr_ref, head, @reviewed_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: head, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> PendingMerge.get(reload(task)).escalated_at != nil end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
    end

    test "a stamp with no durable reviewed baseline never merges" do
      head = sha("no-baseline")
      mr_ref = "!pm-nobaseline"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, nil)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: head, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        sweep()
        wait_until(fn -> PendingMerge.get(reload(task)).escalated_at != nil end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
    end
  end

  # ---- AC4: a non-transient failure escalates once --------------------------

  describe "AC4 — a merge that keeps failing" do
    test "for a non-transient reason escalates once and is not retried again" do
      reviewed = sha("forbidden")
      mr_ref = "!pm-forbidden"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.set_merge_result(
        {:error, %Github.Error{kind: :forbidden, status: 403, message: "Resource not accessible"}}
      )

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> PendingMerge.get(reload(task)).escalated_at != nil end)
        wait_until(fn -> is_nil(Watchdog.retry_whereis(task.id)) end)

        attempts = StubMerger.merge_count(mr_ref)
        assert attempts >= 1

        # Later sweeps — and later boots — leave it to the human it paged.
        assert %{retried: []} = sweep()
        assert %{retried: []} = sweep()
        assert StubMerger.merge_count(mr_ref) == attempts
      end)

      assert [escalation] = escalations(task.id)
      assert escalation.subject =~ task.id
      assert reload(task).status != :closed
    end

    test "transient forge errors keep retrying without escalating" do
      reviewed = sha("transient")
      mr_ref = "!pm-transient"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.set_merge_result(
        {:error, %Github.Error{kind: :conflict, status: 409, message: "Base branch was modified"}}
      )

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> StubMerger.merge_count(mr_ref) >= 5 end)
        StubMerger.set_merge_result(:ok)
        wait_until(fn -> reload(task).status == :closed end)
      end)

      assert escalations(task.id) == []
    end

    test "a PR closed without merging drops the stamp and does not merge" do
      reviewed = sha("closed-pr")
      mr_ref = "!pm-closedpr"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.queue_get(mr_ref, [%{status: :closed, head_sha: reviewed}])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> PendingMerge.get(reload(task)) == nil end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
    end
  end

  # ---- a running retry stands down when the task stops owing the merge ------

  describe "a running retry whose task no longer owes the merge" do
    # Starts a retry held on CI :running and waits until it is actually
    # polling, so the change under test lands mid-wait rather than before the
    # retry ever ran.
    defp start_held_retry(label) do
      reviewed = sha(label)
      mr_ref = "!pm-#{label}"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :running}
      ])

      capture_log(fn ->
        assert %{retried: [_]} = sweep()
        wait_until(fn -> StubMerger.get_count(mr_ref) >= 2 end)
      end)

      retry = Watchdog.retry_whereis(task.id)
      assert is_pid(retry)
      {task, mr_ref, reviewed, retry}
    end

    defp assert_stands_down_without_merging(retry, mr_ref, reviewed) do
      ref = Process.monitor(retry)

      capture_log(fn ->
        # CI goes green: a retry that still thought it owned the merge would
        # merge on this poll.
        StubMerger.queue_get(mr_ref, [
          %{status: :open, head_sha: reviewed, base_ref: "main", pipeline: :success}
        ])

        # `:noproc` — it already stood down on the poll that saw the change
        # (e.g. the `:close` half of a close-then-reopen).
        assert_receive {:DOWN, ^ref, :process, ^retry, reason}, 3_000
        assert reason in [:normal, :noproc]
      end)

      assert StubMerger.merge_count(mr_ref) == 0
    end

    test "closing the task (won't-do) stops it before it can merge" do
      {task, mr_ref, reviewed, retry} = start_held_retry("close-mid-retry")

      {:ok, _} = Ash.update(reload(task), %{close_upstream: false}, action: :close)

      assert_stands_down_without_merging(retry, mr_ref, reviewed)
      assert escalations(task.id) == []
    end

    test "reopening the task stops it before it can merge the old PR" do
      {task, mr_ref, reviewed, retry} = start_held_retry("reopen-mid-retry")

      {:ok, closed} = Ash.update(reload(task), %{close_upstream: false}, action: :close)
      {:ok, reopened} = Ash.update(closed, %{}, action: :reopen)
      assert reopened.status == :open

      assert_stands_down_without_merging(retry, mr_ref, reviewed)
      assert PendingMerge.get(reload(task)) == nil
    end

    test "a stamp re-pointed at a different PR stops it" do
      {task, mr_ref, reviewed, retry} = start_held_retry("repointed-mid-retry")

      stamp!(task, reviewed, %{mr_ref: "!pm-some-newer-pr"})

      assert_stands_down_without_merging(retry, mr_ref, reviewed)
    end

    test "a stamp latched escalated stops it" do
      {task, mr_ref, reviewed, retry} = start_held_retry("escalated-mid-retry")

      :ok = PendingMerge.mark_escalated(task.id, :operator_took_over)

      assert_stands_down_without_merging(retry, mr_ref, reviewed)
    end
  end

  # ---- a retry cannot wait forever ------------------------------------------

  describe "a retry waiting on a blocker it cannot clear" do
    test "gives up and pages once when the pending merge outlives max_wait_ms" do
      reviewed = sha("wait-exhausted")
      mr_ref = "!pm-wait-exhausted"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed, %{reason: :merge_failed})

      # The PR has sat as a draft for three days since the merge first waited.
      three_days_ago =
        DateTime.utc_now() |> DateTime.add(-3 * 24 * 3600, :second) |> DateTime.to_iso8601()

      raw = Map.put(reload(task).pending_merge, "since", three_days_ago)
      {:ok, _} = Ash.update(reload(task), %{pending_merge: raw}, action: :set_pending_merge)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", block_reason: :draft}
      ])

      capture_log(fn ->
        assert %{retried: [_]} =
                 sweep(retry_opts: [interval_ms: 15, initial_delay_ms: 0, max_wait_ms: 3_600_000])

        wait_until(fn -> PendingMerge.get(reload(task)).escalated_at != nil end)
        wait_until(fn -> is_nil(Watchdog.retry_whereis(task.id)) end)

        # Latched: later sweeps leave it to the human it paged.
        assert %{retried: []} = sweep()
      end)

      assert PendingMerge.get(reload(task)).escalation_reason =~ "wait_exhausted"
      assert [_one] = escalations(task.id)
      assert StubMerger.merge_count(mr_ref) == 0
    end

    test "keeps waiting while the pending merge is inside max_wait_ms" do
      reviewed = sha("wait-inside")
      mr_ref = "!pm-wait-inside"
      ws = workspace()
      task = task(ws, mr_ref)
      cleanup_retry(task.id)
      stamp!(task, reviewed)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, head_sha: reviewed, base_ref: "main", block_reason: :draft}
      ])

      capture_log(fn ->
        assert %{retried: [_]} =
                 sweep(retry_opts: [interval_ms: 15, initial_delay_ms: 0, max_wait_ms: 3_600_000])

        wait_until(fn -> StubMerger.get_count(mr_ref) >= 5 end)
      end)

      assert is_pid(Watchdog.retry_whereis(task.id))
      assert PendingMerge.get(reload(task)).escalated_at == nil
      assert escalations(task.id) == []
    end
  end

  describe "sweeper scope" do
    test "a workspace with auto_merge turned off is not retried" do
      reviewed = sha("manual")
      ws = workspace(%{"auto_merge" => false})
      task = task(ws, "!pm-manual")
      stamp!(task, reviewed)

      assert %{retried: []} = sweep()
    end

    test "a stamp for a PR the task has since replaced is dropped, not retried" do
      ws = workspace()
      task = task(ws, "!pm-new-pr")
      stamp!(task, sha("superseded"), %{mr_ref: "!pm-old-pr"})

      assert %{retried: [], skipped: [{_, :superseded}]} = sweep()
      assert PendingMerge.get(reload(task)) == nil
      assert StubMerger.get_count("!pm-old-pr") == 0
    end

    test "reopening a task drops its stamp" do
      ws = workspace()
      task = task(ws, "!pm-reopen")
      {:ok, closed} = Ash.update(reload(task), %{close_upstream: false}, action: :close)

      # A stamp can only land on an open task; force one onto the closed row
      # to prove :reopen itself clears it.
      {:ok, closed} =
        Ash.update(closed, %{pending_merge: %{"mr_ref" => "!pm-reopen"}},
          action: :set_pending_merge
        )

      {:ok, reopened} = Ash.update(closed, %{}, action: :reopen)
      assert PendingMerge.get(reopened) == nil
    end

    test "a non-primary instance never sweeps" do
      reviewed = sha("secondary")
      ws = workspace()
      task = task(ws, "!pm-secondary")
      stamp!(task, reviewed)

      assert %{retried: [], skipped: :not_primary} = sweep(primary?: fn -> false end)
    end
  end
end
