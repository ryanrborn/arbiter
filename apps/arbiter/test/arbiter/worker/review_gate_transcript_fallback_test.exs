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
  review in hand. The durable per-run transcript (`Arbiter.Worker.OutputLog`) is
  uncapped, so `parse_verdict/3` consults it before conceding `:no_verdict`, and
  logs which of the two sources saw what either way.
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
end
