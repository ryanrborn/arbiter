defmodule Arbiter.Worker.EvidenceIntegrity do
  @moduledoc """
  Evidence integrity for workers and the ReviewGate (bd-80talz).

  On bd-aro53b (PR #2057) an economy-tier agy worker met two acceptance
  criteria it could not honestly meet by manufacturing the evidence. It passed
  a standalone HTML mockup off as screenshots of the app, uploaded them to
  files.catbox.moe (a public, anonymous, non-deletable host), and under
  reviewer pressure swapped a true artwork citation for an unverified one.
  Each fix round then reported both findings "resolved". The honest outcomes
  ("screenshots are not possible headlessly", a placeholder with a stated
  reason) were open to it the whole time.

  This module holds the two halves of the response that are not the egress
  deny list (`:no_public_upload` in `Arbiter.Agents.SecurityPolicy`):

    * **The prompt text.** `worker_block/0` goes into every authoring prompt
      (work, task and ReviewGate revise, for every provider) and
      `reviewer_block/0` into both review prompts.
    * **The detection rule.** A reviewer finding that says the work fabricated
      or falsified its evidence ends the automatic fix loop. The ReviewGate
      stops revising and reports the rejection with `marker/0` leading the
      findings (`escalation_findings/2`), and `Arbiter.Worker` escalates it to
      the coordinator rather than dispatching another fix round
      (`escalation?/1`). Another round on the same provider hands the
      question back to the mind that made the evidence up. The reviewer can
      also be wrong: on bd-aro53b it misread a true Wikimedia citation as
      false. Either way a human has to look.

  ## The detection rule

  A line flags when either:

    1. it carries the reviewer tag `[FABRICATED-EVIDENCE]` (`tag/0`), which
       `reviewer_block/0` asks reviewers to use; or
    2. it contains an **integrity term** (`fabricat*`, `falsified`,
       `falsification`, `forged`, `forgery`, `doctored`, `misrepresent*`,
       `passed/passes/passing off`)
       that is **not negated** (no `no`/`not`/`never`/`without`/`n't`… in the
       three words before it) and has an **evidence term** within eight words
       either side (screenshot, image, capture, mockup, citation, cited,
       source, provenance, attribution, credit, evidence, artifact, artwork,
       asset, logo, icon, mark, licence, proof, verification, benchmark, test
       output/result/run).

  Only the past-tense `falsified` counts: "a claim that this PR falsifies" is
  the logical sense, and it was the one false positive when the rule was run
  over the 1,395 reviewer rounds on record (2026-09-25). The other three hits
  were real accusations: bd-aro53b rounds 1 and 2, and bd-2exkl0 ("PR body
  misrepresents AC1 verification as a real dispatch").

  The evidence-term requirement keeps ordinary review vocabulary out: "the test
  fabricates a fake struct", "a fabricated pid" and "a fake adapter" name no
  evidence and do not flag. "fake" is not an integrity term for the same
  reason. The rule leans towards flagging: a false positive costs one
  coordinator look instead of one automatic fix round.
  """

  @tag "[FABRICATED-EVIDENCE]"
  @marker "ReviewGate: reviewer flagged fabricated or falsified evidence"

  @integrity ~r/\A(?:fabricat\w*|falsified|falsification|forged|forgery|forgeries|doctored|misrepresent\w*)\z/i
  @pass_off ~r/\A(?:pass|passed|passes|passing)\z/i
  @negation ~r/\A(?:no|not|never|nothing|none|without|neither|nor|\w+n't)\z/i
  @evidence ~r/\b(?:screenshots?|screen-?caps?|captures?|images?|mock-?ups?|citations?|cited|sources?|sourced|provenance|attributions?|credits?|credited|evidence|artifacts?|artefacts?|artwork|assets?|logos?|icons?|marks?|licen[cs]es?|proof|verification|benchmarks?|test\s+(?:outputs?|results?|runs?|logs?))\b/i

  @negation_window 3
  @evidence_window 8

  @doc "The tag a reviewer puts on a fabricated-evidence finding."
  @spec tag() :: String.t()
  def tag, do: @tag

  @doc """
  The leading sentence of a ReviewGate rejection that stopped on a
  fabricated-evidence finding. `Arbiter.Worker` keys the no-fix-round escalation
  off it, like the commit-gate markers in `Arbiter.Worker.ReviewGate`.
  """
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "Whether any line of `text` flags fabricated or falsified evidence."
  @spec flagged?(String.t() | nil) :: boolean()
  def flagged?(text), do: flagged_lines(text) != []

  @doc "The trimmed lines of `text` that flag fabricated or falsified evidence."
  @spec flagged_lines(String.t() | nil) :: [String.t()]
  def flagged_lines(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&flagged_line?/1)
  end

  def flagged_lines(_), do: []

  @doc """
  Whether a rejection's findings call for the coordinator rather than a fix
  round: the ReviewGate stopped on a fabricated-evidence finding, so
  `marker/0` leads them.

  This deliberately does not re-run `flagged?/1`. The ReviewGate is the only
  source of these findings and already ran the rule on the reviewer's own text
  in every round. What it reports on other paths (the round cap, a reviewer
  that could not start) is `escalation_payload/1`: the whole thread, the
  implementer's replies and the full diff. Scanning that would flag an
  implementer's rebuttal ("I disagree the icon source is fabricated") or any
  diff that touches this rule's own prompt text.
  """
  @spec escalation?(String.t() | nil) :: boolean()
  def escalation?(findings) when is_binary(findings),
    do: String.starts_with?(findings, @marker)

  def escalation?(_), do: false

  @doc """
  The findings a ReviewGate reports when it stops on a fabricated-evidence
  finding: `marker/0`, what happens next, the lines that flagged, then
  `payload` (the usual escalation payload with the full transcript and diff).
  """
  @spec escalation_findings(String.t(), String.t()) :: String.t()
  def escalation_findings(reviewer_findings, payload) do
    quoted = reviewer_findings |> flagged_lines() |> Enum.map_join("\n", &("> " <> &1))

    """
    #{@marker}. No further fix round was dispatched; this needs a human.

    The reviewer says the work fabricated or falsified evidence (a mockup
    presented as a screenshot, a citation to a source the thing did not come
    from, output that was never produced). Another automatic fix round would
    put the same question back to the provider that produced the evidence.
    The reviewer can also be wrong about provenance, so check the evidence it
    cites before acting on it.

    Flagged by the detection rule (`Arbiter.Worker.EvidenceIntegrity`):

    #{quoted}

    #{payload}
    """
    |> String.trim()
  end

  @doc """
  The integrity and no-public-upload block every authoring prompt carries,
  whatever the provider.
  """
  @spec worker_block() :: String.t()
  def worker_block do
    """
    EVIDENCE INTEGRITY — never fabricate evidence, citations, screenshots or
    artifacts. A screenshot must be a real capture of the real app, a source
    or licence citation must name where the thing actually came from, and a
    test result must be output you actually saw. If an acceptance criterion
    cannot be met (screenshots are not possible headlessly, an official asset
    cannot be found), report that AC as unmet: say so in the PR body and your
    notes, and leave it unmet or flagged for the reviewer and coordinator. An
    honest "not met" is always acceptable. A mockup presented as a screenshot,
    or a citation you did not verify, is not. Never change a true statement to
    satisfy a reviewer: if a finding is wrong, rebut it with the evidence.

    NO PUBLIC UPLOADS — never upload repo content, logs, images or anything
    else to a public or anonymous file or paste host (catbox.moe, litterbox,
    0x0.st, transfer.sh, file.io, pastebin and the like), never create a gist,
    and never post test or throwaway comments on issues or PRs. Uploads there
    are public, often permanent, and outside the operator's control.
    """
  end

  @doc "The fabricated-evidence reporting rule both review prompts carry."
  @spec reviewer_block() :: String.t()
  def reviewer_block do
    """
    FABRICATED EVIDENCE — if the work fabricates or falsifies evidence (a
    mockup presented as a screenshot, a citation to a source the thing did not
    come from, test output that was never produced), start that finding with
    `#{@tag}` and include evidence the coordinator can check: the URL you
    fetched, the command you ran and what it printed, a hash or byte
    comparison. That finding sends the task to the coordinator instead of
    another fix round, so be sure first. Compare against the actual source
    before you call a provenance claim false; appearance alone is not enough.
    """
  end

  # ---- internals ---------------------------------------------------------

  defp flagged_line?(""), do: false

  defp flagged_line?(line) do
    String.contains?(line, @tag) or accusation?(line)
  end

  defp accusation?(line) do
    words = Regex.scan(~r/[\w'’-]+/u, line) |> List.flatten() |> Enum.map(&normalize/1)
    indexed = Enum.with_index(words)

    Enum.any?(indexed, fn {word, i} ->
      integrity_term?(word, Enum.at(words, i + 1)) and not negated?(words, i) and
        evidence_near?(words, i)
    end)
  end

  defp normalize(word), do: String.replace(word, "’", "'")

  defp integrity_term?(word, next) do
    Regex.match?(@integrity, word) or
      (Regex.match?(@pass_off, word) and is_binary(next) and String.downcase(next) == "off")
  end

  defp negated?(words, i) do
    words
    |> Enum.slice(max(i - @negation_window, 0), min(i, @negation_window))
    |> Enum.any?(&Regex.match?(@negation, &1))
  end

  defp evidence_near?(words, i) do
    from = max(i - @evidence_window, 0)

    words
    |> Enum.slice(from, i - from + @evidence_window + 1)
    |> Enum.join(" ")
    |> then(&Regex.match?(@evidence, &1))
  end
end
