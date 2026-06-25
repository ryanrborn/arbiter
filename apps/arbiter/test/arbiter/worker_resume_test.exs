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
      for cat <- [:auth_expired, :credit_exhausted, :rate_limited, :crashed, :killed, :stalled] do
        assert {:fail, :not_resumable_category} =
                 Worker.resume_decision(cat, "sid", 0, 3, nil, nil)
      end
    end

    test "does not resume without a captured session id" do
      assert {:fail, :no_session_id} =
               Worker.resume_decision(:exited_without_done, nil, 0, 3, nil, nil)
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
  end
end
