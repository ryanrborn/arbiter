defmodule Arbiter.Worker.CoordinatorOnlyFindingsTest do
  @moduledoc """
  bd-6d3h8m: the detection rule behind escalating straight away when every
  `[NOT MET]` criterion in a round is one the reviewer marked as needing
  coordinator/operator action, not another implementer round.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.CoordinatorOnlyFindings

  @bd_28t80i_round3 File.read!(
                      Path.expand("../../fixtures/review_findings_bd_28t80i_round3.md", __DIR__)
                    )

  describe "only_coordinator_blocked_unmet?/1" do
    test "true for the bd-28t80i round-3 fixture: its only NOT MET is tagged" do
      assert CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(@bd_28t80i_round3)
    end

    test "false when there is no NOT MET line at all (nothing to route)" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] AC1: done
      """

      refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(findings)
    end

    test "false when a NOT MET line is untagged: an implementer round is still warranted" do
      findings = """
      VERDICT: REQUEST_CHANGES
      CRITERIA:
      - [NOT MET] [NEEDS-COORDINATOR] AC3: needs deploy to verify
      - [NOT MET] AC4: the guard clause is missing entirely
      """

      refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(findings)
    end

    test "false for nil/non-binary input" do
      refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(nil)
    end
  end

  describe "escalation?/1" do
    test "true only for findings that lead with marker/0" do
      assert CoordinatorOnlyFindings.escalation?(
               CoordinatorOnlyFindings.marker() <> ". more text"
             )

      refute CoordinatorOnlyFindings.escalation?("some other findings text")
      refute CoordinatorOnlyFindings.escalation?(nil)
    end

    test "escalation_findings/2 output round-trips through escalation?/1" do
      out = CoordinatorOnlyFindings.escalation_findings(@bd_28t80i_round3, "FULL PAYLOAD")
      assert CoordinatorOnlyFindings.escalation?(out)
      assert out =~ "FULL PAYLOAD"
      assert out =~ CoordinatorOnlyFindings.tag()
    end
  end
end
