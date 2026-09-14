defmodule Arbiter.Worker.WatchdogCoverageShadowTest do
  @moduledoc """
  P3 (bd-b0fqcl / #1649) — the Watchdog's merge-guard path in **shadow mode**.

  The contract these tests hold is narrow and entirely about *non*-behaviour:
  the Watchdog still merges (or refuses) exactly what
  `Arbiter.Mergers.ReviewedSha` says, and the only thing
  `Arbiter.Reviews.Coverage.decide/3` is allowed to do on the way past is
  count and log. A test that asserted the coverage predicate's own answer
  belongs in `coverage_decide_test.exs`; what belongs here is that the merge
  came out the same either way.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.CoverageShadow
  alias Arbiter.Reviews.CoverageShadow.Tally
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog

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

  # The same file, with a line no reviewer approved (Cause A).
  @authored_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,8 @@ defmodule A do
    def run do
      :ok
  +    :extra
  +    :smuggled_in
    end
   end
  """

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
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

  defp workspace do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "cs#{System.unique_integer([:positive])}"
    })
  end

  defp running_task(attrs) do
    ws = workspace()

    task =
      Ash.create!(
        Issue,
        Map.merge(
          %{title: "coverage shadow", description: "body", workspace_id: ws.id},
          attrs
        )
      )

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(pid) end)

    {pid, task, ws}
  end

  defp start_watchdog(worker_pid, task_id, mr_ref, ws, opts) do
    base = [
      task_id: task_id,
      worker: worker_pid,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      auto_resume_dispatcher: StubAutoResumeDispatcher
    ]

    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
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
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  describe "the shadow runs on every guarded-merge decision" do
    test "an exact match with a coverage row agrees, and the merge is unchanged" do
      head = sha("wd-agree")
      mr_ref = "!wdshadow1"

      {pid, task, ws} = running_task(%{last_reviewed_sha: head})

      {:ok, _} =
        Coverage.record(%{
          task_id: task.id,
          mr_ref: mr_ref,
          head_sha: head,
          base_ref: "main",
          net_diff_id: "fp-wd-agree",
          kind: :reviewed,
          source: :review_gate
        })

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws, last_reviewed_sha: head)
          wait_until(fn -> Worker.state(pid).status == :completed end)
        end)

      assert StubMerger.last_merge() == {mr_ref, head}

      refute log =~ "DISAGREEMENT"
      assert %{agreements: agreements, disagreements: 0} = Tally.snapshot()
      assert agreements >= 1
      assert Tally.snapshot().by_site[:watchdog] >= 1
    end

    test "a disagreement is logged and counted, and the merge still goes through" do
      # No coverage row at all — the state every PR opened before P1 is in. The
      # old guard merges (head == last_reviewed_sha); `decide/3` says
      # `{:uncovered, :no_coverage}`. The merge must still happen.
      head = sha("wd-disagree")
      mr_ref = "!wdshadow2"

      {pid, task, ws} = running_task(%{last_reviewed_sha: head})

      StubMerger.set_diff(mr_ref, head, @reviewed_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws, last_reviewed_sha: head)
          wait_until(fn -> Worker.state(pid).status == :completed end)
        end)

      assert StubMerger.last_merge() == {mr_ref, head},
             "shadow mode must not change what the Watchdog merges"

      disagreements =
        for line <- String.split(log, "\n"), line =~ "DISAGREEMENT", do: line

      assert length(disagreements) == 1
      [line] = disagreements
      assert line =~ "site=watchdog"
      assert line =~ "task=#{task.id}"
      assert line =~ "mr=#{mr_ref}"
      assert line =~ "head=#{head}"
      assert line =~ "old=covered"
      assert line =~ "new=uncovered"
      assert line =~ "new_reason=no_coverage"

      assert %{disagreements: 1} = Tally.snapshot()
      assert CoverageShadow.disagreement_count() == 1
    end

    test "the refusal path is unchanged, and the two predicates agree on it" do
      # Cause A: the head carries content nobody reviewed. The old guard
      # refuses and buys a re-review; `decide/3` independently says
      # `{:uncovered, :authored_content}`. Same class, so no disagreement —
      # and, more importantly, the same refusal.
      reviewed = sha("wd-reviewed")
      head = sha("wd-authored")
      mr_ref = "!wdshadow3"

      {pid, task, ws} = running_task(%{last_reviewed_sha: reviewed})

      {:ok, _} =
        Coverage.record(%{
          task_id: task.id,
          mr_ref: mr_ref,
          head_sha: reviewed,
          base_ref: "main",
          net_diff_id: NetDiff.fingerprint(@reviewed_diff),
          kind: :reviewed,
          source: :review_gate
        })

      StubMerger.set_diff(mr_ref, reviewed, @reviewed_diff)
      StubMerger.set_diff(mr_ref, head, @authored_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws, last_reviewed_sha: reviewed)
          wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)
        end)

      assert StubMerger.merge_count(mr_ref) == 0,
             "shadow mode must not turn a refusal into a merge"

      refute log =~ "DISAGREEMENT"
      assert %{agreements: agreements} = Tally.snapshot()
      assert agreements >= 1
    end
  end
end
