defmodule Arbiter.Worker.ReviewGateTranscriptFallbackTest do
  @moduledoc """
  bd-6dxit2: a review that DID emit a `VERDICT:` line must never be reported as
  `:no_verdict`, however long the transcript is and however many lines of
  findings follow the sentinel.

  Two line buffers feed verdict parsing and both are bounded:

    * `Arbiter.Worker.ClaudeSession` keeps the most recent `@line_cap` (1000)
      emitted lines in `meta[:output_lines]`;
    * `Arbiter.Worker` mirrors only the last `@max_output_lines` (500) of those
      into the persisted `worker_runs.output_lines` row.

  `Arbiter.Worker.route_reviewer_completion/1` parses `meta[:output_lines]`, so a
  reviewer that prints its verdict and then keeps talking for more than 1000
  lines loses the sentinel to eviction and lands INCONCLUSIVE with a complete
  review in hand.

  A cap drops the OLDEST lines. The gate's own live capture (`state.lines`) fails
  the other way — it loses the NEWEST — and that, not eviction, is what the
  measured production failures actually were (see the "shape actually observed in
  production" describe block below for the run-by-run evidence). Both directions
  are covered here, because the recovery must not care which end went missing.

  The durable per-run transcript (`Arbiter.Worker.OutputLog`) is uncapped, so
  `parse_verdict/3` consults it before conceding `:no_verdict`, and logs which
  source saw what either way.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.ReviewGate

  setup do
    prev = Application.get_env(:arbiter, :output_log_root)
    root = Path.join(System.tmp_dir!(), "rg-fallback-#{System.unique_integer([:positive])}")
    Application.put_env(:arbiter, :output_log_root, root)

    on_exit(fn ->
      File.rm_rf(root)

      if prev do
        Application.put_env(:arbiter, :output_log_root, prev)
      else
        Application.delete_env(:arbiter, :output_log_root)
      end
    end)

    %{root: root, run_id: "run-#{System.unique_integer([:positive])}"}
  end

  # A reviewer transcript whose VERDICT sits `trailing` lines from the end —
  # long enough that a naive tail scan of either cap misses it.
  defp transcript(trailing) do
    head = for i <- 1..40, do: "reviewing hunk #{i}..."
    tail = for i <- 1..trailing, do: "- [MEDIUM] finding #{i}: see file_#{i}.ex:#{i}"
    head ++ ["VERDICT: REQUEST_CHANGES", "Findings follow."] ++ tail ++ ["arb done"]
  end

  defp write_transcript!(run_id, lines) do
    {:ok, handle} = OutputLog.open(run_id)
    Enum.each(lines, &OutputLog.append(handle, &1))
    :ok = OutputLog.close(handle)
  end

  describe "parse_verdict/3 — durable transcript fallback" do
    test "uses the in-memory lines when they already carry the verdict", %{run_id: run_id} do
      lines = ["reviewing...", "VERDICT: APPROVE", "ship it"]

      assert {{:approve, findings}, :memory} = ReviewGate.parse_verdict(lines, run_id, "ctx")
      assert findings =~ "ship it"
    end

    test "does not need a run_id when the in-memory lines carry the verdict" do
      lines = ["VERDICT: APPROVE", "ship it"]
      assert {{:approve, _}, :memory} = ReviewGate.parse_verdict(lines, nil, "ctx")
    end

    test "recovers the verdict from the transcript when the in-memory tail lost it", %{
      run_id: run_id
    } do
      full = transcript(1_200)
      write_transcript!(run_id, full)

      # What ClaudeSession's 1000-line cap would have left in meta[:output_lines]:
      # the verdict is 1202 lines from the end, so it is gone.
      capped = Enum.take(full, -1_000)
      refute Enum.any?(capped, &(&1 =~ ~r/^VERDICT:/))

      log =
        capture_log(fn ->
          assert {{:request_changes, findings}, :transcript} =
                   ReviewGate.parse_verdict(capped, run_id, "task=t1")

          assert findings =~ "VERDICT: REQUEST_CHANGES"
          assert findings =~ "finding 1:"
          assert findings =~ "finding 1200:"
        end)

      assert log =~ "task=t1"
      assert log =~ "1000"
      assert log =~ to_string(length(full))
    end

    test "recovers it past the 500-line persisted-row cap too", %{run_id: run_id} do
      full = transcript(600)
      write_transcript!(run_id, full)

      capped = Enum.take(full, -500)
      refute Enum.any?(capped, &(&1 =~ ~r/^VERDICT:/))

      assert {{:request_changes, _}, :transcript} =
               ReviewGate.parse_verdict(capped, run_id, "task=t2")
    end

    test "concedes :no_verdict when neither source has one, and says so", %{run_id: run_id} do
      lines = ["reviewing...", "I could not finish.", "arb done"]
      write_transcript!(run_id, lines)

      log =
        capture_log(fn ->
          assert {:no_verdict, :none} = ReviewGate.parse_verdict(lines, run_id, "task=t3")
        end)

      assert log =~ "task=t3"
      assert log =~ "reviewer emitted no"
      refute log =~ "recovered"
    end

    test "reports the transcript as unavailable rather than blaming the reviewer", %{
      run_id: run_id
    } do
      lines = ["reviewing...", "arb done"]

      log =
        capture_log(fn ->
          assert {:no_verdict, :none} = ReviewGate.parse_verdict(lines, run_id, "task=t4")
        end)

      assert log =~ "durable transcript could not be read"
      assert log =~ "enoent"
    end

    test "a nil run_id degrades to the in-memory answer without crashing" do
      log =
        capture_log(fn ->
          assert {:no_verdict, :none} =
                   ReviewGate.parse_verdict(["nothing here"], nil, "task=t5")
        end)

      assert log =~ "no_run_id"
    end
  end

  describe "parse_verdict/3 — the shape actually observed in production (bd-6dxit2)" do
    # Measured, not assumed. Across the 72 recorded `:review_gate_inconclusive`
    # failures, 18 have a durable transcript for the pass that produced the
    # verdict-less finish; 5 of those transcripts DO contain a parseable
    # `VERDICT:` line. In every one of those 5 the sentinel sits 10–43 lines from
    # the end and is present in the persisted (<=500-line) tail:
    #
    #   run 7e09a5df bd-4qv2ni#review   863 lines, VERDICT at 843 (20 from end)
    #   run 3ce71b94 bd-1oddho#review   875 lines, VERDICT at 832 (43 from end)
    #   run b1264b9e bd-bcx6im#review   311 lines, VERDICT at 295 (16 from end)
    #   run a6cfc980 vs-8b4uqk#review#r2 621 lines, VERDICT at 611 (10 from end)
    #   run 84383309 vs-94r2c7#review   643 lines, VERDICT at 605 (38 from end)
    #
    # So cap eviction is NOT what happened in any observed case — a cap drops the
    # OLDEST lines, and a verdict 10 lines from the end survives every cap we
    # have. The buffer that lacked the sentinel was `ReviewGate.state.lines`, the
    # gate's own live PubSub capture, which is neither the capped meta buffer nor
    # the durable transcript: it loses its NEWEST lines when the pass is finished
    # before the tail of the stream has been delivered into it.
    #
    # That is the opposite end of the buffer from the cap case, so a fix that only
    # understood eviction would still lose these. The fallback must be
    # truncation-agnostic — it is, and these lock that in.
    defp production_shape(trailing) do
      head = for i <- 1..570, do: "- [MEDIUM] finding #{i}: file_#{i}.ex:#{i} needs a bounds check"
      tail = for i <- 1..trailing, do: "summary line #{i}"
      head ++ ["VERDICT: REQUEST_CHANGES"] ++ tail ++ ["arb done"]
    end

    test "recovers a verdict the live buffer lost from its TAIL, not its head", %{
      run_id: run_id
    } do
      full = production_shape(20)
      write_transcript!(run_id, full)

      # The gate was told the pass had finished before the last 30 lines of the
      # stream reached it, so its buffer ends just short of the sentinel. Note it
      # is well under both caps (1000/500) — nothing was evicted; the tail simply
      # never arrived.
      live = Enum.take(full, length(full) - 30)
      assert length(live) < 1_000
      refute Enum.any?(live, &(&1 =~ ~r/^VERDICT:/))

      log =
        capture_log(fn ->
          assert {{:request_changes, findings}, :transcript} =
                   ReviewGate.parse_verdict(live, run_id, "task=bd-4qv2ni#review")

          assert findings =~ "VERDICT: REQUEST_CHANGES"
        end)

      assert log =~ "recovered"
      assert log =~ "truncated tail"
    end

    test "recovers it when the live buffer is empty because no line was delivered",
         %{run_id: run_id} do
      full = production_shape(10)
      write_transcript!(run_id, full)

      assert {{:request_changes, _}, :transcript} =
               ReviewGate.parse_verdict([], run_id, "task=vs-8b4uqk#review#r2")
    end

    test "an APPROVE stranded in the tail is recovered too, not just REQUEST_CHANGES",
         %{run_id: run_id} do
      full = ["reviewing...", "VERDICT: APPROVE", "CRITERIA: all met"]
      write_transcript!(run_id, full)

      assert {{:approve, findings}, :transcript} =
               ReviewGate.parse_verdict(["reviewing..."], run_id, "task=t6")

      assert findings =~ "CRITERIA: all met"
    end
  end

  describe "the invariant the fallback rests on" do
    # `ClaudeSession.handle_exit/2` broadcasts `:worker_exited` BEFORE it calls
    # `close_durable/1` (claude_session.ex:1176-1177), and `ReviewGate` parses
    # the moment it sees that broadcast — so the fallback reads the transcript
    # while the writer still holds an open handle. That is only safe because
    # `OutputLog.open/1` uses a plain (non-`:raw`, non-`:delayed_write`) file
    # device, whose writes go through the file server synchronously and are
    # visible to other processes immediately. Adding `:delayed_write` or `:raw`
    # buffering to `open/1` would silently reintroduce bd-6dxit2 through the very
    # path that fixes it, so assert the property rather than trusting the comment.
    test "a transcript reads back complete from another process before it is closed",
         %{run_id: run_id} do
      {:ok, handle} = OutputLog.open(run_id)
      Enum.each(1..600, &OutputLog.append(handle, "finding #{&1}"))
      :ok = OutputLog.append(handle, "VERDICT: REQUEST_CHANGES")
      Enum.each(1..20, &OutputLog.append(handle, "trailer #{&1}"))

      # Deliberately NOT closed yet — this is the state the gate observes.
      assert {{:request_changes, _}, :transcript} =
               Task.await(
                 Task.async(fn -> ReviewGate.parse_verdict([], run_id, "task=unclosed") end)
               )

      :ok = OutputLog.close(handle)
    end
  end
end
