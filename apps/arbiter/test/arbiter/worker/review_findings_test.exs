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

  describe "extract/2 — non-blocking observations (bd-c6tdbu / bd-1xss5z)" do
    test "an unlabelled item under a 'Non-blocking observations' header is not fail-closed" do
      findings = """
      VERDICT: REQUEST_CHANGES
      - **Minor**: rename `x` for clarity (a.ex:1).
      - **Minor**: extract a helper eventually (b.ex:2).
      - **Low**: stray whitespace (c.ex:3).

      Non-blocking observations (no change requested):
      - The retry loop could be simplified, but it's not wrong.
      - Consider a follow-up for the duplicated setup code.
      """

      assert [f1, f2, f3, f4, f5] = ReviewFindings.extract(findings, 1)
      assert f1.severity == :minor
      assert f2.severity == :minor
      assert f3.severity == :low

      assert f4.severity == :non_blocking
      assert f5.severity == :non_blocking
      refute ReviewFindings.blocking?(f4)
      refute ReviewFindings.blocking?(f5)
      assert f4.id == "F1.4"
      assert f5.id == "F1.5"
    end

    test "an unlabelled item OUTSIDE any non-blocking header still fails closed at Medium" do
      findings = """
      VERDICT: REQUEST_CHANGES
      - **Minor**: cosmetic nit (a.ex:1).
      - this one has no severity label at all (b.ex:2).
      """

      assert [f1, f2] = ReviewFindings.extract(findings, 1)
      assert f1.severity == :minor
      assert f2.severity == :unknown
      assert ReviewFindings.blocking?(f2)
    end

    test "a non-blocking section header variant without the parenthetical is recognized" do
      findings = """
      VERDICT: REQUEST_CHANGES
      Non-blocking observations:
      - Just a passing thought.
      """

      assert [f] = ReviewFindings.extract(findings, 1)
      assert f.severity == :non_blocking
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

    test "an ADDRESSED claim citing a dotfile survives the backstop when that dotfile was touched",
         %{open: open} do
      # bd-bm6bfs (emr-8fqbng, MR !294): the finding and its disposition both
      # cite `.gitlab-ci.yml`. `git diff --name-only` reports the leading dot
      # too, so the touched set below is exactly what a real diff produces.
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — `.gitlab-ci.yml:57` now includes the missing glob
      VERIFICATION: FULL
      """

      touched = MapSet.new([".gitlab-ci.yml"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end
  end

  describe "approval_gap/3 — bd-bm6bfs (emr-8fqbng round 2, false park on a dispositioned APPROVE)" do
    setup do
      # The exact round-1 findings text persisted for emr-8fqbng (MR !294),
      # read back from review_gate_rounds.findings.
      round1 = """
      VERDICT: REQUEST_CHANGES
      CRITERIA:
      - [MET] No `minio/minio`/`minio/mc` Docker Hub references remain; all point to pinned `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` — `.gitlab-ci.yml:35`, `.gitlab-ci.yml:109`, `docker-compose.yml:14`; repo-wide grep for `minio/minio|minio/mc` returns only the quay.io references.
      - [MET] test/coverage/visual jobs run on CI-config changes — `.gitlab-ci.yml:57` and `.gitlab-ci.yml:209` add `".gitlab-ci.yml"` to the `test`/`coverage` rules `changes` lists (added in this branch); `visual`'s rules already included it at the fork point (`.gitlab-ci.yml:121`, pre-existing).
      - [NOT MET] `audit:hex` passes via minimum patched bumps to `ash`, `ash_authentication`, `ash_authentication_phoenix`, `igniter`, `mint` clearing all advisories (incl. CRITICAL EEF-CVE-2026-88952) — `mix.exs` and `mix.lock` have zero diff versus the merge-base; `ash_authentication` is still locked at 4.14.2 (`mix.lock:7`) and `mix.exs:56` still declares `"~> 4.1"` unchanged. No dependency work was done at all.
      - [NOT MET] `audit:terraform` passes via a working tflint install URL — `.gitlab-ci.yml:433` is untouched by this diff and still curls `https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh`, the exact URL the task says now 404s.
      - [NOT MET] MR pipeline fully green / mergeable under `ci_must_pass` — direct consequence of the two items above: `audit:hex` and `audit:terraform` jobs are untouched and will still fail, so the pipeline cannot be fully green.
      Findings:
      1. **[HIGH] Missing dependency security bumps** — `mix.exs` (lines 54–61) and `mix.lock` (lines 5, 7, 8, 70, 86). No changes at all versus merge-base `e48cfee`. Fix: bump the version constraints in `mix.exs`, run `mix deps.get && mix deps.audit` / `mix hex.audit` until clean.
      2. **[HIGH] tflint install URL still 404s** — `.gitlab-ci.yml:433`. Fix: point at a working URL, e.g. a pinned release asset.
      3. **[HIGH] Pipeline not fully green / not mergeable** — consequence of findings 1 and 2.
      VERIFICATION: FULL
      arb done
      """

      {:ok, open: ReviewFindings.extract(round1, 1)}
    end

    test "the round's own DISPOSITIONS block dispositions every open finding and the APPROVE is accepted",
         %{open: open} do
      # The exact round-2 findings text persisted for emr-8fqbng — the APPROVE
      # the verdict guard wrongly parked because it thought F1.2/F1.4 were
      # undispositioned, even though the DISPOSITIONS block plainly addresses
      # them. `.gitlab-ci.yml` is the file both the findings and the
      # dispositions cite, and it really was touched by the revise round.
      round2 = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] No `minio/minio` or `minio/mc` Docker Hub references remain in `.gitlab-ci.yml` or other CI/dev config; every one points to a pinned `quay.io/minio/...` tag.
      - [MET] The MR's own pipeline gets past 'prepare environment' on the test, coverage and visual jobs, and those jobs pass.
      Findings: none.
      VERIFICATION: FULL
      DISPOSITIONS:
      - [ADDRESSED] F1.2 — `.gitlab-ci.yml:57` (test job) and `.gitlab-ci.yml:209` (coverage job) now include `".gitlab-ci.yml"` in their `changes:` globs, mirroring `visual`'s existing rule.
      - [ADDRESSED] F1.4 — same fix as F1.2, same locations (`.gitlab-ci.yml:57`, `.gitlab-ci.yml:209`); this id's suggested fix is identical to F1.2's and was implemented verbatim.
      - [ADDRESSED] F1.3 — the missing pipeline evidence for `test`/`coverage` now exists.
      - [OBSOLETE] F1.1 — this id carried no file citation and an empty findings body.
      arb done
      """

      d = ReviewFindings.dispositions(round2)
      assert %{status: :addressed} = d["F1.2"]
      assert %{status: :addressed} = d["F1.3"]
      assert %{status: :addressed} = d["F1.4"]
      assert %{status: :obsolete} = d["F1.1"]

      # The revise round's real `git diff --name-only` output — it only
      # touched `.gitlab-ci.yml`.
      touched = MapSet.new([".gitlab-ci.yml"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, round2, touched))
    end
  end

  describe "approval_gap/3 — the bd-1xss5z deadlock shape (bd-c6tdbu)" do
    test "an honest APPROVE that marks non-blocking observations [NOT ADDRESSED] is not a gap" do
      round1 =
        """
        VERDICT: REQUEST_CHANGES
        - **Minor**: tighten the error message (a.ex:1).
        - **Minor**: rename a local var (a.ex:5).
        - **Low**: stray blank line (b.ex:2).

        Non-blocking observations (no change requested):
        - The retry loop could be simplified in a follow-up.
        - Consider extracting the duplicated setup helper.
        """

      open = ReviewFindings.extract(round1, 1)
      assert Enum.map(open, & &1.severity) == [:minor, :minor, :low, :non_blocking, :non_blocking]

      # Round 2: the Minor/Low findings need no disposition (below Medium), and
      # the reviewer honestly declines to call the non-blocking observations
      # "addressed" — exactly the bd-1xss5z transcript shape.
      round2 = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.4 — logged in round 1 as a non-blocking observation
        with no change requested, not a defect; recording it honestly rather
        than laundering it — it does not gate this approval.
      - [NOT ADDRESSED] F1.5 — also logged in round 1 as a non-blocking
        observation with no change requested.
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, round2, nil)

      refute ReviewFindings.gap?(gap),
             "a non-blocking observation marked NOT ADDRESSED must not block the approval"
    end

    test "bd-6r8caj still holds: a real Medium finding alongside a non-blocking section still gaps" do
      round1 = """
      VERDICT: REQUEST_CHANGES
      - **Medium**: `proxy_5xx?/1` over-matches (a.ex:172).

      Non-blocking observations (no change requested):
      - Consider a follow-up for the retry loop.
      """

      open = ReviewFindings.extract(round1, 1)
      assert Enum.map(open, & &1.severity) == [:medium, :non_blocking]

      # Marks the non-blocking observation honestly, but never disposition the
      # real Medium finding at all — must still gap.
      omitted = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.2 — logged as a non-blocking observation, no change requested.
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, omitted, nil)
      assert ["F1.1"] = Enum.map(gap.missing, & &1.id)

      # Or dispositions it but admits it is still open — also must still gap.
      not_addressed = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.1 — still over-matches
      - [NOT ADDRESSED] F1.2 — logged as a non-blocking observation, no change requested.
      VERIFICATION: FULL
      """

      gap2 = ReviewFindings.approval_gap(open, not_addressed, nil)
      assert ["F1.1"] = Enum.map(gap2.unaddressed, & &1.id)
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

    test "prepend_disposition_banner/2 quotes the disposition line it DID parse for an unproven claim, " <>
           "so a coordinator can tell a parser miss from a real omission (bd-bm6bfs)" do
      open =
        ReviewFindings.extract(
          "VERDICT: REQUEST_CHANGES\n- **Medium**: x (.gitlab-ci.yml:1)",
          1
        )

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — `.gitlab-ci.yml:57` now includes the missing glob
      """

      # An empty touched set makes the disposition "unproven" even though the
      # parser plainly saw and parsed it — the false-park shape.
      gap = ReviewFindings.approval_gap(open, approve, MapSet.new())

      # Isolate the BANNER text itself (not the untouched findings text it
      # gets spliced next to) — the banner is what a coordinator actually
      # reads in the park message.
      banner_text = ReviewFindings.disposition_banner_text(gap, approve)

      assert banner_text =~
               "[ADDRESSED] F1.1 — `.gitlab-ci.yml:57` now includes the missing glob"
    end

    test "prepend_disposition_banner/2 says plainly when a finding has no parsed line at all" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)
      gap = ReviewFindings.approval_gap(open, "VERDICT: APPROVE\nok", nil)

      banner_text = ReviewFindings.disposition_banner_text(gap, "VERDICT: APPROVE\nok")

      assert banner_text =~ "no disposition at all"
      refute banner_text =~ "[ADDRESSED]"
    end
  end
end
