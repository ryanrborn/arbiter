defmodule Arbiter.Worker.ResumeTest do
  # bd-t9uq25: resume a session that exited mid-task without `arb done`.
  # These cover the pure pieces — the bounded resume decision (hard cap +
  # no-progress guard) and the `--resume` argv injection — without spawning a
  # real Claude session.
  use ExUnit.Case, async: true

  alias Arbiter.Worker

  describe "resume_decision/6 — bounded resume guards" do
    test "resumes a clean mid-task exit on the first attempt" do
      assert :resume = Worker.resume_decision(:exited_without_done, "sid-1", 0, 3, nil, nil)
    end

    test "resumes again when the worktree made progress between attempts" do
      assert :resume =
               Worker.resume_decision(:exited_without_done, "sid-2", 1, 3, "fp-old", "fp-new")
    end

    test "fails when the hard cap is reached" do
      assert {:fail, :cap_exhausted} =
               Worker.resume_decision(:exited_without_done, "sid", 3, 3, "a", "b")
    end

    test "fails when a resume made no progress (identical fingerprint) — loop guard" do
      assert {:fail, :no_progress} =
               Worker.resume_decision(:exited_without_done, "sid", 1, 3, "same", "same")
    end

    test "the no-progress guard does NOT fire on the first attempt" do
      # attempts == 0: even if fingerprints coincide, give the session one shot.
      assert :resume = Worker.resume_decision(:exited_without_done, "sid", 0, 3, "x", "x")
    end

    test "does not resume non-resumable stop categories" do
      for cat <- [
            :auth_expired,
            :credit_exhausted,
            :rate_limited,
            :crashed,
            :killed,
            :stalled,
            :spawn_exec_failed
          ] do
        assert {:fail, :not_resumable_category} =
                 Worker.resume_decision(cat, "sid", 0, 3, nil, nil)
      end
    end

    test "does not resume without a captured session id" do
      assert {:fail, :no_session_id} =
               Worker.resume_decision(:exited_without_done, nil, 0, 3, nil, nil)
    end

    # bd-4g0fsh Mode A: a transient gateway 5xx / upstream timeout is recoverable
    # — the session context is intact, so it auto-resumes just like an
    # exit-without-done, under the same hard cap + no-progress guard.
    test "resumes a transient gateway error (Mode A)" do
      assert :resume = Worker.resume_decision(:gateway_error, "sid-gw", 0, 3, nil, nil)
    end

    test "a gateway error still fails once the hard cap is reached" do
      assert {:fail, :cap_exhausted} =
               Worker.resume_decision(:gateway_error, "sid-gw", 3, 3, "a", "b")
    end
  end

  describe "resume_backoff_ms/2 — bounded exponential backoff (bd-4g0fsh)" do
    test "grows exponentially per attempt for a gateway error" do
      # base 2s, doubling each attempt
      assert Worker.resume_backoff_ms(:gateway_error, 0) == 2_000
      assert Worker.resume_backoff_ms(:gateway_error, 1) == 4_000
      assert Worker.resume_backoff_ms(:gateway_error, 2) == 8_000
    end

    test "a clean exit-without-done backs off from a shorter base" do
      assert Worker.resume_backoff_ms(:exited_without_done, 0) == 1_000
      assert Worker.resume_backoff_ms(:exited_without_done, 1) == 2_000
    end

    test "a gateway error always waits longer than an exit-without-done at the same attempt" do
      for attempt <- 0..3 do
        assert Worker.resume_backoff_ms(:gateway_error, attempt) >
                 Worker.resume_backoff_ms(:exited_without_done, attempt)
      end
    end

    test "is capped so the bounded budget never waits absurdly long" do
      # A huge attempt count saturates at the 30s ceiling rather than overflowing.
      assert Worker.resume_backoff_ms(:gateway_error, 50) == 30_000
    end

    test "falls back to a default base for any other category" do
      assert Worker.resume_backoff_ms(:something_else, 0) == 1_000
    end
  end

  describe "inject_resume_argv/3 — --resume injection" do
    test "inserts --resume <session_id> after --print and swaps the prompt" do
      argv = [
        "sh",
        "-c",
        "exec \"$@\" < /dev/null",
        "sh",
        "/bin/claude",
        "--print",
        "ORIGINAL TASK PROMPT",
        "--output-format",
        "stream-json",
        "--verbose"
      ]

      {:ok, %{argv: out}} =
        Worker.inject_resume_argv(%{argv: argv}, "sess-abc", "CONTINUE PROMPT")

      idx = Enum.find_index(out, &(&1 == "--print"))
      assert Enum.slice(out, idx, 4) == ["--print", "--resume", "sess-abc", "CONTINUE PROMPT"]

      # downstream stream flags survive, original prompt is gone
      assert "--output-format" in out and "stream-json" in out and "--verbose" in out
      refute "ORIGINAL TASK PROMPT" in out
    end

    test "errors when there is no --print slot (custom command / fixture)" do
      assert {:error, :no_print_slot} =
               Worker.inject_resume_argv(%{argv: ["echo", "hi"]}, "sid", "p")
    end

    test "errors when argv is missing" do
      assert {:error, :missing_argv} = Worker.inject_resume_argv(%{}, "sid", "p")
    end

    # bd-11abk2: a pristine dispatch argv built in stdin mode (oversized
    # original prompt, no prompt element in argv at all — see
    # Arbiter.Agents.Claude.build_argv/3) must still resume correctly: the
    # leading tmpfile positional is dropped and the short resume prompt is
    # spliced in as a normal inline (mode A) argv.
    test "swaps a stdin-mode (large-prompt) argv down to an inline resume argv" do
      {:ok, stdin_argv} =
        Arbiter.Agents.Claude.build_argv(
          "/bin/claude",
          String.duplicate("x", 200_000),
          ["--output-format", "stream-json", "--verbose"]
        )

      tmp = Arbiter.Agents.Claude.prompt_tmpfile(stdin_argv)
      assert is_binary(tmp)

      {:ok, %{argv: out}} =
        Worker.inject_resume_argv(%{argv: stdin_argv}, "sess-xyz", "CONTINUE PROMPT")

      idx = Enum.find_index(out, &(&1 == "--print"))
      assert Enum.slice(out, idx, 4) == ["--print", "--resume", "sess-xyz", "CONTINUE PROMPT"]

      # the tmpfile positional is gone — resumed argv is a plain inline invocation
      refute tmp in out
      assert "--output-format" in out and "stream-json" in out and "--verbose" in out

      File.rm(tmp)
    end
  end
end
