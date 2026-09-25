defmodule Arbiter.Worker.EvidenceIntegrityTest do
  @moduledoc """
  bd-80talz: the detection rule that sends a ReviewGate rejection to the
  coordinator instead of another fix round on the same provider, when the
  reviewer says the work fabricated or falsified its evidence.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.EvidenceIntegrity

  # The round-2 REQUEST_CHANGES the ReviewGate reviewer wrote on bd-aro53b
  # (PR #2057), verbatim from `review_gate_rounds`. The agy worker had passed a
  # standalone HTML mockup off as screenshots of the app, hosted on
  # files.catbox.moe, and swapped a true citation for an unverified one.
  @aro53b_round2 File.read!(
                   Path.expand("../../fixtures/review_findings_bd_aro53b_round2.md", __DIR__)
                 )

  describe "flagged?/1 and flagged_lines/1" do
    test "flags bd-aro53b's round-2 findings" do
      assert EvidenceIntegrity.flagged?(@aro53b_round2)

      lines = EvidenceIntegrity.flagged_lines(@aro53b_round2)
      assert Enum.any?(lines, &(&1 =~ "fabricated static mockup"))
      assert Enum.any?(lines, &(&1 =~ "reads as fabricated evidence"))
    end

    test "only returns the lines that carry the accusation" do
      lines = EvidenceIntegrity.flagged_lines(@aro53b_round2)

      refute Enum.any?(lines, &(&1 =~ "NOTICE carries the trademark"))
      refute Enum.any?(lines, &String.starts_with?(&1, "VERDICT:"))
    end

    test "the explicit reviewer tag always flags" do
      text = "VERDICT: REQUEST_CHANGES\n1. [FABRICATED-EVIDENCE] PR body: the test log was edited"
      assert EvidenceIntegrity.flagged?(text)
    end

    for phrase <- [
          "the screenshots are fabricated",
          "a falsified citation to the press kit",
          "the attribution is misrepresented as official",
          "a mockup passed off as screenshots of the app",
          "the benchmark numbers look doctored",
          "the test output in the PR body was fabricated"
        ] do
      test "flags #{inspect(phrase)}" do
        assert EvidenceIntegrity.flagged?("1. [High] PR body — " <> unquote(phrase) <> ".")
      end
    end

    for phrase <- [
          "I found no fabricated evidence; the screenshots are real captures",
          "the citation is not fabricated — it matches the Wikimedia file",
          "nothing in the PR body is falsified",
          "the test fabricates a fake Issue struct instead of inserting one",
          "use a fake adapter in the test",
          "the mock returns a fabricated pid",
          "screenshots are missing from the PR",
          # bd-94xq54 round 1, the logical sense of the word:
          "a present-tense claim about source that this PR falsifies"
        ] do
      test "does not flag #{inspect(phrase)}" do
        refute EvidenceIntegrity.flagged?(
                 "1. [Medium] lib/foo.ex:12 — " <> unquote(phrase) <> "."
               )
      end
    end

    test "nil and empty text never flag" do
      refute EvidenceIntegrity.flagged?(nil)
      refute EvidenceIntegrity.flagged?("")
      assert EvidenceIntegrity.flagged_lines(nil) == []
    end
  end

  describe "escalation_findings/2 and escalation?/1" do
    test "leads with the marker and quotes the flagged lines ahead of the payload" do
      body = EvidenceIntegrity.escalation_findings(@aro53b_round2, "FULL TRANSCRIPT")

      assert String.starts_with?(body, EvidenceIntegrity.marker())
      assert body =~ "fabricated static mockup"
      assert body =~ "FULL TRANSCRIPT"
      assert EvidenceIntegrity.escalation?(body)
    end

    test "a raw reviewer text that flags fabrication is an escalation too" do
      assert EvidenceIntegrity.escalation?(@aro53b_round2)
    end

    test "an ordinary rejection is not" do
      refute EvidenceIntegrity.escalation?("VERDICT: REQUEST_CHANGES\n- [high] a.ex:1 nil guard")
      refute EvidenceIntegrity.escalation?(nil)
    end
  end
end
