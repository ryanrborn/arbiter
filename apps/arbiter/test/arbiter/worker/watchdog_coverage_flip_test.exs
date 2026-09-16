defmodule Arbiter.Worker.WatchdogCoverageFlipTest do
  @moduledoc """
  P4 (bd-df3zlo / #1736) — the Watchdog's **read-path flip**, behind
  `merge.coverage_enabled`.

  P3's tests (`watchdog_coverage_shadow_test.exs`) pin the flag-off half: the
  coverage predicate counts and logs and changes nothing. What this file pins
  is the other half, and the fact that the switch is the only difference
  between them:

    * the ctx now carries an `:ancestor?` probe, so §3.2's rule 2 is reachable
      and a forge-lag poll answers `{:unknown, :forge_lagging}` (AC1);
    * with the flag off, the old `last_reviewed_sha` guard still decides every
      merge, exactly as in P3 (AC2);
    * with the flag on, `Coverage.decide/3` decides and the old guard is the
      one shadowing — including where the two disagree (AC2);
    * a probe that cannot answer waits, bounded, and then parks and escalates
      once. It never merges (AC4).
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
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

  # The same net contribution after a merge from the base branch moved it.
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

  defp workspace(coverage_enabled?) do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "cf#{System.unique_integer([:positive])}",
      config: %{"merge" => %{"coverage_enabled" => coverage_enabled?}}
    })
  end

  defp running_task(ws, attrs) do
    task =
      Ash.create!(
        Issue,
        Map.merge(
          %{title: "coverage flip", description: "body", workspace_id: ws.id},
          attrs
        )
      )

    {:ok, pid} = Worker.start(task_id: task.id, repo: "arbiter")
    :ok = Worker.advance(pid, :implement)
    on_exit(fn -> stop_quietly(pid) end)

    {pid, task}
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

  # `wait_until` + a follow-up `:sys.get_state` races the poll loop: the state
  # that satisfied the condition is not necessarily the one read back. This
  # returns the snapshot that matched, so a whole set of assertions can be made
  # against one consistent view of the Watchdog.
  defp wait_for_state(pid, fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_state(pid, fun, deadline)
  end

  defp do_wait_state(pid, fun, deadline) do
    state = :sys.get_state(pid)

    cond do
      fun.(state) ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("watchdog state condition not met within timeout")

      true ->
        Process.sleep(5)
        do_wait_state(pid, fun, deadline)
    end
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

  defp shadow_events do
    Arbiter.Events.Record
    |> Ash.Query.filter(topic == "coverage_shadow")
    |> Ash.read!()
  end

  defp record_reviewed(task_id, mr_ref, head, fingerprint) do
    {:ok, entry} =
      Coverage.record(%{
        task_id: task_id,
        mr_ref: mr_ref,
        head_sha: head,
        base_ref: "main",
        net_diff_id: fingerprint,
        kind: :reviewed,
        source: :review_gate
      })

    entry
  end

  describe "AC1 — the ctx supplies an ancestry probe" do
    test "a forge-lag poll answers forge_lagging, on the #1709 shape" do
      # The shape P3's live run mis-answered: we pushed (and the gate approved)
      # `local`, the PR resource still reports `forge_head`, and `forge_head` is
      # an ancestor of `local`. Without a probe, rule 2 was unreachable and the
      # shadow recorded `unknown -> uncovered`.
      local = sha("flip-local")
      forge_head = sha("flip-forge-head")
      mr_ref = "!flipprobe"
      ws = workspace(false)

      {pid, task} = running_task(ws, %{last_reviewed_sha: local})
      record_reviewed(task.id, mr_ref, local, NetDiff.fingerprint(@reviewed_diff))
      StubMerger.set_ancestor(mr_ref, {forge_head, local}, {:ok, true})

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: forge_head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws,
            last_reviewed_sha: local,
            local_head_sha: local,
            # One poll, then quiet: the Watchdog's own forge-lag grace is five
            # polls, and this assertion is about the first one.
            interval_ms: 5_000
          )

          wait_until(fn -> Tally.snapshot().evaluations >= 1 end)
        end)

      assert StubMerger.ancestor_calls() == [{mr_ref, forge_head, local}],
             "rule 2 must ask the adapter whether the forge's head is behind our push"

      assert Tally.snapshot().by_transition["unknown->uncovered"] == nil,
             "P3 counted this poll as a disagreement; with the probe it is rule 2's answer"

      refute log =~ "DISAGREEMENT"
      assert StubMerger.merge_count(mr_ref) == 0

      # The durable row names the reason, so "it agreed" cannot be agreement on
      # some other answer.
      assert [event] = shadow_events()
      assert event.payload["result"] == "agree"
      assert event.payload["new"] == "unknown"
      assert event.payload["new_reason"] == "forge_lagging"
    end
  end

  describe "AC2 — merge.coverage_enabled false (the default)" do
    test "the old guard still decides: it merges where coverage would refuse" do
      # No coverage row at all, but the task's stamp names the head. The old
      # guard merges; `decide/3` says `{:uncovered, :no_coverage}`. Flag off,
      # so the merge happens and the disagreement is only counted.
      head = sha("flip-off-merge")
      mr_ref = "!flipoff1"
      ws = workspace(false)

      {pid, task} = running_task(ws, %{last_reviewed_sha: head})
      StubMerger.set_diff(mr_ref, head, @reviewed_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws, last_reviewed_sha: head, local_head_sha: head)
          wait_until(fn -> Worker.state(pid).status == :completed end)
        end)

      assert StubMerger.last_merge() == {mr_ref, head}
      assert log =~ "DISAGREEMENT"
      assert log =~ "the existing last_reviewed_sha guard's answer (covered) is the one acted on"
    end

    test "the old guard still decides: it refuses where coverage would merge" do
      # A later review round recorded coverage for the current head, but the
      # task row still carries the older stamp. Flag off, so the old guard's
      # refusal stands and the PR goes back to review.
      reviewed = sha("flip-off-old-stamp")
      head = sha("flip-off-new-head")
      mr_ref = "!flipoff2"
      ws = workspace(false)

      {pid, task} = running_task(ws, %{last_reviewed_sha: reviewed})
      record_reviewed(task.id, mr_ref, head, NetDiff.fingerprint(@reviewed_diff))

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      capture_log(fn ->
        start_watchdog(pid, task.id, mr_ref, ws,
          last_reviewed_sha: reviewed,
          local_head_sha: head
        )

        wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
    end
  end

  describe "AC2 — merge.coverage_enabled true" do
    test "decide/3 refuses a head with no coverage that the old guard would merge" do
      head = sha("flip-on-refuse")
      mr_ref = "!flipon1"
      ws = workspace(true)

      {pid, task} = running_task(ws, %{last_reviewed_sha: head})
      StubMerger.set_diff(mr_ref, head, @reviewed_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws, last_reviewed_sha: head, local_head_sha: head)
          wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)
        end)

      assert StubMerger.merge_count(mr_ref) == 0,
             "with the flag on, an uncovered head must not merge on the old stamp alone"

      assert log =~ "DISAGREEMENT"
      assert log =~ "old=covered"
      assert log =~ "new=uncovered"

      assert log =~ "coverage predicate's answer (uncovered) is the one acted on",
             "the disagreement line must name the answer that was acted on"
    end

    test "decide/3 merges a covered head the old guard would refuse" do
      # The money case (the phase's restart-and-observe AC): a fix round
      # recorded coverage for the current head, the task row still carries the
      # older stamp, and the old guard would buy a whole re-review for it.
      reviewed = sha("flip-on-old-stamp")
      head = sha("flip-on-new-head")
      mr_ref = "!flipon2"
      ws = workspace(true)

      {pid, task} = running_task(ws, %{last_reviewed_sha: reviewed})
      record_reviewed(task.id, mr_ref, head, NetDiff.fingerprint(@reviewed_diff))

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      log =
        capture_log(fn ->
          start_watchdog(pid, task.id, mr_ref, ws,
            last_reviewed_sha: reviewed,
            local_head_sha: head
          )

          wait_until(fn -> Worker.state(pid).status == :completed end)
        end)

      assert StubMerger.last_merge() == {mr_ref, head},
             "the merge must be pinned to the head coverage actually covers"

      assert StubAutoResumeDispatcher.resume_count() == 0
      assert log =~ "DISAGREEMENT"
      assert log =~ "old=uncovered"
      assert log =~ "new=covered"
    end

    test "a rule-3 match merges AND records the :mechanical row (§3.4)" do
      # A merge from the base branch: a different head, the same net diff. P3
      # deliberately discarded the row a rule-3 match implies; P4 is the
      # adopter, so the next poll resolves at rule 1 instead of re-fetching.
      reviewed = sha("flip-mech-reviewed")
      head = sha("flip-mech-head")
      mr_ref = "!flipon3"
      ws = workspace(true)

      {pid, task} = running_task(ws, %{last_reviewed_sha: reviewed})
      source_row = record_reviewed(task.id, mr_ref, reviewed, NetDiff.fingerprint(@reviewed_diff))

      StubMerger.set_diff(mr_ref, reviewed, @reviewed_diff)
      StubMerger.set_diff(mr_ref, head, @base_merged_diff)
      # Not a lag: the head is not an ancestor of anything we pushed.
      StubMerger.set_ancestor(mr_ref, {head, reviewed}, {:ok, false})

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: head, base_ref: "main"}
      ])

      capture_log(fn ->
        start_watchdog(pid, task.id, mr_ref, ws,
          last_reviewed_sha: reviewed,
          local_head_sha: reviewed
        )

        wait_until(fn -> Worker.state(pid).status == :completed end)
      end)

      assert StubMerger.last_merge() == {mr_ref, head}

      rows = Coverage.for_mr(mr_ref)
      assert mechanical = Enum.find(rows, &(&1.kind == :mechanical))
      assert mechanical.head_sha == head
      assert mechanical.derived_from == source_row.id
      assert mechanical.source == :watchdog
    end
  end

  describe "AC4 — a probe that cannot answer" do
    test "waits (bounded), never merges, and parks with one escalation" do
      local = sha("flip-probe-fail-local")
      forge_head = sha("flip-probe-fail-head")
      mr_ref = "!flipprobefail"
      ws = workspace(true)

      {pid, task} = running_task(ws, %{last_reviewed_sha: local})
      record_reviewed(task.id, mr_ref, local, NetDiff.fingerprint(@reviewed_diff))
      # The probe is wired, and the forge cannot answer it.
      StubMerger.set_ancestor(mr_ref, {forge_head, local}, {:error, :timeout})
      # A diff that WOULD fingerprint to the covered row: rule 3 must never be
      # reached, because rule 2 was asked and could not answer (AC4's "never
      # covered").
      StubMerger.set_diff(mr_ref, forge_head, @reviewed_diff)

      StubMerger.queue_get(mr_ref, [
        %{status: :open, approved: true, head_sha: forge_head, base_ref: "main"}
      ])

      # A ceiling low enough that an un-lifted park would run it out inside the
      # test: the grace is 5 polls, so the lane has 3 left after parking.
      cap = Watchdog.coverage_unknown_grace_polls() + 3

      log =
        capture_log(fn ->
          wpid =
            start_watchdog(pid, task.id, mr_ref, ws,
              last_reviewed_sha: local,
              local_head_sha: local,
              max_polls: cap
            )

          # Bounded: the park arrives after a finite number of polls, and the
          # counter stops there rather than climbing forever.
          state = wait_for_state(wpid, & &1.coverage_parked?)
          assert state.coverage_unknown_polls == Watchdog.coverage_unknown_grace_polls()

          # ...and TERMINAL: the park lifts the poll ceiling, so the lane keeps
          # watching instead of running the remaining polls out into
          # `{:awaiting_review_timeout, cap}` and an auto-resumed re-review.
          assert state.max_polls == :infinity
          assert state.coverage_park_poll < cap

          # Well past the ceiling an un-lifted park would have hit.
          later = wait_for_state(wpid, &(&1.poll_count > cap * 2))
          assert Process.alive?(wpid), "the park must not fail the lane at the ceiling"
          assert later.coverage_unknown_polls == state.coverage_unknown_polls
        end)

      assert StubMerger.merge_count(mr_ref) == 0,
             "a probe failure must never merge"

      assert StubAutoResumeDispatcher.resume_count() == 0,
             "a probe failure must not buy a re-review either — it is a pause"

      assert Worker.state(pid).status != :failed,
             "the park must not fail the worker: no {:awaiting_review_timeout, _}"

      refute log =~ "without a terminal outcome",
             "the auto_merge poll ceiling must not fire while the lane is coverage-parked"

      parked = for line <- String.split(log, "\n"), line =~ "coverage_unknown", do: line
      assert length(parked) == 1, "the park must escalate exactly once per episode"
    end

    test "the lifted ceiling is unwound — and rewound — once the head moves" do
      # The park is terminal *for that head*. A new head is a new question, so
      # the configured ceiling comes back, and it comes back against the poll
      # count the park began at: the parked polls do not count against the
      # merge timeout, and `last_escalated_poll` stays consistent with it.
      local = sha("flip-probe-unpark-local")
      forge_head = sha("flip-probe-unpark-head")
      next_head = sha("flip-probe-unpark-next")
      mr_ref = "!flipprobeunpark"
      ws = workspace(true)

      {pid, task} = running_task(ws, %{last_reviewed_sha: local})
      record_reviewed(task.id, mr_ref, local, NetDiff.fingerprint(@reviewed_diff))
      StubMerger.set_ancestor(mr_ref, {forge_head, local}, {:error, :timeout})
      StubMerger.set_ancestor(mr_ref, {next_head, local}, {:error, :timeout})
      StubMerger.set_diff(mr_ref, forge_head, @reviewed_diff)
      StubMerger.set_diff(mr_ref, next_head, @reviewed_diff)

      # Roomy enough that the restored ceiling is not re-tripped before the
      # assertions run: the new head gets its own budget and re-parks after
      # another `grace` polls.
      cap = Watchdog.coverage_unknown_grace_polls() * 4

      capture_log(fn ->
        StubMerger.queue_get(mr_ref, [
          %{status: :open, approved: true, head_sha: forge_head, base_ref: "main"}
        ])

        wpid =
          start_watchdog(pid, task.id, mr_ref, ws,
            last_reviewed_sha: local,
            local_head_sha: local,
            max_polls: cap
          )

        parked = wait_for_state(wpid, & &1.coverage_parked?)
        assert parked.max_polls == :infinity

        # Sit parked well past the configured ceiling, then move the head.
        wait_for_state(wpid, &(&1.poll_count > cap * 2))

        StubMerger.queue_get(mr_ref, [
          %{status: :open, approved: true, head_sha: next_head, base_ref: "main"}
        ])

        state = wait_for_state(wpid, &(&1.coverage_unknown_head == next_head))

        assert state.max_polls == cap, "the configured ceiling comes back with the new head"
        assert state.coverage_park_poll == nil

        assert state.poll_count < cap,
               "the parked polls do not count against the restored ceiling"

        assert Process.alive?(wpid)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 0
    end
  end
end
