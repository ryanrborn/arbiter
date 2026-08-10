defmodule Arbiter.Worker.ReviewFindingsTest do
  @moduledoc """
  Finding identity and the per-round DISPOSITIONS protocol (bd-6r8caj / #1137).

  Before this module existed, `review_gate_rounds.findings` was free prose: a
  round-2 reviewer could emit `VERDICT: APPROVE` / `VERIFICATION: FULL` without
  ever revisiting the round-1 finding it had raised, and nothing in the gate
  could tell. These tests pin the mechanical half of the fix — stable ids,
  severity ranking, disposition parsing, and the approval gap — so the gate's
  guard has something checkable to read back.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewFindings

  describe "extract/2" do
    test "assigns a stable F<round>.<n> id to each enumerated finding" do
      findings = """
      VERDICT: REQUEST_CHANGES

      - **Medium**: `proxy_5xx?/1` over-matches bare "http 500" substrings
        (apps/arbiter/lib/arbiter/loop/failure_classifier.ex:172).
      - **Low**: a stray typo in the moduledoc (lib/arbiter/loop/foo.ex:3).
      """

      assert [one, two] = ReviewFindings.extract(findings, 1)
      assert one.id == "F1.1"
      assert two.id == "F1.2"
      assert one.round == 1
      assert one.severity == :medium
      assert two.severity == :low
      assert "apps/arbiter/lib/arbiter/loop/failure_classifier.ex" in one.files
    end

    test "ids are namespaced by round so round 2's findings never collide with round 1's" do
      assert [%{id: "F2.1"}] =
               ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- [high] a.ex:1 bad", 2)
    end

    test "unstructured prose findings become a single fail-closed finding" do
      findings = "VERDICT: REQUEST_CHANGES\nfindings: feature.txt:1 needs a guard before merge"

      assert [%{id: "F1.1", severity: :unknown} = f] = ReviewFindings.extract(findings, 1)
      assert ReviewFindings.blocking?(f), "an unlabelled finding must be treated as blocking"
    end

    test "ignores verdict payload that is not a finding" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] Criterion one — delivered in foo.ex
      - [NOT MET] Criterion two — missing
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed in foo.ex:12
      VERIFICATION: FULL
      arb done
      ⚙ claude session success · 94.7s · $0.59
      """

      assert ReviewFindings.extract(findings, 2) == []
    end

    test "returns [] for nil / blank findings" do
      assert ReviewFindings.extract(nil, 1) == []
      assert ReviewFindings.extract("VERDICT: APPROVE\n", 1) == []
    end
  end

  describe "blocking?/1 severity ranking" do
    for {label, sev} <- [
          {"Critical", :critical},
          {"Blocker", :blocker},
          {"High", :high},
          {"Major", :major},
          {"Medium", :medium},
          {"Moderate", :moderate}
        ] do
      test "#{label} is Medium-or-higher and therefore blocking" do
        assert [f] =
                 ReviewFindings.extract(
                   "VERDICT: REQUEST_CHANGES\n- #{unquote(label)}: a.ex:1 x",
                   1
                 )

        assert f.severity == unquote(sev)
        assert ReviewFindings.blocking?(f)
      end
    end

    for {label, sev} <- [{"Low", :low}, {"Minor", :minor}, {"Nit", :nit}] do
      test "#{label} is below Medium and not blocking" do
        assert [f] =
                 ReviewFindings.extract(
                   "VERDICT: REQUEST_CHANGES\n- #{unquote(label)}: a.ex:1 x",
                   1
                 )

        assert f.severity == unquote(sev)
        refute ReviewFindings.blocking?(f)
      end
    end
  end

  describe "dispositions/1" do
    test "parses every disposition status, in either order" do
      text = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed in failure_classifier.ex:180
      - [NOT ADDRESSED] F1.2 — the implementer never touched this
      - [OBSOLETE] F1.3 — the branch it cited was deleted by another fix
      - F1.4 [ADDRESSED] — id-first form is tolerated too
      VERIFICATION: FULL
      """

      d = ReviewFindings.dispositions(text)

      assert d["F1.1"].status == :addressed
      assert d["F1.2"].status == :not_addressed
      assert d["F1.3"].status == :obsolete
      assert d["F1.4"].status == :addressed
    end

    test "[NOT ADDRESSED] is never mis-read as [ADDRESSED]" do
      d = ReviewFindings.dispositions("DISPOSITIONS:\n- [NOT ADDRESSED] F1.1 — nope")
      assert d["F1.1"].status == :not_addressed
    end

    test "returns an empty map when no DISPOSITIONS block is present" do
      assert ReviewFindings.dispositions("VERDICT: APPROVE\nlooks good\nVERIFICATION: FULL") ==
               %{}

      assert ReviewFindings.dispositions(nil) == %{}
    end
  end

  describe "approval_gap/3 — the bd-8mtb0q shape" do
    setup do
      open =
        ReviewFindings.extract(
          """
          VERDICT: REQUEST_CHANGES
          - **Medium**: proxy_5xx?/1 over-matches (apps/arbiter/lib/arbiter/loop/failure_classifier.ex:172)
          - **Low**: typo in the moduledoc (apps/arbiter/lib/arbiter/loop/other.ex:3)
          """,
          1
        )

      {:ok, open: open}
    end

    test "a round-2 APPROVE that never mentions the prior Medium finding is a gap", %{open: open} do
      approve = "VERDICT: APPROVE\nThe change looks good.\nVERIFICATION: FULL\narb done"

      gap = ReviewFindings.approval_gap(open, approve, nil)

      assert ReviewFindings.gap?(gap)
      assert ["F1.1"] = Enum.map(gap.missing, & &1.id)
      assert gap.unaddressed == []
      assert gap.unproven == []
    end

    test "a Low finding left undispositioned is NOT a gap", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — guarded in failure_classifier.ex:180
      VERIFICATION: FULL
      """

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, nil))
    end

    test "an APPROVE that admits a Medium finding is NOT ADDRESSED is a gap", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.1 — still over-matches, but I'll let it slide
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, approve, nil)
      assert ReviewFindings.gap?(gap)
      assert ["F1.1"] = Enum.map(gap.unaddressed, & &1.id)
    end

    test "OBSOLETE dispositions a finding invalidated by a different fix (AC5)", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [OBSOLETE] F1.1 — the whole proxy_5xx? branch was deleted, so the over-match cannot occur
      VERIFICATION: FULL
      """

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, nil))
    end

    test "the untouched-file backstop rejects an ADDRESSED claim with no diff and no evidence",
         %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — the implementer resolved this
      VERIFICATION: FULL
      """

      # The implementer's revise round touched only an unrelated file — exactly
      # the bd-8mtb0q shape, where `git diff` for the cited file was empty.
      touched = MapSet.new(["apps/arbiter/lib/arbiter/loop/unrelated.ex"])

      gap = ReviewFindings.approval_gap(open, approve, touched)
      assert ReviewFindings.gap?(gap)
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end

    test "naming an untouched file is not an escape hatch — a fix cannot land in an unchanged file",
         %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed in apps/arbiter/lib/arbiter/loop/failure_classifier.ex:180
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, approve, MapSet.new(["docs/loop-review.md"]))
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end

    test "an ADDRESSED claim that names where the fix landed survives the backstop", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — the classification now happens in apps/arbiter/lib/arbiter/loop/router.ex:44
      VERIFICATION: FULL
      """

      touched = MapSet.new(["apps/arbiter/lib/arbiter/loop/router.ex"])
      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end

    test "an ADDRESSED claim whose cited file WAS touched survives the backstop", %{open: open} do
      approve =
        "VERDICT: APPROVE\nDISPOSITIONS:\n- [ADDRESSED] F1.1 — guarded now\nVERIFICATION: FULL"

      touched = MapSet.new(["apps/arbiter/lib/arbiter/loop/failure_classifier.ex"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end

    test "no open findings means no gap — a round-1 APPROVE is untouched by this guard" do
      refute ReviewFindings.gap?(ReviewFindings.approval_gap([], "VERDICT: APPROVE", nil))
    end
  end

  describe "carry_over/2" do
    test "keeps undispositioned and NOT ADDRESSED findings, drops ADDRESSED and OBSOLETE ones" do
      open =
        ReviewFindings.extract(
          """
          VERDICT: REQUEST_CHANGES
          - **High**: one (a.ex:1)
          - **High**: two (b.ex:1)
          - **High**: three (c.ex:1)
          - **High**: four (d.ex:1)
          """,
          1
        )

      text = """
      VERDICT: REQUEST_CHANGES
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed
      - [OBSOLETE] F1.2 — gone
      - [NOT ADDRESSED] F1.3 — still open
      """

      assert ["F1.3", "F1.4"] = open |> ReviewFindings.carry_over(text) |> Enum.map(& &1.id)
    end
  end

  describe "prompt + persistence surfaces" do
    test "open_findings_block/2 names each id, its severity, and flags untouched cited files" do
      open =
        ReviewFindings.extract(
          "VERDICT: REQUEST_CHANGES\n- **Medium**: over-match (a/b.ex:172)",
          1
        )

      block = ReviewFindings.open_findings_block(open, MapSet.new(["a/other.ex"]))

      assert block =~ "F1.1"
      assert block =~ "medium"
      assert block =~ "a/b.ex"
      assert block =~ "NOT TOUCHED"
    end

    test "disposition_block/1 states the required syntax" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)
      block = ReviewFindings.disposition_block(open)

      assert block =~ "DISPOSITIONS:"
      assert block =~ "[ADDRESSED]"
      assert block =~ "[NOT ADDRESSED]"
      assert block =~ "[OBSOLETE]"
      assert block =~ "F1.1"
    end

    test "encode_ids/1 and encode_dispositions/2 render persistable JSON" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)

      assert ReviewFindings.encode_ids(open) == ~s(["F1.1"])
      assert ReviewFindings.encode_ids([]) == nil

      text = "DISPOSITIONS:\n- [ADDRESSED] F1.1 — done"
      assert ReviewFindings.encode_dispositions(open, text) == ~s({"F1.1":"addressed"})
      assert ReviewFindings.encode_dispositions([], text) == nil
    end

    test "prepend_disposition_banner/2 puts the banner directly under the VERDICT line" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)
      gap = ReviewFindings.approval_gap(open, "VERDICT: APPROVE\nok", nil)

      banner = ReviewFindings.prepend_disposition_banner("VERDICT: APPROVE\nok", gap)

      assert ["VERDICT: APPROVE", "", line | _] = String.split(banner, "\n")
      assert line =~ "PRIOR FINDINGS NOT ACCOUNTED FOR"
      assert banner =~ "F1.1"
    end
  end
end
