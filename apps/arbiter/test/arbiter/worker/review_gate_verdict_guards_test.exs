defmodule Arbiter.Worker.ReviewGateVerdictGuardsTest do
  @moduledoc """
  Parity harness for the table-driven verdict-guard dispatcher (bd-6coisl).

  The four verdict guards — partial verification (bd-4te55l), unaddressed
  findings (bd-6r8caj), unmet criteria and missing criteria (bd-4yhv4x) — used
  to be four hand-written copies of the same `retries_left > 0` retry-vs-fail-
  closed shape. They now share one dispatcher parameterised by
  `ReviewGate.verdict_guard_spec/2`.

  This file freezes the pre-refactor behaviour of each guard as data, so a
  future change to the dispatcher cannot silently move one guard's retry-budget
  semantics, recorded verdict, or banner. The values below were read directly
  off the four pre-refactor function bodies; see the PR body for the
  before/after table.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewFindings
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Worker.ReviewVerification

  # {guard, verdict_reprompt_prompt/2 reason, verdict recorded when failing
  #  closed, which text that recorded round stores}
  #
  # `:banner` means the fail-closed round records the BANNERED findings (the
  # pre-refactor `handle_reject(state, unverified_banner(findings))` shape);
  # `:raw` means it records the reviewer's untouched findings and only the
  # routed payload carries the banner (the pre-refactor `record_round(..., :approve,
  # findings, ...)` + `route_after_reject(state, banner(findings))` shape).
  # `:raw` is load-bearing: `record_round/5` re-parses the findings text for
  # criteria counts and finding ids, so recording bannered text would corrupt
  # those columns.
  @parity [
    {:partial_verification, :unverified, :request_changes, :banner},
    {:unaddressed_findings, :unaddressed_findings, :approve, :raw},
    {:unmet_criteria, :unmet_criteria, :approve, :raw},
    {:missing_criteria, :missing_criteria, :approve, :raw}
  ]

  @approve_findings """
  VERDICT: APPROVE

  CRITERIA:
  - [MET] first criterion
  - [NOT MET] second criterion

  Looks fine otherwise.
  """

  @reject_findings """
  VERDICT: REQUEST_CHANGES
  VERIFICATION: PARTIAL

  - [Medium] lib/foo.ex:1 — something is off.
  """

  describe "verdict_guard_spec/2 (the table)" do
    test "covers exactly the four verdict guards" do
      assert Enum.map(@parity, &elem(&1, 0)) |> Enum.sort() ==
               Enum.sort(ReviewGate.verdict_guard_names())
    end

    for {guard, reason, verdict, record} <- @parity do
      test "#{guard} re-prompts with #{reason}, records #{verdict} from #{record} findings" do
        spec = ReviewGate.verdict_guard_spec(unquote(guard), gap())

        assert spec.reason == unquote(reason)
        assert spec.verdict == unquote(verdict)
        assert spec.record == unquote(record)
      end
    end

    # The exact log text each guard emits, frozen off the four pre-refactor
    # function bodies. These lines are how a `[warning]` in production is
    # attributed to a specific guard, and they are the only thing distinguishing
    # the four now that they share one dispatcher — so they are asserted
    # verbatim, not merely for shape.
    @log_parity %{
      partial_verification: %{
        retry:
          "ReviewGate: reviewer for task=bd-parity disclosed partial verification; re-prompting for a fully-verified pass (attempt 2)",
        spawn_error:
          "ReviewGate: partial-verification re-prompt failed to spawn for task=bd-parity: :enoent; proceeding with the unverified findings, clearly marked",
        exhausted:
          "ReviewGate: reviewer for task=bd-parity disclosed partial verification and the re-prompt budget is exhausted; proceeding with the unverified findings, clearly marked"
      },
      unaddressed_findings: %{
        retry:
          "ReviewGate: reviewer for task=bd-parity approved without dispositioning 1 open finding(s); re-prompting (attempt 2)",
        spawn_error:
          "ReviewGate: unaddressed-findings re-prompt failed to spawn for task=bd-parity: :enoent; rejecting the approval, clearly marked",
        exhausted:
          "ReviewGate: reviewer for task=bd-parity approved without dispositioning open finding(s) F1.1 and the re-prompt budget is exhausted; rejecting the approval, clearly marked"
      },
      unmet_criteria: %{
        retry:
          "ReviewGate: reviewer for task=bd-parity approved with unmet acceptance criteria; re-prompting for a per-criterion re-review (attempt 2)",
        spawn_error:
          "ReviewGate: unmet-criteria re-prompt failed to spawn for task=bd-parity: :enoent; rejecting the approval, clearly marked",
        exhausted:
          "ReviewGate: reviewer for task=bd-parity approved with unmet acceptance criteria and the re-prompt budget is exhausted; rejecting the approval, clearly marked"
      },
      missing_criteria: %{
        retry:
          "ReviewGate: reviewer for task=bd-parity approved a criteria-bearing task with no CRITERIA breakdown; re-prompting for a per-criterion review (attempt 2)",
        spawn_error:
          "ReviewGate: missing-criteria re-prompt failed to spawn for task=bd-parity: :enoent; rejecting the approval, clearly marked",
        exhausted:
          "ReviewGate: reviewer for task=bd-parity approved a criteria-bearing task with no CRITERIA breakdown and the re-prompt budget is exhausted; rejecting the approval, clearly marked"
      }
    }

    for {guard, _reason, _verdict, _record} <- @parity do
      test "#{guard} emits its exact pre-refactor log text for all three events" do
        spec = ReviewGate.verdict_guard_spec(unquote(guard), gap())
        expected = @log_parity[unquote(guard)]
        state = %{task_id: "bd-parity", attempt: 2}

        assert spec.logs.retry.(state) == expected.retry
        assert spec.logs.spawn_error.(state, :enoent) == expected.spawn_error
        assert spec.logs.exhausted.(state) == expected.exhausted
      end
    end

    test "an unknown guard name raises rather than silently defaulting" do
      # `apply/3` keeps the bad name opaque to the compiler's type checker,
      # which would otherwise flag the deliberately-unmatched call.
      assert_raise FunctionClauseError, fn ->
        apply(ReviewGate, :verdict_guard_spec, [:not_a_guard, nil])
      end
    end
  end

  describe "banner parity — each guard still prepends its own banner" do
    test "partial_verification uses the unverified banner" do
      spec = ReviewGate.verdict_guard_spec(:partial_verification, nil)

      assert spec.banner.(@reject_findings) ==
               ReviewVerification.prepend_banner(@reject_findings)
    end

    test "unaddressed_findings uses the disposition banner, closing over the gap" do
      gap = gap()
      spec = ReviewGate.verdict_guard_spec(:unaddressed_findings, gap)

      assert spec.banner.(@approve_findings) ==
               ReviewFindings.prepend_disposition_banner(@approve_findings, gap)
    end

    test "unmet_criteria uses the criteria banner with the parsed counts" do
      spec = ReviewGate.verdict_guard_spec(:unmet_criteria, nil)
      {total, unmet} = ReviewVerification.criteria_counts(@approve_findings)

      assert spec.banner.(@approve_findings) ==
               ReviewVerification.prepend_criteria_banner(@approve_findings, unmet, total)
    end

    test "missing_criteria uses the missing-criteria banner" do
      spec = ReviewGate.verdict_guard_spec(:missing_criteria, nil)

      assert spec.banner.(@approve_findings) ==
               ReviewVerification.prepend_missing_criteria_banner(@approve_findings)
    end
  end

  defp gap do
    ReviewFindings.approval_gap(
      ReviewFindings.extract(
        """
        VERDICT: REQUEST_CHANGES

        - [Medium] lib/foo.ex:1 — the original finding.
        """,
        1
      ),
      @approve_findings,
      nil
    )
  end
end
