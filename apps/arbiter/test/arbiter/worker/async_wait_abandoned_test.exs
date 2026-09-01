defmodule Arbiter.Worker.AsyncWaitAbandonedTest do
  @moduledoc """
  bd-606zlr / #1437 — a worker that correctly recognises a command will not
  finish inside the tool-call timeout, backgrounds it, and then *waits on a
  notification* dies on the spot.

  `claude --print` is non-interactive: the agent loop ends the moment a turn
  produces no tool call. Arming a `Monitor`, a `ScheduleWakeup`, or a
  backgrounded `Bash` and then yielding the turn to await the notification is
  exactly such a turn — the process exits 0, and the notification it is waiting
  for can never be delivered because there is no longer a session to deliver it
  to. Uncommitted work in the worktree is then discarded by the no-progress
  resume guard.

  The fixtures below are verbatim output tails from the three real runs in the
  ticket:

    * `028759f4-6b9a-4855-a9c2-27d0603ae0b5` (vs-3vlaqi) — armed a `Monitor`.
    * `beeaac80-d3ea-43c3-a52b-cd99f1a54070` (emr-20e8kp) — backgrounded a
      compile and yielded the turn.
    * `5b372d81-2801-48c3-aec6-ed684f452865` (emr-20e8kp, the resume of the
      above) — did the identical thing again, then failed the no-progress
      guard with the correct fix still uncommitted.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.StopReason

  # ---- verbatim tails from the three runs in the ticket -------------------

  @monitor_tail [
    "started pid 2323967",
    ~s|⏵ Monitor(while kill -0 2323967 2>/dev/null; do sleep 5; done; echo "TEST RUN FINISHED"; tail -80 /tmp/mix_test_907.log)|,
    "⏴ tool result",
    "Monitor started (task bqpqgx4fo, persistent — runs until TaskStop or session end). " <>
      "You will be notified on each event. Keep working — do not poll or sleep. Events may " <>
      "arrive while you are waiting for the user — an event is not their reply.",
    "I'll wait for the test suite to finish rather than poll — the monitor will notify me with the results."
  ]

  @backgrounded_bash_tail [
    "⏵ Bash(export DATABASE_URL=\"ecto://postgres:postgres@localhost/tonic_test\"",
    "mix compile 2>&1 | tail -100)",
    "⏴ tool result",
    "Command running in background with ID: b69zmqf00. Output is being written to: " <>
      "/tmp/claude-1000/x/tasks/b69zmqf00.output. You will be notified when it completes. " <>
      "To check interim output, use Read on that file path.",
    "I'll wait for the compile task notification before continuing."
  ]

  @timed_out_to_background_tail [
    "⏵ Bash(MIX_ENV=test mix audit 2>&1 | tail -100)",
    "⏴ tool result",
    "Command did not complete within its 300s timeout and was moved to the background " <>
      "(ID: bswmu8ny4). Output is being written to: /tmp/claude-1000/x/tasks/bswmu8ny4.output. " <>
      "You will be notified when it completes. To check interim output, use Read on that file path.",
    "It's compiling the full project (slow), running in background now. I'll wait for the notification.",
    "⏵ Bash(sleep 5; echo ok)",
    "⏴ tool result",
    "ok",
    "",
    "Waiting for the background `mix audit` compile+run to finish."
  ]

  describe "StopReason.classify/2 — the abandoned-async-wait signature" do
    test "an armed Monitor as the last act is :async_wait_abandoned, not a plain early quit" do
      reason = StopReason.classify(0, @monitor_tail)

      assert reason.category == :async_wait_abandoned
      assert reason.exit_status == 0
    end

    test "a backgrounded Bash the agent yielded the turn to await is :async_wait_abandoned" do
      assert StopReason.classify(0, @backgrounded_bash_tail).category == :async_wait_abandoned
    end

    test "a tool-timeout backgrounding the agent never drained is :async_wait_abandoned" do
      assert StopReason.classify(0, @timed_out_to_background_tail).category ==
               :async_wait_abandoned
    end

    test "an armed ScheduleWakeup as the last act is :async_wait_abandoned" do
      # Verbatim from a real vs-3vlaqi CI fix-pass run.
      lines = [
        ~s|⏵ ScheduleWakeup({"delaySeconds":300,"noop":true,"prompt":"Check on the background mix test run"})|,
        "⏴ tool result",
        "Next wakeup scheduled for 17:07:00 (in 233s). Nothing more to do this turn — the " <>
          "harness re-invokes you when the wakeup fires or a task-notification arrives.",
        "I'll pick this back up when the background run completes."
      ]

      assert StopReason.classify(0, lines).category == :async_wait_abandoned
    end

    test "the summary and remediation name the non-interactive-session cause, not 're-dispatch'" do
      reason = StopReason.classify(0, @monitor_tail)

      assert reason.summary =~ "notification"
      assert reason.remediation =~ "resume"
      # The whole point: re-dispatching from scratch throws away the worktree.
      refute reason.remediation =~ "re-dispatch the task"
    end

    test "label/1 is compact and distinct from :exited_without_done" do
      assert StopReason.label(StopReason.classify(0, @monitor_tail)) ==
               "abandoned an async wait (background task never drained) (exit 0)"
    end
  end

  describe "StopReason.classify/2 — false-positive guards" do
    test "a background task that WAS drained before the run ended is not async_wait_abandoned" do
      # The successful emr-20e8kp run: backgrounded the suite, then blocked on
      # TaskOutput in the same turn and carried on to commit + push.
      lines = [
        "⏴ tool result",
        "Command did not complete within its 120s timeout and was moved to the background " <>
          "(ID: bngos5za3). You will be notified when it completes.",
        "Full test suite running in background. Let me check credo in the meantime.",
        ~s|⏵ TaskOutput({"block":true,"task_id":"bngos5za3","timeout":400000})|,
        "⏴ tool result",
        "Finished in 92.4 seconds — 412 tests, 0 failures",
        "⏵ Bash(git commit -m \"fix: ...\")",
        "⏴ tool result",
        "[feature/x 8a16374] fix: ...",
        " 6 files changed, 247 insertions(+), 3 deletions(-)"
      ]

      assert StopReason.classify(0, lines).category == :exited_without_done
    end

    test "a background task armed early but far from the tail does not match" do
      early = [
        "Command running in background with ID: babc123. You will be notified when it completes."
      ]

      lines = early ++ Enum.map(1..40, &"ordinary work line #{&1}")

      assert StopReason.classify(0, lines).category == :exited_without_done
    end

    test "a non-zero exit with an async-wait tail stays a crash — exit status is authoritative" do
      assert StopReason.classify(1, @monitor_tail).category == :crashed
    end

    test "a real provider error in the same tail still outranks the async-wait signature" do
      lines = @monitor_tail ++ ["API error 401: invalid authentication credentials"]

      assert StopReason.classify(0, lines).category == :auth_expired
    end

    test "the signature keys on the harness's own markers, not the agent's prose" do
      # An agent *saying* it will wait proves nothing — the wording is unbounded
      # paraphrase, and prose alone must never be enough to reclassify a run.
      prose_only = [
        "The suite takes ~11 minutes, well past the tool timeout.",
        "I'll wait for the test suite to finish rather than poll.",
        "The monitor will notify me with the results."
      ]

      assert StopReason.classify(0, prose_only).category == :exited_without_done
    end

    test "an ordinary early quit with no async marker is still :exited_without_done" do
      assert StopReason.classify(0, ["did some work", "but never finished"]).category ==
               :exited_without_done
    end
  end

  describe "Worker.resume_decision/6 — an abandoned async wait must survive the guards" do
    test "the category is resumable" do
      assert Arbiter.Worker.resume_decision(:async_wait_abandoned, "sess-1", 0, 3, nil, "fp-a") ==
               :resume
    end

    test "an unchanged worktree does NOT trip the no-progress guard" do
      # This is what discarded the correct-but-uncommitted fix on emr-20e8kp:
      # the pass's remaining job was *verification*, which legitimately changes
      # no files, so the fingerprint is identical across the resume.
      assert Arbiter.Worker.resume_decision(:async_wait_abandoned, "sess-1", 1, 3, "fp-a", "fp-a") ==
               :resume
    end

    test "it is still bounded by the hard attempt cap" do
      assert Arbiter.Worker.resume_decision(:async_wait_abandoned, "sess-1", 3, 3, "fp-a", "fp-a") ==
               {:fail, :cap_exhausted}
    end

    test "a plain exited_without_done keeps the no-progress guard" do
      assert Arbiter.Worker.resume_decision(:exited_without_done, "sess-1", 1, 3, "fp-a", "fp-a") ==
               {:fail, :no_progress}
    end
  end

  describe "Worker.resume_continue_prompt/2 — the corrective nudge" do
    test "an abandoned async wait is told why it died and what to do instead" do
      prompt = Arbiter.Worker.resume_continue_prompt(:async_wait_abandoned, "bd-606zlr")

      assert prompt =~ "bd-606zlr"
      assert prompt =~ "Monitor"
      assert prompt =~ "ScheduleWakeup"
      assert prompt =~ "TaskOutput"
      assert prompt =~ ~r/never (arrive|be delivered)/
      # It must also protect the work that is already on disk.
      assert prompt =~ "commit"
    end

    test "every other resumable category keeps the terse continue prompt" do
      prompt = Arbiter.Worker.resume_continue_prompt(:exited_without_done, "bd-606zlr")

      assert prompt =~ "did not print `arb done`"
      refute prompt =~ "ScheduleWakeup"
    end
  end
end

defmodule Arbiter.Worker.AsyncWaitPromptGuidanceTest do
  @moduledoc """
  bd-606zlr / #1437 — the prevention half.

  The ASYNC TOOLS block used to say only "you may background things, but wait
  for every background task to finish before printing `arb done`". A worker
  reading that reasonably concludes that arming a `Monitor` and yielding the
  turn *is* waiting. In a `claude --print` session it is not — it is suicide.
  Every prompt that grants background execution must therefore also say which
  waiting primitives actually work here.
  """
  use Arbiter.DataCase, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker.PromptBuilder

  defp task(overrides) do
    struct!(
      %Issue{
        id: "bd-async1",
        title: "T",
        description: "D",
        acceptance: "A",
        issue_type: :bug,
        tracker_type: :none
      },
      overrides
    )
  end

  # The four surfaces that grant background execution.
  defp surfaces do
    [
      {"work prompt", PromptBuilder.prompt_for_task(task(%{}), worktree_path: "/tmp/wt")},
      {"task prompt", PromptBuilder.prompt_for_task(task(%{issue_type: :task}), [])},
      {"review prompt", PromptBuilder.prompt_for_task(task(%{}), review: true)},
      {"claude adapter async_tool_instruction", Arbiter.Agents.Claude.async_tool_instruction()}
    ]
  end

  test "every async-tools block names the two primitives that cannot work here" do
    for {label, prompt} <- surfaces() do
      assert prompt =~ "Monitor", "#{label} must name `Monitor` as unusable for waiting"
      assert prompt =~ "ScheduleWakeup", "#{label} must name `ScheduleWakeup` as unusable"
    end
  end

  test "every async-tools block gives the working alternative: a blocking TaskOutput drain" do
    for {label, prompt} <- surfaces() do
      assert prompt =~ "TaskOutput", "#{label} must point at TaskOutput as the drain"
      assert prompt =~ ~r/block/i, "#{label} must say the drain is blocking"
    end
  end

  test "every async-tools block explains WHY — the notification cannot be delivered" do
    for {label, prompt} <- surfaces() do
      assert prompt =~ ~r/non-interactive/i, "#{label} must say the session is non-interactive"

      assert prompt =~ ~r/(never|cannot|can't|no)[^.]{0,60}(reach|deliver|arrive)/i,
             "#{label} must say the notification never arrives"
    end
  end

  test "the work prompt tells the agent to commit before long verification" do
    prompt = PromptBuilder.prompt_for_task(task(%{}), worktree_path: "/tmp/wt")

    assert prompt =~ ~r/commit[^.]{0,80}before[^.]{0,80}verif/i
  end

  test "the work prompt still keeps the ASYNC TOOLS heading its consumers key on" do
    assert PromptBuilder.prompt_for_task(task(%{}), worktree_path: "/tmp/wt") =~ "ASYNC TOOLS"
  end
end

defmodule Arbiter.Worker.AsyncWaitAbandonedIntegrationTest do
  @moduledoc """
  bd-606zlr / #1437 — the new category must be understood by everything that
  already switches on a `StopReason` category, or it silently degrades those
  surfaces (an unclassified run, or a preflight probe read as an auth failure).
  """
  use ExUnit.Case, async: true

  test "the loop's failure classifier gives it a conclusive, distinct bucket" do
    map = Arbiter.Loop.FailureClassifier.conclusive_stop_categories()

    assert Map.fetch!(map, :async_wait_abandoned) == {:agent_quality, :async_wait_abandoned}

    # Distinct from a plain early quit — the whole point is that the
    # coordinator can see this cause without reading a transcript.
    refute Map.fetch!(map, :async_wait_abandoned) == Map.fetch!(map, :exited_without_done)
  end

  test "it is one of the resumable stop categories the worker acts on" do
    # Guards the wiring end-to-end: classification → resume decision.
    reason =
      Arbiter.Worker.StopReason.classify(0, [
        "Monitor started (task bx1, persistent). You will be notified on each event."
      ])

    assert reason.category == :async_wait_abandoned

    assert Arbiter.Worker.resume_decision(reason.category, "sess-1", 0, 3, nil, "fp") == :resume
  end
end
